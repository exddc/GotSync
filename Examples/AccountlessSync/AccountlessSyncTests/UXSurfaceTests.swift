import Foundation
import XCTest
@testable import AccountlessSync
@testable import GotSync

@MainActor
final class UXSurfaceTests: XCTestCase {
    func testMultiDeviceBoundaryReplacesTwoDeviceOnlyCopy() {
        XCTAssertEqual(ProductSyncPolicy.maxDevices, 8)
        XCTAssertEqual(
            ProductSyncPolicy.multiDeviceBoundary,
            ProductSyncPolicy.multiDeviceBoundary
        )
        XCTAssertTrue(
            ProductSyncPolicy.multiDeviceBoundary.contains("8")
        )
        XCTAssertTrue(
            ProductSyncPolicy.groupFullMessage.contains("8")
        )
        XCTAssertEqual(ProductSyncPolicy.manageSyncTitle, "Manage sync")
        XCTAssertFalse(
            ConsumerCopyBanlist.containsBannedToken(
                ProductSyncPolicy.multiDeviceBoundary
            )
        )
        XCTAssertFalse(
            ProductSyncPolicy.deliverySummary
                .localizedCaseInsensitiveContains("Got Done")
        )
    }

    func testHonestSecurityCopyOnManageInviteAndSafety() {
        XCTAssertTrue(
            ProductSyncPolicy.sharedAccessDisclosure
                .localizedCaseInsensitiveContains("every linked")
        )
        XCTAssertTrue(
            ProductSyncPolicy.inviteDetail
                .localizedCaseInsensitiveContains("anyone with this code")
        )
        XCTAssertTrue(
            ProductSyncPolicy.leaveSyncDetail
                .localizedCaseInsensitiveContains("not remotely wiped")
        )
        XCTAssertTrue(
            ProductSyncPolicy.safetyCodeDetail
                .localizedCaseInsensitiveContains("does not stop")
        )
        let surfaces = [
            ProductSyncPolicy.sharedAccessDisclosure,
            ProductSyncPolicy.inviteDetail,
            ProductSyncPolicy.leaveSyncDetail,
            ProductSyncPolicy.safetyCodeDetail,
            ProductSyncPolicy.linkedStatusSummary(memberCount: 3),
        ]
        XCTAssertTrue(
            ConsumerCopyBanlist.bannedTokens(in: surfaces).isEmpty
        )
        XCTAssertTrue(
            ConsumerCopyBanlist.containsBannedToken("This is hacker-proof")
        )
    }

    func testPairingWindowIsSingleProductNumber() {
        XCTAssertEqual(ProductSyncPolicy.pairingWindowTimeToLive, 15 * 60)
        XCTAssertEqual(
            ProductSyncPolicy.invitationTimeToLive,
            ProductSyncPolicy.pairingWindowTimeToLive
        )
        XCTAssertEqual(
            ProductSyncPolicy.waitingRoomTimeToLive,
            ProductSyncPolicy.pairingWindowTimeToLive
        )
        XCTAssertEqual(
            ProductSyncPolicy.waitingRoomTimeToLiveSeconds,
            900
        )
        XCTAssertGreaterThanOrEqual(
            ProductSyncPolicy.pairingWindowTimeToLive,
            10 * 60
        )
        XCTAssertEqual(
            ProductSyncPolicy.invitationTimeToLiveNanoseconds,
            UInt64(ProductSyncPolicy.pairingWindowTimeToLive * 1_000_000_000)
        )
    }

    func testErrorTaxonomyKeepsExpiredCancelledAndUnreachableDistinct() {
        XCTAssertNotEqual(SyncError.invitationExpired.errorDescription, SyncError.pairingDeclined.errorDescription)
        XCTAssertNotEqual(SyncError.pairingDeclined.errorDescription, SyncError.privateSyncUnreachable.errorDescription)
        XCTAssertEqual(
            SyncError.mapRelayCode("waitingExpired") as SyncError,
            .invitationExpired
        )
        XCTAssertEqual(
            SyncError.mapRelayCode("peerLeft") as SyncError,
            .pairingDeclined
        )
        XCTAssertEqual(
            SyncError.mapRelayCode("relayBusy") as SyncError,
            .privateSyncUnreachable
        )
        let surfaces = [
            ProductSyncPolicy.invitationExpiredMessage,
            ProductSyncPolicy.otherPhoneCancelledMessage,
            ProductSyncPolicy.privateSyncUnreachableMessage,
            SyncError.relay("waitingExpired").errorDescription!,
            SyncError.relay("relayBusy").errorDescription!,
        ]
        XCTAssertFalse(
            ConsumerCopyBanlist.containsBannedToken(
                surfaces.joined(separator: " ")
            )
        )
        XCTAssertTrue(
            SyncError.relay("waitingExpired").errorDescription!
                .localizedCaseInsensitiveContains("invitation expired")
        )
        XCTAssertFalse(
            SyncError.relay("waitingExpired").errorDescription!
                .lowercased()
                .contains("network")
        )
    }

