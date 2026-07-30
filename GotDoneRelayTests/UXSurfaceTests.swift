import Foundation
import XCTest
@testable import GotDoneRelay

@MainActor
final class UXSurfaceTests: XCTestCase {
    func testInvitationTTLIsSingleLongLivedConstant() {
        XCTAssertEqual(ProductSyncPolicy.invitationTimeToLive, 15 * 60)
        XCTAssertGreaterThanOrEqual(ProductSyncPolicy.invitationTimeToLive, 10 * 60)
        XCTAssertEqual(
            ProductSyncPolicy.invitationTimeToLiveNanoseconds,
            UInt64(ProductSyncPolicy.invitationTimeToLive * 1_000_000_000)
        )
    }

    func testCreatePrivateSyncUsesProductInvitationTTL() async throws {
        let keychain = KeychainStore(
            service: "com.gotdone.relay.tests.\(UUID().uuidString)"
        )
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? keychain.delete(account: InstallIdentity.account)
            try? FileManager.default.removeItem(at: baseDirectory)
        }
        try FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )
        try keychain.write(
            Data(repeating: 0x11, count: 16),
            account: InstallIdentity.account
        )

        let model = SyncAppModel(
            keychain: keychain,
            baseDirectory: baseDirectory,
            mailboxTransport: NoopMailboxTransport()
        )
        model.createPrivateSync()
        let expiresAt = try XCTUnwrap(model.invitationExpiresAt)
        let remaining = expiresAt.timeIntervalSinceNow
        XCTAssertGreaterThan(remaining, 14 * 60)
        XCTAssertLessThanOrEqual(remaining, ProductSyncPolicy.invitationTimeToLive + 2)
        await model.stopRuntimeForTesting()
    }

    func testConsumerSurfacesBanProtocolJargon() async throws {
        let keychain = KeychainStore(
            service: "com.gotdone.relay.tests.\(UUID().uuidString)"
        )
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? keychain.delete(account: InstallIdentity.account)
            try? FileManager.default.removeItem(at: baseDirectory)
        }
        try FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )
        try keychain.write(
            Data(repeating: 0x22, count: 16),
            account: InstallIdentity.account
        )

        let model = SyncAppModel(
            keychain: keychain,
            baseDirectory: baseDirectory,
            mailboxTransport: NoopMailboxTransport()
        )
        model.createPrivateSync()

        let surfaces = [
            model.statusTitle,
            model.statusDetail,
            model.syncNotice?.title,
            model.syncNotice?.detail,
            model.userPairingPresentation.title,
            model.userPairingPresentation.detail,
            model.supportStatusSummary.deliveryDetail,
            model.supportStatusSummary.linkStatusLine,
            ProductSyncPolicy.deliverySummary,
            ProductSyncPolicy.twoDeviceBoundary,
        ].compactMap { $0 }

        let banned = ConsumerCopyBanlist.bannedTokens(in: surfaces)
        XCTAssertTrue(
            banned.isEmpty,
            "Banned consumer tokens found: \(banned) in \(surfaces)"
        )
        await model.stopRuntimeForTesting()
    }

    func testUserPairingStepsCollapseFinalizationEnums() {
        let waiting = UserPairingPresentationBuilder.presentation(
            phase: .finalizing,
            isHostApprovalPending: false,
            hasPairingReplicaConflict: false,
            finalizationState: .waitingForProvision,
            role: .joiner,
            errorMessage: nil
        )
        XCTAssertEqual(waiting.step, .waitingForOtherPhone)
        XCTAssertFalse(waiting.title.lowercased().contains("waitingfor"))
        XCTAssertTrue(waiting.voiceOverAnnouncement.contains("other iPhone"))

        let conflict = UserPairingPresentationBuilder.presentation(
            phase: .finalizing,
            isHostApprovalPending: false,
            hasPairingReplicaConflict: true,
            finalizationState: .provisionStagedAwaitingMergeApproval,
            role: .joiner,
            errorMessage: nil
        )
        XCTAssertEqual(conflict.step, .waitingForYou)
        XCTAssertEqual(conflict.title, "Combine task lists?")
        XCTAssertFalse(conflict.title.lowercased().contains("recover"))
    }

    func testKeepBothPreviewCountsMatchOutcomes() throws {
        let sharedID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let conflictID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let localOnlyID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let stagedOnlyID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let device = try ReplicaDeviceID(bytes: Data(repeating: 0x33, count: 16))

        var staged = try TaskReplica(deviceID: device)
        try staged.createTask(id: sharedID, title: "Shared", completed: true)
        try staged.createTask(id: conflictID, title: "Host")
        try staged.createTask(id: stagedOnlyID, title: "Host only")

        var local = try TaskReplica(deviceID: device)
        try local.createTask(id: sharedID, title: "Shared", completed: true)
        try local.createTask(id: conflictID, title: "Local", completed: true)
        try local.createTask(id: localOnlyID, title: "Local only")

        let preview = try TaskReplica.keepBothPreview(staged: staged, local: local)
        XCTAssertEqual(preview.reusedCount, 1)
        XCTAssertEqual(preview.localOnlyCount, 1)
        XCTAssertEqual(preview.conflictCount, 1)
        XCTAssertEqual(preview.sharedOnlyCount, 1)
        XCTAssertFalse(preview.isAdditiveOnly)
        XCTAssertTrue(preview.confirmationSummary.contains("shared"))
        XCTAssertTrue(preview.confirmationSummary.contains("twice"))
    }

    func testAdditiveOnlyPreviewIsAutoContinueEligible() throws {
        let sharedID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let localOnlyID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
        let device = try ReplicaDeviceID(bytes: Data(repeating: 0x44, count: 16))

        var staged = try TaskReplica(deviceID: device)
        try staged.createTask(id: sharedID, title: "Shared", completed: false)

        var local = try TaskReplica(deviceID: device)
        try local.createTask(id: sharedID, title: "Shared", completed: false)
        try local.createTask(id: localOnlyID, title: "Only here")

        let preview = try TaskReplica.keepBothPreview(staged: staged, local: local)
        XCTAssertEqual(preview.conflictCount, 0)
        XCTAssertTrue(preview.isAdditiveOnly)
        XCTAssertEqual(preview.localOnlyCount, 1)
        XCTAssertEqual(preview.reusedCount, 1)
    }

    func testSupportStatusSaysLocalEditDoesNotNeedPeerOnline() async throws {
        let keychain = KeychainStore(
            service: "com.gotdone.relay.tests.\(UUID().uuidString)"
        )
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? keychain.delete(account: InstallIdentity.account)
            try? FileManager.default.removeItem(at: baseDirectory)
        }
        try FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )
        try keychain.write(
            Data(repeating: 0x55, count: 16),
            account: InstallIdentity.account
        )
        let model = SyncAppModel(
            keychain: keychain,
            baseDirectory: baseDirectory,
            mailboxTransport: NoopMailboxTransport()
        )
        XCTAssertFalse(model.supportStatusSummary.otherPhoneMustBeOpenForLocalEdit)
        XCTAssertTrue(
            model.supportStatusSummary.localEditLine
                .contains("not required online")
        )
        await model.stopRuntimeForTesting()
    }
}

/// Transport that never succeeds; used only for UI-surface unit tests.
private actor NoopMailboxTransport: MailboxTransport {
    func put(
        route: Data,
        authorization: Data,
        messages: [StoredMailboxEnvelope]
    ) async throws -> [MailboxStoredReceipt] {
        throw URLError(.notConnectedToInternet)
    }

    func fetch(
        route: Data,
        authorization: Data,
        after cursor: UInt64,
        limit: Int
    ) async throws -> MailboxFetchPage {
        throw URLError(.notConnectedToInternet)
    }

    func acknowledge(
        route: Data,
        authorization: Data,
        through cursor: UInt64
    ) async throws {
        throw URLError(.notConnectedToInternet)
    }

    func forget(route: Data, authorization: Data) async throws {
        throw URLError(.notConnectedToInternet)
    }
}
