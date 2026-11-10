import Foundation
import XCTest
@_spi(HostJournalPreview) @testable import GotSync

/// The bounded window proof, its intake token and bounded promotion of
/// pending chains.
@MainActor
final class HostWindowProofTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = try JournalFixture.directory()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func enrolled() throws -> (HostJournalStore, HostStandIn) {
        let store = try HostJournalStore.create(in: directory, group: JournalFixture.group)
        let host = try HostStandIn(url: directory.appendingPathComponent("host.json"))
        try host.save(try store.enroll())
        _ = try store.resume(XCTUnwrap(host.provenance))
        return (store, host)
    }

    /// Leaves `chain[1...]` pending: they wait for the record before them.
    private func pendingChain(_ store: HostJournalStore, _ chain: [JournalEnvelope], cursor: inout UInt64) throws {
        for start in stride(from: 1, to: chain.count, by: 256) {
            let run = Array(chain[start..<min(start + 256, chain.count)])
            XCTAssertEqual(try store.intake([JournalFixture.arrival(run, cursor: cursor)]).ownedArrivals, 1)
            cursor += 1
        }
    }

    private func prove(_ store: HostJournalStore, _ arrivals: [HostJournalArrival]) throws -> (HostWindowProof, Int) {
        var proof = try store.beginProof(arrivals)
        var steps = 0
        repeat {
            steps += 1
        } while try !store.extendProof(&proof)
        return (proof, steps)
    }

    // MARK: - Promotion

    func testGapFillingArrivalCommitsOnlyItsOwnEnvelopes() throws {
        let store = try HostJournalStore.create(in: directory, group: JournalFixture.group)
        let origin = JournalFixture.origin(4)
        let chain = try JournalFixture.chain(origin, count: 300)
        var cursor: UInt64 = 1
        try pendingChain(store, chain, cursor: &cursor)
        XCTAssertFalse(store.hasPromotable)
        let retained = store.view.retainedBytes
        var (proof, _) = try prove(store, [JournalFixture.arrival([chain[0]], cursor: cursor)])
        XCTAssertEqual(try store.intake(next: 1, of: &proof).ownedArrivals, 1)
        XCTAssertEqual(store.view.recordCount, 1)
        XCTAssertEqual(store.view.pendingCount, 299)
        XCTAssertEqual(try store.receivedVector()[origin], 1)
        XCTAssertTrue(store.hasPromotable)
        XCTAssertEqual(store.view.retainedBytes, retained + UInt64(chain[0].bytes.count))
        let reopened = try HostJournalStore.open(store.url)
        XCTAssertTrue(reopened.hasPromotable, "a promotable journal did not validate")
        XCTAssertEqual(reopened.view, store.view)
    }

    func testPromotionStepsAreBoundedAcrossOriginsAndOrdered() throws {
        let (store, host) = try enrolled()
        var cursor: UInt64 = 1
        let chains = try [JournalFixture.origin(4), JournalFixture.origin(5)].map { try JournalFixture.chain($0, count: 200) }
        for chain in chains { try pendingChain(store, chain, cursor: &cursor) }
        _ = try store.intake([JournalFixture.arrival([chains[0][0]], cursor: cursor), JournalFixture.arrival([chains[1][0]], cursor: cursor + 1)])
        XCTAssertEqual(store.view.recordCount, 2, "direct intake promoted a pending chain")
        while try store.promote() > 0 {}
        XCTAssertEqual(store.view.recordCount, 400)

        let other = try HostJournalStore.create(in: directory.appendingPathComponent("b", isDirectory: true).creatingDirectory(), group: JournalFixture.group)
        cursor = 1
        for chain in chains { try pendingChain(other, chain, cursor: &cursor) }
        var (proof, _) = try prove(other, [JournalFixture.arrival([chains[0][0]], cursor: cursor), JournalFixture.arrival([chains[1][0]], cursor: cursor + 1)])
        XCTAssertEqual(try other.intake(next: 2, of: &proof).ownedArrivals, 2)
        let retained = other.view.retainedBytes
        var steps: [Int] = []
        while other.hasPromotable {
            steps.append(try other.promote())
            XCTAssertEqual(other.view.retainedBytes, retained)
        }
        XCTAssertEqual(steps, [128, 128, 128, 14], "one budget covers every origin together")
        XCTAssertEqual(other.view.recordCount, 400)
        XCTAssertEqual(other.view.pendingCount, 0)
        _ = host
        let positions = try JournalFixture.exportAll(other.url).compactMap { item -> UInt64? in
            if case .remote(let position, _, _, _, _) = item { return position }
            return nil
        }
        XCTAssertEqual(positions.sorted(), Array(1...400))
    }

    func testCompletionArrivesOnlyAfterTheTargetIsPromoted() throws {
        let (store, host) = try enrolled()
        let origin = JournalFixture.origin(4)
        let chain = try JournalFixture.chain(origin, count: 300)
        XCTAssertTrue(try store.recordCompletionTarget(provider: Data(repeating: 1, count: 32), through: [origin: 200]))
        var cursor: UInt64 = 1
        try pendingChain(store, chain, cursor: &cursor)
        var (proof, _) = try prove(store, [JournalFixture.arrival([chain[0]], cursor: cursor)])
        _ = try store.intake(next: 1, of: &proof)
        XCTAssertFalse(store.view.historyComplete)
        XCTAssertEqual(try store.promote(), 128)
        XCTAssertFalse(store.view.historyComplete, "completion counted pending records")
        XCTAssertEqual(try store.promote(), 128)
        XCTAssertTrue(store.view.historyComplete)
        XCTAssertEqual(store.view.completionPosition, 200)
        XCTAssertFalse(store.view.historyApplied)
        try host.applyAll(store)
        XCTAssertTrue(store.view.historyApplied)
    }

    func testRetirementPreservesPromotableRowsExactly() throws {
        let store = try HostJournalStore.create(in: directory, group: JournalFixture.group)
        let chain = try JournalFixture.chain(JournalFixture.origin(4), count: 50)
        var cursor: UInt64 = 1
        try pendingChain(store, chain, cursor: &cursor)
        var (proof, _) = try prove(store, [JournalFixture.arrival([chain[0]], cursor: cursor)])
        _ = try store.intake(next: 1, of: &proof)
        try store.retire(.unlink, heldInbox: [])
        let pending = try JournalFixture.exportAll(store.url).compactMap { item -> Data? in
            if case .pending(_, _, let envelope) = item { return envelope }
            return nil
        }
        XCTAssertEqual(pending, chain[1...].map(\.bytes))
        XCTAssertThrowsError(try store.promote()) { XCTAssertEqual($0 as? JournalStoreError, .retired) }
    }

    func testValidationAcceptsPromotableButRejectsPendingAtOrBelowTheHead() throws {
        let store = try HostJournalStore.create(in: directory, group: JournalFixture.group)
        let chain = try JournalFixture.chain(JournalFixture.origin(4), count: 5)
        var cursor: UInt64 = 1
        try pendingChain(store, chain, cursor: &cursor)
        var (proof, _) = try prove(store, [JournalFixture.arrival([chain[0]], cursor: cursor)])
        _ = try store.intake(next: 1, of: &proof)
        XCTAssertNoThrow(try HostJournalStore.open(store.url))
        try JournalFixture.tamper(store.url, "INSERT INTO pending SELECT origin, sequence, envelope, digest FROM records WHERE sequence = 1")
        let damaged = JournalFixture.storedState(store.url)
        XCTAssertThrowsError(try HostJournalStore.open(store.url)) { XCTAssertEqual($0 as? JournalStoreError, .storeCorrupt("pending")) }
        XCTAssertEqual(JournalFixture.storedState(store.url), damaged)
    }

    func testFormatTwoJournalIsRejectedPreservingItsBytes() throws {
        let store = try HostJournalStore.create(in: directory, group: JournalFixture.group)
        try JournalFixture.tamper(store.url, "PRAGMA user_version = 2")
        let before = JournalFixture.storedState(store.url)
        XCTAssertThrowsError(try HostJournalStore.open(store.url)) { XCTAssertEqual($0 as? JournalStoreError, .formatUnsupported(2)) }
        XCTAssertEqual(JournalFixture.storedState(store.url), before)
    }

    func testInterruptedPromotionResumesAfterReopen() throws {
        let store = try HostJournalStore.create(in: directory, group: JournalFixture.group)
        let origin = JournalFixture.origin(4)
        let chain = try JournalFixture.chain(origin, count: 300)
        var cursor: UInt64 = 1
        try pendingChain(store, chain, cursor: &cursor)
        var (proof, _) = try prove(store, [JournalFixture.arrival([chain[0]], cursor: cursor)])
        _ = try store.intake(next: 1, of: &proof)
        XCTAssertEqual(try store.promote(), 128)
        store.faultHookForTesting = { if $0 == .beforeCommit("promote") { throw CancellationError() } }
        XCTAssertThrowsError(try store.promote())
        let reopened = try HostJournalStore.open(store.url)
        XCTAssertEqual(try reopened.receivedVector()[origin], 129)
        XCTAssertTrue(reopened.hasPromotable)
        while try reopened.promote() > 0 {}
        XCTAssertEqual(try reopened.receivedVector()[origin], 300)
        XCTAssertEqual(reopened.view.pendingCount, 0)
        XCTAssertEqual(try HostJournalStore.open(store.url).view, reopened.view)
    }

    // MARK: - Proof

    func testLateForkInAPendingChainFailsTheProofWithoutWriting() throws {
        let store = try HostJournalStore.create(in: directory, group: JournalFixture.group)
        let origin = JournalFixture.origin(4)
        let honest = try JournalFixture.chain(origin, count: 1_500)
        let forged = try JournalFixture.chain(origin, count: 300, from: 1_201, prior: Data(repeating: 7, count: 32))
        var cursor: UInt64 = 1
        try pendingChain(store, Array(honest[0..<1_200]) + forged, cursor: &cursor)
        let before = JournalFixture.storedState(store.url)
        let revision = store.view.revision
        let other = try JournalFixture.chain(JournalFixture.origin(5), count: 3)
        var proof = try store.beginProof([JournalFixture.arrival(other, cursor: cursor), JournalFixture.arrival([honest[0]], cursor: cursor + 1)])
        var steps = 0
        XCTAssertThrowsError(try {
            while try !store.extendProof(&proof) {
                steps += 1
                XCTAssertFalse(store.isInTransactionForTesting)
            }
        }()) { XCTAssertEqual($0 as? JournalStoreError, .fork(origin: origin, sequence: 1_201)) }
        XCTAssertGreaterThan(steps, 2, "the fork was not found in a later walk step")
        XCTAssertEqual(JournalFixture.storedState(store.url), before)
        XCTAssertEqual(store.view.revision, revision)
        XCTAssertFalse(store.isInTransactionForTesting)
    }

    func testOwnEditsBetweenStepsKeepTheProof() throws {
        let (store, host) = try enrolled()
        let chain = try JournalFixture.chain(JournalFixture.origin(4), count: 2_000)
        var proof = try store.beginProof(stride(from: 0, to: 2_000, by: 200).enumerated().map {
            JournalFixture.arrival(Array(chain[$1..<$1 + 200]), cursor: UInt64($0 + 1))
        })
        var steps = 0
        while try !store.extendProof(&proof) {
            steps += 1
            try host.capture(Data("edit \(steps)".utf8))
            _ = try host.submitOutbox(store)
        }
        XCTAssertGreaterThan(steps, 3)
        XCTAssertEqual(try store.intake(next: 10, of: &proof).ownedArrivals, 10)
        XCTAssertEqual(store.view.delivered, 2_000)
    }

    func testUnrelatedIntakeBetweenStepsMakesTheProofStale() throws {
        let store = try HostJournalStore.create(in: directory, group: JournalFixture.group)
        let chain = try JournalFixture.chain(JournalFixture.origin(4), count: 1_200)
        var proof = try store.beginProof([JournalFixture.arrival(chain, cursor: 1)])
        XCTAssertFalse(try store.extendProof(&proof))
        _ = try store.intake([JournalFixture.arrival(try JournalFixture.chain(JournalFixture.origin(5), count: 1), cursor: 9)])
        XCTAssertThrowsError(try store.extendProof(&proof)) { XCTAssertEqual($0 as? JournalStoreError, .proofStale) }
        var (fresh, _) = try prove(store, [JournalFixture.arrival(chain, cursor: 1)])
        XCTAssertEqual(try store.intake(next: 1, of: &fresh).ownedArrivals, 1)
        XCTAssertEqual(store.view.delivered, 1_201)
    }

    func testOwnChunkCommitsAdvanceTheTokenWithoutReproof() throws {
        let store = try HostJournalStore.create(in: directory, group: JournalFixture.group)
        let chain = try JournalFixture.chain(JournalFixture.origin(4), count: 600)
        var (proof, _) = try prove(store, stride(from: 0, to: 600, by: 200).enumerated().map {
            JournalFixture.arrival(Array(chain[$1..<$1 + 200]), cursor: UInt64($0 + 1))
        })
        for _ in 0..<3 {
            XCTAssertEqual(try store.intake(next: 1, of: &proof).ownedArrivals, 1)
        }
        XCTAssertEqual(store.view.delivered, 600)
        XCTAssertThrowsError(try store.intake(next: 1, of: &proof))
    }

    func testAnotherHandleOfTheSameJournalCannotUseTheProof() throws {
        let store = try HostJournalStore.create(in: directory, group: JournalFixture.group)
        let chain = try JournalFixture.chain(JournalFixture.origin(4), count: 3)
        var (proof, _) = try prove(store, [JournalFixture.arrival(chain, cursor: 1)])
        let replacement = try HostJournalStore.open(store.url)
        XCTAssertThrowsError(try replacement.intake(next: 1, of: &proof)) { XCTAssertEqual($0 as? JournalStoreError, .proofStale) }
        try store.retire(.unlink, heldInbox: [])
        XCTAssertThrowsError(try store.intake(next: 1, of: &proof)) { XCTAssertEqual($0 as? JournalStoreError, .proofStale) }
    }

    func testIncompleteProofCannotIntake() throws {
        let store = try HostJournalStore.create(in: directory, group: JournalFixture.group)
        let chain = try JournalFixture.chain(JournalFixture.origin(4), count: 1_200)
        var proof = try store.beginProof([JournalFixture.arrival(chain, cursor: 1)])
        XCTAssertFalse(try store.extendProof(&proof))
        XCTAssertThrowsError(try store.intake(next: 1, of: &proof))
        XCTAssertEqual(store.view.recordCount, 0)
    }

    func testEveryTransactionHasAProofEffect() {
        XCTAssertEqual(HostJournalStore.proofEffects, [
            "enroll": .none, "resume": .none, "submit": .none, "markApplied": .none, "markEstablished": .none,
            "declareReady": .none, "recordCompletionTarget": .none, "setHistoryProvider": .none,
            "enterControlRepair": .none, "intake": .intake, "promote": .intake, "retire": .generation,
        ])
    }
}

private extension URL {
    func creatingDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
        return self
    }
}
