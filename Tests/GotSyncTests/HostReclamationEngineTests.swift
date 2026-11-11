import Foundation
import GotSyncMLS
import os
import XCTest
@_spi(HostJournalPreview) @testable import GotSync

/// A reclaiming group: an all-member reclamation round with complete store
/// scope, and a restored store whose old lineage is behind the frontier.
@MainActor
final class HostReclamationEngineTests: XCTestCase {
    var root: URL!
    var relay: FakeMLSRelay!
    var rendezvous: FakePairingRendezvous!
    var stores: [String: MemorySecretStore] = [:]
    var engines: [SyncEngine] = []
    var captured: [String: UInt64] = [:]
    let reclaimed = OSAllocatedUnfairLock(initialState: [String: [HostReclamation]]())
    let profile = try! SyncGroupProfile(
        application: "org.gotsync.host", schema: .reclaimingHostJournal(payload: "test.state", version: 1), memberLimit: 10
    )
    let schema = try! HostSnapshotSchema(label: "test.state", version: 1)

    override func setUp() async throws {
        FakeBlobRelay.reset()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        relay = FakeMLSRelay()
        rendezvous = FakePairingRendezvous()
    }

    override func tearDown() async throws {
        for engine in engines { await engine.stop() }
        try? FileManager.default.removeItem(at: root)
    }

    func engine(_ name: String) -> SyncEngine {
        let secrets = stores[name] ?? MemorySecretStore()
        stores[name] = secrets
        let engine = SyncEngine(
            configuration: try! SyncConfiguration(
                relayURL: TestEndpoints.relayURL, mailboxURL: TestEndpoints.mailboxURL,
                storageDirectory: root.appendingPathComponent(name), invitationURLScheme: "gotsync-tests",
                endpointPolicy: .localDevelopment, groupProfile: profile
            ),
            secretStore: secrets, backgroundMailboxScheduler: nil, pairingRetryDelayNanoseconds: 20_000_000,
            mlsTransport: relay, rendezvous: rendezvous, syncIntervalNanoseconds: 50_000_000
        )
        engine.snapshotRelayProtocolsForTesting = [FakeBlobRelay.self]
        engine.registerSnapshotHost(SnapshotTestHost(content: Data(repeating: 0x33, count: 4_096)).hooks(schema))
        let reclaimed = reclaimed
        engine.registerRetentionHost(HostRetentionHooks(
            attest: { request in
                HostRetentionAttestation(appliedThrough: request.appliedThrough, capturedThrough: request.capturedThrough,
                                         outboxEmpty: true, keepsDeletionMetadata: true)
            },
            reclaim: { reclamation in reclaimed.withLock { $0[name, default: []].append(reclamation) } }
        ))
        engines.append(engine)
        return engine
    }

