import Foundation

/// Product-level sync contract for this proof of concept.
///
/// **Receive (open-to-sync):** linked iPhones see edits while Got Done is open,
/// or the next time they open. There is no push path yet.
///
/// **Send (background-capable):** this iPhone uploads pending edits to the
/// private mailbox while Got Done is open and while iOS grants background time.
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

    /// How long a pending upload may remain quiet before the dashboard notices.
    static let savingNoticeDelay: TimeInterval = 2

    /// How long the link-complete celebration remains visible.
    static let linkCompleteCelebrationDuration: TimeInterval = 2.4

    /// How long a subtle “Updated just now” confidence cue remains visible.
    static let lastSyncConfidenceDuration: TimeInterval = 4

    /// How long an inbound arrival cue remains visible.
    static let inboundArrivalCueDuration: TimeInterval = 2.8

    /// Cap aligned with `ReplicaLimits.maxOrigins` (Group Sync v2).
    static let maxDevices = ReplicaLimits.maxOrigins

    /// BGTaskScheduler identifier for deferred mailbox upload.
    static let backgroundMailboxTaskIdentifier =
        "com.gotdone.relay.poc.mailbox-flush"

    static let deliverySummary =
        "Edits save on this iPhone first and upload even when Got Done is in the background when iOS allows it. Other linked iPhones see them while Got Done is open, or the next time they open Got Done."

    static let senderBackgroundSummary =
        "This iPhone uploads pending edits in the background when iOS allows it. If upload is interrupted, it retries the next time you open Got Done."

    static let pairingKeepOpenSummary =
        "Keep both apps open while you pair them the first time. Pairing windows last 15 minutes."

    /// Legacy name kept for tests; multi-device boundary is the product string.
    static let twoDeviceBoundary = multiDeviceBoundary

    static let multiDeviceBoundary =
        "Private Sync can link up to \(maxDevices) iPhones on one shared link. There is no account recovery if every phone is lost."

    /// C1 product honesty: co-members share full task access for this sync.
    static let sharedAccessDisclosure =
        "Every linked iPhone can read and edit this sync’s tasks. There is no privacy between co-members."

    static let groupFullMessage =
        "This sync already has \(maxDevices) iPhones. Leave a phone or start a new sync."

    static let manageSyncTitle = "Manage Sync"

    static let inviteAnotherIPhone = "Invite another iPhone"

    /// C4: live invite is full admission capability while valid.
    static let inviteDetail =
        "Anyone with this code can join this sync and see its tasks. Show it only on phones you trust. Valid for 15 minutes; one successful join uses it up."

    static let leaveSyncTitle = "Leave sync and keep tasks"

    /// C3: no remote wipe; remaining members rekey so a left phone cannot decrypt new traffic.
    static let leaveSyncDetail =
        "Tasks stay on this iPhone. Other phones drop this phone and rotate keys so it cannot read new edits. Past data already on a phone is not remotely wiped."

    /// M3: safety code is accidental cross-pair protection, not invite-theft defense.
    static let safetyCodeDetail =
        "Compare this code with the other iPhone. Matching digits confirm the two phones are in the same setup. This does not stop someone who already has your live invite code."

    static func linkedStatusSummary(memberCount: Int) -> String {
        let phones = memberCount == 1 ? "1 iPhone" : "\(memberCount) iPhones"
        return "Linked with \(phones). \(sharedAccessDisclosure) Edits save here first; others see them when they open Got Done."
    }

    // MARK: - Error taxonomy (consumer-facing)

    static let invitationExpiredMessage =
        "Invitation expired. Create a new one."

    static let otherPhoneCancelledMessage =
        "Other phone cancelled pairing."

    static let privateSyncUnreachableMessage =
        "Can’t reach private sync. Try again in a moment."
}

/// Tokens that must not appear in consumer-facing status surfaces.
enum ConsumerCopyBanlist {
    static let bannedTokens = [
        "ciphertext",
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
