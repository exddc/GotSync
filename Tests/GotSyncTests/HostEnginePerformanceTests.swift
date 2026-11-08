import Foundation
import GotSyncMLS
import XCTest
@testable import GotSync

/// Measures the synchronous main-actor work of host intake: the whole-window
/// verify and each chunk commit the engine runs between suspension points,
/// plus a cold open. The results are printed as measurements; the plan's
/// thresholds are exposure gates, not assertions here.
@MainActor
final class HostEnginePerformanceTests: XCTestCase {
    private var directory: URL!
    private var samples: [String: [Double]] = [:]
    private var cursor: UInt64 = 1

    override func setUp() async throws {
        directory = try JournalFixture.directory()
        samples = [:]
        cursor = 1
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testLargeArrivals() throws {
        let adapter = try adapterWithStore()
        let run = try JournalFixture.chain(JournalFixture.origin(3), count: 64, payload: { _ in Data(count: 65_000) })
        try drain(adapter, run.map { [$0] }, label: "64x64KiB")
        report()
    }

    func testRetainedStoreOf24MiB() throws {
        let adapter = try adapterWithStore()
        let filler = try JournalFixture.chain(JournalFixture.origin(4), count: 380, payload: { _ in Data(count: 65_000) })
        try drain(adapter, filler.map { [$0] }, label: "fill")
        XCTAssertGreaterThanOrEqual(adapter.store?.view.recordBytes ?? 0, 23 * 1_048_576 + 524_288)
        samples = [:]
        let run = try JournalFixture.chain(JournalFixture.origin(5), count: 512, payload: { _ in Data(count: 120) })
        try drain(adapter, stride(from: 0, to: run.count, by: 2).map { Array(run[$0..<$0 + 2]) }, label: "24MiB")
        report()
    }

    func testFullInboxOf1000Messages() throws {
        let adapter = try adapterWithStore()
        let run = try JournalFixture.chain(JournalFixture.origin(6), count: 4_000, payload: { _ in Data(count: 120) })
        try drain(adapter, stride(from: 0, to: run.count, by: 4).map { Array(run[$0..<$0 + 4]) }, label: "1000msg")
        report()
    }

    func testColdOpenAt120000Records() throws {
        let store = try HostJournalStore.create(in: directory, group: JournalFixture.group)
        let origin = JournalFixture.origin(7)
        var prior = JournalEnvelope.zeroDigest
        var sequence: UInt64 = 1
        while sequence <= 120_000 {
            let run = try JournalFixture.chain(origin, count: 256, from: sequence, prior: prior, payload: { _ in Data(count: 40) })
            _ = try store.intake([JournalFixture.arrival(Array(run.prefix(Int(min(256, 120_001 - sequence)))), cursor: cursor)])
            prior = run.last!.digest
            sequence += 256
            cursor += 1
        }
        XCTAssertEqual(store.view.recordCount, 120_000)
        let url = store.url
        for _ in 0..<5 {
            try measure("coldOpen.120k") { _ = try HostJournalStore.open(url) }
        }
        report()
    }

    // MARK: - Helpers

    private func adapterWithStore() throws -> HostJournalAdapter {
        let adapter = HostJournalAdapter(directory: directory, limits: .standard)
        adapter.bind(try HostJournalStore.create(in: directory, group: JournalFixture.group))
        return adapter
    }

    /// Verifies the whole window once, then commits it chunk by chunk, as
    /// the engine's drain does.
    private func drain(_ adapter: HostJournalAdapter, _ messages: [[JournalEnvelope]], label: String) throws {
        let window = try messages.map { envelopes -> ReplicationWindowItem in
            let plaintext = try HostJournalMessage.records(envelopes.map(\.bytes)).encoded()
            let decoded = adapter.decode(plaintext)
            defer { cursor += 1 }
            return ReplicationWindowItem(
                message: try Self.inboxMessage(cursor: cursor, plaintext: plaintext), fromSelf: false,
                control: decoded.control, decoded: decoded.decoded
            )
        }
        try measure("\(label).verify[\(window.count)]") { try adapter.verify(window) }
        let chunks = adapter.chunks(of: window)
        samples["\(label).chunks", default: []].append(Double(chunks.count))
        for range in chunks {
            try measure("\(label).chunk") {
                let intake = try adapter.intake(Array(window[range]))
                XCTAssertEqual(intake.heldMessages, range.count)
            }
        }
    }

    private static func inboxMessage(cursor: UInt64, plaintext: Data) throws -> MLSInboxMessage {
        let json = try JSONSerialization.data(withJSONObject: [
            "cursor": cursor, "sender": JournalFixture.sender.base64EncodedString(), "plaintext": plaintext.base64EncodedString(),
        ])
        return try JSONDecoder().decode(MLSInboxMessage.self, from: json)
    }

    private func measure(_ name: String, _ body: () throws -> Void) rethrows {
        let start = ContinuousClock.now
        try body()
        let elapsed = ContinuousClock.now - start
        samples[name, default: []].append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1e3)
    }

    private func report() {
        for (name, values) in samples.sorted(by: { $0.key < $1.key }) {
            let sorted = values.sorted()
            if name.hasSuffix(".chunks") {
                print("HOST_TIMING \(name) count=\(Int(sorted[0]))")
                continue
            }
            let p50 = sorted[sorted.count / 2]
            let p99 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
            print(String(format: "HOST_TIMING %@ n=%d p50=%.3fms p99=%.3fms max=%.3fms", name, sorted.count, p50, p99, sorted.last!))
        }
    }
}
