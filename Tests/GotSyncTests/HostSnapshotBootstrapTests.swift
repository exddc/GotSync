import Foundation
import os
import XCTest
@_spi(HostJournalPreview) @testable import GotSync

/// A stand-in app snapshot host: exports fixed content at the library's cut
/// and records every install and completion.
final class SnapshotTestHost: Sendable {
    struct State {
        var exports: [HostSnapshotCut] = []
        var installs: [(id: HostSnapshotID, content: Data, coverage: [Data: UInt64], appliedThrough: UInt64)] = []
        var completed: [HostSnapshotID] = []
        var blockFirstExport = false
        var blockFirstInstall = false
        var tooLarge = false
    }

    let content: Data
    let state = OSAllocatedUnfairLock(initialState: State())

    init(content: Data) {
        self.content = content
    }

    func hooks(_ schema: HostSnapshotSchema) -> HostSnapshotHooks {
        HostSnapshotHooks(
            schema: schema,
            export: { [self] cut in
                let block = state.withLock { state in
                    state.exports.append(cut)
                    defer { state.blockFirstExport = false }
                    return state.blockFirstExport
                }
                if block { try await Task.sleep(for: .seconds(120)) }
                if state.withLock({ $0.tooLarge }) { return .tooLarge }
                try content.write(to: cut.destination)
                return .exported(HostSnapshotExport(appliedThrough: cut.appliedThrough, capturedThrough: cut.capturedThrough))
            },
            install: { [self] install in
                let bytes = try Data(contentsOf: install.file)
                let block = state.withLock { state in
                    defer { state.blockFirstInstall = false }
                    if !state.installs.contains(where: { $0.id == install.id }) {
                        state.installs.append((install.id, bytes, install.coverage, install.appliedThrough?.rawValue ?? 0))
                    }
                    return state.blockFirstInstall
                }
                if block { try await Task.sleep(for: .seconds(120)) }
                return .installed
            },
            completed: { [self] id in
                state.withLock { $0.completed.append(id) }
            }
        )
    }
}

extension HostEngineTests {
    private var snapshotSchema: HostSnapshotSchema { try! HostSnapshotSchema(label: "test.state", version: 1) }

    private func snapshotEngine(_ name: String, host: SnapshotTestHost?, schema: HostSnapshotSchema? = nil) -> SyncEngine {
        let created = engine(name)
        created.snapshotRelayProtocolsForTesting = [FakeBlobRelay.self]
        if let host {
            created.registerSnapshotHost(host.hooks(schema ?? snapshotSchema))
        }
        return created
    }

    private func bootstrap(_ engine: SyncEngine) -> HostSnapshotPhase? {
        (try? store(engine))?.view.bootstrap?.phase
    }

    func testSnapshotBootstrapInstallsTheProviderStateAndDeliversOnlyTheTail() async throws {
        FakeBlobRelay.reset()
        let provider = SnapshotTestHost(content: Data((0..<9_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }))
        let joiner = SnapshotTestHost(content: Data())
        let a = snapshotEngine("a", host: provider)
        let b = snapshotEngine("b", host: joiner)
        try await pair(a, b)
        try await enroll(a, "a")
        try await submit(a, "a", ["one", "two", "three"])
        try await ready(a, "a")
        try await enroll(b, "b")
        try await wait("snapshot installed", timeout: .seconds(60)) { self.bootstrap(b) == .completed }

        let installs = joiner.state.withLock { $0.installs }
        XCTAssertEqual(installs.count, 1)
        XCTAssertEqual(installs.first?.content, provider.content, "two chunks reassemble to the exported bytes")
        let origin = try store(a).view.origin
        XCTAssertEqual(installs.first?.coverage, [origin: 3])
        XCTAssertEqual(installs.first?.appliedThrough, 3)
        XCTAssertEqual(joiner.state.withLock { $0.completed }, installs.map(\.id))
        XCTAssertEqual(provider.state.withLock { $0.exports.count }, 1)
        XCTAssertEqual(provider.state.withLock { $0.exports.first?.capturedThrough }, 3)
        let applied1 = try await applyAll(b, "b")
        XCTAssertEqual(applied1, [], "covered records are not delivered")
        XCTAssertTrue(try store(b).view.historyApplied)
        XCTAssertEqual(try store(b).view.retainedCount, 3, "every covered record stays retained")
        XCTAssertEqual(b.hostJournalView?.journal?.bootstrap, .completed(try XCTUnwrap(installs.first?.id)))

        try await submit(a, "a", ["four"])
        try await wait("tail record") { (try? self.store(b).view.delivered) == 4 }
        let applied2 = try await applyAll(b, "b")
        XCTAssertEqual(applied2, [Data("four".utf8)])
        let joinerFingerprint = try await fingerprint(b)
        XCTAssertNil(a.snapshotExport(for: joinerFingerprint), "the provider dropped its export once offered")
    }

    func testAnInstallInterruptedByRestartIsAskedAgainWithTheSameSnapshot() async throws {
        FakeBlobRelay.reset()
        let provider = SnapshotTestHost(content: Data(repeating: 0x42, count: 4_096))
        let joiner = SnapshotTestHost(content: Data())
        joiner.state.withLock { $0.blockFirstInstall = true }
        let a = snapshotEngine("a", host: provider)
        var b = snapshotEngine("b", host: joiner)
        try await pair(a, b)
        try await enroll(a, "a")
        try await submit(a, "a", ["one", "two"])
        try await ready(a, "a")
        try await enroll(b, "b")
        try await wait("install started", timeout: .seconds(60)) { joiner.state.withLock { $0.installs.count } == 1 }
        XCTAssertEqual(bootstrap(b), .installing)

        await b.stop()
        engines.removeAll { $0 === b }
        b = snapshotEngine("b", host: joiner)
        await opened(b)
        XCTAssertEqual(bootstrap(b), .installing, "the durable phase survives the restart")
        try await enroll(b, "b")
        try await wait("completed after restart", timeout: .seconds(60)) { self.bootstrap(b) == .completed }
        let installs = joiner.state.withLock { $0.installs }
        XCTAssertEqual(installs.count, 1, "the repeated install carried the same snapshot ID")
        XCTAssertEqual(joiner.state.withLock { $0.completed }, installs.map(\.id))
        let applied3 = try await applyAll(b, "b")
        XCTAssertEqual(applied3, [])
    }

