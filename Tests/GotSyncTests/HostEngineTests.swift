import CryptoKit
import Foundation
import GotSyncMLS
import XCTest
@testable import GotSync

/// Host-journal groups on the one sync engine: generation binding, provider
/// eligibility and finite completion, intake ownership, quiescence and the
/// closing lifecycle.
@MainActor
final class HostEngineTests: XCTestCase {
    var root: URL!
    var relay: FakeMLSRelay!
    var rendezvous: FakePairingRendezvous!
    var stores: [String: MemorySecretStore] = [:]
    var engines: [SyncEngine] = []
    var provenances: [String: HostJournalProvenance] = [:]
    var captured: [String: UInt64] = [:]
    let profile = try! SyncGroupProfile(
        application: "org.gotsync.host", schema: .hostJournal(payload: "example.records", version: 1), memberLimit: 10
    )

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        relay = FakeMLSRelay()
        rendezvous = FakePairingRendezvous()
        stores = [:]
        engines = []
        provenances = [:]
        captured = [:]
    }

    override func tearDown() async throws {
        for engine in engines { await engine.stop() }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Harness

    func engine(_ name: String, limits: HostJournalLimits = .standard) -> SyncEngine {
        let store = stores[name] ?? MemorySecretStore()
        stores[name] = store
        let engine = SyncEngine(
            configuration: try! SyncConfiguration(
                relayURL: TestEndpoints.relayURL,
                mailboxURL: TestEndpoints.mailboxURL,
                storageDirectory: directory(name),
                invitationURLScheme: "gotsync-tests",
                endpointPolicy: .localDevelopment,
                groupProfile: profile
            ),
            secretStore: store,
            backgroundMailboxScheduler: nil,
            pairingRetryDelayNanoseconds: 20_000_000,
            mlsTransport: relay,
            rendezvous: rendezvous,
            syncIntervalNanoseconds: 50_000_000,
            hostJournalLimits: limits
        )
        engines.append(engine)
        return engine
    }

    func directory(_ name: String) -> URL { root.appendingPathComponent(name) }

    func restart(_ engine: SyncEngine, _ name: String, limits: HostJournalLimits = .standard) async -> SyncEngine {
        await engine.stop()
        engines.removeAll { $0 === engine }
        let restarted = self.engine(name, limits: limits)
        await opened(restarted)
        return restarted
    }

    /// Waits until a launch has validated and installed its journal.
    func opened(_ engine: SyncEngine) async {
        for _ in 0..<2_000 where engine.hostLifecycle == .opening {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func wait(
        _ stage: String, timeout: Duration = .seconds(20), file: StaticString = #filePath, line: UInt = #line,
        until predicate: () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while (try? await predicate()) != true {
            guard ContinuousClock.now < deadline else {
                let details = engines.map {
                    "\($0.phase) paired=\($0.isPaired) cancel=\($0.canCancelPairing) lifecycle=\($0.hostLifecycle) repair=\(String(describing: $0.hostRepair)) error=\($0.errorMessage ?? "none") view=\(String(describing: $0.hostView))"
                }.joined(separator: "\n")
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

    func fingerprint(_ engine: SyncEngine) async throws -> Data {
        try await XCTUnwrapAsync(await engine.mlsSessionForTesting?.fingerprint())
    }

    func authorization(_ engine: SyncEngine) async throws -> Data {
        try await XCTUnwrapAsync(engine.mlsSessionForTesting).client.transportAuthorization()
    }

    /// The engine's journal; after `stop`, the closed one, whose view stays
    /// readable and whose calls are refused.
    func store(_ engine: SyncEngine) throws -> HostJournal {
        guard let journal = engine.hostJournal ?? engine.stoppedHostJournalForTesting else { throw HostEngineError.journalUnbound }
        return journal
    }

    func enroll(_ engine: SyncEngine, _ name: String) async throws {
        try await engine.reopenStoppedHostJournalForTesting()
        let journal = try store(engine)
        if let stored = provenances[name] {
            provenances[name] = try await journal.resume(HostJournalProvenance(
                journalID: stored.journalID, enrollmentID: stored.enrollmentID,
                appliedThrough: max(stored.appliedThrough, journal.view.appliedThrough),
                capturedThrough: captured[name] ?? stored.capturedThrough
            ))
        } else {
            provenances[name] = try await journal.resume(try await journal.enroll())
        }
    }

    @discardableResult
    func submit(_ engine: SyncEngine, _ name: String, _ payloads: [String]) async throws -> [JournalRecordID] {
        try await engine.reopenStoppedHostJournalForTesting()
        captured[name, default: 0] += UInt64(payloads.count)
        return try await store(engine).submit(
            payloads.map { HostJournalMutation(id: HostJournalStore.randomBytes(16), payload: Data($0.utf8)) },
            capturedThrough: captured[name, default: 0]
        )
    }

    func ready(_ engine: SyncEngine, _ name: String) async throws {
        try await engine.reopenStoppedHostJournalForTesting()
        try await store(engine).declareReady(capturedThrough: captured[name, default: 0])
    }

    @discardableResult
    func applyAll(_ engine: SyncEngine, _ name: String) async throws -> [Data] {
        try await engine.reopenStoppedHostJournalForTesting()
        let journal = try store(engine)
        var payloads: [Data] = []
        while true {
            let batch = try await journal.incoming(after: journal.view.appliedThrough, limit: 64)
            guard let last = batch.last else { return payloads }
            payloads += batch.map(\.payload)
            try await journal.markApplied(through: last.position)
        }
    }

    func send(_ message: HostJournalMessage, from session: MLSSession) async throws {
        guard case .accepted = try await session.send(message.encoded()) else { throw CancellationError() }
    }

    func inboxMessages(_ engine: SyncEngine) async throws -> [HostJournalMessage] {
        let session = try XCTUnwrap(engine.mlsSessionForTesting)
        _ = try await session.synchronize()
        return try await session.inbox().compactMap { try? HostJournalMessage.decode($0.plaintext) }
    }

    /// Links `a` and `b`; `a` enrolls, submits and declares ready, `b`
    /// enrolls and applies its completed history.
    func completedPair(
        _ a: String = "a", _ b: String = "b", records: [String] = ["one", "two", "three"], limits: HostJournalLimits = .standard
    ) async throws -> (SyncEngine, SyncEngine) {
        let first = engine(a)
        let second = engine(b, limits: limits)
        try await pair(first, second)
        try await enroll(first, a)
        try await submit(first, a, records)
        try await ready(first, a)
        try await enroll(second, b)
        try await wait("history complete") { (try? self.store(second).view.historyComplete) == true }
        try await applyAll(second, b)
        try await ready(second, b)
        return (first, second)
    }

    // MARK: - Bootstrap and completion

    func testFreshFounderLinksWithoutAJournalAndJoinerCompletesHistory() async throws {
        let a = engine("a")
        let b = engine("b")
        XCTAssertNil(a.hostJournal)
        try await pair(a, b)
        let founder = try store(a)
        XCTAssertTrue(founder.view.established)
        XCTAssertTrue(founder.view.historyComplete)
        let joiner = try store(b)
        XCTAssertTrue(joiner.view.established)
        XCTAssertFalse(joiner.view.historyComplete)
        XCTAssertEqual(try XCTUnwrap(b.hostView).journal?.journalID, joiner.view.journalID)

        try await enroll(a, "a")
        try await submit(a, "a", ["one", "two", "three"])
        try await ready(a, "a")
        try await enroll(b, "b")
        try await wait("history complete") { joiner.view.historyComplete && joiner.view.delivered == 3 }
        XCTAssertFalse(joiner.view.historyApplied)
        let applied = try await applyAll(b, "b")
        XCTAssertEqual(applied.map { String(decoding: $0, as: UTF8.self) }, ["one", "two", "three"])
        XCTAssertTrue(joiner.view.historyApplied)
        try await ready(b, "b")
        try await wait("both quiescent") { a.hostView?.isQuiescent == true && b.hostView?.isQuiescent == true }
    }

    func testLaterInvitationsNeedReadiness() async throws {
        let a = engine("a")
        let b = engine("b")
        try await pair(a, b)
        try await enroll(a, "a")
        a.inviteToGroup()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(a.invitationURL)
        try await ready(a, "a")
        a.inviteToGroup()
        try await wait("invitation") { a.invitationURL != nil }
    }

    func testProviderCompletesOnlyAfterItDeclaresReadiness() async throws {
        let a = engine("a")
        let b = engine("b")
        try await pair(a, b)
        try await enroll(a, "a")
        try await submit(a, "a", ["one", "two"])
        try await enroll(b, "b")
        try await wait("records delivered") { try self.store(b).view.delivered == 2 }
        try await Task.sleep(for: .seconds(1))
        XCTAssertFalse(try store(b).view.historyComplete, "a provider certified history before readiness")
        XCTAssertEqual(a.replyObligationForTesting?.bootstrap?.first?.cut, nil)
        try await ready(a, "a")
        try await wait("history complete") { try self.store(b).view.historyComplete }
    }

    func testIncompleteJoinerCannotCompleteAnotherJoiner() async throws {
        let a = engine("a")
        var p = engine("p")
        try await pair(a, p)
        try await enroll(a, "a")
        try await submit(a, "a", ["deletion barrier"])
        try await enroll(p, "p")
        try await ready(p, "p")
        try await wait("provider asked") { p.hostView?.journal?.historyProvider != nil && a.replyObligationForTesting?.bootstrap != nil }
        await a.stop()
        let checkpointURL = directory("p").appendingPathComponent(ReplicationCheckpoint.filename)
        var visible = try XCTUnwrap(ReplicationCheckpoint.load(from: checkpointURL))
        visible.reservationsVisible = true
        visible.membersWithUnknownHistory = nil
        await p.stop()
        try visible.save(to: checkpointURL)
        p = await restart(p, "p")
        await p.stop()
        XCTAssertEqual(p.hostView?.journal?.historyComplete, false)
        XCTAssertFalse(p.awaitsReservationsForTesting)
        let aFingerprint = try await fingerprint(a)
        let pFingerprint = try await fingerprint(p)
        try await send(
            try HostJournalMessage(control: .hello(vector: ReplicaVersionVector(), provider: pFingerprint)),
            from: try XCTUnwrap(a.mlsSessionForTesting)
        )
        _ = try await XCTUnwrapAsync(p.mlsSessionForTesting).synchronize()
        try await p.drainInboxForTesting()
        XCTAssertEqual(p.replyObligationForTesting?.bootstrap?.map(\.member), [aFingerprint])
        try await p.sendRepliesForTesting()
        XCTAssertEqual(p.replyObligationForTesting?.bootstrap?.map(\.cut), [nil], "an incomplete provider chose a cut")
        let early = try await inboxMessages(a).filter { $0.kind == .complete }
        XCTAssertTrue(early.isEmpty)

        try await ready(a, "a")
        try await a.sendRepliesForTesting()
        _ = try await XCTUnwrapAsync(p.mlsSessionForTesting).synchronize()
        try await p.drainInboxForTesting()
        XCTAssertTrue(try store(p).view.historyComplete)
        try await p.sendRepliesForTesting()
        XCTAssertNil(p.replyObligationForTesting?.bootstrap)
        let completes = try await inboxMessages(a).filter { $0.kind == .complete }
        XCTAssertEqual(completes.map(\.member), [aFingerprint])
    }

    func testCutWaitsOnAGapInIntake() async throws {
        let (a, b) = try await completedPair()
        await a.stop()
        await b.stop()
        let bSession = try XCTUnwrap(b.mlsSessionForTesting)
        let run = try JournalFixture.chain(Data(repeating: 0x5C, count: 16), count: 2)
        try await send(.records([run[1].bytes]), from: bSession)
        try await send(try HostJournalMessage(control: .hello(vector: ReplicaVersionVector(), provider: try await fingerprint(a))), from: bSession)
        _ = try await XCTUnwrapAsync(a.mlsSessionForTesting).synchronize()
        try await a.drainInboxForTesting()
        XCTAssertEqual(try store(a).view.pendingCount, 1)
        try await a.sendRepliesForTesting()
        XCTAssertEqual(a.replyObligationForTesting?.bootstrap?.map(\.cut), [nil], "a provider chose a cut over a gap")

        try await send(.records([run[0].bytes]), from: bSession)
        _ = try await XCTUnwrapAsync(a.mlsSessionForTesting).synchronize()
        try await a.drainInboxForTesting()
        XCTAssertEqual(try store(a).view.pendingCount, 0)
        try await a.sendRepliesForTesting()
        XCTAssertNil(a.replyObligationForTesting?.bootstrap)
        let messages = try await inboxMessages(b)
        let complete = try XCTUnwrap(messages.last { $0.kind == .complete })
        XCTAssertEqual(complete.through.map(HostJournalAdapter.dictionary)?[run[0].origin], 2)
    }

    func testRepeatedHelloDoesNotMoveAnExistingCut() async throws {
        let (a, b) = try await completedPair()
        await a.stop()
        await b.stop()
        let aSession = try XCTUnwrap(a.mlsSessionForTesting)
        let bSession = try XCTUnwrap(b.mlsSessionForTesting)
        let aFingerprint = try await fingerprint(a)
        try await send(try HostJournalMessage(control: .hello(vector: ReplicaVersionVector(), provider: aFingerprint)), from: bSession)
        _ = try await aSession.synchronize()
        try await a.drainInboxForTesting()
        let firstCut = try store(a).receivedVector
        await relay.setAppendsUnavailable(true)
        do {
            try await a.sendRepliesForTesting()
            XCTFail("replies were sent while appends are unavailable")
        } catch {}
        await relay.setAppendsUnavailable(false)
        XCTAssertEqual(a.replyObligationForTesting?.bootstrap?.first?.cut.map(HostJournalAdapter.dictionary), firstCut)
        try await submit(a, "a", ["after the cut"])
        try await send(try HostJournalMessage(control: .hello(vector: ReplicaVersionVector(), provider: aFingerprint)), from: bSession)
        _ = try await aSession.synchronize()
        try await a.drainInboxForTesting()
        XCTAssertEqual(a.replyObligationForTesting?.bootstrap?.first?.cut.map(HostJournalAdapter.dictionary), firstCut)
        try await a.sendRepliesForTesting()
        let completes = try await inboxMessages(b).filter { $0.kind == .complete }
        XCTAssertEqual(completes.count, 1)
        XCTAssertEqual(completes.first?.through.map(HostJournalAdapter.dictionary), firstCut)
    }

    func testProviderReplyIncludesOwnRecordsAboveTheUploadWatermark() async throws {
        let (a, b) = try await completedPair()
        await a.stop()
        await b.stop()
        try await submit(a, "a", ["not uploaded"])
        let journal = try store(a)
        XCTAssertLessThan(a.hostView?.uploadedThrough ?? 0, journal.view.ownHead)
        let bSession = try XCTUnwrap(b.mlsSessionForTesting)
        _ = try await bSession.synchronize()
        if let last = try await bSession.inbox().last {
            try await bSession.acknowledgeInbox(through: last.cursor)
        }
        try await send(
            try HostJournalMessage(control: .hello(vector: HostJournalAdapter.vector(try store(b).receivedVector), provider: try await fingerprint(a))),
            from: bSession
        )
        _ = try await XCTUnwrapAsync(a.mlsSessionForTesting).synchronize()
        try await a.drainInboxForTesting()
        try await a.sendRepliesForTesting()
        let messages = try await inboxMessages(b)
        let payloads = messages.flatMap { $0.records ?? [] }.compactMap { try? JournalEnvelope(parsing: $0).payload }
        XCTAssertTrue(payloads.contains(Data("not uploaded".utf8)))
        let complete = try XCTUnwrap(messages.first { $0.kind == .complete })
        XCTAssertEqual(complete.through.map(HostJournalAdapter.dictionary)?[journal.view.origin], journal.view.ownHead)
        XCTAssertLessThan(a.hostView?.uploadedThrough ?? 0, journal.view.ownHead)
    }

    // MARK: - Intake and status

    func testHeldInboxPreventsQuiescenceAtHistoryCap() async throws {
        var limits = HostJournalLimits.standard
        limits.historyRecords = 3
        let (a, b) = try await completedPair(records: ["one", "two"], limits: limits)
        try await submit(a, "a", ["three"])
        try await wait("third applied") { try self.store(b).view.delivered == 3 }
        try await applyAll(b, "b")
        try await submit(a, "a", ["four"])
        try await wait("held") {
            if case .settled(let held) = b.hostView?.intake { return held > 0 }
            return false
        }
        XCTAssertEqual(try store(b).view.delivered, 3)
        XCTAssertFalse(b.hostView?.isQuiescent ?? true, "held intake reported quiescent")
        XCTAssertTrue(b.isTaskHistoryAtCapacity || b.hostView?.journal?.retainedCount == 3)
    }

    func testIdleUploadPublishesQuiescenceAfterTheCheckpointSave() async throws {
        let (a, b) = try await completedPair()
        try await wait("quiescent") { a.hostView?.isQuiescent == true }
        try await submit(a, "a", ["idle"])
        XCTAssertEqual(a.hostView?.unuploaded, 1)
        let revision = a.hostView?.revision ?? 0
        try await wait("uploaded") { a.hostView?.unuploaded == 0 && a.hostView?.isQuiescent == true }
        XCTAssertGreaterThan(a.hostView?.revision ?? 0, revision)
        try await wait("delivered") { try self.store(b).view.delivered == 4 }
    }

    func testLateWindowForkLeavesTheWholeWindowUncommitted() async throws {
        let (a, b) = try await completedPair()
        await a.stop()
        await b.stop()
        let bSession = try XCTUnwrap(b.mlsSessionForTesting)
        _ = try await bSession.synchronize()
        let prior = try await bSession.inbox().count
        let aSession = try XCTUnwrap(a.mlsSessionForTesting)
        let origin = Data(repeating: 0x7A, count: 16)
        let run = try JournalFixture.chain(origin, count: 70)
        for envelope in run {
            try await send(.records([envelope.bytes]), from: aSession)
        }
        let conflicting = try JournalEnvelope(origin: origin, sequence: 1, prior: JournalEnvelope.zeroDigest, payload: Data("fork".utf8))
        try await send(.records([conflicting.bytes]), from: aSession)
        _ = try await bSession.synchronize()
        try await b.reopenStoppedHostJournalForTesting()
        let journal = try store(b)
        let before = journal.view
        let inbox = try await bSession.inbox().count
        XCTAssertEqual(inbox, prior + 71)
        do {
            try await b.drainInboxForTesting()
            XCTFail("a forked window was taken")
        } catch HostJournalError.fork(let forked, let sequence) {
            XCTAssertEqual(forked, origin)
            XCTAssertEqual(sequence, 1)
        }
        XCTAssertEqual(journal.view, before)
        let remaining = try await bSession.inbox().count
        XCTAssertEqual(remaining, inbox)
    }

    func testMixedControlAndDataAcknowledgeTheExactPrefix() async throws {
        var limits = HostJournalLimits.standard
        limits.historyRecords = 4
        let (a, b) = try await completedPair(limits: limits)
        await a.stop()
        await b.stop()
        let aSession = try XCTUnwrap(a.mlsSessionForTesting)
        let origin = Data(repeating: 0x6B, count: 16)
        let run = try JournalFixture.chain(origin, count: 2)
        try await send(.records([run[0].bytes]), from: aSession)
        try await send(try HostJournalMessage(control: .hello(vector: ReplicaVersionVector(), provider: nil)), from: aSession)
        try await send(.records([run[1].bytes]), from: aSession)
        try await send(try HostJournalMessage(control: .hello(vector: ReplicaVersionVector(), provider: nil)), from: aSession)
        let bSession = try XCTUnwrap(b.mlsSessionForTesting)
        _ = try await bSession.synchronize()
        try await b.drainInboxForTesting()
        let remaining = try await bSession.inbox()
        XCTAssertEqual(remaining.count, 2)
        XCTAssertEqual(try HostJournalMessage.decode(try XCTUnwrap(remaining.first).plaintext).records, [run[1].bytes])
        XCTAssertEqual(try store(b).view.recordCount, 4)
    }

    // MARK: - Lifecycle

    func testRemovalAtIntakeCapRetainsTheHeldInboxBytes() async throws {
        var limits = HostJournalLimits.standard
        limits.historyRecords = 3
        let (a, b) = try await completedPair(limits: limits)
        try await submit(a, "a", ["four", "five"])
        try await wait("held") {
            if case .settled(let held) = b.hostView?.intake { return held > 0 }
            return false
        }
        let held = try await XCTUnwrapAsync(b.mlsSessionForTesting).inbox()
        XCTAssertFalse(held.isEmpty)
        let journalID = try store(b).view.journalID
        let bFingerprint = try await fingerprint(b)
        XCTAssertTrue(a.removeDevice(fingerprint: bFingerprint))
        try await wait("removed and closed") { !b.isPaired && b.hostLifecycle == .active }
        let url = HostJournalStore.fileURL(in: directory("b"), journalID: journalID)
        let exported = try JournalFixture.exportAll(url)
        let heldItems = exported.compactMap { item -> Data? in
            if case .held(_, _, let plaintext) = item { return plaintext }
            return nil
        }
        XCTAssertEqual(heldItems, held.map(\.plaintext))
        XCTAssertEqual(try HostJournalStore.open(url).view.retirement, .removed)
        XCTAssertEqual(b.linkEndedReason, .removedFromGroup)
    }

    func testUnlinkCopiesHeldBytesThenDepartsControlOnly() async throws {
        var limits = HostJournalLimits.standard
        limits.historyRecords = 3
        let (a, b) = try await completedPair(limits: limits)
        try await submit(a, "a", ["four"])
        try await wait("held") {
            if case .settled(let held) = b.hostView?.intake { return held > 0 }
            return false
        }
        let held = try await XCTUnwrapAsync(b.mlsSessionForTesting).inbox()
        let stale = try store(b)
        let journalID = stale.view.journalID
        b.unlinkAndKeepTasks()
        try await wait("unlinked") { !b.isPaired && b.hostLifecycle == .active }
        await XCTAssertThrowsErrorAsync(try await stale.submit([HostJournalMutation(id: HostJournalStore.randomBytes(16), payload: Data())], capturedThrough: 9)) {
            XCTAssertEqual($0 as? HostJournalError, .retired)
        }
        let url = HostJournalStore.fileURL(in: directory("b"), journalID: journalID)
        let exported = try JournalFixture.exportAll(url)
        XCTAssertEqual(exported.compactMap { if case .held(_, _, let plaintext) = $0 { plaintext } else { nil } }, held.map(\.plaintext))
        try await submit(a, "a", ["after the cut"])
        try await wait("departed") { a.linkedMemberCount == 1 }
        XCTAssertEqual(try HostJournalStore.open(url).view.heldCount, UInt64(held.count))
    }

    func testFailedHandoffKeepsOwnersAndTheIntentClosesAtLaunch() async throws {
        let (_, b) = try await completedPair()
        let journal = try store(b)
        journal.faultHookForTesting = { if $0 == .beforeCommit("retire") { throw CancellationError() } }
        b.unlinkAndKeepTasks()
        try await wait("failed") { b.hostLifecycle == .failed(.unlink) }
        XCTAssertTrue(b.isPaired)
        XCTAssertFalse(journal.view.isRetired)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory("b").appendingPathComponent(SyncEngine.hostLifecycleFilename).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory("b").appendingPathComponent(ReplicationCheckpoint.filename).path))
        let restarted = await restart(b, "b")
        XCTAssertNil(restarted.hostJournal, "the restarted engine reopened work before closing")
        try await wait("closed at launch") { !restarted.isPaired && restarted.hostLifecycle == .active }
        XCTAssertEqual(try HostJournalStore.open(journal.url).view.retirement, .unlink)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory("b").appendingPathComponent(SyncEngine.hostLifecycleFilename).path))
    }

    func testUnlinkResumesAtLaunchFromEachStep() async throws {
        for step in ["retired", "controlOnly"] {
            setUpRootForStep()
            let (a, b) = try await completedPair()
            let journalID = try store(b).view.journalID
            b.hostClosingHookForTesting = { if $0 == step { throw CancellationError() } }
            b.unlinkAndKeepTasks()
            try await wait("stopped at \(step)") { b.hostLifecycle == .failed(.unlink) }
            let restarted = await restart(b, "b")
            XCTAssertNil(restarted.hostJournal, step)
            try await wait("unlinked after restart at \(step)") { restarted.hostLifecycle == .active && !restarted.isPaired }
            XCTAssertEqual(try HostJournalStore.open(HostJournalStore.fileURL(in: directory("b"), journalID: journalID)).view.retirement, .unlink, step)
            try await wait("departed after \(step)") { a.linkedMemberCount == 1 }
            for engine in engines { await engine.stop() }
            engines = []
        }
    }

    func testUnreadableMLSStateIsPreservedInHostMode() async throws {
        let (_, b) = try await completedPair()
        await b.stop()
        engines.removeAll { $0 === b }
        let mls = MLSSession.directory(in: directory("b"))
        let before = try Self.tree(mls)
        try stores["b"]?.write(Data(repeating: 0x42, count: 32), account: SecretStoreMLSStateKey.account)
        let reopened = engine("b")
        await opened(reopened)
        XCTAssertEqual(reopened.hostRepair, .mlsUnreadable)
        XCTAssertEqual(try Self.tree(mls), before)
        XCTAssertTrue(reopened.isPaired)
        reopened.unlinkAndKeepTasks()
        try await wait("unlink refused") { reopened.hostLifecycle == .failed(.unlink) }
        XCTAssertEqual(try Self.tree(mls), before)
        XCTAssertEqual(try stores["b"]?.read(account: SecretStoreMLSStateKey.account), Data(repeating: 0x42, count: 32))
        reopened.eraseLocalData()
        try await wait("erased") { reopened.hostLifecycle == .active && !reopened.isPaired }
        XCTAssertTrue(try Self.journalFiles(directory("b")).isEmpty)
    }

    func testEraseRemovesLibraryJournalsAndResumesFromEachStep() async throws {
        for step in ["start", "marked", "controlOnly"] {
            setUpRootForStep()
            let (a, b) = try await completedPair()
            let extra = try HostJournalStore.create(in: directory("b"), group: JournalFixture.group)
            try extra.retire(.unlink, heldInbox: [])
            b.hostClosingHookForTesting = { if $0 == step { throw CancellationError() } }
            b.eraseLocalData()
            try await wait("stopped at \(step)") { b.hostLifecycle == .failed(.erase) }
            let restarted = await restart(b, "b")
            try await wait("erased after restart at \(step)") { restarted.hostLifecycle == .active && !restarted.isPaired }
            XCTAssertTrue(try Self.journalFiles(directory("b")).isEmpty, step)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory("b").appendingPathComponent(SyncEngine.eraseMarkerFilename).path), step)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory("b").appendingPathComponent(ReplicationCheckpoint.filename).path), step)
            try await wait("departed after \(step)") { a.linkedMemberCount == 1 }
            for engine in engines { await engine.stop() }
            engines = []
        }
    }

    func testCheckpointLossKeepsTheGenerationUnderControlRepair() async throws {
        let (_, b) = try await completedPair()
        let journalID = try store(b).view.journalID
        await b.stop()
        engines.removeAll { $0 === b }
        try Data("not a checkpoint".utf8).write(to: directory("b").appendingPathComponent(ReplicationCheckpoint.filename))
        let reopened = engine("b")
        await opened(reopened)
        XCTAssertEqual(reopened.hostView?.journal?.journalID, journalID)
        XCTAssertEqual(reopened.hostView?.journal?.controlRepair, true)
        XCTAssertTrue(reopened.isTaskHistoryAtCapacity)
        let preserved = try FileManager.default.contentsOfDirectory(atPath: directory("b").path).filter { $0.hasPrefix("sync-v2.unreadable-") }
        XCTAssertEqual(preserved.count, 1)
        try await wait("checkpoint rebuilt") { reopened.isPaired }
        reopened.inviteToGroup()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(reopened.invitationURL)
        XCTAssertEqual(try Self.journalFiles(directory("b")).filter { $0.hasSuffix(".sqlite3") }.count, 1)
    }

    func testJoinIntentRestartKeepsTheSameGeneration() async throws {
        let (_, b) = try await completedPair()
        let journalID = try store(b).view.journalID
        await b.stop()
        engines.removeAll { $0 === b }
        let checkpointURL = directory("b").appendingPathComponent(ReplicationCheckpoint.filename)
        var intent = try XCTUnwrap(ReplicationCheckpoint.load(from: checkpointURL))
        intent.members = []
        try intent.save(to: directory("b").appendingPathComponent(ReplicationCheckpoint.joinIntentFilename))
        try FileManager.default.removeItem(at: checkpointURL)
        let reopened = engine("b")
        await opened(reopened)
        XCTAssertEqual(reopened.hostView?.journal?.journalID, journalID)
        XCTAssertEqual(reopened.hostView?.journal?.controlRepair, false)
        try await wait("rebuilt") { reopened.isPaired }
        XCTAssertEqual(try ReplicationCheckpoint.load(from: checkpointURL)?.hostJournal, journalID)
        XCTAssertEqual(try Self.journalFiles(directory("b")).filter { $0.hasSuffix(".sqlite3") }.count, 1)
    }

    func testRemovalDuringASyncCycleClosesWithoutWaitingOnItself() async throws {
        let (a, b) = try await completedPair()
        let bFingerprint = try await fingerprint(b)
        XCTAssertTrue(a.removeDevice(fingerprint: bFingerprint))
        try await wait("closed", timeout: .seconds(10)) { !b.isPaired && b.hostLifecycle == .active }
    }

    func testRemovalFoundAtLaunchCloses() async throws {
        let (a, b) = try await completedPair()
        let bFingerprint = try await fingerprint(b)
        await b.stop()
        engines.removeAll { $0 === b }
        XCTAssertTrue(a.removeDevice(fingerprint: bFingerprint))
        try await wait("removed") { a.linkedMemberCount == 1 }
        let reopened = engine("b")
        try await wait("closed at launch") { !reopened.isPaired && reopened.hostLifecycle == .active }
    }

    func testWorkIsRefusedWhileClosingAndStopSettlesIt() async throws {
        let (_, b) = try await completedPair()
        let journalID = try store(b).view.journalID
        b.hostClosingHookForTesting = { step in
            if step == "start" {
                b.applicationDidBecomeActive()
                XCTAssertEqual(b.hostLifecycle, .closing(.unlink))
                try await Task.sleep(for: .milliseconds(300))
            }
        }
        b.unlinkAndKeepTasks()
        XCTAssertEqual(b.hostLifecycle, .closing(.unlink))
        XCTAssertNil(b.hostJournal)
        b.inviteToGroup()
        XCTAssertNil(b.invitationURL)
        await b.stop()
        XCTAssertEqual(b.hostLifecycle, .failed(.unlink))
        XCTAssertNil(b.hostJournal)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory("b").appendingPathComponent(SyncEngine.hostLifecycleFilename).path))
        engines.removeAll { $0 === b }
        let restarted = engine("b")
        try await wait("closed at launch") { !restarted.isPaired && restarted.hostLifecycle == .active }
        XCTAssertEqual(try HostJournalStore.open(HostJournalStore.fileURL(in: directory("b"), journalID: journalID)).view.retirement, .unlink)
    }

    func testArchivesAtTheCapAreReachableWhileUnlinked() async throws {
        let a = engine("a")
        let c = engine("c")
        try FileManager.default.createDirectory(at: directory("c"), withIntermediateDirectories: true)
        var retired: [Data] = []
        for _ in 0..<4 {
            let archive = try HostJournalStore.create(in: directory("c"), group: JournalFixture.group)
            try archive.retire(.unlink, heldInbox: [])
            retired.append(archive.view.journalID)
        }
        try await wait("host ready") { !a.canCancelPairing }
        a.createPrivateSync()
        try await wait("invitation") { a.invitationURL != nil }
        c.joinPrivateSync(url: try XCTUnwrap(a.invitationURL))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(c.safetyCode)
        XCTAssertEqual(try c.hostJournalArchives().count, 4)
        let url = HostJournalStore.fileURL(in: directory("c"), journalID: retired[0])
        XCTAssertNotNil(try c.exportHostJournal(url, after: nil, limit: 10))
        await XCTAssertThrowsErrorAsync(try await c.discardRetiredHostJournal(retired[0], confirming: retired[1]))
        try await c.discardRetiredHostJournal(retired[0], confirming: retired[0])
        a.cancelPairing()
        try await pair(a, c)
    }

    // MARK: - Helpers

    func setUpRootForStep() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        relay = FakeMLSRelay()
        rendezvous = FakePairingRendezvous()
        stores = [:]
        provenances = [:]
        captured = [:]
    }

    static func tree(_ url: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else { return result }
        for case let file as URL in enumerator where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            result[file.path] = try Data(contentsOf: file)
        }
        return result
    }

    static func journalFiles(_ url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).filter { $0.hasPrefix(HostJournalStore.filePrefix) }
    }
}

private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
