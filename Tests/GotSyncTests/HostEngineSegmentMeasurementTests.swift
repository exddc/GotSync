import Foundation
import GotSyncMLS
import XCTest
@_spi(HostJournalPreview) @testable import GotSync

/// Main-actor segments of the host engine around the writer: window decode
/// stretches, the drain-chunk continuation up to acknowledgement, checkpoint
/// saves, view and state publication with live subscribers, and the journal
/// facade's admission and settlement, plus a 1 ms main-actor ticker over the
/// whole flow. Run with `GOTSYNC_MEASURE_ENGINE=<samples>`; values are printed.
extension HostEngineTests {
    @MainActor
    private final class SegmentLog {
        var segments: [String: [Double]] = [:]
        var lateness: [Double] = []
        var ticker: Task<Void, Never>?

        func record(_ name: String, _ duration: Duration) {
            segments[name, default: []].append(Self.milliseconds(duration))
        }

        func startTicker() {
            ticker = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    let start = ContinuousClock.now
                    try? await Task.sleep(for: .milliseconds(1), tolerance: .zero)
                    guard !Task.isCancelled else { return }
                    self?.lateness.append(max(0, Self.milliseconds(ContinuousClock.now - start) - 1))
                }
            }
        }

        func stopTicker() {
            ticker?.cancel()
            ticker = nil
        }

        nonisolated static func milliseconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1e3 + Double(duration.components.attoseconds) / 1e15
        }

        func report(_ label: String) {
            var all = segments
            all["ticker.lateness"] = lateness
            for (name, values) in all.sorted(by: { $0.key < $1.key }) where !values.isEmpty {
                let sorted = values.sorted()
                let p99 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
                print(String(
                    format: "ENGINE_TIMING %@.%@ n=%d p50=%.3fms p99=%.3fms max=%.3fms",
                    label, name, sorted.count, sorted[sorted.count / 2], p99, sorted.last ?? 0
                ))
            }
        }
    }

    private func engineSamples() throws -> Int {
        guard let value = ProcessInfo.processInfo.environment["GOTSYNC_MEASURE_ENGINE"], let count = Int(value), count > 0 else {
            throw XCTSkip("Set GOTSYNC_MEASURE_ENGINE to the number of samples.")
        }
        return count
    }

    /// Hooks both engines and their current journals, and keeps a view and
    /// a state subscriber on each that read the composed view per update.
    private func observe(_ engines: [SyncEngine], into log: SegmentLog) async throws -> [Task<Void, Never>] {
        var subscribers: [Task<Void, Never>] = []
        for engine in engines {
            try await engine.reopenStoppedHostJournalForTesting()
            engine.segmentHookForTesting = { log.record($0, $1) }
            try store(engine).segmentHookForTesting = { log.record("journal.\($0)", $1) }
            subscribers.append(Task { @MainActor in
                for await _ in engine.hostViewChanges() { _ = engine.hostView?.isQuiescent }
            })
            subscribers.append(Task { @MainActor in
                for await state in engine.states() { _ = state.phase }
            })
        }
        return subscribers
    }

    func testEngineSegmentsForSteadyHostTraffic() async throws {
        let samples = try engineSamples()
        let (a, b) = try await completedPair()
        await a.stop()
        await b.stop()
        let log = SegmentLog()
        let subscribers = try await observe([a, b], into: log)
        let bSession = try XCTUnwrap(b.mlsSessionForTesting)
        log.startTicker()
        for index in 0..<samples {
            try await submit(a, "a", ["steady \(index)"])
            try await a.uploadLocalOperationsForTesting()
            _ = try await bSession.synchronize()
            try await b.drainInboxForTesting()
            try await applyAll(b, "b")
        }
        log.stopTicker()
        subscribers.forEach { $0.cancel() }
        XCTAssertEqual(try store(b).view.delivered, UInt64(3 + samples))
        log.report("steady")
    }

    func testEngineSegmentsForLargeWindows() async throws {
        let samples = try engineSamples()
        let log = SegmentLog()
        let origin = Data(repeating: 0x6C, count: 16)
        let windows = max(1, samples / 7 + (samples % 7 == 0 ? 0 : 1))
        let perWindow = 32
        for start in stride(from: 0, to: windows, by: 4) {
            let receiver = "large-b-\(start)"
            let (a, b) = try await completedPair("large-a-\(start)", receiver)
            await a.stop()
            await b.stop()
            let subscribers = try await observe([b], into: log)
            let aSession = try XCTUnwrap(a.mlsSessionForTesting)
            let bSession = try XCTUnwrap(b.mlsSessionForTesting)
            let count = min(4, windows - start)
            let chain = try JournalFixture.chain(origin, count: count * perWindow, payload: { _ in Data(count: 60_000) })
            log.startTicker()
            defer {
                log.stopTicker()
                subscribers.forEach { $0.cancel() }
            }
            for window in 0..<count {
                for envelope in chain[(window * perWindow)..<((window + 1) * perWindow)] {
                    try await send(.records([envelope.bytes]), from: aSession)
                }
                _ = try await bSession.synchronize()
                try await b.drainInboxForTesting()
                try await applyAll(b, receiver)
            }
            log.stopTicker()
            XCTAssertEqual(try store(b).receivedVector[origin], UInt64(chain.count))
            await b.stop()
            engines.removeAll { $0 === a || $0 === b }
        }
        for name in ["drain.decode", "drain.continuation"] {
            XCTAssertGreaterThanOrEqual(log.segments[name]?.count ?? 0, samples, name)
        }
        log.report("large-windows")
    }
}
