import Foundation
import XCTest
@_spi(HostJournalPreview) @testable import GotSync

/// The recipient journal's snapshot bootstrap: held delivery, the offer
/// taken with the completion target, anchors checked against retained
/// records, coverage skipping and refusals that keep full history.
@MainActor
final class HostSnapshotStoreTests: XCTestCase {
    private var root: URL!
    private let provider = Data(repeating: 0xAB, count: 32)
    private let schema = "test.state/1"

    override func setUp() async throws {
        root = try JournalFixture.directory()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func joiner() throws -> HostJournalStore {
        let store = try HostJournalStore.create(in: root, group: JournalFixture.group)
        _ = try store.resume(store.enroll())
        return store
    }

    private func offer(_ anchors: [HostSnapshotAnchor], id: Data = Data(repeating: 7, count: 16)) -> HostSnapshotOffer {
        HostSnapshotOffer(
            id: id, schema: schema, anchors: anchors, length: 10, contentHash: Data(repeating: 1, count: 32),
            chunks: [Data(repeating: 2, count: 152)]
        )
    }

    func testCoveredRecordsAreSkippedAndTheMarkMovesOverThem() throws {
        let store = try joiner()
        XCTAssertTrue(try store.requestSnapshot(schema: schema))
        let a = try JournalFixture.chain(JournalFixture.origin(2), count: 3)
        let c = try JournalFixture.chain(JournalFixture.origin(3), count: 2)
        _ = try store.intakeAndPromote([
            JournalFixture.arrival([a[0], a[1]], cursor: 1),
            JournalFixture.arrival([c[0]], cursor: 2),
            JournalFixture.arrival([a[2], c[1]], cursor: 3),
        ])
        XCTAssertEqual(try store.incoming(after: 0, limit: 64), [], "delivery is held while the bootstrap is unresolved")
        XCTAssertThrowsError(try store.markApplied(through: 1)) { XCTAssertEqual($0 as? JournalStoreError, .bootstrapPending) }

        let covering = offer([
            HostSnapshotAnchor(origin: a[1].origin, sequence: 2, digest: a[1].digest),
            HostSnapshotAnchor(origin: c[0].origin, sequence: 1, digest: c[0].digest),
        ])
        XCTAssertTrue(try store.recordCompletionTarget(provider: provider, through: [a[0].origin: 3, c[0].origin: 2], offer: covering))
        XCTAssertEqual(store.view.bootstrap?.phase, .offered)
        XCTAssertTrue(store.view.historyComplete)
        XCTAssertTrue(try store.verifySnapshotAnchors())
        for (from, to) in [(HostSnapshotPhase.offered, HostSnapshotPhase.fetching), (.fetching, .assembled), (.assembled, .installing)] {
            XCTAssertTrue(try store.advanceSnapshot(id: covering.id, from: from, to: to))
        }
        XCTAssertFalse(try store.advanceSnapshot(id: covering.id, from: .offered, to: .fetching), "a stale step changes nothing")
        XCTAssertFalse(try store.commitSnapshotInstall(id: Data(repeating: 9, count: 16), appliedThrough: 0), "another snapshot's install is dropped")
        let installPosition = try XCTUnwrap(store.snapshotInstallPosition(id: covering.id))
        XCTAssertEqual(installPosition, 3)
        XCTAssertThrowsError(try store.commitSnapshotInstall(id: covering.id, appliedThrough: 4))
        XCTAssertTrue(try store.commitSnapshotInstall(id: covering.id, appliedThrough: installPosition))
        XCTAssertEqual(store.view.bootstrap?.phase, .installed)
        XCTAssertEqual(store.view.appliedThrough, 3, "a1, a2 and c1 are covered and lead the positions")

        let tail = try store.incoming(after: store.view.appliedThrough, limit: 64)
        XCTAssertEqual(tail.map(\.record), [a[2].id, c[1].id])
        XCTAssertFalse(store.view.historyApplied)
        try store.markApplied(through: tail[1].position)
        XCTAssertTrue(store.view.historyApplied)
        XCTAssertEqual(try store.incoming(after: 0, limit: 64).map(\.record), [a[2].id, c[1].id], "covered records are never delivered")
        XCTAssertEqual(store.view.retainedCount, 5, "every covered record stays retained")

        let reopened = try HostJournalStore.open(store.url)
        XCTAssertEqual(reopened.view, store.view)
        XCTAssertEqual(reopened.view.bootstrap?.coverage, [a[0].origin: 2, c[0].origin: 1])
        XCTAssertTrue(try reopened.advanceSnapshot(id: covering.id, from: .installed, to: .completed))
    }

    func testCoveredMarksAreSavedExplicitlyBeforeAcknowledgement() throws {
        let store = try joiner()
        try store.requestSnapshot(schema: schema)
        let a = try JournalFixture.chain(JournalFixture.origin(2), count: 2)
        let c = try JournalFixture.chain(JournalFixture.origin(3), count: 1)
        _ = try store.intakeAndPromote([JournalFixture.arrival([c[0]], cursor: 1), JournalFixture.arrival(a, cursor: 2)])
        let covering = offer([HostSnapshotAnchor(origin: a[1].origin, sequence: 2, digest: a[1].digest)])
        try store.recordCompletionTarget(provider: provider, through: [a[0].origin: 2, c[0].origin: 1], offer: covering)
        for (from, to) in [(HostSnapshotPhase.offered, HostSnapshotPhase.fetching), (.fetching, .assembled), (.assembled, .installing)] {
            try store.advanceSnapshot(id: covering.id, from: from, to: to)
        }
        try store.commitSnapshotInstall(id: covering.id, appliedThrough: 0)
        XCTAssertEqual(store.view.appliedThrough, 0)
        let tail = try store.incoming(after: 0, limit: 64)
        XCTAssertEqual(tail.map(\.record), [c[0].id])
        try store.markApplied(through: tail[0].position)
        XCTAssertEqual(store.view.appliedThrough, 1)
        XCTAssertFalse(store.view.historyApplied)
        let coveredPosition = try XCTUnwrap(store.coveredThrough(after: tail[0].position))
        XCTAssertEqual(coveredPosition, 3)
        guard case .confirmed(let enrollmentID) = store.view.enrollment else { return XCTFail("not enrolled") }
        let saved = HostJournalProvenance(journalID: store.view.journalID, enrollmentID: enrollmentID,
                                         appliedThrough: tail[0].position, capturedThrough: store.view.capturedThrough)
        let reopened = try HostJournalStore.open(store.url)
        XCTAssertEqual(try reopened.resume(saved).appliedThrough, tail[0].position)
        try store.markApplied(through: coveredPosition)
        XCTAssertEqual(store.view.appliedThrough, 3)
        XCTAssertTrue(store.view.historyApplied)
        _ = try HostJournalStore.open(store.url)
    }

    func testSnapshotMarkResumesAfterTheAppSaveBeforeLibraryCompletion() throws {
        var store = try joiner()
        try store.requestSnapshot(schema: schema)
        let a = try JournalFixture.chain(JournalFixture.origin(2), count: 2)
        _ = try store.intakeAndPromote([JournalFixture.arrival(a, cursor: 1)])
        let covering = offer([HostSnapshotAnchor(origin: a[1].origin, sequence: 2, digest: a[1].digest)])
        try store.recordCompletionTarget(provider: provider, through: [a[0].origin: 2], offer: covering)
        for (from, to) in [(HostSnapshotPhase.offered, HostSnapshotPhase.fetching), (.fetching, .assembled), (.assembled, .installing)] {
            try store.advanceSnapshot(id: covering.id, from: from, to: to)
        }
        let installPosition = try XCTUnwrap(store.snapshotInstallPosition(id: covering.id))
        XCTAssertEqual(installPosition, 2)
        guard case .confirmed(let enrollmentID) = store.view.enrollment else { return XCTFail("not enrolled") }
        let saved = HostJournalProvenance(journalID: store.view.journalID, enrollmentID: enrollmentID,
                                         appliedThrough: installPosition, capturedThrough: store.view.capturedThrough)
        store = try HostJournalStore.open(store.url)
        XCTAssertEqual(try store.resume(saved).appliedThrough, installPosition)
        XCTAssertTrue(try store.commitSnapshotInstall(id: covering.id, appliedThrough: installPosition))
        store = try HostJournalStore.open(store.url)
        XCTAssertEqual(try store.resume(saved).appliedThrough, installPosition)
        XCTAssertEqual(try store.incoming(after: installPosition, limit: 64), [])
        XCTAssertNil(try store.coveredThrough(after: installPosition))
    }

    func testAnAnchorWithoutTheRetainedDigestIsNotProofOfOldBytes() throws {
        let store = try joiner()
        try store.requestSnapshot(schema: schema)
        let a = try JournalFixture.chain(JournalFixture.origin(2), count: 2)
        _ = try store.intakeAndPromote([JournalFixture.arrival(a, cursor: 1)])
        let forged = offer([HostSnapshotAnchor(origin: a[0].origin, sequence: 2, digest: Data(repeating: 0xEE, count: 32))])
        try store.recordCompletionTarget(provider: provider, through: [a[0].origin: 2], offer: forged)
        XCTAssertFalse(try store.verifySnapshotAnchors())
        XCTAssertTrue(try store.refuseSnapshot(.anchorMismatch, in: [.offered], id: forged.id))
        XCTAssertEqual(store.view.bootstrap?.phase, .refused)
        XCTAssertEqual(store.view.bootstrap?.offer, forged, "the refused offer is preserved")
        XCTAssertEqual(try store.incoming(after: 0, limit: 64).map(\.record), a.map(\.id), "full history is delivered")
    }

    func testCompletionWithoutAnUsableOfferRefusesVisiblyAndKeepsFullHistory() throws {
        let cases: [(HostSnapshotOffer?, HostSnapshotRefusalReason?, HostSnapshotRefusalReason)] = [
            (nil, nil, .notOffered),
            (nil, .tooLarge, .tooLarge),
            (nil, .hostRefused, .notOffered),
            (offer([], id: Data(count: 3)), nil, .malformedOffer),
        ]
        for (index, (offered, refusal, expected)) in cases.enumerated() {
            let store = try joiner()
            try store.requestSnapshot(schema: schema)
            let a = try JournalFixture.chain(JournalFixture.origin(UInt8(10 + index)), count: 1)
            _ = try store.intakeAndPromote([JournalFixture.arrival(a, cursor: 1)])
            try store.recordCompletionTarget(provider: provider, through: [a[0].origin: 1], offer: offered, refusal: refusal)
            XCTAssertEqual(store.view.bootstrap?.phase, .refused, "case \(index)")
            XCTAssertEqual(store.view.bootstrap?.refusal, expected, "case \(index)")
            XCTAssertEqual(try store.incoming(after: 0, limit: 64).map(\.record), [a[0].id], "case \(index)")
            XCTAssertEqual(try HostJournalStore.open(store.url).view, store.view, "case \(index)")
        }
    }

    func testOnlyAFreshJournalRequestsAndAnExportCutCarriesRetainedHeads() throws {
        let store = try joiner()
        let a = try JournalFixture.chain(JournalFixture.origin(2), count: 2)
        _ = try store.intakeAndPromote([JournalFixture.arrival(a, cursor: 1)])
        try store.markApplied(through: 1)
        XCTAssertFalse(try store.requestSnapshot(schema: schema), "a journal that applied records keeps full history")
        XCTAssertNil(store.view.bootstrap)
        _ = try store.submit([HostJournalMutation(id: JournalFixture.mutationID(1), payload: Data("own".utf8))], capturedThrough: 1)

        let cut = try store.snapshotExportCut()
        XCTAssertEqual(cut.appliedThrough, 1)
        XCTAssertEqual(cut.capturedThrough, 1)
        XCTAssertEqual(Set(cut.anchors.map(\.origin)), [a[0].origin, store.view.origin])
        XCTAssertEqual(cut.anchors.first { $0.origin == a[0].origin }, HostSnapshotAnchor(origin: a[0].origin, sequence: 1, digest: a[0].digest),
                       "only the applied prefix is covered; a2 is the recipient's tail")
        XCTAssertEqual(cut.anchors.first { $0.origin == store.view.origin }?.sequence, 1)
    }

    func testOptionalSnapshotFieldsDecodeAndOlderShapesStayValid() throws {
        let covering = offer([HostSnapshotAnchor(origin: JournalFixture.origin(2), sequence: 1, digest: Data(repeating: 3, count: 32))])
        let complete = HostJournalMessage.complete(member: provider, through: ReplicaVersionVector(), snapshot: covering)
        XCTAssertEqual(try HostJournalMessage.decode(complete.encoded()).snapshot, covering)
        let refused = HostJournalMessage.complete(member: provider, through: ReplicaVersionVector(), refusal: .tooLarge)
        XCTAssertEqual(try HostJournalMessage.decode(refused.encoded()).snapshotRefusal, "tooLarge")
        var hello = try HostJournalMessage(control: .hello(vector: ReplicaVersionVector(), provider: provider))
        hello.snapshotSchema = schema
        XCTAssertEqual(try HostJournalMessage.decode(hello.encoded()).snapshotSchema, schema)
        hello.snapshotSchema = "Not A Schema"
        XCTAssertThrowsError(try HostJournalMessage.decode(hello.encoded()))
        var both = complete
        both.snapshotRefusal = "tooLarge"
        XCTAssertThrowsError(try HostJournalMessage.decode(both.encoded()), "an offer never comes with a refusal")

        struct OlderComplete: Codable {
            let version: Int
            let kind: String
            let member: Data
            let through: ReplicaVersionVector
        }
        let older = try ReplicaCanonicalJSON.decode(OlderComplete.self, from: complete.encoded())
        XCTAssertEqual(older.kind, "complete", "an earlier reader ignores the snapshot fields")
    }
}
