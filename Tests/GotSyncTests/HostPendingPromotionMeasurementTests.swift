import Foundation
import XCTest
@_spi(HostJournalPreview) @testable import GotSync

/// Characterizes closing a near-limit pending chain: the window proof
/// steps, the arriving head's proof-token intake, and every bounded
/// promotion step that follows.
/// Run with `GOTSYNC_MEASURE_PROMOTION=<samples>`; the samples are printed,
/// and only the state after promotion is asserted.
@MainActor
final class HostPendingPromotionMeasurementTests: XCTestCase {
    private var samples: Int = 0

    override func setUp() async throws {
        guard let value = ProcessInfo.processInfo.environment["GOTSYNC_MEASURE_PROMOTION"], let count = Int(value), count > 0 else {
            throw XCTSkip("Set GOTSYNC_MEASURE_PROMOTION to the number of samples.")
        }
        samples = count
    }

    func testClosingANearLimitPendingChainWithSmallRecords() throws {
        try measurePromotion(label: "small", pending: 9_999, payload: 40)
    }

    func testClosingANearLimitPendingChainNearThePendingByteLimit() throws {
        try measurePromotion(label: "bytes", pending: 9_999, payload: 700)
    }

    func testClosingANearLimitPendingChainWithTwiceTheStepBound() throws {
        try measurePromotion(label: "bytes-256", pending: 9_999, payload: 700, maxRecords: 256, maxBytes: 262_144)
    }

    /// One-megabyte `submit` calls: new mutations, then the same batch again,
    /// which returns the existing records.
    /// Calls that fill the current limit exactly: each mutation encodes to
    /// 65,536 bytes with its header.
    func testSubmitCallsAtTheByteLimit() throws {
        let limit = HostJournalLimits.standard.submitCallBytes
        try measureSubmitCalls(label: "submit-\(limit / 1_024)k", mutations: limit / 65_536, limit: limit)
    }

    /// The earlier trial limits, 1 MiB and 512 KiB, measured again on the same terms.
    func testSubmitCallsAtTheEarlierTrialLimits() throws {
        try measureSubmitCalls(label: "submit-1024k", mutations: 16, limit: 1_048_576)
        try measureSubmitCalls(label: "submit-512k", mutations: 8, limit: 524_288)
    }

    private func measureSubmitCalls(label: String, mutations: Int, limit: Int) throws {
        var limits = HostJournalLimits.standard
        limits.submitCallBytes = limit
        var fresh: [Double] = []
        var repeated: [Double] = []
        var commits: [Double] = []
        for sample in 0..<(samples * 4) {
            let directory = try JournalFixture.directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try HostJournalStore.create(in: directory, group: JournalFixture.group, limits: limits)
            _ = try store.resume(try store.enroll())
            let batch = (0..<mutations).map { index in
                HostJournalMutation(id: JournalFixture.mutationID(sample * 100 + index), payload: Data(repeating: UInt8(index), count: 65_536 - 64))
            }
            var commitStart: ContinuousClock.Instant?
            store.faultHookForTesting = { point in
                switch point {
                case .beforeCommit: commitStart = .now
                case .afterCommit: if let start = commitStart { commits.append(Self.milliseconds(ContinuousClock.now - start)) }
                }
            }
            var start = ContinuousClock.now
            XCTAssertEqual(try store.submit(batch, capturedThrough: 16).count, mutations)
            fresh.append(Self.milliseconds(ContinuousClock.now - start))
            start = ContinuousClock.now
            XCTAssertEqual(try store.submit(batch, capturedThrough: 16).count, mutations)
            repeated.append(Self.milliseconds(ContinuousClock.now - start))
        }
        Self.report("\(label).new", fresh)
        Self.report("\(label).repeated", repeated)
        Self.report("\(label).commit", commits)
    }

    /// Host application acknowledgements of 1 and of 256 records.
    func testMarkAppliedSteps() throws {
        let directory = try JournalFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HostJournalStore.create(in: directory, group: JournalFixture.group)
        _ = try store.resume(try store.enroll())
        let origin = JournalFixture.origin(8)
        let total = samples * 257
        var prior = JournalEnvelope.zeroDigest
        for (cursor, start) in stride(from: 1, through: total, by: 256).enumerated() {
            let run = try JournalFixture.chain(origin, count: min(256, total + 1 - start), from: UInt64(start), prior: prior, payload: { _ in Data(count: 40) })
            _ = try store.intake([JournalFixture.arrival(run, cursor: UInt64(cursor + 1))])
            prior = run.last!.digest
        }
        var single: [Double] = []
        var batched: [Double] = []
        var position: UInt64 = 0
        for _ in 0..<samples {
            position += 1
            var start = ContinuousClock.now
            try store.markApplied(through: position)
            single.append(Self.milliseconds(ContinuousClock.now - start))
            position += 256
            start = ContinuousClock.now
            try store.markApplied(through: position)
            batched.append(Self.milliseconds(ContinuousClock.now - start))
        }
        Self.report("markApplied.1", single)
        Self.report("markApplied.256", batched)
    }

