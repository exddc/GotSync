import Foundation
import GotSyncMLS
import XCTest
@_spi(HostJournalPreview) @testable import GotSync

extension HostEngineTests {
    func testCancelledRemovedJoinRetiresItsInboxBeforeCheckpoint() async throws {
        try await preserveRemovedJoin(relaunch: false)
    }

    func testRemovedJoinRelaunchRetiresItsInboxBeforeCheckpoint() async throws {
        try await preserveRemovedJoin(relaunch: true)
    }

    func testRemovedJoinWithMissingJournalKeepsInboxUntilRepair() async throws {
        try await preserveRemovedJoin(relaunch: true, damage: "missing")
    }

    func testRemovedJoinWithUnreadableJournalKeepsInboxUntilRepair() async throws {
        try await preserveRemovedJoin(relaunch: true, damage: "unreadable")
    }

    private func preserveRemovedJoin(relaunch: Bool, damage: String? = nil) async throws {
        let a = engine("a")
        let b = engine("b")
        var gate: CheckedContinuation<Void, Never>?
        defer { gate?.resume() }
        b.afterJoinHookForTesting = { await withCheckedContinuation { gate = $0 } }
        try await wait("host ready") { !a.canCancelPairing }
        a.createPrivateSync()
        try await wait("invitation") { a.invitationURL != nil }
        b.joinPrivateSync(url: try XCTUnwrap(a.invitationURL))
        try await wait("approval") { a.isHostApprovalPending && b.safetyCode != nil }
        a.approveSafetyCode()
        try await wait("joined before checkpoint") { gate != nil }
        try await wait("inviter settled") { !a.canCancelPairing && a.linkedMemberCount == 2 }
        let owner = try XCTUnwrap(b.mlsSessionForTesting)
        let checkpointURL = directory("b").appendingPathComponent(ReplicationCheckpoint.filename)
        let intentURL = directory("b").appendingPathComponent(ReplicationCheckpoint.joinIntentFilename)
        let intent = try XCTUnwrap(ReplicationCheckpoint.load(from: intentURL))
        let journalID = try XCTUnwrap(intent.hostJournal)
        let journalURL = HostJournalStore.fileURL(in: directory("b"), journalID: journalID)
        XCTAssertFalse(b.isPaired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpointURL.path))
        try await enroll(a, "a")
        try await submit(a, "a", ["retain before the main checkpoint"])
        try await ready(a, "a")
        try await wait("held application") {
            _ = try await owner.synchronize()
            return try await owner.inbox().contains { (try? HostJournalMessage.decode($0.plaintext).kind) == .records }
        }
        let target = try await owner.fingerprint()
        XCTAssertTrue(a.removeDevice(fingerprint: target))
        try await wait("removal processed before checkpoint") {
            _ = try await owner.synchronize()
            return try await owner.isRemoved()
        }
        try await wait("remaining member refreshed") { a.linkedMemberCount == 1 }
        await a.stop()
        let held = try await owner.inbox()
        XCTAssertTrue(held.contains { (try? HostJournalMessage.decode($0.plaintext).kind) == .records })
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpointURL.path))
        let expected = held.map { HostJournalHeldMessage(sender: $0.sender, cursor: $0.cursor, plaintext: $0.plaintext) }
        var current = b

        if relaunch {
            let stopping = Task { await b.stop() }
            await Task.yield()
            gate?.resume()
            gate = nil
            b.afterJoinHookForTesting = nil
            await stopping.value
            engines.removeAll { $0 === b }
            XCTAssertFalse(FileManager.default.fileExists(atPath: checkpointURL.path))
            let stoppedInbox = try await owner.inbox()
            XCTAssertEqual(stoppedInbox, held)
            let original = try Data(contentsOf: journalURL)
            let intentBytes = try Data(contentsOf: intentURL)
            let key = try stores["b"]?.read(account: SecretStoreMLSStateKey.account)

            if damage == "missing" {
                try FileManager.default.removeItem(at: journalURL)
            } else if damage == "unreadable" {
                try Data(repeating: 0x5A, count: original.count).write(to: journalURL)
            }
            current = engine("b")
            await opened(current)

            if let damage {
                XCTAssertNotNil(current.hostRepair, damage)
                XCTAssertEqual(current.phase, .failed, damage)
                let retainedOwner = try XCTUnwrap(current.mlsSessionForTesting)
                let retainedInbox = try await retainedOwner.inbox()
                let remainsRemoved = try await retainedOwner.isRemoved()
                XCTAssertEqual(retainedInbox, held, damage)
                XCTAssertTrue(remainsRemoved, damage)
                XCTAssertEqual(try Data(contentsOf: intentURL), intentBytes, damage)
                XCTAssertEqual(try stores["b"]?.read(account: SecretStoreMLSStateKey.account), key, damage)
                if damage == "unreadable" {
                    XCTAssertEqual(try Data(contentsOf: journalURL), Data(repeating: 0x5A, count: original.count))
                } else {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
                }
                await current.stop()
                engines.removeAll { $0 === current }
                try original.write(to: journalURL)
                current = engine("b")
                await opened(current)
            }
        } else {
            b.cancelPairing()
            gate?.resume()
            gate = nil
            b.afterJoinHookForTesting = nil
        }

        try await wait("removed join settled") {
            let fingerprint = try await current.mlsSessionForTesting?.fingerprint()
            return fingerprint != nil && fingerprint != target && current.canJoinExistingSync && current.hostLifecycle == .active
        }
        let archive = try HostJournalStore.open(journalURL)
        XCTAssertEqual(archive.view.journalID, journalID)
        XCTAssertEqual(archive.view.retirement, .removed)
        XCTAssertTrue(try archive.holdsInbox(expected))
        let exported = try JournalFixture.exportAll(journalURL).compactMap { item -> HostJournalHeldMessage? in
            if case .held(let sender, let cursor, let plaintext) = item {
                return HostJournalHeldMessage(sender: sender, cursor: cursor, plaintext: plaintext)
            }
            return nil
        }
        XCTAssertEqual(exported, expected)
        XCTAssertEqual(current.linkEndedReason, .removedFromGroup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: intentURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpointURL.path))
    }
}
