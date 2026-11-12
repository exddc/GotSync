import Foundation
import GotSyncMLS
import XCTest
@_spi(HostJournalPreview) @testable import GotSync

/// Cancelled-join settlement, exact handoff identity and composed-view
/// publication of intake changes.
extension HostEngineTests {
    // MARK: - Cancelled join settlement

    /// B joins A's group and stops before saving its checkpoint; A's record
    /// then reaches only B's MLS inbox. Returns the paused gate, the owner
    /// session, its held inbox and C's pending invitation.
    private func joinedOwnerHoldingBytes(
        _ a: SyncEngine, _ b: SyncEngine, _ c: SyncEngine
    ) async throws -> (gate: () -> CheckedContinuation<Void, Never>?, owner: MLSSession, held: [MLSInboxMessage], next: URL) {
        var gate: CheckedContinuation<Void, Never>?
        b.afterJoinHookForTesting = { await withCheckedContinuation { gate = $0 } }
        try await wait("hosts ready") { !a.canCancelPairing && !c.canCancelPairing }
        a.createPrivateSync()
        c.createPrivateSync()
        try await wait("invitations") { a.invitationURL != nil && c.invitationURL != nil }
        let next = try XCTUnwrap(c.invitationURL)
        b.joinPrivateSync(url: try XCTUnwrap(a.invitationURL))
        try await wait("safety code") { a.isHostApprovalPending && b.safetyCode != nil }
        a.approveSafetyCode()
        try await wait("joined before the checkpoint") { gate != nil }
        try await wait("inviter done") { !a.canCancelPairing && a.linkedMemberCount == 2 }
        let owner = try XCTUnwrap(b.mlsSessionForTesting)
        try await enroll(a, "a")
        try await submit(a, "a", ["owned before cancellation"])
        try await ready(a, "a")
        try await wait("held before cancellation") {
            _ = try await owner.synchronize()
            return try await owner.inbox().contains { (try? HostJournalMessage.decode($0.plaintext).kind) == .records }
        }
        let held = try await owner.inbox()
        return ({ gate }, owner, held, next)
    }

    func testImmediateRejoinWaitsForTheCancelledJoinedOwner() async throws {
        let a = engine("a")
        let b = engine("b")
        let c = engine("c")
        let (gate, owner, held, next) = try await joinedOwnerHoldingBytes(a, b, c)
        let mls = MLSSession.directory(in: directory("b"))
        let files = try Self.tree(mls)
        let intent = try XCTUnwrap(ReplicationCheckpoint.load(from: directory("b").appendingPathComponent(ReplicationCheckpoint.joinIntentFilename)))
        b.cancelPairing()
        XCTAssertFalse(b.canJoinExistingSync)
        b.joinPrivateSync(url: next)
        b.createPrivateSync()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(b.mlsSessionForTesting === owner, "a new join replaced the committed owner")
        XCTAssertNil(b.invitationURL, "a new invitation started during settlement")
        XCTAssertNil(c.safetyCode)
        let remaining = try await owner.inbox()
        XCTAssertEqual(remaining, held)
        let current = try Self.tree(mls)
        XCTAssertTrue(files.keys.allSatisfy { current[$0] != nil }, "owner files disappeared")
        gate()?.resume()
        b.afterJoinHookForTesting = nil
        try await wait("committed owner adopted") { b.isPaired }
        XCTAssertTrue(b.mlsSessionForTesting === owner)
        XCTAssertEqual(b.hostView?.journal?.journalID, intent.hostJournal)
        try await enroll(b, "b")
        try await wait("history complete") { (try? self.store(b).view.historyComplete) == true }
        let applied = try await applyAll(b, "b")
        XCTAssertEqual(applied, [Data("owned before cancellation".utf8)])
        c.cancelPairing()
    }

    func testStopDuringJoinSettlementLeavesTheOwnerForLaunch() async throws {
        let a = engine("a")
        let b = engine("b")
        let c = engine("c")
        let (gate, owner, held, next) = try await joinedOwnerHoldingBytes(a, b, c)
        let group = try await XCTUnwrapAsync(await owner.group())
        let mls = MLSSession.directory(in: directory("b"))
        let files = try Self.tree(mls)
        let intentURL = directory("b").appendingPathComponent(ReplicationCheckpoint.joinIntentFilename)
        let intent = try XCTUnwrap(ReplicationCheckpoint.load(from: intentURL))
        b.cancelPairing()
        var didStop = false
        let stopping = Task { await b.stop(); didStop = true }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(didStop, "stop returned while the cancelled attempt was unsettled")
        gate()?.resume()
        b.afterJoinHookForTesting = nil
        await stopping.value
        engines.removeAll { $0 === b }
        XCTAssertEqual(try Self.tree(mls), files, "settlement changed the owner after stop")
        XCTAssertNotNil(try ReplicationCheckpoint.load(from: intentURL))
        let remaining = try await owner.inbox()
        XCTAssertEqual(remaining, held)

        let relaunched = engine("b")
        relaunched.joinPrivateSync(url: next)
        try await wait("committed owner adopted at launch") { relaunched.isPaired }
        let adoptedGroup = try await XCTUnwrapAsync(relaunched.mlsSessionForTesting).group()
        XCTAssertEqual(adoptedGroup, group)
        XCTAssertEqual(relaunched.hostView?.journal?.journalID, intent.hostJournal)
        XCTAssertNil(c.safetyCode, "the replacement join reached another inviter")
        try await enroll(relaunched, "b")
        try await wait("history complete") { (try? self.store(relaunched).view.historyComplete) == true }
        let applied = try await applyAll(relaunched, "b")
        XCTAssertEqual(applied, [Data("owned before cancellation".utf8)])
        c.cancelPairing()
    }

