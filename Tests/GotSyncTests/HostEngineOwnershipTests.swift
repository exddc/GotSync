import Foundation
import GotSyncMLS
import XCTest
@testable import GotSync

/// Ownership, finite delivery, certification and intake status of the host
/// engine across closing, restarts, saved obligations and direct MLS work.
extension HostEngineTests {
    // MARK: - Handoff proof

    func testUnlinkWithoutItsJournalKeepsTheHeldOwnerUntilTheJournalReturns() async throws {
        for damage in ["missing", "unreadable"] {
            setUpRootForStep()
            var limits = HostJournalLimits.standard
            limits.historyRecords = 3
            let (a, b) = try await completedPair(limits: limits)
            try await submit(a, "a", ["held original"])
            try await wait("held") {
                if case .settled(let held) = b.hostView?.intake { return held > 0 }
                return false
            }
            let journal = try store(b)
            let url = journal.url
            let held = try await XCTUnwrapAsync(b.mlsSessionForTesting).inbox()
            XCTAssertFalse(held.isEmpty)
            journal.faultHookForTesting = { if $0 == .beforeCommit("retire") { throw CancellationError() } }
            b.unlinkAndKeepTasks()
            try await wait("failed handoff") { b.hostLifecycle == .failed(.unlink) }
            await b.stop()
            engines.removeAll { $0 === b }
            let original = try Data(contentsOf: url)
            if damage == "missing" {
                try FileManager.default.removeItem(at: url)
            } else {
                try Data(repeating: 0x5A, count: original.count).write(to: url)
            }
            for launch in 1...2 {
                let reopened = engine("b", limits: limits)
                await opened(reopened)
                XCTAssertNotNil(reopened.hostRepair, "\(damage) launch \(launch)")
                try await wait("closing settled") { reopened.hostLifecycle != .closing(.unlink) && reopened.hostLifecycle != .opening }
                XCTAssertEqual(reopened.hostLifecycle, .failed(.unlink), "\(damage) launch \(launch)")
                XCTAssertTrue(reopened.isPaired, "\(damage): the MLS owner was discarded")
                let remaining = try await XCTUnwrapAsync(reopened.mlsSessionForTesting).inbox()
                XCTAssertEqual(remaining, held, "\(damage): held bytes changed")
                XCTAssertTrue(FileManager.default.fileExists(atPath: directory("b").appendingPathComponent(SyncEngine.hostLifecycleFilename).path))
                await reopened.stop()
                engines.removeAll { $0 === reopened }
            }
            try original.write(to: url)
            let restored = engine("b", limits: limits)
            try await wait("unlinked with the journal back") { restored.hostLifecycle == .active && !restored.isPaired }
            let archive = try HostJournalStore.open(url)
            XCTAssertEqual(archive.view.retirement, .unlink, damage)
            let archived = try JournalFixture.exportAll(url).compactMap { item -> Data? in
                if case .held(_, _, let plaintext) = item { return plaintext }
                return nil
            }
            XCTAssertEqual(archived, held.map(\.plaintext), damage)
            try await wait("departed") { a.linkedMemberCount == 1 }
            for engine in engines { await engine.stop() }
            engines = []
        }
    }

    func testIntentForAnotherGenerationKeepsTheLink() async throws {
        var limits = HostJournalLimits.standard
        limits.historyRecords = 3
        let (a, b) = try await completedPair(limits: limits)
        try await submit(a, "a", ["held original"])
        try await wait("held") {
            if case .settled(let held) = b.hostView?.intake { return held > 0 }
            return false
        }
        let session = try XCTUnwrap(b.mlsSessionForTesting)
        let held = try await session.inbox()
        let group = try await XCTUnwrapAsync(await session.group())
        let journalURL = try store(b).url
        await b.stop()
        engines.removeAll { $0 === b }
        let record = HostLifecycleRecord(intent: .unlink, journal: HostJournalStore.randomBytes(16), group: group)
        try ProtectedStorage.write(
            ReplicaCanonicalJSON.encode(record), to: directory("b").appendingPathComponent(SyncEngine.hostLifecycleFilename)
        )
        let reopened = engine("b", limits: limits)
        try await wait("closing settled") { reopened.hostLifecycle != .closing(.unlink) && reopened.hostLifecycle != .opening }
        XCTAssertEqual(reopened.hostLifecycle, .failed(.unlink))
        XCTAssertTrue(reopened.isPaired)
        let remaining = try await XCTUnwrapAsync(reopened.mlsSessionForTesting).inbox()
        XCTAssertEqual(remaining, held)
        XCTAssertNil(try HostJournalStore.open(journalURL).view.retirement)
    }

