import Foundation
import GotSyncMLS
import SQLite3
import XCTest
@testable import GotSync

extension HostEngineTests {
    func testUnreadableJoinedOwnerSurvivesReplacementJoinAndRestart() async throws {
        let a = engine("a")
        let b = engine("b")
        let c = engine("c")
        var gate: CheckedContinuation<Void, Never>?
        defer { gate?.resume() }
        b.afterJoinHookForTesting = { await withCheckedContinuation { gate = $0 } }
        try await wait("hosts ready") { !a.canCancelPairing && !c.canCancelPairing }
        a.createPrivateSync()
        c.createPrivateSync()
        try await wait("invitations") { a.invitationURL != nil && c.invitationURL != nil }
        let next = try XCTUnwrap(c.invitationURL)
        b.joinPrivateSync(url: try XCTUnwrap(a.invitationURL))
        try await wait("approval") { a.isHostApprovalPending && b.safetyCode != nil }
        a.approveSafetyCode()
        try await wait("joined before checkpoint") { gate != nil }
        try await wait("inviter settled") { !a.canCancelPairing && a.linkedMemberCount == 2 }
        let owner = try XCTUnwrap(b.mlsSessionForTesting)
        let originalGroup = try await owner.group()
        let payload = "transient lock must preserve owner"
        try enroll(a, "a")
        try submit(a, "a", [payload])
        try ready(a, "a")
        try await wait("held application bytes") {
            _ = try await owner.synchronize()
            return try await owner.inbox().contains { (try? HostJournalMessage.decode($0.plaintext).kind) == .records }
        }
        await a.stop()
        let held = try await owner.inbox()
        XCTAssertFalse(held.isEmpty)
        let directory = b.mlsDirectoryForTesting
        let files = try Self.tree(directory)
        let secretStore = try XCTUnwrap(stores["b"])
        let key = try secretStore.read(account: SecretStoreMLSStateKey.account)
        let intentURL = self.directory("b").appendingPathComponent(ReplicationCheckpoint.joinIntentFilename)
        let intentBytes = try Data(contentsOf: intentURL)
        let intent = try XCTUnwrap(ReplicationCheckpoint.load(from: intentURL))
        let journalURL = HostJournalStore.fileURL(in: self.directory("b"), journalID: try XCTUnwrap(intent.hostJournal))
        let journalBytes = try Data(contentsOf: journalURL)
        var lock: OpaquePointer?
        let database = directory.appendingPathComponent("mls-v2.sqlite3")
        XCTAssertEqual(sqlite3_open_v2(database.path, &lock, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        defer {
            sqlite3_exec(lock, "ROLLBACK", nil, nil, nil)
            sqlite3_close(lock)
        }
        XCTAssertEqual(sqlite3_exec(lock, "BEGIN EXCLUSIVE", nil, nil, nil), SQLITE_OK)
        b.cancelPairing()
        gate?.resume()
        gate = nil
        b.afterJoinHookForTesting = nil
        try await wait("unreadable settlement ends", timeout: .seconds(30)) { b.canJoinExistingSync }
        XCTAssertTrue(b.mlsSessionForTesting === owner)
        XCTAssertEqual(sqlite3_exec(lock, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        let recovered = try await owner.inbox()
        XCTAssertEqual(recovered, held)
        XCTAssertEqual(try Self.tree(directory), files)

        XCTAssertEqual(sqlite3_exec(lock, "BEGIN EXCLUSIVE", nil, nil, nil), SQLITE_OK)
        b.joinPrivateSync(url: next)
        try await wait("replacement attempt exits", timeout: .seconds(30)) { !b.canCancelPairing }
        await b.stop()
        XCTAssertTrue(b.mlsSessionForTesting === owner)
        XCTAssertEqual(try Self.tree(directory), files)
        XCTAssertEqual(try secretStore.read(account: SecretStoreMLSStateKey.account), key)
        XCTAssertEqual(try Data(contentsOf: intentURL), intentBytes)
        XCTAssertEqual(try Data(contentsOf: journalURL), journalBytes)
        XCTAssertNil(c.safetyCode)
        XCTAssertEqual(sqlite3_exec(lock, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        let afterFailure = try await owner.inbox()
        XCTAssertEqual(afterFailure, held)

        engines.removeAll { $0 === b }
        let reopened = engine("b")
        try await wait("original owner adopted after restart") { reopened.isPaired }
        let reopenedGroup = try await XCTUnwrap(reopened.mlsSessionForTesting).group()
        XCTAssertEqual(reopenedGroup, originalGroup)
        XCTAssertEqual(reopened.hostView?.journal?.journalID, intent.hostJournal)
        try enroll(reopened, "b")
        a.applicationDidBecomeActive()
        try await wait("history complete") { reopened.hostView?.journal?.historyComplete == true }
        XCTAssertEqual(try applyAll(reopened, "b"), [Data(payload.utf8)])
        c.cancelPairing()
    }
}
