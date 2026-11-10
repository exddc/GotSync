import Foundation
import XCTest
@_spi(HostJournalPreview) @testable import GotSync

@MainActor
final class HostJournalArchiveTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = try JournalFixture.directory()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func enrolled() throws -> (HostJournalStore, HostStandIn) {
        let store = try HostJournalStore.create(in: directory, group: JournalFixture.group)
        let host = try HostStandIn(url: directory.appendingPathComponent("host-\(UUID().uuidString).json"))
        try host.save(try store.enroll())
        _ = try store.resume(XCTUnwrap(host.provenance))
        return (store, host)
    }

    func testRetiredExportReturnsEveryOwnedClassWithExactBytes() throws {
        let (store, host) = try enrolled()
        let firstID = try host.capture(Data("one".utf8))
        let secondID = try host.capture(Data("two".utf8))
        _ = try host.submitOutbox(store)
        XCTAssertTrue(host.state.outbox.isEmpty)
        let remote = try JournalFixture.chain(JournalFixture.origin(2), count: 3)
        let gap = try JournalFixture.chain(JournalFixture.origin(3), count: 1, from: 3, prior: Data(repeating: 6, count: 32))
        let senderB = Data(repeating: 0xD1, count: 32)
        _ = try store.intake([
            JournalFixture.arrival(remote, cursor: 10),
            JournalFixture.arrival(gap, cursor: 11),
            JournalFixture.raw(Data("unknown b".utf8), cursor: 12, sender: senderB),
            JournalFixture.raw(Data("unknown a".utf8), cursor: 13),
        ])
        let applied = try store.incoming(after: 0, limit: 2)
        try store.markApplied(through: try XCTUnwrap(applied.last).position)
        let held = [
            HostJournalHeldMessage(sender: senderB, cursor: 14, plaintext: Data("held b".utf8)),
            HostJournalHeldMessage(sender: JournalFixture.sender, cursor: 15, plaintext: Data([0, 1, 2])),
        ]
        try store.retire(.unlink, heldInbox: held)

        let own = try (1...2).map { sequence -> HostJournalExportItem in
            let payload = Data(sequence == 1 ? "one".utf8 : "two".utf8)
            let prior = sequence == 1 ? JournalEnvelope.zeroDigest
                : try JournalEnvelope(origin: store.view.origin, sequence: 1, prior: JournalEnvelope.zeroDigest, payload: Data("one".utf8)).digest
            let envelope = try JournalEnvelope(origin: store.view.origin, sequence: UInt64(sequence), prior: prior, payload: payload)
            return .own(sequence: UInt64(sequence), mutationID: sequence == 1 ? firstID : secondID, envelope: envelope.bytes)
        }
        let expected: [HostJournalExportItem] = own + remote.enumerated().map {
            .remote(position: UInt64($0.offset + 1), origin: $0.element.origin, sequence: $0.element.sequence,
                    applied: $0.offset < 2, envelope: $0.element.bytes)
        } + [
            .pending(origin: gap[0].origin, sequence: 3, envelope: gap[0].bytes),
            .quarantined(sender: JournalFixture.sender, cursor: 13, reason: "undecodable", bytes: Data("unknown a".utf8)),
            .quarantined(sender: senderB, cursor: 12, reason: "undecodable", bytes: Data("unknown b".utf8)),
            .held(sender: JournalFixture.sender, cursor: 15, plaintext: Data([0, 1, 2])),
            .held(sender: senderB, cursor: 14, plaintext: Data("held b".utf8)),
        ]
        let url = store.url
        for pageSize in [1, 2, 3, 5, 100] {
            XCTAssertEqual(try JournalFixture.exportAll(url, pageSize: pageSize), expected, "page size \(pageSize)")
        }
        let before = try JournalFixture.fileHash(url)
        XCTAssertEqual(try JournalFixture.exportAll(url), expected)
        XCTAssertEqual(try JournalFixture.fileHash(url), before)
    }

    func testExportCursorsAreBoundToTheirJournalAndRevision() throws {
        let (store, _) = try enrolled()
        _ = try store.intake([JournalFixture.arrival(try JournalFixture.chain(JournalFixture.origin(2), count: 4), cursor: 1)])
        let first = try HostJournalFiles.export(store.url, after: nil, limit: 2)
        let cursor = try XCTUnwrap(first.next)
        XCTAssertEqual(try HostJournalFiles.export(store.url, after: cursor, limit: 2).items.count, 2)
        let other = try HostJournalStore.create(in: directory, group: JournalFixture.group)
        XCTAssertThrowsError(try HostJournalFiles.export(other.url, after: cursor, limit: 2)) {
            XCTAssertEqual($0 as? JournalStoreError, .exportCursorMismatch)
        }
        _ = try store.intake([JournalFixture.raw(Data("x".utf8), cursor: 2)])
        XCTAssertThrowsError(try HostJournalFiles.export(store.url, after: cursor, limit: 2)) {
            XCTAssertEqual($0 as? JournalStoreError, .exportRevisionChanged)
        }
        try store.retire(.orphaned, heldInbox: [])
        let frozen = try XCTUnwrap(try HostJournalFiles.export(store.url, after: nil, limit: 2).next)
        let reopened = try HostJournalStore.open(store.url)
        XCTAssertTrue(reopened.view.isRetired)
        XCTAssertEqual(try HostJournalFiles.export(store.url, after: frozen, limit: 10).items.count, 3)
    }

    func testDiscoveryCountsRetiredAndUnreadableButNotActiveOrIncomplete() throws {
        let active = try HostJournalStore.create(in: directory, group: JournalFixture.group)
        var retired: [HostJournalStore] = []
        for _ in 0..<3 {
            let store = try HostJournalStore.create(in: directory, group: JournalFixture.group)
            try store.retire(.unlink, heldInbox: [])
            retired.append(store)
        }
        let incomplete = URL(fileURLWithPath: HostJournalStore.fileURL(in: directory, journalID: Data(repeating: 7, count: 16)).path + ".creating")
        try Data("partial".utf8).write(to: incomplete)
        var listings = try HostJournalFiles.discover(in: directory)
        XCTAssertEqual(listings.count, 5)
        XCTAssertTrue(listings.contains(.journal(url: active.url, view: active.view)))
        XCTAssertTrue(listings.contains(.incomplete(url: incomplete)))
        XCTAssertTrue(HostJournalFiles.admitsNewLink(listings))

        let garbage = HostJournalStore.fileURL(in: directory, journalID: Data(repeating: 8, count: 16))
        try Data(repeating: 0x33, count: 4_096).write(to: garbage)
        listings = try HostJournalFiles.discover(in: directory)
        XCTAssertTrue(listings.contains { if case .unreadable(garbage, _) = $0 { true } else { false } })
        XCTAssertFalse(HostJournalFiles.admitsNewLink(listings))
        XCTAssertEqual(try Data(contentsOf: garbage), Data(repeating: 0x33, count: 4_096))
        try FileManager.default.removeItem(at: garbage)

        let fourth = try HostJournalStore.create(in: directory, group: JournalFixture.group)
        fourth.faultHookForTesting = { if $0 == .beforeCommit("retire") { throw CancellationError() } }
        XCTAssertThrowsError(try fourth.retire(.removed, heldInbox: [HostJournalHeldMessage(sender: JournalFixture.sender, cursor: 1, plaintext: Data("h".utf8))]))
        XCTAssertTrue(HostJournalFiles.admitsNewLink(try HostJournalFiles.discover(in: directory)))
        fourth.faultHookForTesting = nil
        try fourth.retire(.removed, heldInbox: [])
        XCTAssertFalse(HostJournalFiles.admitsNewLink(try HostJournalFiles.discover(in: directory)))
    }

    func testDiscardNeedsTheMatchingIDAndARetiredJournal() throws {
        let active = try HostJournalStore.create(in: directory, group: JournalFixture.group)
        let retired = try HostJournalStore.create(in: directory, group: JournalFixture.group)
        try retired.retire(.unlink, heldInbox: [])
        let keep = try HostJournalStore.create(in: directory, group: JournalFixture.group)
        try keep.retire(.unlink, heldInbox: [])
        let id = retired.view.journalID
        XCTAssertThrowsError(try HostJournalFiles.discard(in: directory, journalID: id, confirming: keep.view.journalID)) {
            XCTAssertEqual($0 as? JournalStoreError, .confirmationMismatch)
        }
        XCTAssertThrowsError(try HostJournalFiles.discard(in: directory, journalID: active.view.journalID, confirming: active.view.journalID)) {
            XCTAssertEqual($0 as? JournalStoreError, .notArchived)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: retired.url.path))
        let garbage = HostJournalStore.fileURL(in: directory, journalID: Data(repeating: 9, count: 16))
        try Data(repeating: 0x44, count: 4_096).write(to: garbage)
        XCTAssertThrowsError(try HostJournalFiles.discard(in: directory, journalID: Data(repeating: 9, count: 16), confirming: Data(repeating: 9, count: 16)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: garbage.path))
        try HostJournalFiles.discard(in: directory, journalID: id, confirming: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: retired.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.url.path))
    }
}

