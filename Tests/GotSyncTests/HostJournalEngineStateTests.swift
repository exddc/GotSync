import Foundation
import XCTest
@_spi(HostJournalPreview) @testable import GotSync

/// Format 2 journal state used by the engine: readiness, completion,
/// establishment, control repair, window verification and record selection.
@MainActor
final class HostJournalEngineStateTests: XCTestCase {
    private var directory: URL!
    private let provider = Data(repeating: 0xAB, count: 32)

    override func setUp() async throws {
        directory = try JournalFixture.directory()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func resumed(founder: Bool = false) throws -> HostJournalStore {
        let store = try HostJournalStore.create(in: directory, group: JournalFixture.group, founder: founder)
        _ = try store.resume(try store.enroll())
        return store
    }

    func testFormatOnePreviewJournalIsRejectedPreservingBytes() throws {
        let store = try HostJournalStore.create(in: directory, group: JournalFixture.group)
        try JournalFixture.tamper(store.url, "PRAGMA user_version = 1")
        let before = JournalFixture.storedState(store.url)
        XCTAssertThrowsError(try HostJournalStore.open(store.url)) { XCTAssertEqual($0 as? JournalStoreError, .formatUnsupported(1)) }
        XCTAssertEqual(JournalFixture.storedState(store.url), before)
    }

    func testFounderStartsCompleteAndJoinerStartsIncomplete() throws {
        let founder = try HostJournalStore.create(in: directory, group: JournalFixture.group, founder: true)
        XCTAssertTrue(founder.view.historyComplete)
        XCTAssertTrue(founder.view.historyApplied)
        XCTAssertEqual(founder.view.completionPosition, 0)
        let joiner = try HostJournalStore.create(in: directory, group: JournalFixture.group)
        XCTAssertFalse(joiner.view.historyComplete)
        XCTAssertFalse(joiner.view.historyApplied)
        XCTAssertEqual(try HostJournalStore.open(joiner.url).view, joiner.view)
    }

    func testCompletionNeedsCoverageAndApplicationNeedsItsPosition() throws {
        let store = try resumed()
        let a = try JournalFixture.chain(JournalFixture.origin(2), count: 3)
        let b = try JournalFixture.chain(JournalFixture.origin(3), count: 2)
        _ = try store.intake([a[0], b[0], a[1], b[1], a[2]].enumerated().map { JournalFixture.arrival([$0.element], cursor: UInt64($0.offset + 1)) })
        XCTAssertTrue(try store.recordCompletionTarget(provider: provider, through: [a[0].origin: 2, b[0].origin: 2]))
        XCTAssertTrue(store.view.historyComplete)
        XCTAssertEqual(store.view.completionPosition, 4)
        XCTAssertEqual(store.view.completionProvider, provider)
        XCTAssertFalse(store.view.historyApplied)
        try store.markApplied(through: 3)
        XCTAssertFalse(store.view.historyApplied)
        try store.markApplied(through: 4)
        XCTAssertTrue(store.view.historyApplied)
        XCTAssertEqual(try HostJournalStore.open(store.url).view, store.view)
    }

    func testTargetBeforeRecordsCompletesInsideTheIntakeThatCoversIt() throws {
        let store = try resumed()
        let run = try JournalFixture.chain(JournalFixture.origin(2), count: 3)
        XCTAssertTrue(try store.recordCompletionTarget(provider: provider, through: [run[0].origin: 3]))
        XCTAssertFalse(store.view.historyComplete)
        _ = try store.intake([JournalFixture.arrival(Array(run[..<2]), cursor: 1)])
        XCTAssertFalse(store.view.historyComplete)
        _ = try store.intake([JournalFixture.arrival([run[2]], cursor: 2)])
        XCTAssertTrue(store.view.historyComplete)
        XCTAssertEqual(store.view.completionPosition, 3)
    }

    func testATargetIsNeverLoweredAndCompletionIsNotReopened() throws {
        let store = try resumed()
        let a = JournalFixture.origin(2)
        let b = JournalFixture.origin(3)
        XCTAssertTrue(try store.recordCompletionTarget(provider: provider, through: [a: 5, b: 2]))
        let weaker = Data(repeating: 0xCD, count: 32)
        XCTAssertFalse(try store.recordCompletionTarget(provider: weaker, through: [a: 6, b: 1]))
        XCTAssertFalse(try store.recordCompletionTarget(provider: weaker, through: [a: 5]))
        XCTAssertEqual(store.view.completionTarget, [a: 5, b: 2])
        XCTAssertEqual(store.view.completionProvider, provider)
        XCTAssertTrue(try store.recordCompletionTarget(provider: weaker, through: [a: 6, b: 2]))
        XCTAssertEqual(store.view.completionTarget, [a: 6, b: 2])
        XCTAssertEqual(store.view.completionProvider, weaker)
        let founder = try resumed(founder: true)
        XCTAssertFalse(try founder.recordCompletionTarget(provider: provider, through: [a: 1]))
        XCTAssertNil(founder.view.completionTarget)
    }

    func testReadinessNeedsTheCaptureToBeSubmitted() throws {
        let store = try resumed(founder: true)
        XCTAssertThrowsError(try store.declareReady(capturedThrough: 1)) { XCTAssertEqual($0 as? JournalStoreError, .hostCaptureRegressed) }
        XCTAssertFalse(store.view.isReady)
        _ = try store.submit([HostJournalMutation(id: JournalFixture.mutationID(1), payload: Data("seed".utf8))], capturedThrough: 1)
        try store.declareReady(capturedThrough: 1)
        XCTAssertTrue(store.view.isReady)
        XCTAssertEqual(store.view.readyThrough, 1)
        let empty = try resumed(founder: true)
        try empty.declareReady(capturedThrough: 0)
        XCTAssertTrue(empty.view.isReady)
        let unresumed = try HostJournalStore.open(empty.url)
        XCTAssertThrowsError(try unresumed.declareReady(capturedThrough: 0)) { XCTAssertEqual($0 as? JournalStoreError, .notResumed) }
        XCTAssertTrue(unresumed.view.isReady)
    }

    func testEstablishmentControlRepairAndHistoryProviderPersist() throws {
        let store = try HostJournalStore.create(in: directory, group: JournalFixture.group)
        XCTAssertFalse(store.view.established)
        try store.markEstablished()
        try store.enterControlRepair()
        try store.setHistoryProvider(provider)
        let reopened = try HostJournalStore.open(store.url)
        XCTAssertTrue(reopened.view.established)
        XCTAssertTrue(reopened.view.controlRepair)
        XCTAssertEqual(reopened.view.historyProvider, provider)
    }

    func testCorruptEngineStateIsRejectedPreservingBytes() throws {
        let store = try resumed()
        _ = try store.intake([JournalFixture.arrival(try JournalFixture.chain(JournalFixture.origin(2), count: 1), cursor: 1)])
        _ = try store.recordCompletionTarget(provider: provider, through: [JournalFixture.origin(2): 1])
        for (damage, reason) in [
            ("UPDATE meta SET value = 2 WHERE key = 'established'", "meta established"),
            ("UPDATE meta SET value = x'0102' WHERE key = 'completionTarget'", "vector"),
            ("UPDATE meta SET value = x'00' WHERE key = 'historyProvider'", "meta historyProvider"),
            ("UPDATE meta SET value = 9 WHERE key = 'readyThrough'", "ready"),
            ("UPDATE meta SET value = 5 WHERE key = 'completionPosition'", "positions"),
        ] {
            let copy = directory.appendingPathComponent("copy-\(UUID().uuidString).sqlite3")
            try FileManager.default.copyItem(at: store.url, to: copy)
            try JournalFixture.tamper(copy, damage)
            let before = JournalFixture.storedState(copy)
            XCTAssertThrowsError(try HostJournalStore.open(copy), damage) { XCTAssertEqual($0 as? JournalStoreError, .storeCorrupt(reason), damage) }
            XCTAssertEqual(JournalFixture.storedState(copy), before, damage)
        }
    }

    func testWindowVerificationFindsALateForkWithoutWriting() throws {
        let store = try resumed()
        let origin = JournalFixture.origin(2)
        let run = try JournalFixture.chain(origin, count: 2)
        _ = try store.intake([JournalFixture.arrival([run[0]], cursor: 1)])
        let conflicting = try JournalEnvelope(origin: origin, sequence: 1, prior: JournalEnvelope.zeroDigest, payload: Data("other".utf8))
        let window = [
            JournalFixture.arrival(try JournalFixture.chain(JournalFixture.origin(3), count: 3), cursor: 2),
            JournalFixture.arrival([run[1]], cursor: 3),
            JournalFixture.arrival([conflicting], cursor: 4),
        ]
        let before = JournalFixture.storedState(store.url)
        let view = store.view
        XCTAssertThrowsError(try store.verify(window)) { XCTAssertEqual($0 as? JournalStoreError, .fork(origin: origin, sequence: 1)) }
        XCTAssertNoThrow(try store.verify(Array(window[..<2])))
        XCTAssertEqual(JournalFixture.storedState(store.url), before)
        XCTAssertEqual(store.view, view)
    }

    func testRecordSelectionFollowsVectorCutAndBounds() throws {
        let store = try resumed()
        let a = try JournalFixture.chain(JournalFixture.origin(2), count: 4, payload: { _ in Data(count: 100) })
        let b = try JournalFixture.chain(JournalFixture.origin(3), count: 2, payload: { _ in Data(count: 100) })
        _ = try store.intake([JournalFixture.arrival(a, cursor: 1), JournalFixture.arrival(b, cursor: 2)])
        _ = try store.submit([HostJournalMutation(id: JournalFixture.mutationID(1), payload: Data("own".utf8))], capturedThrough: 1)
        let origin = store.view.origin
        XCTAssertEqual(try store.receivedVector(), [a[0].origin: 4, b[0].origin: 2, origin: 1])
        let all = try store.records(missingFrom: [a[0].origin: 1], through: nil, maxBytes: 1 << 20, maxCount: 100)
        XCTAssertEqual(Set(all.map(\.id)), Set((Array(a[1...]) + b).map(\.id) + [JournalRecordID(origin: origin, sequence: 1)]))
        XCTAssertEqual(all.filter { $0.origin == a[0].origin }.map(\.sequence), [2, 3, 4])
        let cut = try store.records(missingFrom: [:], through: [a[0].origin: 2, b[0].origin: 1], maxBytes: 1 << 20, maxCount: 100)
        XCTAssertEqual(cut.map(\.id), [a[0].id, a[1].id, b[0].id])
        let bounded = try store.records(missingFrom: [:], through: nil, maxBytes: 330, maxCount: 100)
        XCTAssertEqual(bounded.count, 2)
        XCTAssertEqual(try store.records(missingFrom: [:], through: nil, maxBytes: 10, maxCount: 100).count, 1)
        XCTAssertEqual(try store.ownRecords(after: 0, maxBytes: 1 << 20, maxCount: 10).map(\.payload), [Data("own".utf8)])
        XCTAssertEqual(try store.ownRecords(after: 1, maxBytes: 1 << 20, maxCount: 10), [])
    }
}