    func testUncommittedCancelledJoinIsDiscardedThenANewJoinWorks() async throws {
        let a = engine("a")
        let b = engine("b")
        let c = engine("c")
        try await wait("host ready") { !a.canCancelPairing }
        a.createPrivateSync()
        try await wait("invitation") { a.invitationURL != nil }
        b.joinPrivateSync(url: try XCTUnwrap(a.invitationURL))
        let intentURL = directory("b").appendingPathComponent(ReplicationCheckpoint.joinIntentFilename)
        try await wait("join intent saved") { FileManager.default.fileExists(atPath: intentURL.path) && b.safetyCode != nil }
        let journalID = try XCTUnwrap(ReplicationCheckpoint.load(from: intentURL)?.hostJournal)
        b.cancelPairing()
        XCTAssertFalse(b.canJoinExistingSync, "a new join may start before the outcome is settled")
        try await wait("settled") { b.canJoinExistingSync }
        let group = try await XCTUnwrapAsync(b.mlsSessionForTesting).group()
        XCTAssertNil(group)
        XCTAssertFalse(FileManager.default.fileExists(atPath: intentURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: HostJournalStore.fileURL(in: directory("b"), journalID: journalID).path))
        a.cancelPairing()
        try await pair(c, b)
        XCTAssertTrue(b.isPaired)
    }

    // MARK: - Handoff identity

    func testHandoffRefusesADifferentJournalAtTheExpectedPath() async throws {
        var limits = HostJournalLimits.standard
        limits.historyRecords = 3
        let (a, b) = try await completedPair(limits: limits)
        try await submit(a, "a", ["held original"])
        try await wait("held") {
            if case .settled(let held) = b.hostView?.intake { return held > 0 }
            return false
        }
        let original = try store(b)
        let originalID = original.view.journalID
        let url = original.url
        let held = try await XCTUnwrapAsync(b.mlsSessionForTesting).inbox()
        original.faultHookForTesting = { if $0 == .beforeCommit("retire") { throw CancellationError() } }
        b.unlinkAndKeepTasks()
        try await wait("handoff failed") { b.hostLifecycle == .failed(.unlink) }
        await b.stop()
        engines.removeAll { $0 === b }
        let originalBytes = try Data(contentsOf: url)
        let substitute = try HostJournalStore.create(in: directory("b"), group: original.view.group)
        try substitute.retire(.orphaned, heldInbox: held.map { HostJournalHeldMessage(sender: $0.sender, cursor: $0.cursor, plaintext: $0.plaintext) })
        XCTAssertNotEqual(substitute.view.journalID, originalID)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: substitute.url, to: url)
        let mls = MLSSession.directory(in: directory("b"))
        let files = Set(try Self.tree(mls).keys)
        let key = try stores["b"]?.read(account: SecretStoreMLSStateKey.account)
        XCTAssertNotNil(key)
        let lifecycleURL = directory("b").appendingPathComponent(SyncEngine.hostLifecycleFilename)
        let checkpointURL = directory("b").appendingPathComponent(ReplicationCheckpoint.filename)
        let keptIntent = try Data(contentsOf: lifecycleURL)
        let keptCheckpoint = try Data(contentsOf: checkpointURL)

        let reopened = engine("b", limits: limits)
        try await wait("closing settled") { reopened.hostLifecycle != .closing(.unlink) && reopened.hostLifecycle != .opening }
        XCTAssertEqual(reopened.hostLifecycle, .failed(.unlink), "another generation proved the handoff")
        XCTAssertTrue(reopened.isPaired)
        let remaining = try await XCTUnwrapAsync(reopened.mlsSessionForTesting).inbox()
        XCTAssertEqual(remaining, held)
        XCTAssertEqual(Set(try Self.tree(mls).keys), files)
        XCTAssertEqual(try stores["b"]?.read(account: SecretStoreMLSStateKey.account), key)
        XCTAssertEqual(try Data(contentsOf: lifecycleURL), keptIntent)
        XCTAssertEqual(try Data(contentsOf: checkpointURL), keptCheckpoint)
        await reopened.stop()
        engines.removeAll { $0 === reopened }