    func testRetiredArchiveMustHoldEveryInboxByte() async throws {
        let (a, b) = try await completedPair()
        b.hostClosingHookForTesting = { if $0 == "retired" { throw CancellationError() } }
        b.unlinkAndKeepTasks()
        try await wait("retired, then stopped") { b.hostLifecycle == .failed(.unlink) }
        await b.stop()
        engines.removeAll { $0 === b }
        try await submit(a, "a", ["after retirement"])
        let session = try XCTUnwrap(b.mlsSessionForTesting)
        try await wait("a later message reached the MLS inbox") {
            _ = try await session.synchronize()
            return try await !session.inbox().isEmpty
        }
        let late = try await session.inbox()
        let reopened = engine("b")
        try await wait("closing settled") { reopened.hostLifecycle != .closing(.unlink) && reopened.hostLifecycle != .opening }
        XCTAssertEqual(reopened.hostLifecycle, .failed(.unlink), "an archive without the later bytes proved the handoff")
        XCTAssertTrue(reopened.isPaired)
        let remaining = try await XCTUnwrapAsync(reopened.mlsSessionForTesting).inbox()
        XCTAssertEqual(remaining, late)
    }

    // MARK: - Finite bootstrap delivery

    func testProviderReplyStopsAtItsPersistedCut() async throws {
        let directory = try JournalFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await HostJournal.create(in: directory, group: JournalFixture.group, founder: true)
        _ = try await store.resume(try await store.enroll())
        _ = try await store.submit([HostJournalMutation(id: JournalFixture.mutationID(1), payload: Data("cut".utf8))], capturedThrough: 1)
        let adapter = HostJournalAdapter(directory: directory, limits: .standard)
        adapter.bind(store)
        let cut = adapter.helloVector
        var obligation = ReplyObligation()
        obligation.merge(ReplicaVersionVector(), provider: true)
        obligation.addBootstrap(Data(repeating: 0xAA, count: 32), from: ReplicaVersionVector())
        obligation.bootstrap![0].cut = cut
        _ = try await store.submit([HostJournalMutation(id: JournalFixture.mutationID(2), payload: Data("after cut".utf8))], capturedThrough: 2)
        let selected = try await XCTUnwrapAsync(try await adapter.reply(for: obligation, uploadedThrough: 0, bound: cut))
        XCTAssertEqual(selected.records.map(\.1), [1])
        obligation.advance(past: selected.records)
        let none = try await adapter.reply(for: obligation, uploadedThrough: 0, bound: cut)
        XCTAssertNil(none)
        let unbounded = try await adapter.reply(for: obligation, uploadedThrough: 0, bound: nil)
        XCTAssertEqual(unbounded?.records.map(\.1), [2])
        await store.shutdown()
    }

    func testOngoingEditsDoNotDelayFiniteCompletion() async throws {
        let (a, b) = try await completedPair()
        await a.stop()
        await b.stop()
        let aSession = try XCTUnwrap(a.mlsSessionForTesting)
        let bFingerprint = try await fingerprint(b)
        try await send(
            try HostJournalMessage(control: .hello(vector: ReplicaVersionVector(), provider: try await fingerprint(a))),
            from: try XCTUnwrap(b.mlsSessionForTesting)
        )
        _ = try await aSession.synchronize()
        try await a.drainInboxForTesting()
        var sends = 0
        a.replyBatchHookForTesting = {
            sends += 1
            _ = try? await self.submit(a, "a", ["edit after cut \(sends)"])
        }
        try await a.sendRepliesForTesting()
        a.replyBatchHookForTesting = nil
        XCTAssertEqual(sends, 1, "edits after the cut added reply batches")
        XCTAssertNil(a.replyObligationForTesting?.bootstrap)
        let completes = try await inboxMessages(b).filter { $0.kind == .complete && $0.member == bFingerprint }
        XCTAssertEqual(completes.count, 1)
        let aOrigin = try store(a).view.origin
        XCTAssertEqual(completes.first?.through.map(HostJournalAdapter.dictionary)?[aOrigin], 3)

        let bRestarted = await restart(b, "b")
        _ = await restart(a, "a")
        try await wait("later edits arrive as ordinary traffic") {
            try self.store(bRestarted).receivedVector[aOrigin] == 4
        }
    }

