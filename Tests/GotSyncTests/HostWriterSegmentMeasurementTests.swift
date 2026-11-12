import Foundation
import XCTest
@_spi(HostJournalPreview) @testable import GotSync

/// Main-actor segments of journal commands through the writer: each
/// command's admission and settlement, and the lateness of a 1 ms main-actor
/// ticker while the commands run. Wall time per command, which now waits off
/// the main actor, is reported separately and is not a main-actor segment.
/// Run with `GOTSYNC_MEASURE_WRITER=<samples>`; values are printed.
@MainActor
final class HostWriterSegmentMeasurementTests: XCTestCase {
    private var samples = 0
    private var segments: [String: [Double]] = [:]
    private var lateness: [Double] = []
    private var ticker: Task<Void, Never>?

    override func setUp() async throws {
        guard let value = ProcessInfo.processInfo.environment["GOTSYNC_MEASURE_WRITER"], let count = Int(value), count > 0 else {
            throw XCTSkip("Set GOTSYNC_MEASURE_WRITER to the number of samples.")
        }
        samples = count
        segments = [:]
        lateness = []
    }

    func testSubmitAtTheCallLimit() async throws {
        let limit = HostJournalLimits.standard.submitCallBytes
        startTicker()
        for sample in 0..<samples {
            let directory = try JournalFixture.directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let journal = try await HostJournal.create(in: directory, group: JournalFixture.group)
            _ = try await journal.resume(try await journal.enroll())
            let batch = (0..<(limit / 65_536)).map {
                HostMutation(id: HostMutationID(bytes: JournalFixture.mutationID(sample * 100 + $0)), payload: Data(repeating: UInt8($0), count: 65_536 - 64))
            }
            observe(journal)
            try await timed("submit.new.wall") { _ = try await journal.submit(batch, capturedThrough: 16) }
            try await timed("submit.repeated.wall") { _ = try await journal.submit(batch, capturedThrough: 16) }
            await journal.shutdown()
        }
        stopTicker()
        report("submit-\(limit / 1_024)k")
    }

    func testMarkAppliedSteps() async throws {
        let directory = try JournalFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url: URL
        let provenance: HostJournalProvenance
        do {
            let store = try HostJournalStore.create(in: directory, group: JournalFixture.group)
            provenance = try store.resume(try store.enroll())
            let origin = JournalFixture.origin(8)
            let total = samples * 257
            var prior = JournalEnvelope.zeroDigest
            for (cursor, start) in stride(from: 1, through: total, by: 256).enumerated() {
                let run = try JournalFixture.chain(origin, count: min(256, total + 1 - start), from: UInt64(start), prior: prior, payload: { _ in Data(count: 40) })
                _ = try store.intake([JournalFixture.arrival(run, cursor: UInt64(cursor + 1))])
                prior = run.last!.digest
            }
            url = store.url
        }
        let journal = try await HostJournal.open(url, resumedEnrollment: provenance.enrollmentID)
        observe(journal)
        startTicker()
        var position: UInt64 = 0
        for _ in 0..<samples {
            position += 1
            let single = position
            let singlePosition = try XCTUnwrap(JournalPosition(rawValue: single))
            try await timed("markApplied.1.wall") { try await journal.markApplied(through: singlePosition) }
            position += 256
            let batched = position
            let batchedPosition = try XCTUnwrap(JournalPosition(rawValue: batched))
            try await timed("markApplied.256.wall") { try await journal.markApplied(through: batchedPosition) }
        }
        stopTicker()
        await journal.shutdown()
        report("markApplied")
    }

    func testProofHeadIntakeAndPromotionOfANearLimitChain() async throws {
        for _ in 0..<samples {
            let directory = try JournalFixture.directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let origin = JournalFixture.origin(9)
            let chain = try JournalFixture.chain(origin, count: 10_000, payload: { _ in Data(count: 700) })
            let url: URL
            var cursor: UInt64 = 1
            do {
                let store = try HostJournalStore.create(in: directory, group: JournalFixture.group)
                for start in stride(from: 1, to: chain.count, by: 256) {
                    _ = try store.intake([JournalFixture.arrival(Array(chain[start..<min(start + 256, chain.count)]), cursor: cursor)])
                    cursor += 1
                }
                url = store.url
            }
            let journal = try await HostJournal.open(url)
            observe(journal)
            startTicker()
            let proof = try await journal.beginProof([JournalFixture.arrival([chain[0]], cursor: cursor)])
            var proven = false
            while !proven {
                try await timed("proofStep.wall") { proven = try await journal.extendProof(proof) }
            }
            try await timed("headIntake.wall") { _ = try await journal.intake(next: 1, ofProof: proof, from: 0) }
            while journal.hasPromotable {
                try await timed("promote.wall") { _ = try await journal.promote() }
            }
            XCTAssertEqual(journal.view.pendingCount, 0)
            await journal.shutdown()
            stopTicker()
        }
        report("chain-700")
    }

    // MARK: - Helpers

    private func observe(_ journal: HostJournal) {
        journal.changed = {}
        journal.segmentHookForTesting = { [weak self] name, duration in
            self?.segments[name, default: []].append(Self.milliseconds(duration))
        }
    }

    private func timed(_ name: String, _ body: () async throws -> Void) async rethrows {
        let start = ContinuousClock.now
        try await body()
        segments[name, default: []].append(Self.milliseconds(ContinuousClock.now - start))
    }

    private func startTicker() {
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let start = ContinuousClock.now
                try? await Task.sleep(for: .milliseconds(1), tolerance: .zero)
                guard !Task.isCancelled else { return }
                self?.lateness.append(max(0, Self.milliseconds(ContinuousClock.now - start) - 1))
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1e3 + Double(duration.components.attoseconds) / 1e15
    }

    private func report(_ label: String) {
        var all = segments
        all["ticker.lateness"] = lateness
        for (name, values) in all.sorted(by: { $0.key < $1.key }) where !values.isEmpty {
            let sorted = values.sorted()
            let p99 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
            print(String(
                format: "WRITER_TIMING %@.%@ n=%d p50=%.3fms p99=%.3fms max=%.3fms",
                label, name, sorted.count, sorted[sorted.count / 2], p99, sorted.last ?? 0
            ))
        }
    }
}