        try FileManager.default.removeItem(at: url)
        try originalBytes.write(to: url)
        let restored = engine("b", limits: limits)
        try await wait("unlinked with the right journal") { restored.hostLifecycle == .active && !restored.isPaired }
        let archive = try HostJournalStore.open(url)
        XCTAssertEqual(archive.view.journalID, originalID)
        XCTAssertEqual(archive.view.retirement, .unlink)
        let archived = try JournalFixture.exportAll(url).compactMap { item -> Data? in
            if case .held(_, _, let plaintext) = item { return plaintext }
            return nil
        }
        XCTAssertEqual(archived, held.map(\.plaintext))
        try await wait("departed") { a.linkedMemberCount == 1 }
    }

    // MARK: - Composed view publication

    func testIntakeChangesAdvanceAndPublishTheComposedView() async throws {
        let (a, b) = try await completedPair()
        var settledWhileStopped = false
        for _ in 0..<20 where !settledWhileStopped {
            try await wait("settled") { a.hostView?.intake == .settled(held: 0) }
            await a.stop()
            settledWhileStopped = a.hostView?.intake == .settled(held: 0)
            if !settledWhileStopped { a.applicationDidBecomeActive() }
        }
        XCTAssertTrue(settledWhileStopped)
        let session = try XCTUnwrap(a.mlsSessionForTesting)
        let checkpointURL = directory("a").appendingPathComponent(ReplicationCheckpoint.filename)
        let start = try XCTUnwrap(a.hostView)

        _ = try await session.members()
        _ = try await session.inbox()
        _ = try await session.fingerprint()
        _ = try await session.cursor()
        XCTAssertEqual(a.hostView, start, "a read-only getter changed the composed view")

        await b.stop()
        let run = try JournalFixture.chain(Data(repeating: 0x75, count: 16), count: 1)
        try await send(.records([run[0].bytes]), from: try XCTUnwrap(b.mlsSessionForTesting))
        let checkpoint = try Data(contentsOf: checkpointURL)
        _ = try await session.synchronize()
        let held = try await session.inbox()
        XCTAssertTrue(held.contains { (try? HostJournalMessage.decode($0.plaintext).records) == [run[0].bytes] })
        let invalidated = try XCTUnwrap(a.hostView)
        XCTAssertEqual(invalidated.intake, .unknown)
        XCTAssertGreaterThan(invalidated.revision, start.revision, "the intake changed without a new revision")
        XCTAssertEqual(invalidated.journal?.revision, start.journal?.revision)
        XCTAssertEqual(try Data(contentsOf: checkpointURL), checkpoint)

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(a.hostView, invalidated, "an idle stopped engine kept changing its view")

        var observed: [HostEngineView] = []
        let observer = Task { @MainActor in
            for await _ in a.states() {
                if let view = a.hostView { observed.append(view) }
            }
        }
        a.applicationDidBecomeActive()
        try await wait("settled after the drain") {
            a.hostView?.intake == .settled(held: 0) && a.hostView?.journal?.delivered == (start.journal?.delivered ?? 0) + 1
        }
        let settled = try XCTUnwrap(a.hostView)
        XCTAssertGreaterThan(settled.revision, invalidated.revision)
        try await wait("observer saw the settlement") { observed.last?.intake == .settled(held: 0) }
        XCTAssertTrue(observed.contains { $0.intake == .unknown && $0.revision > invalidated.revision }, "no invalidation was published")
        XCTAssertEqual(observed.map(\.revision), observed.map(\.revision).sorted())

        let applied = try await applyAll(a, "a")

        XCTAssertEqual(applied, [run[0].payload])
        try await wait("idle and quiescent") { a.hostView?.isQuiescent == true }
        await a.stop()
        let idle = try XCTUnwrap(a.hostView)
        let published = observed.count
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(a.hostView, idle)
        XCTAssertEqual(observed.count, published, "a stopped engine kept publishing")

        a.applicationDidBecomeActive()
        let beforeReplacement = try XCTUnwrap(a.hostView).revision
        a.unlinkAndKeepTasks()
        try await wait("generation replaced") { a.hostLifecycle == .active && !a.isPaired }
        XCTAssertNil(a.hostView?.journal)
        XCTAssertEqual(a.hostView?.intake, .unknown)
        XCTAssertGreaterThan(try XCTUnwrap(a.hostView).revision, beforeReplacement)
        XCTAssertEqual(observed.map(\.revision), observed.map(\.revision).sorted())
        observer.cancel()
    }
}

private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
