import Foundation
import GotSyncMLS
import os
import XCTest
@_spi(HostJournalPreview) @testable import GotSync

/// Retention floors across engines in a compacting group: an all-member
/// commit and removal, rounds that must not commit, a joiner bootstrapping
/// from the checkpoint, restart of a compacted journal and below-floor bytes.
@MainActor
final class HostRetentionEngineTests: XCTestCase {
    var root: URL!
    var relay: FakeMLSRelay!
    var rendezvous: FakePairingRendezvous!
    var stores: [String: MemorySecretStore] = [:]
    var engines: [SyncEngine] = []
    var provenances: [String: HostProvenance] = [:]
    var captured: [String: UInt64] = [:]
    let profile = try! SyncGroupProfile(
        application: "org.gotsync.host", schema: .compactingHostJournal(payload: "test.state", version: 1), memberLimit: 10
    )
    let schema = try! HostSnapshotSchema(label: "test.state", version: 1)
    let content = Data((0..<40_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })

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

    // MARK: - Harness

    func engine(_ name: String, hosts: Bool = true, attests: Bool = true) -> SyncEngine {
        let store = stores[name] ?? MemorySecretStore()
        stores[name] = store
        let engine = SyncEngine(
            configuration: try! SyncConfiguration(
                relayURL: TestEndpoints.relayURL, mailboxURL: TestEndpoints.mailboxURL,
                storageDirectory: root.appendingPathComponent(name), invitationURLScheme: "gotsync-tests",
                endpointPolicy: .localDevelopment, groupProfile: profile
            ),
            secretStore: store, backgroundMailboxScheduler: nil, pairingRetryDelayNanoseconds: 20_000_000,
            mlsTransport: relay, rendezvous: rendezvous, syncIntervalNanoseconds: 50_000_000
        )
        engine.snapshotRelayProtocolsForTesting = [FakeBlobRelay.self]
        if hosts {
            engine.registerSnapshotHost(SnapshotTestHost(content: content).hooks(schema))
            engine.registerRetentionHost(attestingHost(attests))
        }
        engines.append(engine)
        return engine
    }

    func attestingHost(_ attests: Bool) -> HostRetentionHooks {
        HostRetentionHooks { request in
            HostRetentionAttestation(
                appliedThrough: request.appliedThrough, capturedThrough: request.capturedThrough,
                outboxEmpty: attests, keepsDeletionMetadata: true
            )
        }
    }