    /// The durable cost of the smallest write transaction, for comparison
    /// with promotion commits on the same machine.
    func testMinimalTransactionCommit() throws {
        let directory = try JournalFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HostJournalStore.create(in: directory, group: JournalFixture.group)
        var commitStart: ContinuousClock.Instant?
        var commits: [Double] = []
        store.faultHookForTesting = { point in
            switch point {
            case .beforeCommit: commitStart = .now
            case .afterCommit: if let start = commitStart { commits.append(Self.milliseconds(ContinuousClock.now - start)) }
            }
        }
        for index in 0..<(samples * 40) {
            try store.setHistoryProvider(Data(repeating: UInt8(index % 2), count: 32))
        }
        Self.report("minimal.commit", commits)
    }

    private func measurePromotion(
        label: String, pending: Int, payload: Int, maxRecords: Int = 128, maxBytes: Int = 131_072
    ) throws {
        var proofSteps: [Double] = []
        var headTotals: [Double] = []
        var headCommits: [Double] = []
        var promoteTotals: [Double] = []
        var promoteCommits: [Double] = []
        for _ in 0..<samples {
            let directory = try JournalFixture.directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try HostJournalStore.create(in: directory, group: JournalFixture.group)
            let origin = JournalFixture.origin(9)
            let chain = try JournalFixture.chain(origin, count: pending + 1, payload: { _ in Data(count: payload) })
            var cursor: UInt64 = 1
            for start in stride(from: 1, to: chain.count, by: 256) {
                let run = Array(chain[start..<min(start + 256, chain.count)])
                XCTAssertEqual(try store.intake([JournalFixture.arrival(run, cursor: cursor)]).ownedArrivals, 1)
                cursor += 1
            }
            XCTAssertEqual(store.view.pendingCount, UInt64(pending))
            XCTAssertEqual(store.view.recordCount, 0)
            XCTAssertFalse(store.hasPromotable)
            let retainedBefore = store.view.retainedBytes

            var proof = try store.beginProof([JournalFixture.arrival([chain[0]], cursor: cursor)])
            var proven = false
            while !proven {
                let start = ContinuousClock.now
                proven = try store.extendProof(&proof)
                proofSteps.append(Self.milliseconds(ContinuousClock.now - start))
            }

            var commitStart: ContinuousClock.Instant?
            var commitEnd: ContinuousClock.Instant?
            store.faultHookForTesting = { point in
                switch point {
                case .beforeCommit: commitStart = .now
                case .afterCommit: commitEnd = .now
                }
            }
            var start = ContinuousClock.now
            let intake = try store.intake(next: 1, of: &proof)
            headTotals.append(Self.milliseconds(ContinuousClock.now - start))
            headCommits.append(Self.milliseconds(try XCTUnwrap(commitEnd) - XCTUnwrap(commitStart)))
            XCTAssertEqual(intake.ownedArrivals, 1)
            XCTAssertEqual(store.view.recordCount, 1)
            XCTAssertEqual(store.view.pendingCount, UInt64(pending))
            XCTAssertTrue(store.hasPromotable)
            XCTAssertEqual(try store.receivedVector()[origin], 1)

            var received: UInt64 = 1
            while store.hasPromotable {
                start = ContinuousClock.now
                let moved = try store.promote(maxRecords: maxRecords, maxBytes: maxBytes)
                promoteTotals.append(Self.milliseconds(ContinuousClock.now - start))
                promoteCommits.append(Self.milliseconds(try XCTUnwrap(commitEnd) - XCTUnwrap(commitStart)))
                XCTAssertGreaterThan(moved, 0)
                XCTAssertLessThanOrEqual(moved, maxRecords)
                received += UInt64(moved)
                XCTAssertEqual(try store.receivedVector()[origin], received)
                XCTAssertEqual(store.view.retainedBytes, retainedBefore + UInt64(chain[0].bytes.count))
            }
            store.faultHookForTesting = nil

            let after = store.view
            XCTAssertEqual(after.pendingCount, 0)
            XCTAssertEqual(after.pendingBytes, 0)
            XCTAssertEqual(after.recordCount, UInt64(pending + 1))
            XCTAssertEqual(after.delivered, UInt64(pending + 1))
            XCTAssertEqual(try store.receivedVector()[origin], UInt64(pending + 1))
            XCTAssertEqual(try HostJournalStore.open(store.url).view, after, "the promoted state did not reopen identically")
        }
        Self.report("\(label).proofStep", proofSteps)
        Self.report("\(label).head.total", headTotals)
        Self.report("\(label).head.commit", headCommits)
        Self.report("\(label).promote.total", promoteTotals)
        Self.report("\(label).promote.commit", promoteCommits)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1e3 + Double(duration.components.attoseconds) / 1e15
    }

    private static func report(_ name: String, _ values: [Double]) {
        let sorted = values.sorted()
        let p99 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
        let raw = values.map { String(format: "%.2f", $0) }.joined(separator: ",")
        print(String(
            format: "PROMOTION_TIMING %@ n=%d min=%.2fms p50=%.2fms p99=%.2fms max=%.2fms",
            name, sorted.count, sorted.first ?? 0, sorted[sorted.count / 2], p99, sorted.last ?? 0
        ))
        print("PROMOTION_RAW \(name) [\(raw)]")
    }
}
