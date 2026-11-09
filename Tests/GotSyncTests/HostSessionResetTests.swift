import Foundation
@testable import GotSync
import GotSyncMLS
import os
import XCTest

/// Host session resets: the old session closes before its files go, the
/// settled final state decides, and an unproven close keeps everything.
extension HostEngineTests {
    private func until(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func mlsDirectories(_ name: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: MLSSession.directory(in: directory(name)).path).sorted()
    }

    /// B is held right before its join commits; A has added it. Returns the
    /// join parameters and a release for the held pairing task.
    private func joinerHeldBeforeCommit(
        _ a: SyncEngine, _ b: SyncEngine
    ) async throws -> (params: (Data, Data, Data, Data?), release: () -> Void) {
        var params: (Data, Data, Data, Data?)?
        var gate: CheckedContinuation<Void, Never>?
        b.beforeJoinHookForTesting = { group, reference, inviter, profile in
            params = (group, reference, inviter, profile)
            await withCheckedContinuation { gate = $0 }
        }
        try await wait("host ready") { !a.canCancelPairing }
        a.createPrivateSync()
        try await wait("invitation") { a.invitationURL != nil }
        b.joinPrivateSync(url: try XCTUnwrap(a.invitationURL))
        try await wait("safety code") { a.isHostApprovalPending && b.safetyCode != nil }
        a.approveSafetyCode()
        try await wait("joiner held before its commit") { gate != nil }
        try await wait("inviter added it") { !a.canCancelPairing && a.linkedMemberCount == 2 }
        return (try XCTUnwrap(params), { gate?.resume(); gate = nil })
    }

