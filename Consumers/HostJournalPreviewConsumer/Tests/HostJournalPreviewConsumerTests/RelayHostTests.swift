import Foundation
@_spi(HostJournalPreview) import GotSync
@_spi(HostJournalPreview) import HostJournalPreviewConsumer
import XCTest

@MainActor
final class RelayHostTests: XCTestCase {
    private var relayURL: URL!
    private var mailboxURL: URL!
    private var root: URL!
    private var engines: [SyncEngine] = []
    private let profile = try! SyncGroupProfile(
        application: "org.gotsync.host-consumer", schema: .hostJournal(payload: "consumer.registers", version: 1),
        memberLimit: 2
    )

    override func setUp() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GOTSYNC_INTEGRATION"] == "1" else {
            if environment["GOTSYNC_REQUIRE_INTEGRATION"] == "1" {
                XCTFail("The required relay integration environment is missing.")
            }
            throw XCTSkip("Run scripts/test-host-consumer.sh to start the real relay.")
        }
        relayURL = try XCTUnwrap(URL(string: environment["GOTSYNC_RELAY_URL"] ?? ""))
        mailboxURL = try XCTUnwrap(URL(string: environment["GOTSYNC_MAILBOX_URL"] ?? ""))
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for engine in engines { await engine.stop() }
        engines = []
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testTwoHostsExchangeRecordsThroughThePreviewSPI() async throws {
        let secrets = (MemorySecrets(), MemorySecrets())
        var first = start("first", secrets.0)
        let second = start("second", secrets.1)

        var changes = first.hostViewChanges().makeAsyncIterator()
        let initial = await changes.next()
        XCTAssertNotNil(initial, "the stream starts with the current revision")

        try await pair(first, second)
        let firstHost = try ReferenceHost(url: root.appendingPathComponent("first.json"))
        let secondHost = try ReferenceHost(url: root.appendingPathComponent("second.json"))
        try firstHost.capture("color", "blue")
        try secondHost.capture("shape", "round")

        let firstJournal = try await activeJournal(first)
        let secondJournal = try await activeJournal(second)
        try await firstHost.enrollOrResume(firstJournal)
        try await secondHost.enrollOrResume(secondJournal)

        let refused = try await secondHost.declareReadyIfSubmitted(secondJournal)
        XCTAssertFalse(refused, "readiness stays closed while a captured row is unsent")
        XCTAssertEqual(second.hostJournalView?.journal?.isReady, false)

        try await firstHost.submitOutbox(firstJournal)
        try await secondHost.submitOutbox(secondJournal)
        XCTAssertTrue(firstHost.state.outbox.isEmpty)
        let firstReady = try await firstHost.declareReadyIfSubmitted(firstJournal)
        let secondReady = try await secondHost.declareReadyIfSubmitted(secondJournal)
        XCTAssertTrue(firstReady && secondReady)

        try await converge([(first, firstHost), (second, secondHost)])
        XCTAssertEqual(firstHost.state.registers, ["color": "blue", "shape": "round"])
        XCTAssertEqual(secondHost.state.registers, firstHost.state.registers)

        await first.stop()
        engines.removeAll { $0 === first }
        XCTAssertNil(first.hostJournal)
        do {
            _ = try await firstJournal.submit([HostMutation(id: HostMutationID(UUID()), payload: Data())], capturedThrough: 2)
            XCTFail("a stopped engine's handle stays fenced")
        } catch let error as HostJournalError {
            XCTAssertEqual(error, .fenced)
        }

        first = start("first", secrets.0)
        let relaunched = try ReferenceHost(url: root.appendingPathComponent("first.json"))
        XCTAssertEqual(relaunched.state, firstHost.state)
        let reopened = try await activeJournal(first)
        XCTAssertNotEqual(ObjectIdentifier(reopened), ObjectIdentifier(firstJournal))
        try await relaunched.enrollOrResume(reopened)
        try relaunched.capture("color", "green")
        try await relaunched.submitOutbox(reopened)
        try await converge([(first, relaunched), (second, secondHost)])
        XCTAssertEqual(secondHost.state.registers["color"], "green")

        let retiredID = secondJournal.journalID
        second.unlinkAndKeepTasks()
        try await wait("unlinked") { !second.isPaired && second.hostJournalView?.lifecycle == .active }
        let archives = try second.hostJournalArchives()
        let archive = try XCTUnwrap(archives.first { $0.journalID == retiredID })
        XCTAssertEqual(archive.reason, .unlink)
        XCTAssertEqual(archive.own, 1)

        var cursor: HostArchiveCursor?
        var own: [Data] = []
        var remote: [Data] = []
        repeat {
            let page = try second.exportHostJournal(retiredID, after: cursor, limit: 1)
            for item in page.items {
                switch item {
                case .own(_, _, _, let payload): own.append(payload)
                case .remote(_, _, _, _, let payload): remote.append(payload)
                default: break
                }
            }
            cursor = try page.next.map {
                try JSONDecoder().decode(HostArchiveCursor.self, from: JSONEncoder().encode($0))
            }
        } while cursor != nil
        XCTAssertEqual(own.count, 1)
        XCTAssertEqual(remote.count, 2)

        do {
            try await second.discardRetiredHostJournal(retiredID, confirmingJournalID: Data(count: 16))
            XCTFail("a wrong confirmation must not discard")
        } catch let error as HostJournalError {
            XCTAssertEqual(error, .confirmationMismatch)
        }
        try await second.discardRetiredHostJournal(retiredID, confirmingJournalID: retiredID)
        XCTAssertFalse(try second.hostJournalArchives().contains { $0.journalID == retiredID })
    }

    func testSmallOutboxRowsRespectTheRecordCountLimit() async throws {
        let first = start("first", MemorySecrets())
        let second = start("second", MemorySecrets())
        try await pair(first, second)
        let host = try ReferenceHost(url: root.appendingPathComponent("host.json"))
        let journal = try await activeJournal(first)
        try await host.enrollOrResume(journal)
        for index in 0..<257 { try host.capture("r\(index)", "v") }
        try await host.submitOutbox(journal)
        XCTAssertTrue(host.state.outbox.isEmpty)
        XCTAssertEqual(first.hostJournalView?.journal?.capturedThrough, 257)
        XCTAssertEqual(first.hostJournalView?.journal?.retainedCount, 257)
    }

    func testFailedOutboxSaveRetainsAcceptedRowsForAnIdempotentRetry() async throws {
        let first = start("first", MemorySecrets())
        let second = start("second", MemorySecrets())
        try await pair(first, second)
        let directory = root.appendingPathComponent("host-state")
        let displaced = root.appendingPathComponent("displaced-state")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let host = try ReferenceHost(url: directory.appendingPathComponent("host.json"))
        let journal = try await activeJournal(first)
        try await host.enrollOrResume(journal)
        try host.capture("r", "v")
        let before = host.state
        try FileManager.default.moveItem(at: directory, to: displaced)
        do {
            try await host.submitOutbox(journal)
            XCTFail("the local save unexpectedly succeeded without its directory")
        } catch is HostJournalError {
            XCTFail("submission failed before the local save")
        } catch {}
        XCTAssertEqual(host.state, before)
        XCTAssertEqual(first.hostJournalView?.journal?.retainedCount, 1)
        let ready = try await host.declareReadyIfSubmitted(journal)
        XCTAssertFalse(ready)
        try FileManager.default.moveItem(at: displaced, to: directory)
        try await host.submitOutbox(journal)
        XCTAssertTrue(host.state.outbox.isEmpty)
        XCTAssertEqual(first.hostJournalView?.journal?.retainedCount, 1)
        XCTAssertEqual(try ReferenceHost(url: host.url).state, host.state)
    }

    func testPersistedApplicationWatermarkIsAcknowledgedOnRetryWithoutNewTraffic() async throws {
        let first = start("first", MemorySecrets())
        let second = start("second", MemorySecrets())
        try await pair(first, second)
        let firstHost = try ReferenceHost(url: root.appendingPathComponent("first.json"))
        let secondHost = try ReferenceHost(url: root.appendingPathComponent("second.json"))
        let firstJournal = try await activeJournal(first)
        let secondJournal = try await activeJournal(second)
        try await firstHost.enrollOrResume(firstJournal)
        try await secondHost.enrollOrResume(secondJournal)
        try firstHost.capture("color", "blue")
        try await firstHost.submitOutbox(firstJournal)
        _ = try await firstHost.declareReadyIfSubmitted(firstJournal)
        _ = try await secondHost.declareReadyIfSubmitted(secondJournal)
        try await wait("incoming record and completed history") {
            (try? await secondJournal.incoming(after: nil, limit: 64).count) == 1
                && second.hostJournalView?.journal?.historyComplete == true
        }

        let inbox = FailingAcknowledgementInbox(secondJournal)
        do {
            _ = try await secondHost.applyIncoming(inbox)
            XCTFail("the first acknowledgement unexpectedly succeeded")
        } catch FailingAcknowledgementInbox.Failure.transient {}

        let position = try XCTUnwrap(secondHost.state.appliedThrough)
        let saved = try Data(contentsOf: secondHost.url)
        XCTAssertEqual(try ReferenceHost(url: secondHost.url).state, secondHost.state)
        XCTAssertEqual(secondHost.state.registers, ["color": "blue"])
        XCTAssertNil(second.hostJournalView?.journal?.appliedThrough)
        XCTAssertEqual(second.hostJournalView?.journal?.historyApplied, false)

        let applied = try await secondHost.applyIncoming(inbox)
        XCTAssertEqual(applied, 0)
        XCTAssertEqual(inbox.acknowledgements, [position, position])
        XCTAssertEqual(try Data(contentsOf: secondHost.url), saved)
        XCTAssertEqual(second.hostJournalView?.journal?.appliedThrough, position)
        XCTAssertEqual(second.hostJournalView?.journal?.historyApplied, true)
        guard second.hostJournalView?.journal?.appliedThrough == position else { return }
        try await converge([(first, firstHost), (second, secondHost)])
    }

    // MARK: - Harness

    private func start(_ name: String, _ secrets: MemorySecrets) -> SyncEngine {
        let configuration = try! SyncConfiguration(
            relayURL: relayURL,
            mailboxURL: mailboxURL,
            storageDirectory: root.appendingPathComponent(name),
            invitationURLScheme: "gotsync-consumer",
            endpointPolicy: .localDevelopment,
            groupProfile: profile
        )
        let engine = SyncEngine(configuration: configuration, secretStore: secrets, pairingRetryDelayNanoseconds: 100_000_000)
        engines.append(engine)
        return engine
    }

    private func pair(_ inviter: SyncEngine, _ joiner: SyncEngine) async throws {
        try await wait("invitation") {
            if inviter.invitationURL == nil { inviter.createPrivateSync() }
            return inviter.invitationURL != nil
        }
        joiner.joinPrivateSync(url: try XCTUnwrap(inviter.invitationURL))
        try await wait("safety code") { inviter.isHostApprovalPending && joiner.safetyCode != nil }
        XCTAssertEqual(inviter.safetyCode, joiner.safetyCode)
        inviter.approveSafetyCode()
        try await wait("paired") { inviter.isPaired && joiner.isPaired && !inviter.canCancelPairing }
    }

    private func activeJournal(_ engine: SyncEngine) async throws -> HostJournal {
        try await wait("active journal") { engine.hostJournalView?.lifecycle == .active && engine.hostJournal != nil }
        return try XCTUnwrap(engine.hostJournal)
    }

    private func converge(_ hosts: [(SyncEngine, ReferenceHost)]) async throws {
        try await wait("converged") {
            var heads: Set<UInt64> = []
            for (engine, host) in hosts {
                guard let journal = engine.hostJournal, (try? await host.applyIncoming(journal)) != nil,
                      let view = engine.hostJournalView, let state = view.journal,
                      state.historyApplied, view.isQuiescent, engine.phase == .synced
                else { return false }
                heads.insert(state.undelivered)
            }
            return Set(hosts.map { $0.1.state.registers }).count == 1 && heads == [0]
        }
    }

    private func wait(_ stage: String, file: StaticString = #filePath, line: UInt = #line, until predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        while await !predicate() {
            guard ContinuousClock.now < deadline else {
                let details = engines.map {
                    "\($0.phase) lifecycle=\(String(describing: $0.hostJournalView?.lifecycle)) repair=\(String(describing: $0.hostJournalView?.repair))"
                }.joined(separator: "; ")
                XCTFail("Timed out at \(stage): \(details)", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

@MainActor
private final class FailingAcknowledgementInbox: ReferenceHostInbox {
    enum Failure: Error { case transient }

    private let journal: HostJournal
    private(set) var acknowledgements: [JournalPosition] = []

    init(_ journal: HostJournal) { self.journal = journal }

    func incoming(after position: JournalPosition?, limit: Int) async throws -> [IncomingRecord] {
        try await journal.incoming(after: position, limit: limit)
    }

    func markApplied(through position: JournalPosition) async throws {
        acknowledgements.append(position)
        if acknowledgements.count == 1 { throw Failure.transient }
        try await journal.markApplied(through: position)
    }
}