    func wait(_ stage: String, timeout: Duration = .seconds(30), file: StaticString = #filePath, line: UInt = #line,
              until predicate: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while (try? await predicate()) != true {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out at \(stage): \(engines.map { String(describing: $0.hostView) })", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func pair(_ host: SyncEngine, _ joiner: SyncEngine) async throws {
        try await wait("host ready to invite") { !host.canCancelPairing && !host.awaitsReservationsForTesting }
        host.createPrivateSync()
        try await wait("invitation") { host.invitationURL != nil }
        joiner.joinPrivateSync(url: try XCTUnwrap(host.invitationURL))
        try await wait("safety code") { host.isHostApprovalPending && joiner.safetyCode != nil }
        host.approveSafetyCode()
        try await wait("paired") { host.isPaired && joiner.isPaired && !host.canCancelPairing }
    }

    func journal(_ engine: SyncEngine) throws -> HostJournal {
        guard let journal = engine.hostJournal else { throw HostEngineError.journalUnbound }
        return journal
    }

    func enroll(_ engine: SyncEngine, _ incarnation: HostStoreIncarnation) async throws {
        let journal = try journal(engine)
        _ = try await journal.resume(try await journal.enroll(incarnation: incarnation))
    }

    func submit(_ engine: SyncEngine, _ name: String, _ payloads: [String]) async throws {
        var mutations: [HostMutation] = []
        for payload in payloads {
            captured[name, default: 0] += 1
            mutations.append(HostMutation(id: HostMutationID(UUID()), payload: Data(payload.utf8), capturedAt: captured[name]))
        }
        _ = try await journal(engine).submit(mutations, capturedThrough: captured[name, default: 0])
    }

    @discardableResult
    func applyAll(_ engine: SyncEngine) async throws -> [String] {
        let journal = try journal(engine)
        var payloads: [String] = []
        while true {
            let batch = try await journal.incoming(after: JournalPosition(rawValue: journal.view.appliedThrough), limit: 64)
            guard let last = batch.last else { return payloads }
            payloads += batch.map { String(decoding: $0.payload, as: UTF8.self) }
            try await journal.markApplied(through: last.position)
        }
    }

    func coordinator(_ engines: [SyncEngine]) async throws -> SyncEngine {
        var best: (SyncEngine, Data)?
        for engine in engines {
            let print = try await XCTUnwrap(engine.mlsSessionForTesting).fingerprint()
            if best == nil || print.lexicographicallyPrecedes(best!.1) { best = (engine, print) }
        }
        return try XCTUnwrap(best?.0)
    }

    /// Links a founder and a fresh joiner, both settled, and returns the
    /// joiner's lineage token from before any reclamation.
    func reclaimedPair() async throws -> (SyncEngine, SyncEngine, HostLineage, [UUID]) {
        let ids = [UUID(), UUID()]
        let a = engine("a")
        let b = engine("b")
        try await pair(a, b)
        try await enroll(a, HostStoreIncarnation(storeID: ids[0], content: .nonempty, lineage: []))
        try await submit(a, "a", ["a1", "a2"])
        try await journal(a).declareReady(capturedThrough: captured["a"]!)
        try await enroll(b, HostStoreIncarnation(storeID: ids[1], content: .empty, lineage: []))
        try await wait("b bootstrapped") {
            _ = try await self.applyAll(b)
            return try self.journal(b).view.historyApplied
        }
        let early = try await journal(b).lineage()
        try await journal(b).declareReady(capturedThrough: 0)
        try await submit(a, "a", ["a3"])
        try await wait("b applied a3") {
            _ = try await self.applyAll(b)
            return try await self.journal(b).lineage().applied[self.journal(a).view.origin] == 3
        }
        XCTAssertEqual(b.hostJournalView?.journal?.ancestry, HostAncestryState(ancestry: .fresh, isResolved: true))
        XCTAssertEqual(a.hostJournalView?.journal?.ancestry, HostAncestryState(ancestry: .founder, isResolved: true))
        let lead = try await coordinator([a, b])
        let outcome = try await lead.proposeRetentionFloor()
        XCTAssertEqual(outcome, .proposed)
        try await wait("reclaimed on both") {
            try [a, b].allSatisfy { try self.journal($0).view.reclamation?.applied == true }
        }
        return (a, b, early, ids)
    }

    func testEveryStoreReclaimsThroughOneAgreedFrontierWithCompleteScope() async throws {
        let (a, b, _, ids) = try await reclaimedPair()
        let calls = reclaimed.withLock { $0 }
        XCTAssertEqual(calls["a"]?.count, 1)
        XCTAssertEqual(calls["b"]?.count, 1)
        XCTAssertEqual(calls["a"]?.first?.frontier, calls["b"]?.first?.frontier)
        XCTAssertEqual(Set(calls["a"]?.first?.stores ?? []), Set(ids), "the scope is every current store")
        let origin = try journal(a).view.origin
        XCTAssertEqual(calls["a"]?.first?.frontier[origin], 3)
        XCTAssertEqual(b.hostJournalView?.journal?.reclamation?.isApplied, true)
        XCTAssertEqual(try journal(b).view.retention?.prunedRecords, 3)
    }

    func testARestoredStoreWithAnOldLineageIsStaleUntilTheHostResolvesIt() async throws {
        let (a, _, early, _) = try await reclaimedPair()
        let c = engine("c")
        try await pair(a, c)
        try await enroll(c, HostStoreIncarnation(storeID: UUID(), content: .nonempty, lineage: [early]))
        try await wait("checkpoint installed", timeout: .seconds(60)) { (try? self.journal(c).view.bootstrap?.phase) == .completed }
        XCTAssertEqual(c.hostJournalView?.journal?.ancestry, HostAncestryState(ancestry: .staleLineage, isResolved: false))
        XCTAssertEqual(try journal(c).view.reclamation?.applied, false)
        XCTAssertNil(reclaimed.withLock { $0["c"] })
        do {
            try await journal(c).declareReady(capturedThrough: 0)
            XCTFail("a stale store must not become ready unresolved")
        } catch let error as HostJournalError {
            XCTAssertEqual(error, .ancestryUnresolved)
        }
        try await journal(c).resolveAncestry(.merged)
        try await wait("joiner host reclaimed") { try self.journal(c).view.reclamation?.applied == true }
        XCTAssertEqual(reclaimed.withLock { $0["c"]?.count }, 1)
        try await journal(c).declareReady(capturedThrough: 0)
        XCTAssertEqual(c.hostJournalView?.journal?.ancestry, HostAncestryState(ancestry: .staleLineage, isResolved: true))
    }
}