    func testEveryRequesterGetsItsOwnFiniteCertificate() async throws {
        let (a, b) = try await completedPair()
        let c = engine("c")
        try await pair(a, c)
        try await enroll(c, "c")
        try await wait("third member complete") { (try? self.store(c).view.historyComplete) == true }
        for engine in [a, b, c] { await engine.stop() }
        let aFingerprint = try await fingerprint(a)
        let observer = try XCTUnwrap(b.mlsSessionForTesting)
        _ = try await observer.synchronize()
        if let last = try await observer.inbox().last {
            try await observer.acknowledgeInbox(through: last.cursor)
        }
        for requester in [b, c] {
            try await send(
                try HostJournalMessage(control: .hello(vector: ReplicaVersionVector(), provider: aFingerprint)),
                from: try XCTUnwrap(requester.mlsSessionForTesting)
            )
        }
        _ = try await XCTUnwrapAsync(a.mlsSessionForTesting).synchronize()
        try await a.drainInboxForTesting()
        let members = Set([try await fingerprint(b), try await fingerprint(c)])
        XCTAssertEqual(Set(a.replyObligationForTesting?.bootstrap?.map(\.member) ?? []), members)
        var sends = 0
        a.replyBatchHookForTesting = {
            sends += 1
            _ = try? await self.submit(a, "a", ["edit \(sends)"])
        }
        try await a.sendRepliesForTesting()
        a.replyBatchHookForTesting = nil
        XCTAssertLessThanOrEqual(sends, 2)
        XCTAssertNil(a.replyObligationForTesting?.bootstrap)
        let completes = try await inboxMessages(b).filter { $0.kind == .complete }
        XCTAssertEqual(completes.compactMap(\.member).sorted { $0.lexicographicallyPrecedes($1) },
                       members.sorted { $0.lexicographicallyPrecedes($1) })
    }

    func testSavedCutSurvivesRestartUnchanged() async throws {
        let (a, b) = try await completedPair()
        await a.stop()
        await b.stop()
        try await send(
            try HostJournalMessage(control: .hello(vector: ReplicaVersionVector(), provider: try await fingerprint(a))),
            from: try XCTUnwrap(b.mlsSessionForTesting)
        )
        _ = try await XCTUnwrapAsync(a.mlsSessionForTesting).synchronize()
        try await a.drainInboxForTesting()
        await relay.setAppendsUnavailable(true)
        do {
            try await a.sendRepliesForTesting()
            XCTFail("replies were sent while appends are unavailable")
        } catch {}
        let cut = try XCTUnwrap(a.replyObligationForTesting?.bootstrap?.first?.cut)
        try await submit(a, "a", ["after the saved cut"])
        await relay.setAppendsUnavailable(false)
        let reopened = await restart(a, "a")
        let bFingerprint = try await fingerprint(b)
        try await wait("saved cut certified") { reopened.replyObligationForTesting?.bootstrap == nil }
        let completes = try await inboxMessages(b).filter { $0.kind == .complete && $0.member == bFingerprint }
        XCTAssertEqual(completes.map(\.through), [cut])
    }

    // MARK: - Certification eligibility

