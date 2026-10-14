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
}
