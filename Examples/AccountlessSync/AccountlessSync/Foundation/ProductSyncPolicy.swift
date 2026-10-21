import GotSync
import Foundation

/// Product-level sync contract for this demo.
///
/// **Receive (open-to-sync):** linked iPhones see edits while Accountless Sync is open,
/// or the next time they open. There is no push path yet.
///
/// **Send (background-capable):** this iPhone uploads pending edits to the
/// relay as MLS messages while Accountless Sync is open and while iOS grants background time.
/// Incomplete uploads are durable and retry on the next launch.
enum ProductSyncPolicy {
    /// Single product number for invitation QR/phrase, host expiry, UI countdown,
    /// and relay waiting-room TTL. Prefer ≥10–15 minutes for physical QR + phrase.
    static let pairingWindowTimeToLive: TimeInterval = 15 * 60

    /// Alias used by invitation generation and host expiry.
    static var invitationTimeToLive: TimeInterval {
        pairingWindowTimeToLive
    }

    /// Alias for relay waiting-room documentation and defaults.
    static var waitingRoomTimeToLive: TimeInterval {
        pairingWindowTimeToLive
    }

    static var invitationTimeToLiveNanoseconds: UInt64 {
        UInt64(pairingWindowTimeToLive * 1_000_000_000)
    }

    /// Seconds form for relay `--waiting-room-ttl` (must match the app window).
    static var waitingRoomTimeToLiveSeconds: Double {
        pairingWindowTimeToLive
    }

    /// Cap aligned with `ReplicaLimits.maxOrigins` (Group Sync v2).
    static let maxDevices = ReplicaLimits.maxOrigins

    /// BGTaskScheduler identifier for deferred mailbox upload.
    static let backgroundMailboxTaskIdentifier =
        "org.gotsync.example.accountless.mailbox-flush"

    static let deliverySummary =
        "Edits save on this phone first and upload in the background when iOS allows it. Other linked phones see them while Accountless Sync is open, or the next time they open it."

    static let senderBackgroundSummary =
        "This phone uploads pending edits in the background when iOS allows it. If upload is interrupted, it retries the next time you open Accountless Sync."

    static let pairingKeepOpenSummary =
        "Keep both apps open while you pair the first time. Pairing windows last 15 minutes."

    static let multiDeviceBoundary =
        "You can link up to \(maxDevices) iPhones on one shared link. \(dataRecoveryDisclosure)"

    static let dataRecoveryDisclosure =
        "If every linked phone is lost, your synced tasks are permanently lost. There is no recovery option."

    /// C1 product honesty: co-members share full task access for this sync.
    static let sharedAccessDisclosure =
        "Every linked phone can read and edit this sync’s tasks."

    static let groupFullMessage =
        "This sync already has \(maxDevices) phones. Leave a phone or start a new link."

    static let manageSyncTitle = "Manage sync"

    static let inviteAnotherIPhone = "Invite another phone"

    /// C4: live invite is full admission capability while valid.
    static let inviteDetail =
        "Anyone with this code can join and see its tasks. Show it only on phones you trust. Valid for 15 minutes; one successful join uses it up."

    static let leaveSyncTitle = "Leave sync and keep tasks"

    /// C3: the remaining phones remove this one, so it cannot read later changes. No remote wipe.
    static let leaveSyncDetail =
        "Tasks stay on this phone. The other phones remove it from the sync, and it cannot read changes made after that. Past data is not remotely wiped."

    static let removePhoneTitle = "Remove phone"

    static let removingPhoneLabel = "Removing…"

    /// H4: removal stops future access but cannot wipe the removed phone.
    static let removePhoneDetail =
        "Remove a lost phone or one you no longer use. It cannot read changes made after removal, but it keeps the tasks it already has. Any linked phone can remove any other."

    /// M3: safety code is accidental cross-pair protection, not invite-theft defense.
    static let safetyCodeDetail =
        "Compare this code with the other phone. Matching digits confirm both phones are in the same setup. This does not stop someone who already has your live invite code."

    static func linkEndedTitle(for reason: SyncError) -> String {
        switch reason {
        case .removedFromGroup:
            "Removed from sync"
        case .relinkRequired:
            "Link again to sync"
        default:
            "Link ended"
        }
    }

    static func linkEndedDetail(for reason: SyncError) -> String {
        switch reason {
        case .removedFromGroup:
            "Another linked phone removed this iPhone. It no longer receives changes, and your tasks stay on this iPhone."
        default:
            reason.errorDescription ?? "Your tasks stay on this iPhone."
        }
    }

    static func linkedStatusSummary(memberCount: Int) -> String {
        let phones = memberCount == 1 ? "1 phone" : "\(memberCount) phones"
        return "Linked with \(phones)."
    }

    // MARK: - Error taxonomy (consumer-facing)

    static let invitationExpiredMessage =
        "Invitation expired. Create a new one."

    static let otherPhoneCancelledMessage =
        "Other phone cancelled pairing."

    static let privateSyncUnreachableMessage =
        "Can’t reach the link. Try again in a moment."
}

/// Tokens that must not appear in consumer-facing status surfaces.
enum ConsumerCopyBanlist {
    static let bannedTokens = [
        "ciphertext",
        "mailbox",
        "live relay",
        "version vector",
        "version vectors",
        "durably applies",
        "durably apply",
        "keep got done open",
        "keep this app open",
        "rtt",
        "check network",
        "check the network",
        // M3 / marketing overclaims
        "hacker-proof",
        "hacker proof",
        "military-grade",
        "unbreakable",
        "completely private from linked",
        "members cannot read",
        "got done",
    ]

    static func containsBannedToken(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return bannedTokens.contains { lowered.contains($0) }
    }

    static func bannedTokens(in texts: [String]) -> [String] {
        texts.flatMap { text in
            bannedTokens.filter { text.lowercased().contains($0) }
        }
    }
}