    func opened(_ engine: SyncEngine) async {
        for _ in 0..<2_000 where engine.hostLifecycle == .opening {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func wait(_ stage: String, timeout: Duration = .seconds(30), file: StaticString = #filePath, line: UInt = #line,
              until predicate: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while (try? await predicate()) != true {
            guard ContinuousClock.now < deadline else {
                let details = engines.map { "\($0.phase) paired=\($0.isPaired) view=\(String(describing: $0.hostView))" }.joined(separator: "\n")
                XCTFail("Timed out at \(stage):\n\(details)", file: file, line: line)
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
        guard let journal = engine.hostJournal ?? engine.stoppedHostJournalForTesting else { throw HostEngineError.journalUnbound }
        return journal
    }

    func enroll(_ engine: SyncEngine, _ name: String) async throws {
        try await engine.reopenStoppedHostJournalForTesting()
        let journal = try journal(engine)
        if let stored = provenances[name] {
            provenances[name] = try await journal.resume(HostProvenance(
                journalID: stored.journalID, enrollmentID: stored.enrollmentID,
                appliedThrough: JournalPosition(rawValue: journal.view.appliedThrough), capturedThrough: captured[name] ?? 0
            ))
        } else {
            provenances[name] = try await journal.resume(try await journal.enroll())
        }
    }

    func submit(_ engine: SyncEngine, _ name: String, _ payloads: [String]) async throws {
        captured[name, default: 0] += UInt64(payloads.count)
        _ = try await journal(engine).submit(
            payloads.map { HostMutation(id: HostMutationID(UUID()), payload: Data($0.utf8)) }, capturedThrough: captured[name, default: 0]
        )
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

    func fingerprint(_ engine: SyncEngine) async throws -> Data {
        try await XCTUnwrap(engine.mlsSessionForTesting).fingerprint()
    }

    /// Links `a` and `b`, each with records the other applied, both ready.
    func settledPair() async throws -> (SyncEngine, SyncEngine) {
        let a = engine("a")
        let b = engine("b")
        try await pair(a, b)
        try await enroll(a, "a")
        try await submit(a, "a", ["a1", "a2", "a3"])
        try await journal(a).declareReady(capturedThrough: captured["a"]!)
        try await enroll(b, "b")
        try await wait("b history") { (try? self.journal(b).view.historyComplete) == true }
        try await applyAll(b)
        try await submit(b, "b", ["b1"])
        try await journal(b).declareReady(capturedThrough: captured["b"]!)
        try await wait("a has b1") { (try? self.journal(a).view.delivered) == 1 }
        try await applyAll(a)
        try await wait("settled") {
            try [a, b].allSatisfy { engine in
                let view = try self.journal(engine).view
                return view.historyApplied && view.undelivered == 0 && view.pendingCount == 0
            }
        }
        return (a, b)
    }

    func coordinator(_ engines: [SyncEngine]) async throws -> SyncEngine {
        var best: (SyncEngine, Data)?
        for engine in engines {
            let print = try await fingerprint(engine)
            if best == nil || print.lexicographicallyPrecedes(best!.1) { best = (engine, print) }
        }
        return try XCTUnwrap(best?.0)
    }

    // MARK: - Tests

    func testEveryMemberCommitsTheSameFloorAndRemovesItsRecords() async throws {
        let (a, b) = try await settledPair()
        let lead = try await coordinator([a, b])
        let other = lead === a ? b : a
        let refused = try await other.proposeRetentionFloor()
        XCTAssertEqual(refused, .notCoordinator)
        let proposed = try await lead.proposeRetentionFloor()
        XCTAssertEqual(proposed, .proposed)
        try await wait("floor committed and records removed") {
            try [a, b].allSatisfy { (try self.journal($0).view.retention?.prunedRecords ?? 0) == 4 }
        }
        let floors = try [a, b].map { try XCTUnwrap(try self.journal($0).view.retention) }
        XCTAssertEqual(floors[0].proposal, floors[1].proposal, "both committed one agreement")
        XCTAssertEqual(floors[0].floor, floors[1].floor)
        XCTAssertEqual(floors[0].floor.values.sorted(), [1, 3])
        for engine in [a, b] {
            let view = try journal(engine).view
            XCTAssertEqual(view.recordCount, 0)
            XCTAssertEqual(view.quarantineCount, 0)
            XCTAssertTrue(view.historyApplied)
            XCTAssertNotNil(engine.checkpointChunks(journal: view.journalID, offer: floors[0].checkpoint), "the checkpoint is held durably")
            XCTAssertEqual(engine.hostJournalView?.journal?.retention?.prunedRecords, 4)
        }
        try await submit(a, "a", ["a4"])
        try await wait("tail after compaction") { (try? self.journal(b).view.delivered) == 4 }
        let tail = try await applyAll(b)
        XCTAssertEqual(tail, ["a4"])
    }

    func testACheckpointReuseRefusesChangedOrTruncatedBytes() async throws {
        let (a, b) = try await settledPair()
        let lead = try await coordinator([a, b])
        _ = try await lead.proposeRetentionFloor()
        try await wait("compacted") {
            try [a, b].allSatisfy { (try self.journal($0).view.retention?.prunedRecords ?? 0) == 4 }
        }
        let floor = try XCTUnwrap(try journal(lead).view.retention)
        let files = try XCTUnwrap(lead.checkpointChunks(journal: try journal(lead).view.journalID, offer: floor.checkpoint))
        let copy = root.appendingPathComponent("checkpoint-copy")
        let bytes = try Data(contentsOf: XCTUnwrap(files.first))
        try bytes.write(to: copy)
        XCTAssertTrue(try SyncEngine.checkpointMatches([copy], offer: floor.checkpoint))
        var changed = bytes
        changed[0] ^= 1
        try changed.write(to: copy)
        XCTAssertFalse(try SyncEngine.checkpointMatches([copy], offer: floor.checkpoint))
        try bytes.dropLast().write(to: copy)
        XCTAssertFalse(try SyncEngine.checkpointMatches([copy], offer: floor.checkpoint))
    }

    func testAnEpochChangeDropsARoundEvenWhenEveryVoteIsAccepted() async throws {
        let (a, b) = try await settledPair()
        let lead = try await coordinator([a, b])
        let other = lead === a ? b : a
        let blocked = OSAllocatedUnfairLock(initialState: true)
        defer { blocked.withLock { $0 = false } }
        other.registerRetentionHost(HostRetentionHooks { request in
            while blocked.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
            return HostRetentionAttestation(appliedThrough: request.appliedThrough, capturedThrough: request.capturedThrough,
                                            outboxEmpty: true, keepsDeletionMetadata: true)
        })
        _ = try await lead.proposeRetentionFloor()
        try await wait("checkpoint exported") { lead.retentionRound != nil }
        let original = try XCTUnwrap(lead.retentionRound)
        let proposal = HostRetentionProposal(round: original.proposal.round, epoch: original.proposal.epoch + 1,
                                             roster: original.proposal.roster, anchors: original.proposal.anchors,
                                             checkpoint: original.proposal.checkpoint)
        let otherID = try await fingerprint(other)
        var stale = HostRetentionRound(proposal: proposal, digest: proposal.digest, proposer: original.proposer, voted: true)
        stale.votes[otherID] = HostRetentionVote(round: proposal.round, proposal: proposal.digest, accept: true)
        lead.retentionRound = stale
        try await wait("epoch mismatch dropped") { lead.retentionRound == nil }
        XCTAssertNil(try journal(lead).view.retention)
        XCTAssertEqual(try journal(lead).view.recordCount, 4)
    }

    func testAMemberThatCannotAttestOrIsStoppedPreventsAnyFloor() async throws {
        let (a, b) = try await settledPair()
        let lead = try await coordinator([a, b])
        let other = lead === a ? b : a
        other.registerRetentionHost(attestingHost(false))
        let proposed = try await lead.proposeRetentionFloor()
        XCTAssertEqual(proposed, .proposed)
        try await wait("round closed by the decline") { lead.retentionRound == nil && lead.retentionTask == nil && other.retentionTask == nil }
        try await Task.sleep(for: .milliseconds(300))
        for engine in [a, b] {
            XCTAssertNil(try journal(engine).view.retention, "an unsettled host prevents the floor")
            XCTAssertEqual(try journal(engine).view.recordCount, 4)
        }

        other.registerRetentionHost(attestingHost(true))
        await other.stop()
        let again = try await lead.proposeRetentionFloor()
        XCTAssertEqual(again, .proposed)
        try await Task.sleep(for: .seconds(1))
        XCTAssertNil(try journal(lead).view.retention, "an offline member cannot vote, so nothing commits")
        XCTAssertEqual(try journal(lead).view.recordCount, 4)
    }

    func testARosterChangeDropsAnOpenRound() async throws {
        let (a, b) = try await settledPair()
        let lead = try await coordinator([a, b])
        let other = lead === a ? b : a
        let blocked = OSAllocatedUnfairLock(initialState: true)
        other.registerRetentionHost(HostRetentionHooks { request in
            while blocked.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(20)) }
            return HostRetentionAttestation(appliedThrough: request.appliedThrough, capturedThrough: request.capturedThrough,
                                            outboxEmpty: true, keepsDeletionMetadata: true)
        })
        let proposed = try await lead.proposeRetentionFloor()
        XCTAssertEqual(proposed, .proposed)
        try await wait("vote pending") { other.retentionRound != nil && other.retentionTask != nil }
        let c = engine("c")
        try await pair(lead, c)
        try await wait("roster grew") { lead.linkedMemberCount == 3 }
        blocked.withLock { $0 = false }
        try await Task.sleep(for: .seconds(1))
        XCTAssertNil(try journal(lead).view.retention, "votes for the earlier roster never commit")
        XCTAssertNil(try journal(other).view.retention)
    }

    func testAJoinerAfterCompactionInstallsTheCorroboratedCheckpointAndOnlyGetsTheTail() async throws {
        let (a, b) = try await settledPair()
        let lead = try await coordinator([a, b])
        _ = try await lead.proposeRetentionFloor()
        try await wait("compacted") { try [a, b].allSatisfy { (try self.journal($0).view.retention?.prunedRecords ?? 0) == 4 } }
        try await submit(a, "a", ["a4"])
        try await wait("b has a4") { (try? self.journal(b).view.delivered) == 4 }
        try await applyAll(b)

        let c = engine("c")
        try await pair(lead, c)
        try await enroll(c, "c")
        try await wait("checkpoint installed", timeout: .seconds(60)) {
            (try? self.journal(c).view.bootstrap?.phase) == .completed
        }
        let view = try journal(c).view
        XCTAssertEqual(view.retention?.floorApplied, true)
        XCTAssertEqual(view.retention?.proposal, try journal(a).view.retention?.proposal)
        XCTAssertEqual(view.recordCount, 1, "only a4 was received; the floor's records exist nowhere")
        let tail = try await applyAll(c)
        XCTAssertEqual(tail, ["a4"])
        XCTAssertTrue(try journal(c).view.historyApplied)
        XCTAssertNotNil(c.checkpointChunks(journal: view.journalID, offer: try XCTUnwrap(view.retention?.checkpoint)))
    }

    func testACompactedJournalRestartsAndRefusesBelowFloorBytesWithoutProof() async throws {
        let (a, b) = try await settledPair()
        let lead = try await coordinator([a, b])
        let other = lead === a ? b : a
        _ = try await lead.proposeRetentionFloor()
        try await wait("compacted") { try [a, b].allSatisfy { (try self.journal($0).view.retention?.prunedRecords ?? 0) == 4 } }
        let names = [ObjectIdentifier(a): "a", ObjectIdentifier(b): "b"]
        let otherName = try XCTUnwrap(names[ObjectIdentifier(other)])
        let floor = try XCTUnwrap(try journal(other).view.retention)

        await other.stop()
        engines.removeAll { $0 === other }
        let restarted = engine(otherName)
        await opened(restarted)
        try await enroll(restarted, otherName)
        XCTAssertEqual(try journal(restarted).view.retention, floor, "the committed floor survives a restart")
        XCTAssertTrue(try journal(restarted).view.historyApplied)

        let aOrigin = try journal(a).view.origin
        let leadName = try XCTUnwrap(names[ObjectIdentifier(lead)])
        let forged = try JournalEnvelope(origin: aOrigin == (try journal(lead).view.origin) ? aOrigin : try journal(lead).view.origin,
                                         sequence: 1, prior: JournalEnvelope.zeroDigest, payload: Data("forged \(leadName)".utf8))
        let session = try XCTUnwrap(lead.mlsSessionForTesting)
        guard case .accepted = try await session.send(HostJournalMessage.records([forged.bytes]).encoded()) else { throw CancellationError() }
        try await wait("refused below-floor bytes") { (try? self.journal(restarted).view.quarantineCount) == 1 }
        XCTAssertEqual(try journal(restarted).view.recordCount, 0, "the forged record was never accepted as a duplicate")
    }

    func testACompactingGroupRefusesToPairWithoutBothHosts() async throws {
        let a = engine("a")
        let b = engine("b", hosts: false)
        try await wait("host ready to invite") { !a.canCancelPairing && !a.awaitsReservationsForTesting }
        a.createPrivateSync()
        try await wait("invitation") { a.invitationURL != nil }
        b.joinPrivateSync(url: try XCTUnwrap(a.invitationURL))
        try await wait("refused before Add") { b.errorMessage != nil }
        XCTAssertFalse(b.isPaired)
    }
}
