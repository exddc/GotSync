import Foundation

public struct SyncState: Sendable {
    public let phase: SyncPhase
    public let tasks: [ReplicatedTask]
    public let invitationPhrase: String?
    public let invitationURL: URL?
    public let invitationExpiresAt: Date?
    public let safetyCode: String?
    public let lastRoundTripMilliseconds: Double?
    public let lastSyncedAt: Date?
    public let errorMessage: String?
    public let isPaired: Bool
    public let isHostApprovalPending: Bool
    public let localEditErrorMessage: String?
    public let mailboxState: MailboxSyncState
    public let pendingMailboxOperationCount: Int
    public let lastMailboxStoredAt: Date?
    public let lastMailboxReceivedAt: Date?
    public let mailboxError: SyncError?
    public let mailboxErrorMessage: String?
    public let mailboxRequiresRepair: Bool
    public let mailboxCapacityReached: Bool
    public let isPairingFinalizationLocked: Bool
    public let hasPairingReplicaConflict: Bool
    public let keepBothPreview: KeepBothPreview?
    public let showsLinkCompleteCelebration: Bool
    public let activePairingRole: DeviceRole?
    public let showsSavingNotice: Bool
    public let pairingFinalizationState: PairingFinalizationState?
    public let linkedMemberCount: Int
    public let linkedDevices: [LinkedDevice]
}

/// A device in the linked group, identified by its MLS signature key.
public struct LinkedDevice: Equatable, Hashable, Identifiable, Sendable {
    public var id: Data { fingerprint }
    public let deviceID: Data
    /// SHA-256 of the device's MLS signature key.
    public let fingerprint: Data
    public let isCurrentDevice: Bool
    /// `removeDevice` was requested and the removal commit is not yet accepted.
    public let isRemovalPending: Bool

    /// The first four fingerprint bytes as hex, for telling devices apart.
    public var shortFingerprint: String {
        fingerprint.prefix(4).map { String(format: "%02X", $0) }.joined()
    }
}
