import Foundation
import GotSyncMLS
import XCTest
@testable import GotSync

/// Engine drains prove the whole frozen window before any intake and
/// promote pending chains in bounded steps.
extension HostEngineTests {
    private func sendRecords(_ envelopes: [JournalEnvelope], from session: MLSSession) async throws {
        for start in stride(from: 0, to: envelopes.count, by: 200) {
            try await send(.records(envelopes[start..<min(start + 200, envelopes.count)].map(\.bytes)), from: session)
        }
    }

    func testForkAtTheEndOfALongPendingChainLeavesTheWholeWindowUnwritten() async throws {
        let (a, b) = try await completedPair()
        await a.stop()
        await b.stop()
        let aSession = try XCTUnwrap(a.mlsSessionForTesting)
        let bSession = try XCTUnwrap(b.mlsSessionForTesting)
        let origin = Data(repeating: 0x4F, count: 16)
        let honest = try JournalFixture.chain(origin, count: 1_200)
        let forged = try JournalFixture.chain(origin, count: 200, from: 1_201, prior: Data(repeating: 9, count: 32))
        try await sendRecords(Array(honest[1...]) + forged, from: aSession)
        _ = try await bSession.synchronize()
        try await b.drainInboxForTesting()
        let journal = try store(b)
        XCTAssertEqual(journal.view.pendingCount, 1_399)
        let drained = try await bSession.inbox()
        XCTAssertEqual(drained.count, 0)

        try await sendRecords(try JournalFixture.chain(Data(repeating: 0x50, count: 16), count: 300), from: aSession)
        try await send(.records([honest[0].bytes]), from: aSession)
        _ = try await bSession.synchronize()
        let window = try await bSession.inbox()
        XCTAssertEqual(window.count, 3)
        let before = JournalFixture.storedState(journal.url)
        do {
            try await b.drainInboxForTesting()
            XCTFail("a window ending in a forked chain was taken")
        } catch HostJournalError.fork(let forkedOrigin, let sequence) {
            XCTAssertEqual(forkedOrigin, origin)
            XCTAssertEqual(sequence, 1_201)
        }
        XCTAssertEqual(JournalFixture.storedState(journal.url), before, "part of the window was written")
        let remaining = try await bSession.inbox()
        XCTAssertEqual(remaining, window, "part of the window was acknowledged")
    }

    func testDrainPromotesAClosedChainInBoundedSteps() async throws {
        let (a, b) = try await completedPair()
        await a.stop()
        await b.stop()
        let aSession = try XCTUnwrap(a.mlsSessionForTesting)
        let bSession = try XCTUnwrap(b.mlsSessionForTesting)
        let origin = Data(repeating: 0x51, count: 16)
        let chain = try JournalFixture.chain(origin, count: 600)
        try await sendRecords(Array(chain[1...]), from: aSession)
        _ = try await bSession.synchronize()
        try await b.drainInboxForTesting()
        let journal = try store(b)
        XCTAssertEqual(journal.view.pendingCount, 599)
        var steps: [UInt64] = []
        journal.adoptionHookForTesting = { name in
            if name == "promote" { steps.append(journal.view.pendingCount) }
        }
        try await send(.records([chain[0].bytes]), from: aSession)
        _ = try await bSession.synchronize()
        try await b.drainInboxForTesting()
        journal.adoptionHookForTesting = nil
        XCTAssertEqual(steps, [471, 343, 215, 87, 0])
        XCTAssertEqual(journal.view.pendingCount, 0)
        XCTAssertEqual(journal.receivedVector[origin], 600)
    }

    func testPromotableRowsLeftAtStopArePromotedAfterLaunch() async throws {
        let (a, b) = try await completedPair()
        await a.stop()
        await b.stop()
        let journalID = try XCTUnwrap(b.hostView?.journal?.journalID)
        let origin = Data(repeating: 0x52, count: 16)
        let chain = try JournalFixture.chain(origin, count: 400)
        let sender = try await fingerprint(a)
        do {
            let journal = try HostJournalStore.open(HostJournalStore.fileURL(in: directory("b"), journalID: journalID))
            for (index, start) in stride(from: 1, to: 400, by: 200).enumerated() {
                _ = try journal.intake([HostJournalArrival(
                    sender: sender, cursor: 1_000 + UInt64(index), plaintext: Data("p\(index)".utf8),
                    envelopes: chain[start..<min(start + 200, 400)].map(\.bytes)
                )])
            }
            var proof = try journal.beginProof([HostJournalArrival(sender: sender, cursor: 2_000, plaintext: Data("head".utf8), envelopes: [chain[0].bytes])])
            while try !journal.extendProof(&proof) {}
            _ = try journal.intake(next: 1, of: &proof)
            XCTAssertTrue(journal.hasPromotable)
            XCTAssertGreaterThan(journal.view.pendingCount, 0)
        }
        let restarted = await restart(b, "b")
        try await wait("promoted after launch") { (try? self.store(restarted).view.pendingCount) == 0 }
        XCTAssertEqual(try store(restarted).receivedVector[origin], 400)
        XCTAssertFalse(try store(restarted).hasPromotable)
    }
}