/// Fills every bound at its standard value and reports logical content next
/// to the actual file footprint.
@MainActor
final class HostJournalCapacityTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = try JournalFixture.directory()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func enrolled() throws -> HostJournalStore {
        let store = try HostJournalStore.create(in: directory, group: JournalFixture.group)
        let provenance = try store.enroll()
        _ = try store.resume(provenance)
        return store
    }

    private func report(_ name: String, _ store: HostJournalStore, peakSidecar: UInt64 = 0) throws {
        let accounting = try HostJournalFiles.accounting(store.url)
        let logical = accounting.categories.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.rows)/\($0.value.bytes)" }.joined(separator: " ")
        print("JOURNAL_ACCOUNTING \(name) database=\(accounting.databaseBytes) allocated=\(accounting.allocatedBytes) free=\(accounting.freeBytes) sidecar=\(accounting.sidecarBytes) peakSidecar=\(peakSidecar) \(logical)")
        let start = ContinuousClock.now
        let reopened = try HostJournalStore.open(store.url)
        print("JOURNAL_OPEN \(name) validate=\(ContinuousClock.now - start)")
        XCTAssertEqual(reopened.view, store.view)
    }

    func testMaximumRecordCount() throws {
        let store = try enrolled()
        var cursor: UInt64 = 0
        for origin in 2..<102 {
            let run = try JournalFixture.chain(JournalFixture.origin(UInt8(origin)), count: 1_200, payload: { _ in Data() })
            for start in stride(from: 0, to: run.count, by: 256) {
                cursor += 1
                let intake = try store.intake([JournalFixture.arrival(Array(run[start..<min(start + 256, run.count)]), cursor: cursor)])
                XCTAssertEqual(intake.ownedArrivals, 1)
            }
        }
        XCTAssertEqual(store.view.recordCount, 120_000)
        let extra = try JournalFixture.chain(JournalFixture.origin(200), count: 1, payload: { _ in Data() })
        XCTAssertEqual(try store.intake([JournalFixture.arrival(extra, cursor: cursor + 1)]), HostJournalIntake(ownedArrivals: 0, refusal: .history))
        try report("records.max-count", store)
    }

    func testMaximumSubmissionMappings() throws {
        let store = try enrolled()
        var index = 0
        while index < 40_000 {
            let batch = (index..<min(index + 256, 40_000)).map { HostJournalMutation(id: JournalFixture.mutationID($0), payload: Data()) }
            _ = try store.submit(batch, capturedThrough: UInt64(index + batch.count))
            index += batch.count
        }
        XCTAssertThrowsError(try store.submit([HostJournalMutation(id: JournalFixture.mutationID(40_001), payload: Data())], capturedThrough: 40_001)) {
            XCTAssertEqual($0 as? JournalStoreError, .capacity(.submitBudget))
        }
        XCTAssertEqual(store.view.ownHead, 40_000)
        try report("submissions.max-count", store)
    }

    func testMaximumHistoryBytesWithLargestPayloads() throws {
        let store = try enrolled()
        let run = try JournalFixture.chain(JournalFixture.origin(2), count: 384, payload: { Data(repeating: UInt8($0 % 251), count: 65_536) })
        var owned = 0
        for (index, envelope) in run.enumerated() {
            let intake = try store.intake([JournalFixture.arrival([envelope], cursor: UInt64(index + 1))])
            owned += intake.ownedArrivals
            if intake.refusal != nil {
                XCTAssertEqual(intake.refusal, .history)
                break
            }
        }
        XCTAssertEqual(owned, 383)
        XCTAssertLessThanOrEqual(store.view.retainedBytes, 24 * 1_024 * 1_024)
        try report("records.max-bytes", store)
    }

    func testMaximumPendingAndQuarantine() throws {
        let store = try enrolled()
        var cursor: UInt64 = 0
        for origin in 2..<42 {
            let run = try JournalFixture.chain(JournalFixture.origin(UInt8(origin)), count: 251, from: 2, prior: Data(repeating: 1, count: 32), payload: { _ in Data() })
            cursor += 1
            let intake = try store.intake([JournalFixture.arrival(run, cursor: cursor)])
            if intake.refusal != nil {
                XCTAssertEqual(intake.refusal, .pending)
                break
            }
        }
        XCTAssertLessThanOrEqual(store.view.pendingCount, 10_000)
        XCTAssertGreaterThan(store.view.pendingCount, 10_000 - 251)
        var items = 0
        while true {
            cursor += 1
            let intake = try store.intake([JournalFixture.raw(Data(repeating: 0x51, count: 4_000), cursor: cursor)])
            if intake.refusal != nil {
                XCTAssertEqual(intake.refusal, .quarantine)
                break
            }
            items += 1
        }
        XCTAssertEqual(items, 1_024)
        try report("pending-quarantine.max", store)
    }

    func testRetirementHandoffFootprint() throws {
        let store = try enrolled()
        let held = (0..<1_000).map {
            HostJournalHeldMessage(sender: JournalFixture.sender, cursor: UInt64($0 + 1), plaintext: Data(repeating: UInt8($0 % 251), count: 23_000))
        }
        let before = try HostJournalFiles.accounting(store.url).databaseBytes
        var peak: UInt64 = 0
        store.faultHookForTesting = { point in
            guard point == .beforeCommit("retire") else { return }
            peak = (try? FileManager.default.attributesOfItem(atPath: store.url.path + "-journal")[.size] as? NSNumber)?.uint64Value ?? 0
        }
        try store.retire(.removed, heldInbox: held)
        print("JOURNAL_HANDOFF databaseBefore=\(before) heldLogical=\(store.view.heldBytes)")
        try report("retirement.held-1000x23000", store, peakSidecar: peak)
    }
}