    func testPairingTransportRetryTaxonomy() {
        XCTAssertTrue(
            SyncError.isRetriablePairingTransportFailure(
                SyncError.privateSyncUnreachable
            )
        )
        XCTAssertTrue(
            SyncError.isRetriablePairingTransportFailure(
                RelaySocketError.connectionTimedOut
            )
        )
        XCTAssertTrue(
            SyncError.isRetriablePairingTransportFailure(
                URLError(.notConnectedToInternet)
            )
        )
        XCTAssertTrue(
            SyncError.isRetriablePairingTransportFailure(
                SyncError.relay("relayBusy")
            )
        )
        XCTAssertFalse(
            SyncError.isRetriablePairingTransportFailure(
                SyncError.invitationExpired
            )
        )
        XCTAssertFalse(
            SyncError.isRetriablePairingTransportFailure(
                SyncError.pairingDeclined
            )
        )
        XCTAssertFalse(
            SyncError.isRetriablePairingTransportFailure(
                SyncError.groupAtCapacity
            )
        )
    }

    func testJoinerWaitingCopyNeverSaysJoinLink() {
        let joiner = UserPairingPresentationBuilder.presentation(
            phase: .waitingForPeer,
            isHostApprovalPending: false,
            role: .joiner,
            errorMessage: nil
        )
        XCTAssertFalse(
            joiner.detail.localizedCaseInsensitiveContains("Join link")
        )
        XCTAssertTrue(
            joiner.detail.localizedCaseInsensitiveContains("main phone")
        )

        let host = UserPairingPresentationBuilder.presentation(
            phase: .waitingForPeer,
            isHostApprovalPending: false,
            role: .host,
            errorMessage: nil
        )
        XCTAssertTrue(
            host.detail.localizedCaseInsensitiveContains("Join link")
        )
        XCTAssertTrue(host.detail.contains("15 minutes"))
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
            baseDirectory: baseDirectory
        )
        model.createPrivateSync()
        let expiresAt = try XCTUnwrap(model.invitationExpiresAt)
        let remaining = expiresAt.timeIntervalSinceNow
        XCTAssertGreaterThan(remaining, 14 * 60)
        XCTAssertLessThanOrEqual(remaining, ProductSyncPolicy.invitationTimeToLive + 2)
        await model.engine.stop()
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
            baseDirectory: baseDirectory
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
            ProductSyncPolicy.multiDeviceBoundary,
        ].compactMap { $0 }

        let banned = ConsumerCopyBanlist.bannedTokens(in: surfaces)
        XCTAssertTrue(
            banned.isEmpty,
            "Banned consumer tokens found: \(banned) in \(surfaces)"
        )
        await model.engine.stop()
    }

    func testHostApprovalWaitsForYouAndJoinerWaitsForHost() {
        let host = UserPairingPresentationBuilder.presentation(
            phase: .verifying,
            isHostApprovalPending: true,
            role: .host,
            errorMessage: nil
        )
        XCTAssertEqual(host.step, .waitingForYou)
        XCTAssertTrue(host.voiceOverAnnouncement.contains("Waiting for you"))

        let joiner = UserPairingPresentationBuilder.presentation(
            phase: .verifying,
            isHostApprovalPending: false,
            role: .joiner,
            errorMessage: nil
        )
        XCTAssertEqual(joiner.step, .waitingForOtherPhone)
        XCTAssertTrue(joiner.voiceOverAnnouncement.contains("other iPhone"))
    }

    func testLinkEndedCopyExplainsRemovalWithoutJargon() {
        XCTAssertEqual(ProductSyncPolicy.linkEndedTitle(for: .removedFromGroup), "Removed from sync")
        XCTAssertEqual(ProductSyncPolicy.linkEndedTitle(for: .relinkRequired), "Link again to sync")
        let surfaces = [SyncError.removedFromGroup, .relinkRequired].flatMap {
            [ProductSyncPolicy.linkEndedTitle(for: $0), ProductSyncPolicy.linkEndedDetail(for: $0)]
        }
        XCTAssertTrue(ProductSyncPolicy.linkEndedDetail(for: .removedFromGroup).contains("tasks stay on this iPhone"))
        XCTAssertTrue(ConsumerCopyBanlist.bannedTokens(in: surfaces).isEmpty)
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
            baseDirectory: baseDirectory
        )
        XCTAssertFalse(model.supportStatusSummary.otherPhoneMustBeOpenForLocalEdit)
        XCTAssertTrue(
            model.supportStatusSummary.localEditLine
                .contains("not required online")
        )
        await model.engine.stop()
    }
}