    func testAnExportCancelledByRestartIsRedoneUnderANewIDAndTheStaleOneNeverOffered() async throws {
        FakeBlobRelay.reset()
        let provider = SnapshotTestHost(content: Data(repeating: 0x17, count: 2_048))
        provider.state.withLock { $0.blockFirstExport = true }
        let joiner = SnapshotTestHost(content: Data())
        var a = snapshotEngine("a", host: provider)
        let b = snapshotEngine("b", host: joiner)
        try await pair(a, b)
        try await enroll(a, "a")
        try await submit(a, "a", ["one"])
        try await ready(a, "a")
        try await enroll(b, "b")
        try await wait("first export started", timeout: .seconds(60)) { provider.state.withLock { $0.exports.count } == 1 }

        await a.stop()
        engines.removeAll { $0 === a }
        a = snapshotEngine("a", host: provider)
        await opened(a)
        try await wait("completed", timeout: .seconds(60)) { self.bootstrap(b) == .completed }
        let exports = provider.state.withLock { $0.exports }
        let installs = joiner.state.withLock { $0.installs }
        XCTAssertEqual(exports.count, 2)
        XCTAssertNotEqual(exports[0].id, exports[1].id)
        XCTAssertEqual(installs.map(\.id), [exports[1].id], "the cancelled export's ID was never offered")
    }

    func testAnUnsupportedSchemaRefusesVisiblyAndDeliversFullHistory() async throws {
        FakeBlobRelay.reset()
        let provider = SnapshotTestHost(content: Data(repeating: 1, count: 64))
        let joiner = SnapshotTestHost(content: Data())
        let a = snapshotEngine("a", host: provider, schema: try HostSnapshotSchema(label: "test.state", version: 2))
        let b = snapshotEngine("b", host: joiner)
        try await pair(a, b)
        try await enroll(a, "a")
        try await submit(a, "a", ["one", "two"])
        try await ready(a, "a")
        try await enroll(b, "b")
        try await wait("refused") { self.bootstrap(b) == .refused }
        XCTAssertEqual(b.hostJournalView?.journal?.bootstrap, .refused(.schemaMismatch))
        XCTAssertEqual(provider.state.withLock { $0.exports.count }, 0)
        let applied4 = try await applyAll(b, "b")
        XCTAssertEqual(applied4, [Data("one".utf8), Data("two".utf8)])
        XCTAssertTrue(try store(b).view.historyApplied)
    }

    func testAnOversizeHostExportReportsTooLargeAndPreservesFullHistory() async throws {
        FakeBlobRelay.reset()
        let provider = SnapshotTestHost(content: Data())
        provider.state.withLock { $0.tooLarge = true }
        let joiner = SnapshotTestHost(content: Data())
        let a = snapshotEngine("a", host: provider)
        let b = snapshotEngine("b", host: joiner)
        try await pair(a, b)
        try await enroll(a, "a")
        try await submit(a, "a", ["one"])
        try await ready(a, "a")
        try await enroll(b, "b")
        try await wait("oversize refused") { self.bootstrap(b) == .refused }
        XCTAssertEqual(b.hostJournalView?.journal?.bootstrap, .refused(.tooLarge))
        XCTAssertEqual(joiner.state.withLock { $0.installs.count }, 0)
        let received = try await applyAll(b, "b")
        XCTAssertEqual(received, [Data("one".utf8)])
        XCTAssertTrue(try store(b).view.historyApplied)
    }

    func testMissingSnapshotContentRefusesVisiblyAndKeepsTheOfferAndFullHistory() async throws {
        FakeBlobRelay.reset()
        let provider = SnapshotTestHost(content: Data(repeating: 9, count: 2_048))
        let joiner = SnapshotTestHost(content: Data())
        let a = snapshotEngine("a", host: provider)
        let b = snapshotEngine("b", host: joiner)
        b.snapshotUnavailableLimitForTesting = .milliseconds(200)
        try await pair(a, b)
        try await wait("requested") { self.bootstrap(b) == .requested }
        b.registerSnapshotHost(nil)
        try await enroll(a, "a")
        try await submit(a, "a", ["one"])
        try await ready(a, "a")
        try await enroll(b, "b")
        try await wait("offered", timeout: .seconds(60)) { self.bootstrap(b) == .offered && (try? self.store(b).view.historyComplete) == true }
        let applied5 = try await applyAll(b, "b")
        XCTAssertEqual(applied5, [], "delivery stays held while the offer waits for the host")
        FakeBlobRelay.reset()
        b.registerSnapshotHost(joiner.hooks(snapshotSchema))
        try await wait("refused", timeout: .seconds(60)) { self.bootstrap(b) == .refused }
        XCTAssertEqual(b.hostJournalView?.journal?.bootstrap, .refused(.contentUnavailable))
        XCTAssertNotNil(try store(b).view.bootstrap?.offer, "the offer is preserved")
        XCTAssertEqual(joiner.state.withLock { $0.installs.count }, 0)
        let applied6 = try await applyAll(b, "b")
        XCTAssertEqual(applied6, [Data("one".utf8)])
    }
}
