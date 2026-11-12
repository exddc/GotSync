import Foundation
import SQLite3
import XCTest
@_spi(HostJournalPreview) @testable import GotSync

/// The journal side of a committed retention floor: removal under it, exact
/// discharge of below-floor arrivals, refusal of unproven ones, mappings
/// that survive removal, and a joiner adopting a corroborated floor.
@MainActor
final class HostRetentionStoreTests: XCTestCase {
    private var root: URL!
    private let provider = Data(repeating: 0xAB, count: 32)
    private let x = JournalFixture.origin(2)

    override func setUp() async throws {
        root = try JournalFixture.directory()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func member() throws -> HostJournalStore {
        let store = try HostJournalStore.create(in: root, group: JournalFixture.group)
        _ = try store.resume(store.enroll())
        return store
    }

    private func checkpoint(_ anchors: [HostSnapshotAnchor]) -> HostSnapshotOffer {
        HostSnapshotOffer(
            id: Data(repeating: 7, count: 16), schema: "test.state/1", anchors: anchors, length: 10,
            contentHash: Data(repeating: 1, count: 32), chunks: [Data(repeating: 2, count: 152)]
        )
    }

    private func anchors(_ records: [JournalEnvelope]) -> [HostSnapshotAnchor] {
        records.map { HostSnapshotAnchor(origin: $0.origin, sequence: $0.sequence, digest: $0.digest) }
            .sorted { $0.origin.lexicographicallyPrecedes($1.origin) }
    }

    /// A member that received and applied x1...x5 and submitted two records.
    private func caughtUpMember() throws -> (HostJournalStore, [JournalEnvelope], [JournalRecordID]) {
        let store = try member()
        let chain = try JournalFixture.chain(x, count: 5)
        _ = try store.intakeAndPromote([JournalFixture.arrival(chain, cursor: 1)])
        try store.recordCompletionTarget(provider: provider, through: [x: 5])
        try store.markApplied(through: 5)
        let own = try store.submit(
            [1, 2].map { HostJournalMutation(id: JournalFixture.mutationID($0), payload: Data("own \($0)".utf8)) }, capturedThrough: 2
        )
        try store.declareReady(capturedThrough: 2)
        return (store, chain, own)
    }

    private func ownEnvelope(_ store: HostJournalStore, _ sequence: UInt64) throws -> JournalEnvelope {
        try XCTUnwrap(store.ownRecords(after: sequence - 1, maxBytes: 1 << 20, maxCount: 1).first)
    }

    private func userVersion(_ url: URL) throws -> Int32 {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return sqlite3_column_int(statement, 0)
    }

    func testACommittedFloorRemovesItsRecordsAndKeepsEverythingElseExact() throws {
        let (store, chain, own) = try caughtUpMember()
        let floor = anchors([chain[2], try ownEnvelope(store, 1)])
        XCTAssertNil(try store.retentionDecline(floor))
        XCTAssertTrue(try store.commitRetentionFloor(round: Data(repeating: 1, count: 16), proposal: Data(repeating: 9, count: 32),
                                                    checkpoint: checkpoint(floor)))
        XCTAssertEqual(try userVersion(store.url), 3, "nothing is removed until pruning")
        XCTAssertEqual(try store.pruneBelowFloor(maxRecords: 2), 2)
        XCTAssertEqual(try store.pruneBelowFloor(), 2)
        XCTAssertEqual(try store.pruneBelowFloor(), 0)
        XCTAssertEqual(try userVersion(store.url), 4)
        XCTAssertEqual(store.view.recordCount, 3, "x4, x5 and the second own record remain")
        XCTAssertEqual(store.view.retention?.prunedRecords, 4)
        XCTAssertEqual(store.view.retention?.prunedPositions, 3)
        XCTAssertEqual(store.view.appliedThrough, 5)
        XCTAssertEqual(try store.receivedVector()[x], 5)

        let reopened = try HostJournalStore.open(store.url)
        XCTAssertEqual(reopened.view, store.view)
        let page = try HostJournalFiles.export(store.url, after: nil, limit: 10)
        guard case .checkpoint(let exported)? = page.items.first else { return XCTFail("a compacted export starts with its checkpoint") }
        XCTAssertEqual(exported.anchors, floor)
        XCTAssertEqual(page.items.count, 4, "the checkpoint, then x4, x5 and the second own record")
        _ = try reopened.resume(HostJournalProvenance(
            journalID: store.view.journalID, enrollmentID: Data(repeating: 0, count: 16), appliedThrough: 5, capturedThrough: 2
        ).withEnrollment(of: store))

        let retry = try reopened.submit([HostJournalMutation(id: JournalFixture.mutationID(1), payload: Data("own 1".utf8))], capturedThrough: 2)
        XCTAssertEqual(retry, [own[0]], "a finalized mutation ID keeps its sequence after removal")
        XCTAssertThrowsError(try reopened.submit(
            [HostJournalMutation(id: JournalFixture.mutationID(1), payload: Data("other".utf8))], capturedThrough: 2
        )) { XCTAssertEqual($0 as? JournalStoreError, .hostMutationConflict(JournalFixture.mutationID(1))) }
        let next = try reopened.submit([HostJournalMutation(id: JournalFixture.mutationID(3), payload: Data("own 3".utf8))], capturedThrough: 3)
        XCTAssertEqual(next.first?.sequence, 3)
    }

    func testACompactedArchiveCountsItsRetainedRecords() throws {
        let (store, chain, _) = try caughtUpMember()
        let floor = anchors([chain[3], try ownEnvelope(store, 2)])
        try store.commitRetentionFloor(round: Data(repeating: 1, count: 16), proposal: Data(repeating: 9, count: 32), checkpoint: checkpoint(floor))
        while try store.pruneBelowFloor() > 0 {}
        XCTAssertEqual(store.view.recordCount, 1, "only x5 remains")
        XCTAssertEqual(store.view.ownHead, 2)
        try store.retire(.unlink, heldInbox: [])

        let listing = try XCTUnwrap(HostJournalFiles.discover(in: root).first)
        let archive = try XCTUnwrap(try HostJournalArchive(listing))
        XCTAssertEqual(archive.own, 0)
        XCTAssertEqual(archive.remote, 1)
        let page = try HostJournalFiles.export(store.url, after: nil, limit: 10)
        guard case .checkpoint(let exported)? = page.items.first else { return XCTFail("a compacted export starts with its checkpoint") }
        XCTAssertEqual(exported.anchors, floor)
        guard case .remote(_, _, 5, _, _)? = page.items.last, page.items.count == 2 else { return XCTFail("then only x5") }
    }

    func testBelowFloorBytesAreDischargedOnlyByAnExactRunAndOtherwiseQuarantined() throws {
        let (store, chain, _) = try caughtUpMember()
        let floor = anchors([chain[2], try ownEnvelope(store, 1)])
        try store.commitRetentionFloor(round: Data(repeating: 1, count: 16), proposal: Data(repeating: 9, count: 32), checkpoint: checkpoint(floor))
        XCTAssertEqual(try store.pruneBelowFloor(maxRecords: 1), 1, "x1 removed, x2 and x3 still retained")
        let partial = store.view.recordCount
        _ = try store.intakeAndPromote([JournalFixture.arrival([chain[0]], cursor: 10)])
        XCTAssertEqual(store.view.quarantineCount, 0, "x1 runs into retained x2 whose prior is its digest")
        while try store.pruneBelowFloor() > 0 {}
        XCTAssertLessThan(store.view.recordCount, partial)

        _ = try store.intakeAndPromote([JournalFixture.arrival(Array(chain[0...2]), cursor: 11)])
        XCTAssertEqual(store.view.quarantineCount, 0, "x1...x3 end at the anchor digest")
        let before = store.view

        _ = try store.intakeAndPromote([JournalFixture.arrival([chain[1]], cursor: 12)])
        XCTAssertEqual(store.view.quarantineCount, 1, "a lone x2 proves nothing")
        let forged = try JournalFixture.chain(x, count: 3, payload: { Data("forged \($0)".utf8) })
        _ = try store.intakeAndPromote([JournalFixture.arrival(forged, cursor: 13)])
        XCTAssertEqual(store.view.quarantineCount, 2, "a run ending at a different digest is not the removed bytes")
        XCTAssertEqual(store.view.recordCount, before.recordCount)
        XCTAssertEqual(store.view.delivered, before.delivered)
        let reasons = try FixtureSQL.texts(store.url, "SELECT reason FROM quarantine ORDER BY cursor")
        XCTAssertEqual(reasons, ["belowFloor", "belowFloor"])

        var proof = try store.beginProof([JournalFixture.arrival([chain[2]], cursor: 14)])
        while try !store.extendProof(&proof) {}
        _ = try store.intake(next: 1, of: &proof)
        XCTAssertEqual(store.view.quarantineCount, 2, "x3 alone ends at the anchor through the window proof too")
        var lone = try store.beginProof([JournalFixture.arrival([chain[0]], cursor: 15)])
        while try !store.extendProof(&lone) {}
        _ = try store.intake(next: 1, of: &lone)
        XCTAssertEqual(store.view.quarantineCount, 3, "x1 alone is quarantined through the window proof")

        let fork = try JournalEnvelope(origin: x, sequence: 4, prior: chain[2].digest, payload: Data("other".utf8))
        XCTAssertThrowsError(try store.intake([JournalFixture.arrival([fork], cursor: 16)])) {
            XCTAssertEqual($0 as? JournalStoreError, .fork(origin: self.x, sequence: 4))
        }
        _ = try HostJournalStore.open(store.url)
    }

    func testAFloorIsDeclinedWhileAMemberLagsMismatchesOrIsUnsettled() throws {
        let (store, chain, _) = try caughtUpMember()
        let six = try JournalEnvelope(origin: x, sequence: 6, prior: chain[4].digest, payload: Data("six".utf8))
        _ = try store.intakeAndPromote([JournalFixture.arrival([six], cursor: 2)])
        XCTAssertEqual(try store.retentionDecline(anchors([six])), .notCaughtUp, "x6 is delivered but not applied")
        try store.markApplied(through: 6)
        XCTAssertNil(try store.retentionDecline(anchors([six])))
        let wrong = [HostSnapshotAnchor(origin: x, sequence: 3, digest: Data(repeating: 0xEE, count: 32))]
        XCTAssertEqual(try store.retentionDecline(wrong), .anchorMismatch)
        XCTAssertEqual(try store.retentionDecline([HostSnapshotAnchor(origin: x, sequence: 9, digest: chain[0].digest)]), .notCaughtUp)
        XCTAssertFalse(try store.commitRetentionFloor(round: Data(repeating: 1, count: 16), proposal: Data(repeating: 9, count: 32),
                                                     checkpoint: checkpoint(wrong)))
        _ = try store.intakeAndPromote([JournalFixture.raw(Data("junk".utf8), cursor: 3)])
        XCTAssertEqual(try store.retentionDecline(anchors([six])), .unsettled, "quarantined content fences a floor")
        XCTAssertNil(store.view.retention)
    }

    func testARefusedCheckpointCannotExposeOrAcknowledgeTheCompactedTail() throws {
        let chain = try JournalFixture.chain(x, count: 5)
        let committed = checkpoint(anchors([chain[2]]))
        let proposal = Data(repeating: 9, count: 32)
        var offer = committed
        offer.floor = proposal
        let joiner = try member()
        XCTAssertTrue(try joiner.requestSnapshot(schema: "test.state/1"))
        _ = try joiner.intakeAndPromote([JournalFixture.arrival(Array(chain[3...4]), cursor: 1)])
        try joiner.recordCompletionTarget(provider: provider, through: [x: 5], offer: offer)
        XCTAssertTrue(try joiner.adoptRetentionFloor(round: Data(repeating: 1, count: 16), proposal: proposal,
                                                    checkpoint: committed))
        while try joiner.promote() > 0 {}
        XCTAssertTrue(try joiner.refuseSnapshot(.contentUnavailable, in: [.offered], id: offer.id))
        XCTAssertTrue(joiner.view.isDeliveryHeld)
        XCTAssertFalse(joiner.view.historyApplied)
        XCTAssertEqual(try joiner.incoming(after: 0, limit: 64), [])
        XCTAssertThrowsError(try joiner.coveredThrough(after: 0)) { XCTAssertEqual($0 as? JournalStoreError, .bootstrapPending) }
        XCTAssertThrowsError(try joiner.markApplied(through: 2)) { XCTAssertEqual($0 as? JournalStoreError, .bootstrapPending) }
        XCTAssertThrowsError(try joiner.declareReady(capturedThrough: 0)) { XCTAssertEqual($0 as? JournalStoreError, .bootstrapPending) }
        XCTAssertEqual(joiner.view.appliedThrough, 0)
        XCTAssertEqual(joiner.view.recordCount, 2)
        XCTAssertEqual(try HostJournalStore.open(joiner.url).view, joiner.view)
    }

    func testAJoinerAdoptsACorroboratedFloorAndReceivesOnlyTheTail() throws {
        let chain = try JournalFixture.chain(x, count: 5)
        let floorAnchors = anchors([chain[2]])
        let committed = checkpoint(floorAnchors)
        var offer = committed
        offer.floor = Data(repeating: 9, count: 32)

        let joiner = try member()
        XCTAssertTrue(try joiner.requestSnapshot(schema: "test.state/1"))
        _ = try joiner.intakeAndPromote([JournalFixture.arrival(Array(chain[3...4]), cursor: 1)])
        XCTAssertEqual(joiner.view.pendingCount, 2, "the tail waits for the floor")
        try joiner.recordCompletionTarget(provider: provider, through: [x: 5], offer: offer)
        XCTAssertEqual(joiner.view.bootstrap?.phase, .offered)
        XCTAssertFalse(joiner.view.historyComplete)
        XCTAssertFalse(try joiner.adoptRetentionFloor(round: Data(repeating: 1, count: 16), proposal: Data(repeating: 8, count: 32),
                                                     checkpoint: committed), "another floor than the offer's is not adopted")
        XCTAssertTrue(try joiner.adoptRetentionFloor(round: Data(repeating: 1, count: 16), proposal: Data(repeating: 9, count: 32),
                                                    checkpoint: committed))
        while try joiner.promote() > 0 {}
        XCTAssertEqual(joiner.view.pendingCount, 0)
        XCTAssertTrue(joiner.view.historyComplete)
        XCTAssertEqual(try joiner.receivedVector()[x], 5)
        for (from, to) in [(HostSnapshotPhase.offered, HostSnapshotPhase.fetching), (.fetching, .assembled), (.assembled, .installing)] {
            XCTAssertTrue(try joiner.advanceSnapshot(id: offer.id, from: from, to: to))
        }
        XCTAssertTrue(try joiner.commitSnapshotInstall(id: offer.id, appliedThrough: 0))
        XCTAssertEqual(joiner.view.retention?.floorApplied, true)
        XCTAssertEqual(try joiner.incoming(after: 0, limit: 64).map(\.record), [chain[3].id, chain[4].id])
        try joiner.markApplied(through: 2)
        XCTAssertTrue(joiner.view.historyApplied)
        let reopened = try HostJournalStore.open(joiner.url)
        XCTAssertEqual(reopened.view, joiner.view)
        let lone = try JournalFixture.chain(x, count: 2)
        _ = try joiner.intakeAndPromote([JournalFixture.arrival([lone[1]], cursor: 9)])
        XCTAssertEqual(joiner.view.quarantineCount, 1, "a joiner has no below-floor bytes to compare and refuses them")
    }
}

extension HostJournalProvenance {
    func withEnrollment(of store: HostJournalStore) -> HostJournalProvenance {
        guard case .confirmed(let enrollment) = store.view.enrollment else { return self }
        return HostJournalProvenance(journalID: journalID, enrollmentID: enrollment, appliedThrough: appliedThrough, capturedThrough: capturedThrough)
    }
}

enum FixtureSQL {
    static func texts(_ url: URL, _ sql: String) throws -> [String] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(String(cString: sqlite3_column_text(statement, 0)))
        }
        return result
    }
}
