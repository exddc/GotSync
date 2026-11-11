import Foundation
import XCTest
@_spi(HostJournalPreview) @testable import GotSync

/// Store incarnations and ancestry, lineage tokens, the finalization fence
/// with mapping release, and the recorded reclamation scope.
@MainActor
final class HostProvenanceStoreTests: XCTestCase {
    private var root: URL!
    private let provider = Data(repeating: 0xAB, count: 32)
    private let x = JournalFixture.origin(2)
    private let storeA = Data(repeating: 0x0A, count: 16)

    override func setUp() async throws {
        root = try JournalFixture.directory()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func joined(_ incarnation: HostStoreIncarnationRecord) throws -> HostJournalStore {
        let store = try HostJournalStore.create(in: root, group: JournalFixture.group)
        _ = try store.resume(store.enroll(incarnation: incarnation))
        let chain = try JournalFixture.chain(x, count: 5)
        _ = try store.intakeAndPromote([JournalFixture.arrival(chain, cursor: 1)])
        try store.recordCompletionTarget(provider: provider, through: [x: 5])
        try store.markApplied(through: 5)
        return store
    }

    private func token(group: Data = JournalFixture.group, applied: [Data: UInt64]) -> HostLineageRecord {
        HostLineageRecord(group: group, journalID: Data(repeating: 3, count: 16), storeID: storeA,
                          applied: HostVectorEntry.entries(applied), reclaimedThrough: [])
    }

    func testAncestryIsClassifiedFromTheDeclaredStoreAndGatesReadinessUntilResolved() throws {
        let fresh = try joined(HostStoreIncarnationRecord(storeID: storeA, content: .empty, lineage: []))
        XCTAssertEqual(fresh.view.ancestry, .fresh)
        try fresh.declareReady(capturedThrough: 0)

        let foreign = try joined(HostStoreIncarnationRecord(
            storeID: storeA, content: .nonempty, lineage: [token(group: Data(repeating: 1, count: 32), applied: [x: 9])]
        ))
        XCTAssertEqual(foreign.view.ancestry, .foreign)
        XCTAssertFalse(foreign.view.isAncestryResolved)
        XCTAssertThrowsError(try foreign.declareReady(capturedThrough: 0)) {
            XCTAssertEqual($0 as? JournalStoreError, .ancestryUnresolved)
        }
        XCTAssertTrue(try foreign.resolveAncestry())
        XCTAssertTrue(foreign.view.isAncestryResolved)
        try foreign.declareReady(capturedThrough: 0)
        XCTAssertEqual(try HostJournalStore.open(foreign.url).view, foreign.view, "the resolution is durable")

        let undeclared = try joined(.undeclared)
        XCTAssertEqual(undeclared.view.ancestry, .unknown)
        let same = try joined(HostStoreIncarnationRecord(storeID: storeA, content: .nonempty, lineage: [token(applied: [x: 2])]))
        XCTAssertEqual(same.view.ancestry, .sameLineage, "nothing was reclaimed in this group")

        let founder = try HostJournalStore.create(in: root, group: JournalFixture.group, founder: true)
        _ = try founder.resume(founder.enroll(incarnation: HostStoreIncarnationRecord(storeID: storeA, content: .nonempty, lineage: [])))
        XCTAssertEqual(founder.view.ancestry, .founder)

        let unprofiled = try HostJournalStore.create(in: root, group: JournalFixture.group)
        _ = try unprofiled.resume(unprofiled.enroll())
        XCTAssertNil(unprofiled.view.ancestry, "groups without ancestry keep the earlier behavior")
    }

    func testAStoreBehindTheReclamationFrontierIsStaleAndADeclarationIsImmutable() throws {
        let record = HostStoreIncarnationRecord(storeID: storeA, content: .nonempty, lineage: [token(applied: [x: 3])])
        XCTAssertEqual(HostAncestryKind.classify(record, group: JournalFixture.group, founder: false, frontier: [x: 5]), .staleLineage)
        XCTAssertEqual(HostAncestryKind.classify(record, group: JournalFixture.group, founder: false, frontier: [x: 3]), .sameLineage)

        let store = try HostJournalStore.create(in: root, group: JournalFixture.group)
        _ = try store.enroll(incarnation: record)
        let other = HostStoreIncarnationRecord(storeID: Data(repeating: 0x0B, count: 16), content: .empty, lineage: [])
        XCTAssertThrowsError(try store.enroll(incarnation: other)) {
            XCTAssertEqual($0 as? JournalStoreError, .hostProvenanceMismatch, "a store is never silently re-identified")
        }
        XCTAssertEqual(store.view.incarnation, record)
    }

    func testLineageCarriesTheAppliedVectorAndTheFenceReleasesOnlyFinalizedRemovedMappings() throws {
        let store = try joined(HostStoreIncarnationRecord(storeID: storeA, content: .empty, lineage: []))
        let own = try store.submit(
            [1, 2].map { HostJournalMutation(id: JournalFixture.mutationID($0), payload: Data("own \($0)".utf8), capturedAt: UInt64($0)) },
            capturedThrough: 2
        )
        try store.declareReady(capturedThrough: 2)
        let lineage = try store.lineage()
        XCTAssertEqual(HostVectorEntry.vector(lineage.applied), [x: 5, store.view.origin: 2])
        XCTAssertEqual(lineage.storeID, storeA)

        let ownFirst = try XCTUnwrap(store.ownRecords(after: 0, maxBytes: 1 << 20, maxCount: 1).first)
        let chain = try JournalFixture.chain(x, count: 3)
        let anchors = [
            HostSnapshotAnchor(origin: x, sequence: 3, digest: chain[2].digest),
            HostSnapshotAnchor(origin: store.view.origin, sequence: 1, digest: ownFirst.digest),
        ].sorted { $0.origin.lexicographicallyPrecedes($1.origin) }
        let checkpoint = HostSnapshotOffer(
            id: Data(repeating: 7, count: 16), schema: "test.state/1", anchors: anchors, length: 10,
            contentHash: Data(repeating: 1, count: 32), chunks: [Data(repeating: 2, count: 152)]
        )
        XCTAssertTrue(try store.commitRetentionFloor(round: Data(repeating: 1, count: 16), proposal: Data(repeating: 9, count: 32),
                                                    checkpoint: checkpoint, reclaimStores: [storeA, Data(repeating: 0x0C, count: 16)]))
        XCTAssertEqual(store.view.reclamation?.frontier, [x: 3, store.view.origin: 1])
        XCTAssertEqual(store.view.reclamation?.applied, false)
        XCTAssertTrue(try store.markReclamationApplied(frontier: [x: 3, store.view.origin: 1]))
        while try store.pruneBelowFloor() > 0 {}
        XCTAssertEqual(try store.releaseFinalizedMappings(), 0, "nothing is released before the host's fence")

        let fence = try store.finalizeSubmissions(capturedThrough: 2)
        XCTAssertEqual(fence.own, 2)
        XCTAssertEqual(try store.releaseFinalizedMappings(), 1, "only own 1 is both finalized and removed")
        XCTAssertEqual(try store.releaseFinalizedMappings(), 0)
        XCTAssertEqual(store.view.finalization?.released, 1)

        XCTAssertThrowsError(try store.submit(
            [HostJournalMutation(id: JournalFixture.mutationID(1), payload: Data("own 1".utf8), capturedAt: 1)], capturedThrough: 2
        )) { XCTAssertEqual($0 as? JournalStoreError, .mutationFinalized, "a delayed retry is never a new mutation") }
        XCTAssertThrowsError(try store.submit(
            [HostJournalMutation(id: JournalFixture.mutationID(4), payload: Data("late".utf8))], capturedThrough: 2
        )) { XCTAssertEqual($0 as? JournalStoreError, .captureRequired) }
        XCTAssertEqual(try store.submit(
            [HostJournalMutation(id: JournalFixture.mutationID(2), payload: Data("own 2".utf8), capturedAt: 2)], capturedThrough: 2
        ), [own[1]], "a retained mapping still answers its retry")
        let next = try store.submit(
            [HostJournalMutation(id: JournalFixture.mutationID(3), payload: Data("own 3".utf8), capturedAt: 3)], capturedThrough: 3
        )
        XCTAssertEqual(next.first?.sequence, 3)
        XCTAssertEqual(try HostJournalStore.open(store.url).view, store.view, "mappings plus released mappings equal the own head")
    }

    func testAJoiningStoreCannotPublishUntilTheKnownHistoryAndAncestryAreResolved() throws {
        let store = try HostJournalStore.create(in: root, group: JournalFixture.group)
        _ = try store.resume(store.enroll(incarnation: HostStoreIncarnationRecord(
            storeID: storeA, content: .nonempty, lineage: [token(applied: [x: 5])]
        )))
        let mutation = HostJournalMutation(id: JournalFixture.mutationID(1), payload: Data("old local content".utf8), capturedAt: 1)
        XCTAssertEqual(store.view.ancestry, .sameLineage)
        XCTAssertThrowsError(try store.submit([mutation], capturedThrough: 1)) {
            XCTAssertEqual($0 as? JournalStoreError, .ancestryUnresolved)
        }
        XCTAssertEqual(store.view.ownHead, 0)
        let chain = try JournalFixture.chain(x, count: 5)
        _ = try store.intakeAndPromote([JournalFixture.arrival(chain, cursor: 1)])
        try store.recordCompletionTarget(provider: provider, through: [x: 5])
        XCTAssertThrowsError(try store.submit([mutation], capturedThrough: 1)) {
            XCTAssertEqual($0 as? JournalStoreError, .ancestryUnresolved)
        }
        try store.markApplied(through: 5)
        XCTAssertEqual(try store.submit([mutation], capturedThrough: 1).first?.sequence, 1)

        let unknown = try joined(HostStoreIncarnationRecord(storeID: storeA, content: .nonempty, lineage: []))
        XCTAssertThrowsError(try unknown.submit([mutation], capturedThrough: 1)) {
            XCTAssertEqual($0 as? JournalStoreError, .ancestryUnresolved)
        }
        XCTAssertTrue(try unknown.resolveAncestry())
        XCTAssertEqual(try unknown.submit([mutation], capturedThrough: 1).first?.sequence, 1)
    }

    func testReclamationNeedsAResolvedAncestry() throws {
        let store = try joined(HostStoreIncarnationRecord(storeID: storeA, content: .nonempty, lineage: []))
        let chain = try JournalFixture.chain(x, count: 3)
        let checkpoint = HostSnapshotOffer(
            id: Data(repeating: 7, count: 16), schema: "test.state/1",
            anchors: [HostSnapshotAnchor(origin: x, sequence: 3, digest: chain[2].digest)], length: 10,
            contentHash: Data(repeating: 1, count: 32), chunks: [Data(repeating: 2, count: 152)]
        )
        XCTAssertFalse(try store.commitRetentionFloor(round: Data(repeating: 1, count: 16), proposal: Data(repeating: 9, count: 32),
                                                     checkpoint: checkpoint, reclaimStores: [storeA]))
        XCTAssertNil(store.view.reclamation)
        try store.resolveAncestry()
        XCTAssertTrue(try store.commitRetentionFloor(round: Data(repeating: 1, count: 16), proposal: Data(repeating: 9, count: 32),
                                                    checkpoint: checkpoint, reclaimStores: [storeA]))
        XCTAssertNotNil(store.view.reclamation)
    }
}
