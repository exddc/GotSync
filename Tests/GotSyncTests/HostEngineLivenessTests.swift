import Foundation
import GotSyncMLS
import XCTest
@_spi(HostJournalPreview) @testable import GotSync

/// Intake settles only after the last MLS-capable worker ends, and the
/// composed view reaches every independent subscriber.
extension HostEngineTests {
    private func settledAndStopped(_ engine: SyncEngine) async throws {
        try await wait("settled") { engine.hostView?.intake == .settled(held: 0) }
        await engine.stop()
    }

    func testOverlappingWorkersSettleOnlyAfterTheLastExitsWithoutNetwork() async throws {
        let (a, _) = try await completedPair()
        try await settledAndStopped(a)
        var gates: [CheckedContinuation<Void, Never>] = []
        for _ in 0..<2 {
            a.runHostWorkerForTesting { await withCheckedContinuation { gates.append($0) } }
        }
        try await wait("workers waiting") { gates.count == 2 }
        try await a.settleHostIntakeForTesting()
        XCTAssertEqual(a.hostView?.intake, .unknown)
        await relay.setOffline(try await authorization(a), true)
        gates.removeFirst().resume()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(a.hostView?.intake, .unknown, "settled while a worker was live")
        let revision = try XCTUnwrap(a.hostView).revision
        gates.removeFirst().resume()
        try await wait("settled after the last worker") { a.hostView?.intake == .settled(held: 0) }
        XCTAssertGreaterThan(try XCTUnwrap(a.hostView).revision, revision)
        await relay.setOffline(try await authorization(a), false)
    }

    func testCancelledWorkerSchedulesOneSettlement() async throws {
        let (a, _) = try await completedPair()
        try await settledAndStopped(a)
        let worker = a.runHostWorkerForTesting {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
        }
        try await a.settleHostIntakeForTesting()
        XCTAssertEqual(a.hostView?.intake, .unknown)
        worker.cancel()
        try await wait("settled after cancellation") { a.hostView?.intake == .settled(held: 0) }
    }

    func testWorkerStartingDuringTheInboxReadBlocksSettlement() async throws {
        let (a, _) = try await completedPair()
        try await settledAndStopped(a)
        var gate: CheckedContinuation<Void, Never>?
        a.settleReadHookForTesting = {
            a.settleReadHookForTesting = nil
            a.runHostWorkerForTesting { await withCheckedContinuation { gate = $0 } }
        }
        try await a.settleHostIntakeForTesting()
        XCTAssertEqual(a.hostView?.intake, .unknown, "a worker that started during the read was ignored")
        try await wait("worker waiting") { gate != nil }
        gate?.resume()
        try await wait("settled after the late worker") { a.hostView?.intake == .settled(held: 0) }
    }

    func testViewStreamsAreIndependentNewestOnlyAndFinishOnStop() async throws {
        let (a, _) = try await completedPair()
        try await settledAndStopped(a)
        let first = a.hostViewChanges()
        let slow = a.hostViewChanges()
        var firstIterator = first.makeAsyncIterator()
        let initial = await firstIterator.next()
        XCTAssertEqual(initial, a.hostView?.revision)
        for index in 0..<3 {
            try await submit(a, "a", ["stream \(index)"])
        }
        let latest = try XCTUnwrap(a.hostView).revision
        var slowIterator = slow.makeAsyncIterator()
        let buffered = await slowIterator.next()
        XCTAssertEqual(buffered, latest, "a slow subscriber did not get the newest revision only")
        let next = await firstIterator.next()
        XCTAssertEqual(next, latest)
        await a.stop()
        let ended = await firstIterator.next()
        let slowEnded = await slowIterator.next()
        XCTAssertNil(ended)
        XCTAssertNil(slowEnded)
    }
}
