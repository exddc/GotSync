import Foundation
import XCTest
@testable import GotSync

/// One `submit` call carries at most `submitCallBytes` of encoded envelopes;
/// a host splits its outbox into calls and keeps every row until accepted.
@MainActor
final class HostSubmitBoundTests: XCTestCase {
    private var directory: URL!
    private let limit = HostJournalLimits.standard.submitCallBytes

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

    /// Mutations whose encoded envelopes, headers included, total `bytes`.
    private func batch(totalling bytes: Int, from first: Int = 1) -> [HostJournalMutation] {
        let count = (bytes + JournalEnvelope.maxLength - 1) / JournalEnvelope.maxLength
        var remaining = bytes
        return (0..<count).map { index in
            let size = min(JournalEnvelope.maxLength, remaining - (count - index - 1) * JournalEnvelope.headerLength)
            remaining -= size
            return HostJournalMutation(id: JournalFixture.mutationID(first + index), payload: Data(repeating: UInt8(index % 251), count: size - JournalEnvelope.headerLength))
        }
    }

    private func state(_ store: HostJournalStore) -> [String: Data] {
        JournalFixture.storedState(store.url)
    }

    func testAcceptsExactlyTheLimitAndRefusesOneByteMoreWithoutAnyChange() throws {
        let (store, _) = try enrolled()
        let over = batch(totalling: limit + 1)
        XCTAssertEqual(over.reduce(0) { $0 + JournalEnvelope.headerLength + $1.payload.count }, limit + 1)
        let before = state(store)
        let view = store.view
        XCTAssertThrowsError(try store.submit(over, capturedThrough: 50)) {
            XCTAssertEqual($0 as? HostJournalError, .capacity(.submitCallTooLarge(limit: limit)))
        }
        XCTAssertEqual(state(store), before)
        XCTAssertEqual(store.view, view)
        XCTAssertEqual(try store.submit(batch(totalling: limit), capturedThrough: 50).count, over.count)
    }

    func testHeadersCountTowardTheLimit() throws {
        let (store, _) = try enrolled()
        let count = limit / JournalEnvelope.maxLength + 1
        let payloadOnly = (1...count).map { HostJournalMutation(id: JournalFixture.mutationID($0), payload: Data(count: limit / count)) }
        XCTAssertLessThanOrEqual(payloadOnly.reduce(0) { $0 + $1.payload.count }, limit)
        XCTAssertThrowsError(try store.submit(payloadOnly, capturedThrough: 17)) {
            XCTAssertEqual($0 as? HostJournalError, .capacity(.submitCallTooLarge(limit: limit)))
        }
    }

    func testRepeatedIDsCountAndASplitResubmissionReturnsTheSameRecords() throws {
        let (store, _) = try enrolled()
        let first = batch(totalling: limit / 2, from: 1)
        let second = batch(totalling: limit / 2, from: 100)
        let records = try store.submit(first, capturedThrough: 40) + store.submit(second, capturedThrough: 40)
        let head = store.view.ownHead
        XCTAssertThrowsError(try store.submit(first + second + [batch(totalling: 1_024, from: 200)[0]], capturedThrough: 40)) {
            XCTAssertEqual($0 as? HostJournalError, .capacity(.submitCallTooLarge(limit: limit)), "already accepted IDs were not counted")
        }
        XCTAssertEqual(try store.submit(first, capturedThrough: 40) + store.submit(second, capturedThrough: 40), records)
        XCTAssertEqual(store.view.ownHead, head)
    }

    func testAConflictInALaterChunkKeepsTheEarlierChunks() throws {
        let (store, _) = try enrolled()
        let first = batch(totalling: limit / 2, from: 1)
        let accepted = try store.submit(first, capturedThrough: 30)
        let head = store.view.ownHead
        let before = state(store)
        var later = batch(totalling: limit / 2, from: 100)
        later.append(HostJournalMutation(id: first[0].id, payload: Data("different".utf8)))
        XCTAssertThrowsError(try store.submit(later, capturedThrough: 30)) {
            XCTAssertEqual($0 as? HostJournalError, .hostMutationConflict(first[0].id))
        }
        XCTAssertEqual(state(store), before)
        XCTAssertEqual(store.view.ownHead, head)
        XCTAssertEqual(try store.submit(first, capturedThrough: 30), accepted)
    }

    func testPartiallySubmittedOutboxSurvivesRefusalCrashAndRestartWithReadinessClosed() throws {
        let (store, host) = try enrolled()
        var payloads: [Data] = []
        for index in 0..<40 {
            let payload = Data(repeating: UInt8(index), count: 60_000)
            payloads.append(payload)
            try host.capture(payload)
        }
        store.faultHookForTesting = { point in
            if point == .beforeCommit("submit"), store.view.ownHead > 0 { throw CancellationError() }
        }
        XCTAssertThrowsError(try host.submitOutbox(store, maxBytes: limit))
        store.faultHookForTesting = nil
        let firstChunk = store.view.ownHead
        XCTAssertGreaterThan(firstChunk, 0)
        XCTAssertLessThan(firstChunk, 40)
        XCTAssertEqual(host.state.outbox.count, 40 - Int(firstChunk), "accepted rows were not removed or remaining rows were lost")
        XCTAssertEqual(store.view.capturedThrough, host.state.capturedThrough, "the capture counter is recorded although rows remain")
        XCTAssertFalse(store.view.isReady)

        let restartedHost = try HostStandIn(url: directory.appendingPathComponent("host.json"))
        let reopened = try HostJournalStore.open(store.url)
        _ = try reopened.resume(XCTUnwrap(restartedHost.provenance))
        XCTAssertEqual(restartedHost.state.outbox, host.state.outbox)
        XCTAssertFalse(reopened.view.isReady)
        XCTAssertThrowsError(try reopened.submit(
            restartedHost.state.outbox.sorted { $0.key < $1.key }.map { HostJournalMutation(id: Data(base64Encoded: $0.key)!, payload: $0.value) },
            capturedThrough: restartedHost.state.capturedThrough
        )) { XCTAssertEqual($0 as? HostJournalError, .capacity(.submitCallTooLarge(limit: limit))) }
        XCTAssertEqual(reopened.view.ownHead, firstChunk)

        _ = try restartedHost.submitOutbox(reopened, maxBytes: limit)
        XCTAssertTrue(restartedHost.state.outbox.isEmpty)
        XCTAssertEqual(reopened.view.ownHead, 40, "a retry duplicated own sequences")
        try reopened.declareReady(capturedThrough: restartedHost.state.capturedThrough)
        XCTAssertTrue(reopened.view.isReady)
        let own = try JournalFixture.exportAll(reopened.url).compactMap { item -> Data? in
            if case .own(_, _, let envelope) = item { return try JournalEnvelope(parsing: envelope).payload }
            return nil
        }
        XCTAssertEqual(own, payloads)
    }
}
