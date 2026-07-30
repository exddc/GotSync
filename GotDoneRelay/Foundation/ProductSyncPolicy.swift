import Foundation

/// Product-level sync contract for this proof of concept.
///
/// **Receive (open-to-sync):** the other iPhone sees edits while its app is open,
/// or the next time it opens Got Done. There is no push path yet.
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

    static let maxDevices = 2

    /// BGTaskScheduler identifier for deferred mailbox upload.
    static let backgroundMailboxTaskIdentifier =
        "com.gotdone.relay.poc.mailbox-flush"

    static let deliverySummary =
        "Edits save on this iPhone first and upload even when Got Done is in the background when iOS allows it. The other iPhone sees them while both are open, or the next time it opens Got Done."

    static let senderBackgroundSummary =
        "This iPhone uploads pending edits in the background when iOS allows it. If upload is interrupted, it retries the next time you open Got Done."

    static let pairingKeepOpenSummary =
        "Keep both apps open while you pair them the first time. Pairing windows last 15 minutes."

    static let twoDeviceBoundary =
        "Private Sync links exactly two iPhones. There is no account recovery for a third device yet."

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
