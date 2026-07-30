import Foundation

/// Product-level sync contract for this proof of concept.
///
/// Got Done Relay is an **open-to-sync** sample: live delivery and mailbox
/// polling run while the app is foregrounded. There is no push path yet, so
/// the other iPhone sees edits after it opens Got Done (or while both are open).
enum ProductSyncPolicy {
    /// Invitation wall-clock lifetime for QR + phrase entry.
    static let invitationTimeToLive: TimeInterval = 15 * 60

    static var invitationTimeToLiveNanoseconds: UInt64 {
        UInt64(invitationTimeToLive * 1_000_000_000)
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

    static let deliverySummary =
        "Edits save on this iPhone first. The other iPhone sees them while both are open, or the next time it opens Got Done."

    static let pairingKeepOpenSummary =
        "Keep both apps open while you pair them the first time."

    static let twoDeviceBoundary =
        "Private Sync links exactly two iPhones. There is no account recovery for a third device yet."
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