    /// Queues `work` on the old session as the reset begins and waits until
    /// it is admitted, so the close must let it finish first.
    private func queue(on b: SyncEngine, _ work: @escaping @Sendable (MLSSession) async -> Void) {
        b.resetQueuedWorkHookForTesting = { owner in
            b.resetQueuedWorkHookForTesting = nil
            let admitted = owner.operationCount.started
            Task { await work(owner) }
            while owner.operationCount.started == admitted {
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
    }

    func testAJoinCommittedByQueuedWorkDuringACancelledJoinResetIsAdoptedNotErased() async throws {
        let a = engine("a")
        let b = engine("b")
        let (params, release) = try await joinerHeldBeforeCommit(a, b)
        let intentURL = directory("b").appendingPathComponent(ReplicationCheckpoint.joinIntentFilename)
        let intent = try XCTUnwrap(ReplicationCheckpoint.load(from: intentURL))
        let directories = try mlsDirectories("b")
        queue(on: b) { owner in
            _ = try? await owner.join(group: params.0, keyPackageReference: params.1, verifiedInviterFingerprint: params.2, profile: params.3)
        }
        b.cancelPairing()
        release()
        try await wait("the committed join was adopted") { b.isPaired }
        XCTAssertEqual(try mlsDirectories("b"), directories, "the committed join's state was erased")
        let group = try await XCTUnwrapAsync(b.mlsSessionForTesting).group()
        XCTAssertEqual(group, intent.group)
        XCTAssertEqual(b.hostView?.journal?.journalID, intent.hostJournal)
    }

    func testInboxBytesDeliveredByQueuedWorkDuringACancelledJoinResetSurvive() async throws {
        let a = engine("a")
        let b = engine("b")
        let (params, release) = try await joinerHeldBeforeCommit(a, b)
        try await enroll(a, "a")
        try await submit(a, "a", ["delivered while the reset waited"])
        try await ready(a, "a")
        try await a.uploadLocalOperationsForTesting()
        let directories = try mlsDirectories("b")
        let finalInbox = OSAllocatedUnfairLock(initialState: [Data]())
        b.resetFinalInboxHookForTesting = { messages in
            finalInbox.withLock { $0 = messages.map(\.plaintext) }
        }
        queue(on: b) { owner in
            _ = try? await owner.join(group: params.0, keyPackageReference: params.1, verifiedInviterFingerprint: params.2, profile: params.3)
            _ = try? await owner.synchronize()
        }
        b.cancelPairing()
        release()
        try await wait("the committed join was adopted") { b.isPaired }
        let heldPayloads = finalInbox.withLock { $0 }.flatMap {
            (try? HostJournalMessage.decode($0))?.records ?? []
        }.compactMap { try? JournalEnvelope(parsing: $0).payload }
        XCTAssertTrue(heldPayloads.contains(Data("delivered while the reset waited".utf8)))
        XCTAssertEqual(try mlsDirectories("b"), directories)
        try await enroll(b, "b")
        try await wait("history complete") { (try? self.store(b).view.historyComplete) == true }
        let applied = try await applyAll(b, "b")
        XCTAssertEqual(applied, [Data("delivered while the reset waited".utf8)], "delivered inbox bytes were lost")
    }

    func testAnUnprovenCloseRetainsTheOwnerFilesAndKeyAndBlocksNewWork() async throws {
        let (b, secrets) = gatedEngine("b", holding: nil)
        await opened(b)
        let owner = try XCTUnwrap(b.mlsSessionForTesting)
        let mls = MLSSession.directory(in: directory("b"))
        let files = try Self.tree(mls)
        let key = try stores["b"]?.read(account: SecretStoreMLSStateKey.account)
        let reads = secrets.keyReads
        let writes = secrets.keyWrites
        MLSClient.failNextCloseForTesting(true)
        defer { MLSClient.failNextCloseForTesting(false) }
        await XCTAssertThrowsErrorAsync(try await b.resetHostSessionForTesting(discard: true)) {
            XCTAssertEqual($0 as? HostEngineError, .sessionCloseUncertain)
        }
        XCTAssertTrue(b.hostRetainedSessionForTesting === owner, "the failed owner was not retained")
        XCTAssertNil(b.mlsSessionForTesting)
        XCTAssertEqual(b.hostRepair, .sessionCloseUncertain)
        XCTAssertEqual(secrets.keyReads, reads, "a second constructor ran")
        XCTAssertEqual(secrets.keyWrites, writes, "an identity or key was written")
        XCTAssertEqual(try Self.tree(mls), files)
        XCTAssertEqual(try stores["b"]?.read(account: SecretStoreMLSStateKey.account), key)
        b.createPrivateSync()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(b.invitationURL, "pairing started without a proven close")
        b.eraseLocalData()
        try await wait("erase refused") { b.hostLifecycle == .failed(.erase) }
        XCTAssertEqual(try Self.tree(mls), files, "erase deleted files of an unproven close")
        await b.stop()
        XCTAssertTrue(b.hostRetainedSessionForTesting === owner, "stop dropped the retained owner")
        XCTAssertEqual(try Self.tree(mls), files)
    }

    func testACancelledCallerStillSettlesTheReset() async throws {
        let b = engine("b")
        await opened(b)
        let directories = try mlsDirectories("b")
        var gate: CheckedContinuation<Void, Never>?
        b.resetQueuedWorkHookForTesting = { _ in await withCheckedContinuation { gate = $0 } }
        let caller = Task { try await b.resetHostSessionForTesting(discard: true) }
        try await until { gate != nil }
        caller.cancel()
        gate?.resume()
        await XCTAssertThrowsErrorAsync(try await caller.value) {
            XCTAssertTrue($0 is CancellationError)
        }
        try await until { b.mlsSessionForTesting != nil }
        XCTAssertNotEqual(try mlsDirectories("b"), directories, "the reset did not complete")
        XCTAssertNil(b.hostRepair)
    }

    func testStopWaitsForAHeldReset() async throws {
        let b = engine("b")
        await opened(b)
        var gate: CheckedContinuation<Void, Never>?
        b.resetQueuedWorkHookForTesting = { _ in await withCheckedContinuation { gate = $0 } }
        let caller = Task { try await b.resetHostSessionForTesting(discard: true) }
        try await until { gate != nil }
        var stopped = false
        let stopping = Task(priority: .high) {
            await b.stop()
            stopped = true
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(stopped, "stop returned while a reset was held")
        gate?.resume()
        await stopping.value
        _ = try? await caller.value
        XCTAssertNotNil(b.mlsSessionForTesting, "stop left no session after the reset")
    }

    func testEraseDuringAHeldResetWaitsForItThenErases() async throws {
        let b = engine("b")
        await opened(b)
        var gate: CheckedContinuation<Void, Never>?
        b.resetQueuedWorkHookForTesting = { _ in await withCheckedContinuation { gate = $0 } }
        let caller = Task { try await b.resetHostSessionForTesting(discard: true) }
        try await until { gate != nil }
        b.eraseLocalData()
        XCTAssertEqual(b.hostLifecycle, .closing(.erase))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(b.hostLifecycle, .closing(.erase), "erase did not wait for the reset")
        gate?.resume()
        _ = try? await caller.value
        try await wait("erased") { b.hostLifecycle == .active && b.mlsSessionForTesting != nil }
        XCTAssertNil(b.hostRepair)
    }

    func testEraseAfterAnUnprovenCloseDuringItFailsPreserving() async throws {
        let b = engine("b")
        await opened(b)
        let mls = MLSSession.directory(in: directory("b"))
        let files = try Self.tree(mls)
        var gate: CheckedContinuation<Void, Never>?
        b.resetQueuedWorkHookForTesting = { _ in await withCheckedContinuation { gate = $0 } }
        MLSClient.failNextCloseForTesting(true)
        defer { MLSClient.failNextCloseForTesting(false) }
        let caller = Task { try await b.resetHostSessionForTesting(discard: true) }
        try await until { gate != nil }
        b.eraseLocalData()
        gate?.resume()
        _ = try? await caller.value
        try await wait("erase refused") { b.hostLifecycle == .failed(.erase) }
        XCTAssertNotNil(b.hostRetainedSessionForTesting)
        XCTAssertEqual(try Self.tree(mls), files, "erase deleted files of an unproven close")
    }

    func testTwoResetRequestsForOneOwnerShareOneReset() async throws {
        let (b, secrets) = gatedEngine("b", holding: nil)
        await opened(b)
        let owner = try XCTUnwrap(b.mlsSessionForTesting)
        let writes = secrets.keyWrites
        var gate: CheckedContinuation<Void, Never>?
        b.resetQueuedWorkHookForTesting = { _ in await withCheckedContinuation { gate = $0 } }
        let first = Task { try await b.resetHostSessionForTesting(owner: owner, discard: true) }
        try await until { gate != nil }
        let second = Task { try await b.resetHostSessionForTesting(owner: owner, discard: true) }
        try await Task.sleep(for: .milliseconds(50))
        gate?.resume()
        let outcomes = (try await first.value, try await second.value)
        XCTAssertEqual(outcomes.0, .replaced)
        XCTAssertEqual(outcomes.1, .replaced, "a detached owner's second request was not joined")
        XCTAssertEqual(try mlsDirectories("b").count, 1)
        XCTAssertEqual(secrets.keyWrites, writes + 1, "more than one new identity was created")
    }

    func testAPartialEraseStopsWithOnlyTheRemainderKept() async throws {
        let (b, secrets) = gatedEngine("b", holding: nil)
        await opened(b)
        let key = try stores["b"]?.read(account: SecretStoreMLSStateKey.account)
        let writes = secrets.keyWrites
        secrets.failDeletes()
        await XCTAssertThrowsErrorAsync(try await b.resetHostSessionForTesting(discard: true))
        XCTAssertEqual(b.hostRepair, .mlsUnreadable)
        XCTAssertNil(b.mlsSessionForTesting, "a new session followed a partial erase")
        XCTAssertEqual(secrets.keyWrites, writes, "a new identity followed a partial erase")
        XCTAssertEqual(try stores["b"]?.read(account: SecretStoreMLSStateKey.account), key, "the remaining key was not kept")
        XCTAssertNil(b.hostRetainedSessionForTesting)
    }

    func testAFreshFounderDeclineClosesTheOldSessionBeforeTodaysDeletion() async throws {
        let a = engine("a")
        let b = engine("b")
        var gate: CheckedContinuation<Void, Never>?
        a.afterAddGateForTesting = { await withCheckedContinuation { gate = $0 } }
        try await wait("host ready") { !a.canCancelPairing }
        a.createPrivateSync()
        try await wait("invitation") { a.invitationURL != nil }
        b.joinPrivateSync(url: try XCTUnwrap(a.invitationURL))
        try await wait("safety code") { a.isHostApprovalPending && b.safetyCode != nil }
        a.approveSafetyCode()
        try await wait("inviter held after its Add") { gate != nil }
        let old = try XCTUnwrap(a.mlsSessionForTesting)
        let oldDirectory = a.mlsDirectoryForTesting
        let claims = directory("a").appendingPathComponent(ReplicationCheckpoint.foundingClaimsFilename)
        let key = try stores["a"]?.read(account: SecretStoreMLSStateKey.account)
        let journalsBefore = try Self.journalFiles(directory("a"))
        let filesAtFinalRead = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        a.resetFinalInboxHookForTesting = { _ in
            filesAtFinalRead.withLock { $0 = FileManager.default.fileExists(atPath: oldDirectory.path) }
        }
        b.rejectSafetyCode()
        try await wait("decline received") { a.peerDecisionForTesting == false }
        gate?.resume()
        gate = nil
        try await wait("declined and replaced") {
            a.lastPairingFailure == .pairingDeclined && a.mlsSessionForTesting != nil && a.mlsDirectoryForTesting != oldDirectory
        }
        XCTAssertEqual(filesAtFinalRead.withLock { $0 }, true, "the old session's files were gone before it closed")
        await XCTAssertThrowsErrorAsync(try await old.fingerprint()) {
            XCTAssertEqual($0 as? MLSClientError, .storageUnavailable, "the declined session stayed open")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: claims.path))
        XCTAssertNotEqual(try stores["a"]?.read(account: SecretStoreMLSStateKey.account), key)
        XCTAssertEqual(try Self.journalFiles(directory("a")), journalsBefore, "the decline changed journal retention")
    }
}

private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