    func testCheckpointLossKeepsASavedCutAndAReservationOnlyClaimBlocked() async throws {
        let (a, b) = try await completedPair()
        try await wait("earlier snapshot consumed") { !b.awaitsReservationsForTesting }
        await b.stop()
        let c = engine("c")
        a.reservationHookForTesting = {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        try await wait("host ready to invite") { !a.canCancelPairing }
        a.inviteToGroup()
        try await wait("invitation") { a.invitationURL != nil }
        c.joinPrivateSync(url: try XCTUnwrap(a.invitationURL))
        try await wait("safety code") { a.isHostApprovalPending && c.safetyCode != nil }
        a.approveSafetyCode()
        let cFingerprint = try await fingerprint(c)
        try await wait("claim reserved before the Add") { a.reservationsForTesting.contains { $0.member == cFingerprint } }
        XCTAssertEqual(a.linkedMemberCount, 2, "the claim must be reservation-only")

        let relay = self.relay!
        a.replyBatchHookForTesting = {
            if a.replyObligationForTesting?.bootstrap?.contains(where: { $0.cut != nil }) == true {
                await relay.setAppendsUnavailable(true)
            }
        }
        let bFingerprint = try await fingerprint(b)
        try await send(
            try HostJournalMessage(control: .hello(vector: ReplicaVersionVector(), provider: try await fingerprint(a))),
            from: try XCTUnwrap(b.mlsSessionForTesting)
        )
        try await wait("cut saved") {
            a.replyObligationForTesting?.bootstrap?.first { $0.member == bFingerprint }?.cut != nil
        }
        let cut = a.replyObligationForTesting?.bootstrap?.first { $0.member == bFingerprint }?.cut
        a.replyBatchHookForTesting = nil
        await a.stop()
        await c.stop()
        XCTAssertTrue(a.reservationsForTesting.contains { $0.member == cFingerprint })
        try Data("not a checkpoint".utf8).write(to: directory("a").appendingPathComponent(ReplicationCheckpoint.filename))
        await relay.setAppendsUnavailable(false)
        var reopened = await restart(a, "a")
        for launch in 1...2 {
            XCTAssertEqual(reopened.hostView?.journal?.controlRepair, true)
            try await wait("relinked under repair") { reopened.isPaired }
            try await Task.sleep(for: .milliseconds(800))
            XCTAssertFalse(reopened.reservationsForTesting.contains { $0.member == cFingerprint }, "the claim survived")
            XCTAssertEqual(reopened.replyObligationForTesting?.bootstrap?.first { $0.member == bFingerprint }?.cut, cut, "launch \(launch)")
            XCTAssertTrue(reopened.isTaskHistoryAtCapacity)
            reopened.inviteToGroup()
            XCTAssertNil(reopened.invitationURL, "another admission was allowed without the lost claim")
            if launch == 1 {
                reopened = await restart(reopened, "a")
            }
        }
        let received = try await inboxMessages(b)
        XCTAssertTrue(received.filter { $0.kind == .complete }.isEmpty, "control repair certified a saved cut")
        XCTAssertTrue(received.filter { $0.kind == .reservations }.isEmpty, "control repair sent an incomplete snapshot")
    }

    // MARK: - Handle fence

    func testCachedHandlesAreFencedWhenClosingStarts() async throws {
        for path in ["unlink", "failed unlink", "erase"] {
            setUpRootForStep()
            let (_, b) = try await completedPair()
            let cached = try store(b)
            let provenance = try XCTUnwrap(provenances["b"])
            var gate: CheckedContinuation<Void, Never>?
            if path == "failed unlink" {
                cached.faultHookForTesting = { if $0 == .beforeCommit("retire") { throw CancellationError() } }
            } else {
                b.hostClosingHookForTesting = { if $0 == "start" { await withCheckedContinuation { gate = $0 } } }
            }
            if path == "erase" {
                b.eraseLocalData()
            } else {
                b.unlinkAndKeepTasks()
            }
            if path == "failed unlink" {
                try await wait("handoff failed") { b.hostLifecycle == .failed(.unlink) }
            } else {
                try await wait("worker paused before retirement") { gate != nil }
            }
            XCTAssertNil(cached.view.retirement, path)
            let before = try JournalFixture.fileHash(cached.url)
            let refusals: [(String, () async throws -> Void)] = [
                ("submit", { _ = try await cached.submit([HostJournalMutation(id: HostJournalStore.randomBytes(16), payload: Data("x".utf8))], capturedThrough: 99) }),
                ("markApplied", { try await cached.markApplied(through: 0) }),
                ("declareReady", { try await cached.declareReady(capturedThrough: 99) }),
                ("enroll", { _ = try await cached.enroll() }),
                ("resume", { _ = try await cached.resume(provenance) }),
            ]
            for (name, refusal) in refusals {
                await XCTAssertThrowsErrorAsync(try await refusal(), "\(path): \(name)") { XCTAssertEqual($0 as? HostJournalError, .fenced, "\(path): \(name)") }
            }
            XCTAssertEqual(try JournalFixture.fileHash(cached.url), before, path)
            XCTAssertNil(b.hostJournal)
            if path != "failed unlink" {
                gate?.resume()
                gate = nil
                try await wait("closed") { b.hostLifecycle == .active && !b.isPaired }
                if path == "unlink" {
                    XCTAssertEqual(try HostJournalStore.open(cached.url).view.retirement, .unlink)
                    await XCTAssertThrowsErrorAsync(try await refusals[0].1()) { XCTAssertEqual($0 as? HostJournalError, .retired) }
                } else {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: cached.url.path))
                }
            }
            for engine in engines { await engine.stop() }
            engines = []
        }
    }

    // MARK: - Stop settlement

    func testStopSettlesClosingAtEachSuspension() async throws {
        let schedules: [(HostLifecycleIntent, String)] = [(.unlink, "retired"), (.unlink, "controlOnly"), (.erase, "marked"), (.erase, "controlOnly")]
        for (intent, step) in schedules {
            setUpRootForStep()
            let (a, b) = try await completedPair()
            await a.stop()
            var gate: CheckedContinuation<Void, Never>?
            b.hostClosingHookForTesting = { if $0 == step { await withCheckedContinuation { gate = $0 } } }
            if intent == .erase {
                b.eraseLocalData()
            } else {
                b.unlinkAndKeepTasks()
            }
            try await wait("worker at \(step)") { gate != nil }
            await relay.setAppendsUnavailable(true)
            var didStop = false
            let stopping = Task { await b.stop(); didStop = true }
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertFalse(didStop, "stop returned before the worker settled")
            gate?.resume()
            gate = nil
            await stopping.value
            let rejected = await relay.rejectedAppends
            let files = try Self.tree(directory("b"))
            try await Task.sleep(for: .milliseconds(1300))
            let rejectedLater = await relay.rejectedAppends
            XCTAssertEqual(rejectedLater, rejected, "\(intent) at \(step): transport requests after stop returned")
            XCTAssertEqual(try Self.tree(directory("b")), files, "\(intent) at \(step): files changed after stop returned")
            XCTAssertNotEqual(b.hostLifecycle, .active, "\(intent) at \(step)")
            await relay.setAppendsUnavailable(false)
            engines.removeAll { $0 === b }
            let restarted = engine("b")
            try await wait("closed after restart") { restarted.hostLifecycle == .active && !restarted.isPaired }
            let observer = await restart(a, "a")
            try await wait("departure published after restart") { observer.linkedMemberCount == 1 }
            for engine in engines { await engine.stop() }
            engines = []
        }
    }

    // MARK: - Intake status

    func testReservationFetchInvalidatesQuiescence() async throws {
        let (a, b) = try await completedPair()
        try await wait("quiescent before invitation") { a.hostView?.isQuiescent == true }
        await a.stop()
        await b.stop()
        let c = engine("c")
        let aSession = try XCTUnwrap(a.mlsSessionForTesting)
        let bSession = try XCTUnwrap(b.mlsSessionForTesting)
        let run = try JournalFixture.chain(Data(repeating: 0x77, count: 16), count: 1)
        a.reservationSendHookForTesting = {
            try? await self.send(.records([run[0].bytes]), from: bSession)
        }
        var observed: (fetched: Bool, quiescent: Bool?, intake: HostIntakeSummary?)?
        a.reservationHookForTesting = {
            let inbox = (try? await aSession.inbox()) ?? []
            observed = (
                inbox.contains { (try? HostJournalMessage.decode($0.plaintext).records) == [run[0].bytes] },
                a.hostView?.isQuiescent, a.hostView?.intake
            )
        }
        try await pair(a, c)
        let seen = try XCTUnwrap(observed)
        XCTAssertTrue(seen.fetched)
        XCTAssertEqual(seen.quiescent, false, "unowned inbox work was reported quiescent")
        XCTAssertEqual(seen.intake, .unknown)
    }

    func testDirectMLSOperationsInvalidateSettledIntake() async throws {
        let linked = try await completedPair()
        var a = linked.0
        let bFingerprint = try await fingerprint(linked.1)
        let operations: [(String, (MLSSession) async throws -> Void)] = [
            ("synchronize", { _ = try await $0.synchronize() }),
            ("send", { _ = try await $0.send(try HostJournalMessage(control: .hello(vector: ReplicaVersionVector(), provider: nil)).encoded()) }),
            ("remove", { _ = try await $0.remove(fingerprint: bFingerprint) }),
        ]
        for (name, operation) in operations {
            var settledWhileStopped = false
            for _ in 0..<20 where !settledWhileStopped {
                try await wait("settled before \(name)") {
                    if case .settled = a.hostView?.intake { return true }
                    return false
                }
                await a.stop()
                if case .settled = a.hostView?.intake {
                    settledWhileStopped = true
                } else {
                    a = await restart(a, "a")
                }
            }
            XCTAssertTrue(settledWhileStopped, name)
            try await operation(try XCTUnwrap(a.mlsSessionForTesting))
            XCTAssertEqual(a.hostView?.intake, .unknown, "\(name) left a settled intake")
            XCTAssertFalse(a.hostView?.isQuiescent ?? true, name)
            a = await restart(a, "a")
        }
        try await wait("settled again after a later drain") {
            if case .settled = a.hostView?.intake { return true }
            return false
        }
    }

    // MARK: - Cancelled join

    func testCancelledJoinAfterItCommittedKeepsTheJoinedOwner() async throws {
        let a = engine("a")
        let b = engine("b")
        var gate: CheckedContinuation<Void, Never>?
        b.afterJoinHookForTesting = { await withCheckedContinuation { gate = $0 } }
        try await wait("host ready to invite") { !a.canCancelPairing }
        a.createPrivateSync()
        try await wait("invitation") { a.invitationURL != nil }
        b.joinPrivateSync(url: try XCTUnwrap(a.invitationURL))
        try await wait("safety code") { a.isHostApprovalPending && b.safetyCode != nil }
        a.approveSafetyCode()
        try await wait("joined, before the checkpoint") { gate != nil }
        try await wait("inviter finished") { !a.canCancelPairing && a.linkedMemberCount == 2 }
        let intent = try XCTUnwrap(ReplicationCheckpoint.load(from: directory("b").appendingPathComponent(ReplicationCheckpoint.joinIntentFilename)))
        b.cancelPairing()
        gate?.resume()
        gate = nil
        try await wait("joined link kept") { b.isPaired }
        let group = try await XCTUnwrapAsync(b.mlsSessionForTesting).group()
        XCTAssertEqual(group, intent.group)
        XCTAssertEqual(b.hostView?.journal?.journalID, intent.hostJournal)
        try await enroll(a, "a")
        try await submit(a, "a", ["after the cancelled join"])
        try await ready(a, "a")
        try await enroll(b, "b")
        try await wait("history complete") { (try? self.store(b).view.historyComplete) == true }
        let applied = try await applyAll(b, "b")
        XCTAssertEqual(applied, [Data("after the cancelled join".utf8)])
    }

    // MARK: - Named schedules

    func testWeakerReplacementProviderDoesNotLowerTheStoredTarget() async throws {
        let (a, b) = try await completedPair()
        let j = engine("j")
        var gate: CheckedContinuation<Void, Never>?
        b.replyBatchHookForTesting = {
            if gate == nil, b.replyObligationForTesting?.bootstrap?.contains(where: { $0.cut != nil }) == true {
                await withCheckedContinuation { gate = $0 }
            }
        }
        try await pair(b, j)
        try await wait("weaker provider chose its cut") { gate != nil }
        await j.stop()
        await a.stop()
        let jFingerprint = try await fingerprint(j)
        let aOrigin = try store(a).view.origin
        let weak = try XCTUnwrap(b.replyObligationForTesting?.bootstrap?.first?.cut)
        try await submit(a, "a", ["four", "five"])
        let strong = HostJournalAdapter.vector(try store(a).receivedVector)
        XCTAssertEqual(HostJournalAdapter.dictionary(weak)[aOrigin], 3)
        XCTAssertEqual(HostJournalAdapter.dictionary(strong)[aOrigin], 5)
        try await send(.complete(member: jFingerprint, through: strong), from: try XCTUnwrap(a.mlsSessionForTesting))
        let joiner = await restart(j, "j")
        try await enroll(joiner, "j")
        try await wait("strong target stored") { joiner.hostView?.journal?.completionTarget?[aOrigin] == 5 }
        gate?.resume()
        gate = nil
        b.replyBatchHookForTesting = nil
        try await wait("weaker certificate delivered") {
            b.replyObligationForTesting?.bootstrap == nil && joiner.hostView?.journal?.delivered == 3
        }
        try await Task.sleep(for: .milliseconds(300))
        let view = try XCTUnwrap(joiner.hostView?.journal)
        XCTAssertFalse(view.historyComplete, "a weaker certificate lowered the stored target")
        XCTAssertEqual(view.completionTarget?[aOrigin], 5)
        _ = await restart(a, "a")
        try await wait("complete through the stored target") { joiner.hostView?.journal?.historyComplete == true }
        let applied = try await applyAll(joiner, "j")
        XCTAssertEqual(applied.map { String(decoding: $0, as: UTF8.self) }, ["one", "two", "three", "four", "five"])
        XCTAssertEqual(joiner.hostView?.journal?.historyApplied, true)
    }

    func testOwnRecordAboveALostWatermarkReachesTheJoinerThroughTheCut() async throws {
        let (a, b) = try await completedPair()
        try await wait("history uploaded") { a.hostView?.unuploaded == 0 }
        try await wait("second member may invite") { !b.awaitsReservationsForTesting }
        await b.stop()
        await relay.dropNextAppendResponse(thenUnavailable: true)
        try await submit(a, "a", ["accepted before the add"])
        try await wait("upload landed without an answer") { await self.relay.rejectedAppends > 0 }
        await a.stop()
        let aSession = try XCTUnwrap(a.mlsSessionForTesting)
        let landed = try await XCTUnwrapAsync(await aSession.pendingDelivery())
        XCTAssertEqual(landed.kind, .application)
        let group = try await XCTUnwrapAsync(await aSession.group())
        let landedCursor = try await XCTUnwrapAsync(await relay.log(group: group).first { $0.delivery.payload == landed.payload }?.cursor)
        await relay.setAppendsUnavailable(false)

        let inviter = await restart(b, "b")
        var gate: CheckedContinuation<Void, Never>?
        inviter.replyBatchHookForTesting = {
            if gate == nil, inviter.replyObligationForTesting?.bootstrap?.contains(where: { $0.cut != nil }) == true {
                await withCheckedContinuation { gate = $0 }
            }
        }
        let j = engine("j")
        try await pair(inviter, j)
        try await wait("original provider held at its first reply") { gate != nil }
        await j.stop()
        let log = await relay.log(group: group)
        let addCursor = try XCTUnwrap(log.last { $0.delivery.welcome != nil }?.cursor)
        XCTAssertLessThan(landedCursor, addCursor, "the record must land before the joiner's Add")
        XCTAssertEqual(log.filter { $0.delivery.payload == landed.payload }.count, 1)

        let aOrigin = try store(a).view.origin
        let ownOrigin = try ReplicaDeviceID(bytes: aOrigin)
        let checkpointURL = directory("a").appendingPathComponent(ReplicationCheckpoint.filename)
        let deviceID = try ReplicaDeviceID(bytes: a.localDeviceID)
        func persistedWatermark() throws -> UInt64 {
            try XCTUnwrap(ReplicationCheckpoint.load(from: checkpointURL)).uploadedThrough(origin: ownOrigin, deviceID: deviceID)
        }
        try await send(
            try HostJournalMessage(control: .hello(vector: ReplicaVersionVector(), provider: try await fingerprint(a))),
            from: try XCTUnwrap(j.mlsSessionForTesting)
        )
        _ = try await aSession.synchronize()
        try await a.drainInboxForTesting()
        let jFingerprint = try await fingerprint(j)
        XCTAssertEqual(a.replyObligationForTesting?.bootstrap?.map(\.member), [jFingerprint])
        var atCut: (cut: UInt64?, view: UInt64?, persisted: UInt64?)?
        a.replyBatchHookForTesting = {
            guard atCut == nil else { return }
            atCut = (
                a.replyObligationForTesting?.bootstrap?.first?.cut.map { HostJournalAdapter.dictionary($0)[aOrigin] ?? 0 },
                a.hostView?.uploadedThrough, try? persistedWatermark()
            )
        }
        try await a.sendRepliesForTesting()
        a.replyBatchHookForTesting = nil
        let seen = try XCTUnwrap(atCut)
        XCTAssertEqual(seen.cut, 4, "the cut must include the retained own record")
        XCTAssertEqual(seen.view, 3, "the watermark recovered before the cut")
        XCTAssertEqual(seen.persisted, 3, "the persisted watermark recovered before the cut")
        XCTAssertEqual(try persistedWatermark(), 3)
        let resolved = try await aSession.pendingDelivery()
        XCTAssertNil(resolved, "the resend did not settle")
        let after = await relay.log(group: group)
        XCTAssertEqual(after.filter { $0.delivery.payload == landed.payload }.map(\.cursor), [landedCursor], "the resend did not deduplicate")
        XCTAssertNil(a.replyObligationForTesting?.bootstrap)

        let jSession = try XCTUnwrap(j.mlsSessionForTesting)
        _ = try await jSession.synchronize()
        try await j.drainInboxForTesting()
        let received = try store(j).view
        XCTAssertTrue(received.historyComplete)
        XCTAssertEqual(received.completionTarget?[aOrigin], 4)
        XCTAssertEqual(received.delivered, 4)
        XCTAssertFalse(received.historyApplied, "history counted as applied before the host applied it")
        try await enroll(j, "j")
        let applied = try await applyAll(j, "j")
        XCTAssertEqual(applied.map { String(decoding: $0, as: UTF8.self) }, ["one", "two", "three", "accepted before the add"])
        XCTAssertEqual(try store(j).view.historyApplied, true)
        gate?.resume()
        gate = nil
        inviter.replyBatchHookForTesting = nil
    }

    /// Every copy of the record lands before the joiner's Add and the
    /// watermark recovers before the cut, so only a reply can carry it.
    func testRecordWhoseCopiesAllPrecedeTheAddReachesTheJoinerThroughReplies() async throws {
        let (a, b) = try await completedPair()
        await b.stop()
        try await wait("history uploaded") { a.hostView?.unuploaded == 0 }
        await relay.dropNextAppendResponse(thenUnavailable: true)
        try await submit(a, "a", ["landed before the add"])
        try await wait("upload landed without an answer") { await self.relay.rejectedAppends > 0 }
        XCTAssertEqual(a.hostView?.unuploaded, 1, "the watermark advanced although the answer was lost")
        await a.stop()
        await relay.setAppendsUnavailable(false)
        let provider = await restart(a, "a")
        try await enroll(provider, "a")
        try await wait("duplicate upload settled") { provider.hostView?.unuploaded == 0 }
        let j = engine("j")
        try await pair(provider, j)
        try await enroll(j, "j")
        try await wait("joiner complete") { (try? self.store(j).view.historyComplete) == true }
        let aOrigin = try store(provider).view.origin
        XCTAssertEqual(try store(j).view.completionTarget?[aOrigin], 4)
        let applied = try await applyAll(j, "j")
        XCTAssertEqual(applied.map { String(decoding: $0, as: UTF8.self) }, ["one", "two", "three", "landed before the add"])
        XCTAssertEqual(try store(j).view.historyApplied, true)
    }
}

private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
