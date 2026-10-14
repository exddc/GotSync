import CryptoKit
import Foundation

public enum SyncPhase: Equatable, Sendable {
    case unpaired
    case waitingForPeer
    case verifying
    case provisioning
    case finalizing
    case connecting
    case reconciling
    case synced
    case offline
    case failed
}

public enum MailboxSyncState: Equatable, Sendable {
    case idle
    case syncing
    case available
    case unavailable
}

public enum SyncError: Error, LocalizedError, Equatable, Sendable {
    case invalidPairMessage
    case invalidSyncMessage
    case invalidCredentials
    /// Opaque/unmapped relay code — still user-outcome wording, not “check network.”
    case relay(String)
    /// Distinct taxonomy: other phone cancelled / declined.
    case pairingDeclined
    /// Distinct taxonomy: invitation or waiting-room window ended.
    case invitationExpired
    /// Distinct taxonomy: cannot reach private sync infrastructure.
    case privateSyncUnreachable
    case archiveTooLarge
    case localStorageUnavailable
    case safetyCodeMismatch
    case pairingReplicaConflict
    case pairingMergeTooLarge
    case legacyPairingNeedsRelink
    case pairingRecoveryHistoryFull
    case pairingRecoveryJournalDamaged
    case groupAtCapacity
    case unsupportedProtocolVersion

    public var errorDescription: String? {
        switch self {
        case .invalidPairMessage:
            "Pairing could not continue. Create a new invitation and try again."
        case .invalidSyncMessage:
            "A sync update could not be read. Your tasks are still safe on this iPhone."
        case .invalidCredentials:
            "Saved link details are no longer valid. Keep your tasks and create a new link."
        case .relay(let code):
            Self.mapRelayCode(code).errorDescription
                ?? "Cannot reach the sync service."
        case .pairingDeclined:
            "The peer cancelled pairing."
        case .invitationExpired:
            "The invitation expired."
        case .privateSyncUnreachable:
            "Cannot reach the sync service."
        case .archiveTooLarge:
            "This task list is too large to share in the sync protocol (280 KiB limit). Remove tasks or reset the link, then try again."
        case .localStorageUnavailable:
            "Local storage is unavailable. Restart the app after fixing storage."
        case .safetyCodeMismatch:
            "The safety codes did not match. Nothing was linked. Create a new invitation and try again."
        case .pairingReplicaConflict:
            "Both phones already have tasks. Review how to combine the lists before the link finishes."
        case .pairingMergeTooLarge:
            "These task lists cannot be safely combined on this device. Nothing was linked, and your local tasks are unchanged."
        case .legacyPairingNeedsRelink:
            "An older pairing stopped during its final step. Your tasks are safe. Keep them and create a link again."
        case .pairingRecoveryHistoryFull:
            "Too many unfinished pairing steps are still saved. Keep your tasks and reset the link before creating another one."
        case .pairingRecoveryJournalDamaged:
            "Saved pairing recovery data is damaged. Your tasks are safe. Keep them and reset the link before creating another one."
        case .groupAtCapacity:
            "The group is at its device limit."
        case .unsupportedProtocolVersion:
            "The sync service uses an unsupported protocol version."
        }
    }

    /// Map relay control codes into the product error taxonomy.
    public static func mapRelayCode(_ code: String) -> SyncError {
        switch code {
        case "waitingExpired":
            .invitationExpired
        case "peerLeft":
            .pairingDeclined
        case "routeFull", "relayBusy":
            .privateSyncUnreachable
        default:
            .privateSyncUnreachable
        }
    }

    public static func fromTransport(_ error: Error) -> Error {
        if let sync = error as? SyncError {
            return sync
        }
        if let relay = error as? RelaySocketError {
            switch relay {
            case .peerLeft:
                return SyncError.pairingDeclined
            case .connectionTimedOut, .notConnected, .invalidRelayURL:
                return SyncError.privateSyncUnreachable
            default:
                return SyncError.privateSyncUnreachable
            }
        }
        if error is URLError {
            return SyncError.privateSyncUnreachable
        }
        if let mailbox = error as? MailboxTransportError {
            switch mailbox {
            case .rejected(_, let code) where code == "waitingExpired":
                return SyncError.invitationExpired
            case .unsupportedVersion:
                return SyncError.unsupportedProtocolVersion
            case .insecureTransport, .invalidURL:
                return SyncError.privateSyncUnreachable
            default:
                break
            }
        }
        return error
    }

    /// Transient failures while holding an open invite window. Retry until the
    /// window ends instead of bouncing the user off the QR screen.
    static func isRetriablePairingTransportFailure(_ error: Error) -> Bool {
        let mapped = fromTransport(error)
        guard let sync = mapped as? SyncError else {
            // Unknown transport noise during wait-for-peer: keep the invite.
            return true
        }
        switch sync {
        case .privateSyncUnreachable, .relay:
            return true
        case .invitationExpired, .pairingDeclined, .groupAtCapacity,
             .invalidPairMessage, .invalidCredentials, .archiveTooLarge,
             .localStorageUnavailable, .safetyCodeMismatch,
             .pairingReplicaConflict, .pairingMergeTooLarge,
             .legacyPairingNeedsRelink, .pairingRecoveryHistoryFull,
             .pairingRecoveryJournalDamaged, .invalidSyncMessage, .unsupportedProtocolVersion:
            return false
        }
    }
}

@MainActor
public final class SyncEngine {
    private var stateSubscribers: [UUID: AsyncStream<SyncState>.Continuation] = [:]

    public var pairingFinalizationState: PairingFinalizationState? {
        pendingPairForRecovery?.finalizationState
    }

    public var state: SyncState {
        SyncState(
            phase: phase,
            tasks: tasks,
            invitationPhrase: invitationPhrase,
            invitationURL: invitationURL,
            invitationExpiresAt: invitationExpiresAt,
            safetyCode: safetyCode,
            lastRoundTripMilliseconds: lastRoundTripMilliseconds,
            lastSyncedAt: lastSyncedAt,
            errorMessage: errorMessage,
            isPaired: isPaired,
            isHostApprovalPending: isHostApprovalPending,
            localEditErrorMessage: localEditErrorMessage,
            mailboxState: mailboxState,
            pendingMailboxOperationCount: pendingMailboxOperationCount,
            lastMailboxStoredAt: lastMailboxStoredAt,
            lastMailboxReceivedAt: lastMailboxReceivedAt,
            mailboxError: mailboxError,
            mailboxErrorMessage: mailboxErrorMessage,
            mailboxRequiresRepair: mailboxRequiresRepair,
            mailboxCapacityReached: mailboxCapacityReached,
            isPairingFinalizationLocked: isPairingFinalizationLocked,
            hasPairingReplicaConflict: hasPairingReplicaConflict,
            keepBothPreview: keepBothPreview,
            showsLinkCompleteCelebration: showsLinkCompleteCelebration,
            activePairingRole: activePairingRole,
            showsSavingNotice: showsSavingNotice,
            pairingFinalizationState: pairingFinalizationState,
            linkedMemberCount: linkedMemberCount
        )
    }

    public func states() -> AsyncStream<SyncState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SyncState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stateSubscribers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.stateSubscribers.removeValue(forKey: id) }
        }
        return stream
    }

    private func publishState() {
        let snapshot = state
        for subscriber in stateSubscribers.values { subscriber.yield(snapshot) }
    }

    static let eraseMarkerFilename = "erase-v1.pending"
    static let pairingStagingFilename = "replica-v1.pairing.json"
    static let pairingMergedFilename = "replica-v1.pairing-merged.json"
    static let pairingConflictBackupFilename =
        "replica-v1.pairing-local.json"
    private static let pairingArtifactFilenames = [
        pairingStagingFilename,
        pairingMergedFilename,
        pairingConflictBackupFilename,
    ]

    public private(set) var phase: SyncPhase = .unpaired { didSet { publishState() } }
    public private(set) var tasks: [ReplicatedTask] = [] { didSet { publishState() } }
    public private(set) var invitationPhrase: String? = nil { didSet { publishState() } }
    public private(set) var invitationURL: URL? = nil { didSet { publishState() } }
    public private(set) var invitationExpiresAt: Date? = nil { didSet { publishState() } }
    public private(set) var safetyCode: String? = nil { didSet { publishState() } }
    public private(set) var lastRoundTripMilliseconds: Double? = nil { didSet { publishState() } }
    public private(set) var lastSyncedAt: Date? = nil { didSet { publishState() } }
    public private(set) var errorMessage: String? = nil { didSet { publishState() } }
    public private(set) var isPaired = false { didSet { publishState() } }
    public private(set) var isHostApprovalPending = false { didSet { publishState() } }
    public private(set) var localEditErrorMessage: String? = nil { didSet { publishState() } }
    public private(set) var mailboxState: MailboxSyncState = .idle { didSet { publishState() } }
    public private(set) var pendingMailboxOperationCount = 0 { didSet { publishState() } }
    public private(set) var lastMailboxStoredAt: Date? = nil { didSet { publishState() } }
    public private(set) var lastMailboxReceivedAt: Date? = nil { didSet { publishState() } }
    public private(set) var mailboxError: SyncError? = nil { didSet { publishState() } }
    public private(set) var mailboxErrorMessage: String? = nil { didSet { publishState() } }
    public private(set) var mailboxRequiresRepair = false { didSet { publishState() } }
    public private(set) var mailboxCapacityReached = false { didSet { publishState() } }
    public private(set) var isPairingFinalizationLocked = false { didSet { publishState() } }
    public private(set) var hasPairingReplicaConflict = false { didSet { publishState() } }
    public private(set) var keepBothPreview: KeepBothPreview? = nil { didSet { publishState() } }
    public private(set) var showsLinkCompleteCelebration = false { didSet { publishState() } }
    /// Host vs joiner for the in-flight pairing attempt (presentation only).
    public private(set) var activePairingRole: DeviceRole? = nil { didSet { publishState() } }

    public let relayURL: URL
    public let mailboxURL: URL

    private let credentialStore: CredentialStore
    private let mailboxTransport: any MailboxTransport
    private let backgroundMailboxScheduler: any BackgroundMailboxScheduling
    private let endpointPolicy: EndpointSecurityPolicy
    private let invitationURLScheme: String
    private let deviceID: ReplicaDeviceID
    private let persistenceURL: URL
    private let pairingArtifactsDirectory: URL
    private var pairingArtifactID: Data?
    private let hasDurableIdentity: Bool
    private var hasDurableStorage: Bool
    private var replica: TaskReplica
    private var credentials: GroupCredentials?
    /// Group join material captured from provision (joiner only).
    private var pendingGroupJoinSnapshot: GroupProvisionFields?

    fileprivate struct GroupProvisionFields: Equatable, Sendable {
        let groupID: Data
        let epoch: UInt64
        let groupRoot: Data
        let membershipGeneration: UInt64
        let memberDeviceIDs: [Data]
    }
    private var pendingPairForRecovery: PendingPair?
    private var pairingAttemptID: UUID?
    private var pairingTask: Task<Void, Never>?
    private var pairingExpiryTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var outboundTask: Task<Void, Never>?
    private var mailboxPollTask: Task<Void, Never>?
    private var mailboxCycleTask: Task<Void, Never>?
    private var backgroundFlushTask: Task<Void, Never>?
    private var terminalPairingTask: Task<Void, Never>?
    private var outboundDrainID: UUID?
    private var mailboxCycleID: UUID?
    private var terminalPairingLoopID: UUID?
    private var pairingSocket: RelaySocket?
    private var activeSocket: RelaySocket?
    private var channelReady = false
    private var approvalContinuation: CheckedContinuation<Bool, Never>?
    private var pendingPings: [Data: ContinuousClock.Instant] = [:]
    private var deferredOperations: [TaskOperation] = []
    private var uploadedLocalSequence: UInt64 = 0
    /// Per-recipient high-water marks for group mailbox fan-out.
    private var uploadedThroughByRecipient: [Data: UInt64] = [:]
    private var mailboxCycleRequested = false
    private var mailboxFailureCount = 0
    private var nextMailboxAttemptAt = Date.distantPast
    private var appIsActive = true
    private var terminalPairingActions: [TerminalPairingAction] = []
    private var terminalPairingJournalUsable = true
    private let pairingRetryDelayNanoseconds: UInt64
    private var pendingMailboxSince: Date?
    private var savingNoticeRevealTask: Task<Void, Never>?
    private var linkCompleteCelebrationTask: Task<Void, Never>?
    public private(set) var showsSavingNotice = false { didSet { publishState() } }

    private var pairingStagingURL: URL {
        pairingArtifactURL(filename: Self.pairingStagingFilename)
    }

    private var pairingMergedURL: URL {
        pairingArtifactURL(filename: Self.pairingMergedFilename)
    }

    private var pairingConflictBackupURL: URL {
        pairingArtifactURL(
            filename: Self.pairingConflictBackupFilename
        )
    }

    private func pairingArtifactURL(filename: String) -> URL {
        guard let pairingArtifactID else {
            return pairingArtifactsDirectory
                .appendingPathComponent(filename)
        }
        return pairingArtifactsDirectory.appendingPathComponent(
            "\(filename).\(pairingArtifactID.base64URLString)"
        )
    }

    public init(
        configuration: SyncConfiguration,
        secretStore: any SecretStore,
        mailboxTransport: (any MailboxTransport)? = nil,
        backgroundMailboxScheduler: (any BackgroundMailboxScheduling)? = nil,
        pairingRetryDelayNanoseconds: UInt64 = 1_000_000_000
    ) {
        let keychain = secretStore
        let baseDirectory = configuration.storageDirectory
        let relayURL = configuration.endpoints.relayURL
        let mailboxURL = configuration.endpoints.mailboxURL
        endpointPolicy = configuration.endpointPolicy
        invitationURLScheme = configuration.invitationURLScheme
        self.relayURL = relayURL
        self.mailboxURL = mailboxURL
        self.mailboxTransport = mailboxTransport
            ?? HTTPMailboxTransport(baseURL: mailboxURL, policy: configuration.endpointPolicy)
        self.backgroundMailboxScheduler =
            backgroundMailboxScheduler ?? NoopBackgroundMailboxScheduler()
        self.pairingRetryDelayNanoseconds = pairingRetryDelayNanoseconds
        let resolvedCredentialStore = CredentialStore(keychain: keychain)
        credentialStore = resolvedCredentialStore

        var identityError: Error?
        let installData: Data
        do {
            installData = try InstallIdentity.loadOrCreate(store: keychain).deviceID
            hasDurableIdentity = true
        } catch {
            identityError = error
            installData = ReplicaDeviceID(uuid: UUID()).bytes
            hasDurableIdentity = false
        }
        let resolvedDeviceID = try! ReplicaDeviceID(bytes: installData)
        deviceID = resolvedDeviceID

        let resolvedBaseDirectory = baseDirectory
        persistenceURL = resolvedBaseDirectory
            .appendingPathComponent("replica-v1.json")
        pairingArtifactsDirectory = resolvedBaseDirectory
        pairingArtifactID = nil
        let eraseMarkerURL = resolvedBaseDirectory
            .appendingPathComponent(Self.eraseMarkerFilename)

        var bootError = identityError
        let durableStorage: Bool
        if hasDurableIdentity {
            do {
                try FileManager.default.createDirectory(
                    at: resolvedBaseDirectory,
                    withIntermediateDirectories: true,
                    attributes: ProtectedStorage.directoryAttributes
                )
                if FileManager.default.fileExists(atPath: eraseMarkerURL.path) {
                    replica = try Self.completeErase(
                        store: resolvedCredentialStore,
                        deviceID: resolvedDeviceID,
                        persistenceURL: persistenceURL,
                        markerURL: eraseMarkerURL
                    )
                } else {
                    replica = try TaskReplica(
                        deviceID: resolvedDeviceID,
                        persistenceURL: persistenceURL
                    )
                }
                durableStorage = true
            } catch {
                bootError = error
                replica = try! TaskReplica(deviceID: resolvedDeviceID)
                durableStorage = false
            }
        } else {
            replica = try! TaskReplica(deviceID: resolvedDeviceID)
            durableStorage = false
        }
        hasDurableStorage = durableStorage

        var terminalPairingLoadError: Error?
        if hasDurableIdentity, hasDurableStorage {
            do {
                terminalPairingActions =
                    try credentialStore.terminalPairingActions()
            } catch {
                terminalPairingLoadError = error
                terminalPairingActions = []
                terminalPairingJournalUsable = false
            }
            do {
                credentials = try Self.restoreActiveCredentials(
                    store: credentialStore,
                    deviceID: deviceID
                )
                if let pending = try credentialStore.pending() {
                    pairingArtifactID = pending.pairingArtifactID
                    if pending.pairingVersion == nil, credentials != nil {
                        try credentialStore.clearCurrentPair()
                        credentials = nil
                        try? FileManager.default.removeItem(
                            at: pairingStagingURL
                        )
                        try? FileManager.default.removeItem(
                            at: pairingMergedURL
                        )
                        try? FileManager.default.removeItem(
                            at: pairingConflictBackupURL
                        )
                        bootError =
                            bootError ?? SyncError.legacyPairingNeedsRelink
                    } else if let finalizing = try Self.finalizingPending(
                        pending,
                        active: credentials,
                        deviceID: deviceID
                    ) {
                        if finalizing != pending {
                            try credentialStore.savePending(finalizing)
                        }
                        pendingPairForRecovery = finalizing
                    } else {
                        if pending.role == .joiner,
                           FileManager.default.fileExists(
                               atPath: pairingStagingURL.path
                           )
                        {
                            try? FileManager.default.removeItem(
                                at: pairingStagingURL
                            )
                        }
                        if FileManager.default.fileExists(
                            atPath: pairingMergedURL.path
                        ) {
                            try? FileManager.default.removeItem(
                                at: pairingMergedURL
                            )
                        }
                        if FileManager.default.fileExists(
                            atPath: pairingConflictBackupURL.path
                        ) {
                            try? FileManager.default.removeItem(
                                at: pairingConflictBackupURL
                            )
                        }
                        try credentialStore.clearPending()
                    }
                }
                if let credentials {
                    do {
                        if let checkpoint = try credentialStore.mailboxCheckpoint() {
                            guard
                                checkpoint.version == SyncProtocol.version,
                                checkpoint.pairID == credentials.groupID,
                                checkpoint.uploadedLocalSequence
                                    <= replica.versionVector[deviceID]
                            else {
                                throw SyncError.invalidCredentials
                            }
                            uploadedLocalSequence =
                                checkpoint.uploadedLocalSequence
                            uploadedThroughByRecipient = Dictionary(
                                uniqueKeysWithValues: checkpoint
                                    .uploadedThroughByRecipient
                                    .compactMap { key, value -> (Data, UInt64)? in
                                        guard let data = try? Data(base64URL: key) else {
                                            return nil
                                        }
                                        return (data, value)
                                    }
                            )
                            // Legacy single-field checkpoint: seed all remotes.
                            if uploadedThroughByRecipient.isEmpty,
                               checkpoint.uploadedLocalSequence > 0
                            {
                                for remote in credentials.remoteActiveDeviceIDs {
                                    uploadedThroughByRecipient[remote] =
                                        checkpoint.uploadedLocalSequence
                                }
                            }
                        }
                    } catch {
                        uploadedLocalSequence = 0
                        uploadedThroughByRecipient = [:]
                        try? credentialStore.clearMailboxCheckpoint()
                    }
                }
                if pendingPairForRecovery == nil,
                   FileManager.default.fileExists(
                    atPath: pairingStagingURL.path
                   )
                {
                    try? FileManager.default.removeItem(at: pairingStagingURL)
                }
                if pendingPairForRecovery == nil,
                   FileManager.default.fileExists(
                    atPath: pairingMergedURL.path
                   )
                {
                    try? FileManager.default.removeItem(at: pairingMergedURL)
                }
                if pendingPairForRecovery == nil,
                   FileManager.default.fileExists(
                    atPath: pairingConflictBackupURL.path
                   )
                {
                    try? FileManager.default.removeItem(
                        at: pairingConflictBackupURL
                    )
                }
            } catch {
                bootError = bootError ?? error
                credentials = nil
                pendingPairForRecovery = nil
                try? credentialStore.clearCurrentPair()
            }
            if
                terminalPairingLoadError != nil,
                let active = credentials
            {
                do {
                    if let action = try Self.reconstructedReceiptAction(
                        credentials: active
                    ) {
                        try credentialStore
                            .replaceDamagedTerminalPairingActions(
                                with: action
                            )
                        terminalPairingActions =
                            try credentialStore.terminalPairingActions()
                        terminalPairingLoadError = nil
                        terminalPairingJournalUsable = true
                    }
                } catch {
                    terminalPairingLoadError = error
                    terminalPairingActions = []
                    terminalPairingJournalUsable = false
                }
            }
            if
                terminalPairingLoadError != nil,
                credentials == nil,
                pendingPairForRecovery == nil
            {
                bootError =
                    bootError ?? SyncError.pairingRecoveryJournalDamaged
            }
        } else {
            credentials = nil
        }

        tasks = replica.tasks
        isPaired = credentials != nil
        refreshPendingMailboxCount()
        if let bootError {
            phase = .failed
            errorMessage = Self.displayMessage(for: bootError)
        } else if let pending = pendingPairForRecovery {
            isPairingFinalizationLocked = true
            phase = .finalizing
            let attemptID = UUID()
            pairingAttemptID = attemptID
            pairingTask = Task { [weak self] in
                await self?.runPairingFinalization(
                    pending,
                    attemptID: attemptID
                )
            }
        } else if credentials != nil {
            phase = .connecting
            if let terminalPairingLoadError {
                mailboxErrorMessage =
                    Self.displayMessage(for: terminalPairingLoadError)
                mailboxRequiresRepair = true
            }
            Task { [weak self] in
                self?.startSyncLoop()
                self?.startMailboxLoop()
            }
        } else {
            phase = .unpaired
        }
        if !terminalPairingActions.isEmpty {
            Task { [weak self] in
                self?.startTerminalPairingLoop()
            }
        }
        self.backgroundMailboxScheduler.register { [weak self] in
            await self?.performBackgroundMailboxFlushWork()
        }
        if let pending = pendingPairForRecovery {
            activePairingRole = pending.role
        }
    }


    /// Support self-serve sheet (D20) — outcome language only.

    /// Active members in the linked group (including this iPhone).
    public var linkedDeviceIDs: [Data] { credentials?.activeMemberDeviceIDs ?? [] }
    public var localDeviceID: Data { deviceID.bytes }

    public var linkedMemberCount: Int {
        credentials?.activeMemberCount ?? (isPaired ? 2 : 0)
    }

    public var isGroupAtCapacity: Bool {
        credentials?.isAtCapacity ?? false
    }

    /// Short labels for Manage Sync member list.


    public func leaveGroupAndKeepTasks() {
        // Best-effort signed remove + rekey for remaining members (C3), then local clear.
        if let credentials, credentials.activeMemberCount >= 3 {
            let snapshotCredentials = credentials
            Task { @MainActor [weak self] in
                await self?.publishLocalLeaveMembership(snapshotCredentials)
            }
        }
        unlinkAndKeepTasks()
    }

    /// Seeds a multi-member group for Manage Sync UI demos/screenshots.


    /// Whether the invitation UI is an in-group invite (vs founding).
    public var isIssuingGroupInvite: Bool {
        isPaired && invitationPhrase != nil
    }


    public var pairingRecoveryResetRequired: Bool {
        !terminalPairingJournalUsable
            || terminalPairingActions.count
                >= TerminalPairingActionJournal.maximumActionCount
    }

    public var hasLocalReplicaHistory: Bool {
        !replica.isEmpty
    }

    public var canJoinExistingSync: Bool {
        hasDurableIdentity
            && hasDurableStorage
            && !isPaired
            && !isPairingFinalizationLocked
            && pairingTask == nil
    }

    public var canEditLocalTasks: Bool {
        hasDurableStorage && !isPairingFinalizationLocked
    }

    public var canCancelPairing: Bool {
        guard !isPaired, let pending = pendingPairForRecovery else {
            return false
        }
        if !isPairingFinalizationLocked {
            return true
        }
        return switch (pending.role, pending.finalizationState) {
        case (.host, .provisionMayHaveBeenStored),
             (.joiner, .waitingForProvision),
             (.joiner, .provisionStagedAwaitingMergeApproval):
            true
        default:
            false
        }
    }




    /// Found a new group (unlinked) or invite another iPhone into the current group.
    public func createPrivateSync() {
        if isPaired {
            inviteToGroup()
            return
        }
        guard
            hasDurableIdentity,
            hasDurableStorage,
            !isPairingFinalizationLocked,
            pairingTask == nil
        else {
            return
        }
        do {
            try validateTerminalPairingCapacity()
            try validateProvisioningArchiveSize()
            let invitation = try Invitation.generate()
            invitationPhrase = invitation.phrase
            invitationURL = try invitation.url(scheme: invitationURLScheme)
            invitationExpiresAt = Date().addingTimeInterval(
                SyncTiming.invitationTimeToLive
            )
            safetyCode = nil
            errorMessage = nil
            activePairingRole = .host
            phase = .waitingForPeer
            let attemptID = UUID()
            pairingAttemptID = attemptID
            pairingTask = Task { [weak self] in
                await self?.runHostPairing(invitation, attemptID: attemptID)
            }
            pairingExpiryTask = Task { [weak self] in
                do {
                    try await Task.sleep(
                        nanoseconds: SyncTiming.invitationTimeToLiveNanoseconds
                    )
                    // Client-side pairing window (aligned with relay waiting-room TTL).
                    guard
                        let self,
                        self.pairingAttemptID == attemptID,
                        !self.isPaired,
                        !self.isPairingFinalizationLocked,
                        !Task.isCancelled
                    else {
                        return
                    }
                    self.cancelPairing()
                    self.fail(SyncError.invitationExpired)
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
            }
        } catch {
            fail(error)
        }
    }

    public func joinPrivateSync(phrase: String) {
        guard
            hasDurableIdentity,
            hasDurableStorage,
            !isPaired,
            !isPairingFinalizationLocked,
            pairingTask == nil
        else {
            return
        }
        do {
            try validateTerminalPairingCapacity()
            let invitation = try Invitation.from(phrase: phrase)
            beginJoin(with: invitation)
        } catch {
            fail(error)
        }
    }

    public func joinPrivateSync(url: URL) {
        guard
            hasDurableIdentity,
            hasDurableStorage,
            !isPaired,
            !isPairingFinalizationLocked,
            pairingTask == nil
        else {
            return
        }
        do {
            try validateTerminalPairingCapacity()
            let invitation = try Invitation.from(url: url, scheme: invitationURLScheme)
            beginJoin(with: invitation)
        } catch {
            fail(error)
        }
    }

    public func approveSafetyCode() {
        guard isHostApprovalPending else {
            return
        }
        isHostApprovalPending = false
        approvalContinuation?.resume(returning: true)
        approvalContinuation = nil
    }

    public func rejectSafetyCode() {
        guard safetyCode != nil else {
            return
        }
        if isHostApprovalPending {
            isHostApprovalPending = false
            approvalContinuation?.resume(returning: false)
            approvalContinuation = nil
            return
        }
        cancelPairing(preserveLink: isPaired)
    }

    public func regenerateInvitation() {
        guard
            invitationPhrase != nil,
            !isPairingFinalizationLocked
        else {
            return
        }
        let wasLinked = isPaired
        cancelPairing(preserveLink: wasLinked)
        if wasLinked {
            inviteToGroup()
        } else {
            createPrivateSync()
        }
    }

    /// Any linked member can issue a join invite into the existing group.
    public func inviteToGroup() {
        guard
            hasDurableIdentity,
            hasDurableStorage,
            isPaired,
            !isPairingFinalizationLocked,
            pairingTask == nil,
            let credentials
        else {
            return
        }
        if credentials.isAtCapacity {
            fail(SyncError.groupAtCapacity)
            return
        }
        do {
            try validateTerminalPairingCapacity()
            try validateProvisioningArchiveSize()
            let invitation = try Invitation.generate()
            invitationPhrase = invitation.phrase
            invitationURL = try invitation.url(scheme: invitationURLScheme)
            invitationExpiresAt = Date().addingTimeInterval(
                SyncTiming.invitationTimeToLive
            )
            safetyCode = nil
            errorMessage = nil
            activePairingRole = .host
            phase = .waitingForPeer
            let attemptID = UUID()
            pairingAttemptID = attemptID
            pairingTask = Task { [weak self] in
                await self?.runHostPairing(invitation, attemptID: attemptID)
            }
            pairingExpiryTask = Task { [weak self] in
                do {
                    try await Task.sleep(
                        nanoseconds: SyncTiming.invitationTimeToLiveNanoseconds
                    )
                    guard
                        let self,
                        self.pairingAttemptID == attemptID,
                        self.isPaired,
                        !self.isPairingFinalizationLocked,
                        self.invitationPhrase != nil,
                        !Task.isCancelled
                    else {
                        return
                    }
                    self.cancelPairing(preserveLink: true)
                    self.fail(SyncError.invitationExpired)
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
            }
        } catch {
            fail(error)
        }
    }

    public func cancelPairing(preserveLink: Bool = false) {
        let keepLink = isPaired && (preserveLink || invitationPhrase != nil)
        if isPaired && !keepLink {
            return
        }
        if isPairingFinalizationLocked {
            // Group-invite finalization is still pairing-locked; abort path
            // clears pending without unlinking when credentials already exist.
            requestPendingPairingAbort()
            return
        }
        if isHostApprovalPending {
            isHostApprovalPending = false
            approvalContinuation?.resume(returning: false)
            approvalContinuation = nil
            return
        }
        pairingTask?.cancel()
        pairingExpiryTask?.cancel()
        pairingAttemptID = nil
        pairingTask = nil
        pairingExpiryTask = nil
        if let approvalContinuation {
            approvalContinuation.resume(returning: false)
            self.approvalContinuation = nil
        }
        if let pairingSocket {
            Task {
                await pairingSocket.cancel()
            }
        }
        pairingSocket = nil
        invitationPhrase = nil
        invitationURL = nil
        invitationExpiresAt = nil
        safetyCode = nil
        isHostApprovalPending = false
        activePairingRole = nil
        do {
            try rollbackPendingPairing()
            errorMessage = nil
            if keepLink, credentials != nil {
                phase = channelReady ? .synced : .connecting
                startSyncLoop()
                startMailboxLoop()
            } else {
                phase = .unpaired
            }
        } catch {
            hasDurableStorage = false
            fail(error)
        }
    }

    public func resolvePairingReplicaConflictKeepingBoth() {
        guard
            isPairingFinalizationLocked,
            hasPairingReplicaConflict || keepBothPreview != nil,
            credentials == nil,
            let pending = pendingPairForRecovery,
            pending.role == .joiner,
            pending.finalizationState
                == .provisionStagedAwaitingMergeApproval
        else {
            return
        }
        do {
            let staged = try validatedStagedJoinerReplica(pending)
            keepBothPreview = try TaskReplica.keepBothPreview(
                staged: staged,
                local: replica
            )
            let merged = try TaskReplica.keepBothCandidate(
                staged: staged,
                local: replica,
                pairID: pending.pairID
            )
            try persistPreparedJoinerReplica(merged)
            var ready = pending
            ready.finalizationState = .readyMayHaveBeenStored
            try credentialStore.savePending(ready)
            pendingPairForRecovery = ready
        } catch {
            let displayError = Self.isReplicaCapacityError(error)
                ? SyncError.pairingMergeTooLarge
                : error
            errorMessage =
                "\(Self.displayMessage(for: displayError)) You can cancel pairing and keep this iPhone unchanged."
            return
        }
        hasPairingReplicaConflict = false
        keepBothPreview = nil
        errorMessage = nil
        startPendingPairingFinalization()
    }

    @discardableResult
    public func addTask(title: String) -> Bool {
        guard canEditLocalTasks else {
            localEditErrorMessage = errorMessage ?? "Local storage is unavailable."
            return false
        }
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return false
        }
        do {
            let operation = try replica.createTask(title: normalized)
            publishReplica()
            sendImmediately([operation])
            localEditErrorMessage = nil
            return true
        } catch {
            handleLocalMutationFailure(error)
            return false
        }
    }

    public func clearLocalEditError() {
        localEditErrorMessage = nil
    }

    public func toggleTask(_ task: ReplicatedTask) {
        guard canEditLocalTasks else {
            return
        }
        guard let completed = task.isCompleted else {
            return
        }
        do {
            let operation = try replica.setCompleted(
                taskID: task.id,
                completed: !completed
            )
            publishReplica()
            sendImmediately([operation])
        } catch {
            handleLocalMutationFailure(error)
        }
    }

    public func deleteTasks(at offsets: IndexSet) {
        deleteTasks(
            ids: offsets.compactMap {
                tasks.indices.contains($0) ? tasks[$0].id : nil
            }
        )
    }

    public func deleteTasks(ids: [UUID]) {
        guard canEditLocalTasks else {
            return
        }
        for id in ids {
            guard let task = replica.task(id: id), !task.isDeleted else {
                continue
            }
            do {
                let operation = try replica.deleteTask(taskID: id)
                sendImmediately([operation])
            } catch {
                handleLocalMutationFailure(error)
                return
            }
        }
        publishReplica()
    }

    public func eraseLocalData() {
        guard hasDurableIdentity else {
            return
        }
        let groupMailboxToForget = credentials.flatMap {
            try? GroupMailbox(credentials: $0)
        }
        let terminalActionsToForget = terminalPairingActions
        let mailboxCycleToFinish = mailboxCycleTask
        pairingTask?.cancel()
        pairingExpiryTask?.cancel()
        syncTask?.cancel()
        pingTask?.cancel()
        outboundTask?.cancel()
        mailboxPollTask?.cancel()
        mailboxCycleTask?.cancel()
        backgroundFlushTask?.cancel()
        terminalPairingTask?.cancel()
        pairingAttemptID = nil
        credentials = nil
        pendingPairForRecovery = nil
        isPaired = false
        isPairingFinalizationLocked = false
        hasPairingReplicaConflict = false
        pairingTask = nil
        pairingExpiryTask = nil
        syncTask = nil
        pingTask = nil
        outboundTask = nil
        mailboxPollTask = nil
        mailboxCycleTask = nil
        backgroundFlushTask = nil
        terminalPairingTask = nil
        terminalPairingLoopID = nil
        outboundDrainID = nil
        mailboxCycleID = nil
        mailboxCycleRequested = false
        mailboxFailureCount = 0
        nextMailboxAttemptAt = .distantPast
        approvalContinuation?.resume(returning: false)
        approvalContinuation = nil

        if let pairingSocket {
            Task { await pairingSocket.cancel() }
        }
        if let activeSocket {
            Task { await activeSocket.cancel() }
        }
        pairingSocket = nil
        activeSocket = nil
        channelReady = false
        pendingPings = [:]
        deferredOperations = []
        uploadedLocalSequence = 0
        uploadedThroughByRecipient = [:]
        uploadedThroughByRecipient = [:]
        hasDurableStorage = false

        if let groupMailboxToForget {
            let transport = mailboxTransport
            Task {
                await mailboxCycleToFinish?.value
                for material in groupMailboxToForget.outboundByRecipient.values {
                    try? await transport.forget(
                        route: material.route,
                        authorization: material.authorization
                    )
                }
                for material in groupMailboxToForget.inboundBySender.values {
                    try? await transport.forget(
                        route: material.route,
                        authorization: material.authorization
                    )
                }
            }
        }
        if !terminalActionsToForget.isEmpty {
            let transport = mailboxTransport
            Task {
                for action in terminalActionsToForget {
                    try? await transport.forget(
                        route: action.route,
                        authorization: action.authorization
                    )
                }
            }
        }

        do {
            let markerURL = persistenceURL.deletingLastPathComponent()
                .appendingPathComponent(Self.eraseMarkerFilename)
            try Self.persistEraseMarker(at: markerURL)
            if FileManager.default.fileExists(
                atPath: pairingStagingURL.path
            ) {
                try FileManager.default.removeItem(
                    at: pairingStagingURL
                )
            }
            if FileManager.default.fileExists(
                atPath: pairingMergedURL.path
            ) {
                try FileManager.default.removeItem(
                    at: pairingMergedURL
                )
            }
            if FileManager.default.fileExists(
                atPath: pairingConflictBackupURL.path
            ) {
                try FileManager.default.removeItem(
                    at: pairingConflictBackupURL
                )
            }
            replica = try Self.completeErase(
                store: credentialStore,
                deviceID: deviceID,
                persistenceURL: persistenceURL,
                markerURL: markerURL
            )
            hasDurableStorage = true
            terminalPairingActions = []
            terminalPairingJournalUsable = true
            pairingArtifactID = nil
            tasks = []
            invitationPhrase = nil
            invitationURL = nil
            invitationExpiresAt = nil
            safetyCode = nil
            lastRoundTripMilliseconds = nil
            lastSyncedAt = nil
            lastMailboxStoredAt = nil
            lastMailboxReceivedAt = nil
            errorMessage = nil
            mailboxErrorMessage = nil
            mailboxError = nil
            mailboxRequiresRepair = false
            mailboxCapacityReached = false
            localEditErrorMessage = nil
            mailboxState = .idle
            pendingMailboxOperationCount = 0
            keepBothPreview = nil
            showsLinkCompleteCelebration = false
            showsSavingNotice = false
            pendingMailboxSince = nil
            activePairingRole = nil
            cancelPresentationTasks()
            backgroundMailboxScheduler.cancelFlush()
            phase = .unpaired
        } catch {
            fail(error)
        }
    }

    public func unlinkAndKeepTasks() {
        let resetsPairingRecovery = pairingRecoveryResetRequired
        guard
            hasDurableIdentity,
            isPaired || resetsPairingRecovery,
            !isPairingFinalizationLocked
        else {
            return
        }
        let groupMailboxToForget = credentials.flatMap {
            try? GroupMailbox(credentials: $0)
        }
        let terminalActionsToForget = resetsPairingRecovery
            ? terminalPairingActions
            : []
        let mailboxCycleToFinish = mailboxCycleTask
        do {
            if resetsPairingRecovery {
                try credentialStore.clearAllPairingData()
            } else {
                try credentialStore.clearCurrentPair()
            }
        } catch {
            fail(error)
            return
        }
        pairingTask?.cancel()
        pairingExpiryTask?.cancel()
        syncTask?.cancel()
        pingTask?.cancel()
        outboundTask?.cancel()
        mailboxPollTask?.cancel()
        mailboxCycleTask?.cancel()
        backgroundFlushTask?.cancel()
        terminalPairingTask?.cancel()
        pairingAttemptID = nil
        credentials = nil
        pendingPairForRecovery = nil
        pairingArtifactID = nil
        isPaired = false
        isPairingFinalizationLocked = false
        hasPairingReplicaConflict = false
        keepBothPreview = nil
        pairingTask = nil
        pairingExpiryTask = nil
        syncTask = nil
        pingTask = nil
        outboundTask = nil
        mailboxPollTask = nil
        mailboxCycleTask = nil
        backgroundFlushTask = nil
        terminalPairingTask = nil
        terminalPairingLoopID = nil
        outboundDrainID = nil
        mailboxCycleID = nil
        mailboxCycleRequested = false
        mailboxFailureCount = 0
        nextMailboxAttemptAt = .distantPast
        approvalContinuation?.resume(returning: false)
        approvalContinuation = nil
        cancelPresentationTasks()

        if let pairingSocket {
            Task { await pairingSocket.cancel() }
        }
        if let activeSocket {
            Task { await activeSocket.cancel() }
        }
        pairingSocket = nil
        activeSocket = nil
        channelReady = false
        pendingPings = [:]
        deferredOperations = []
        uploadedLocalSequence = 0
        uploadedThroughByRecipient = [:]
        if resetsPairingRecovery {
            terminalPairingActions = []
            terminalPairingJournalUsable = true
        }

        if let groupMailboxToForget {
            let transport = mailboxTransport
            Task {
                await mailboxCycleToFinish?.value
                for material in groupMailboxToForget.outboundByRecipient.values {
                    try? await transport.forget(
                        route: material.route,
                        authorization: material.authorization
                    )
                }
                for material in groupMailboxToForget.inboundBySender.values {
                    try? await transport.forget(
                        route: material.route,
                        authorization: material.authorization
                    )
                }
            }
        }
        if !terminalActionsToForget.isEmpty {
            let transport = mailboxTransport
            Task {
                for action in terminalActionsToForget {
                    try? await transport.forget(
                        route: action.route,
                        authorization: action.authorization
                    )
                }
            }
        }

        invitationPhrase = nil
        invitationURL = nil
        invitationExpiresAt = nil
        safetyCode = nil
        lastRoundTripMilliseconds = nil
        lastSyncedAt = nil
        lastMailboxStoredAt = nil
        lastMailboxReceivedAt = nil
        errorMessage = nil
        mailboxErrorMessage = nil
        mailboxError = nil
        mailboxRequiresRepair = false
        mailboxCapacityReached = false
        localEditErrorMessage = nil
        mailboxState = .idle
        pendingMailboxOperationCount = 0
        showsLinkCompleteCelebration = false
        showsSavingNotice = false
        pendingMailboxSince = nil
        activePairingRole = nil
        backgroundMailboxScheduler.cancelFlush()
        phase = .unpaired
        if !resetsPairingRecovery {
            startTerminalPairingLoop()
        }
    }

    private func cancelPresentationTasks() {
        savingNoticeRevealTask?.cancel()
        savingNoticeRevealTask = nil
        linkCompleteCelebrationTask?.cancel()
        linkCompleteCelebrationTask = nil
    }

    public func waitForBackgroundWork() async {
        await backgroundFlushTask?.value
    }

    public func stopBackgroundWork() async {
        mailboxCycleTask?.cancel()
        backgroundFlushTask?.cancel()
    }

    public func applicationDidBecomeActive() {
        appIsActive = true
        backgroundFlushTask?.cancel()
        backgroundFlushTask = nil
        if isPairingFinalizationLocked {
            startPendingPairingFinalization()
        } else if isPaired {
            startSyncLoop()
            startMailboxLoop()
        }
        startTerminalPairingLoop()
    }

    public func applicationDidEnterBackground() {
        appIsActive = false
        mailboxPollTask?.cancel()
        mailboxPollTask = nil
        syncTask?.cancel()
        pingTask?.cancel()
        outboundTask?.cancel()
        terminalPairingTask?.cancel()
        pingTask = nil
        outboundTask = nil
        terminalPairingTask = nil
        terminalPairingLoopID = nil
        outboundDrainID = nil
        if let activeSocket {
            Task { await activeSocket.cancel() }
        }
        activeSocket = nil
        channelReady = false
        if isPairingFinalizationLocked {
            phase = .finalizing
        } else if isPaired {
            phase = .offline
            // Immediate best-effort upload window, then OS-scheduled retry.
            startBackgroundMailboxFlush()
            backgroundMailboxScheduler.scheduleFlushIfNeeded(
                pendingOperationCount: pendingMailboxOperationCount
            )
        }
    }

    /// Invoked by BGProcessingTask and UIBackgroundTask flush loops.
    public func performBackgroundMailboxFlushWork() async {
        guard isPaired, credentials != nil, hasDurableStorage else {
            backgroundMailboxScheduler.cancelFlush()
            return
        }
        refreshPendingMailboxCount()
        guard pendingMailboxOperationCount > 0 else {
            backgroundMailboxScheduler.cancelFlush()
            return
        }
        // Keep cycling until empty or the OS cancels this work unit.
        var attempts = 0
        while
            !Task.isCancelled,
            pendingMailboxOperationCount > 0,
            attempts < 8
        {
            attempts += 1
            requestMailboxCycle(force: true, allowInactive: true)
            if let cycleTask = mailboxCycleTask {
                await cycleTask.value
            } else {
                break
            }
            refreshPendingMailboxCount()
            if pendingMailboxOperationCount > 0 {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        if pendingMailboxOperationCount > 0 {
            backgroundMailboxScheduler.scheduleFlushIfNeeded(
                pendingOperationCount: pendingMailboxOperationCount
            )
        } else {
            backgroundMailboxScheduler.cancelFlush()
        }
    }

    func confirmAuthenticatedPeerCompletion() {
        guard let credentials else {
            return
        }
        confirmAuthenticatedPeerCompletion(credentials)
    }

    public func stop() async {
        appIsActive = false
        pairingAttemptID = nil
        approvalContinuation?.resume(returning: false)
        approvalContinuation = nil
        cancelPresentationTasks()
        mailboxCycleRequested = false
        let tasks = [
            pairingTask,
            pairingExpiryTask,
            syncTask,
            pingTask,
            outboundTask,
            mailboxPollTask,
            mailboxCycleTask,
            backgroundFlushTask,
            terminalPairingTask,
        ].compactMap { $0 }
        for task in tasks {
            task.cancel()
        }
        if let pairingSocket {
            await pairingSocket.cancel()
        }
        if let activeSocket {
            await activeSocket.cancel()
        }
        for task in tasks {
            await task.value
        }
        pairingTask = nil
        pairingExpiryTask = nil
        syncTask = nil
        pingTask = nil
        outboundTask = nil
        mailboxPollTask = nil
        mailboxCycleTask = nil
        backgroundFlushTask = nil
        terminalPairingTask = nil
        terminalPairingLoopID = nil
        outboundDrainID = nil
        mailboxCycleID = nil
        mailboxCycleRequested = false
        pairingSocket = nil
        activeSocket = nil
        channelReady = false
        for subscriber in stateSubscribers.values { subscriber.finish() }
        stateSubscribers.removeAll()
    }

    private func beginJoin(with invitation: Invitation) {
        pairingArtifactID = nil
        if FileManager.default.fileExists(atPath: pairingStagingURL.path) {
            try? FileManager.default.removeItem(at: pairingStagingURL)
        }
        if FileManager.default.fileExists(atPath: pairingMergedURL.path) {
            try? FileManager.default.removeItem(at: pairingMergedURL)
        }
        if FileManager.default.fileExists(
            atPath: pairingConflictBackupURL.path
        ) {
            try? FileManager.default.removeItem(
                at: pairingConflictBackupURL
            )
        }
        invitationPhrase = nil
        invitationURL = nil
        safetyCode = nil
        errorMessage = nil
        activePairingRole = .joiner
        phase = .waitingForPeer
        let attemptID = UUID()
        pairingAttemptID = attemptID
        pairingTask = Task { [weak self] in
            await self?.runJoinerPairing(invitation, attemptID: attemptID)
        }
    }

    private func runHostPairing(
        _ invitation: Invitation,
        attemptID: UUID
    ) async {
        guard isCurrentPairingAttempt(attemptID) else {
            return
        }
        var socket: RelaySocket?
        do {
            let liveSocket = try await connectPairingSocketUntilPeerReady(
                route: invitation.pairRoute,
                attemptID: attemptID
            )
            socket = liveSocket
            try requireCurrentPairingAttempt(attemptID)
            pairingExpiryTask?.cancel()
            pairingExpiryTask = nil

            let context = HandshakeContext.pairing(
                relayOrigin: try relayOrigin(),
                route: invitation.pairRoute
            )
            let handshake = try InitiatorHandshake(
                context: context,
                psk: invitation.pairPSK
            )
            try await liveSocket.send(handshake.hello)
            let response = try await nextBinary(on: liveSocket)
            try requireCurrentPairingAttempt(attemptID)
            let result = try handshake.receive(response)
            try await liveSocket.send(result.confirm)

            let pairRoot = try requirePairRoot(result.material)
            let pairID = try requirePairID(result.material)
            safetyCode = result.material.safetyCode
            isHostApprovalPending = true
            phase = .verifying
            let approved = await waitForApproval(attemptID: attemptID)
            try requireCurrentPairingAttempt(attemptID)
            if !approved {
                let pending = PendingPair(
                    version: SyncProtocol.version,
                    pairRoot: pairRoot,
                    pairID: pairID,
                    role: .host,
                    localDeviceID: deviceID.bytes,
                    remoteDeviceID: nil,
                    archiveHash: Data(),
                    expiresAt: Date().addingTimeInterval(
                        SyncTiming.invitationTimeToLive
                    ),
                    finalizationState: .abortMayHaveBeenStored,
                    pairingArtifactID: pairID
                )
                try credentialStore.savePending(pending)
                beginPairingFinalization(pending)
                await liveSocket.cancel()
                pairingSocket = nil
                await runPairingFinalization(
                    pending,
                    attemptID: attemptID
                )
                return
            }

            let archive = try replica.exportProvisioningArchive()
            guard archive.count <= ProtocolLimits.provisioningArchiveBytes else {
                throw SyncError.archiveTooLarge
            }
            let archiveHash = archive.sha256
            let pending = PendingPair(
                version: SyncProtocol.version,
                pairRoot: pairRoot,
                pairID: pairID,
                role: .host,
                localDeviceID: deviceID.bytes,
                remoteDeviceID: nil,
                archiveHash: archiveHash,
                expiresAt: Date().addingTimeInterval(
                    SyncTiming.invitationTimeToLive
                ),
                finalizationState: .provisionMayHaveBeenStored,
                pairingArtifactID: pairID
            )
            try credentialStore.savePending(pending)
            try requireCurrentPairingAttempt(attemptID)
            beginPairingFinalization(pending)
            await liveSocket.cancel()
            pairingSocket = nil
            await runPairingFinalization(
                pending,
                attemptID: attemptID
            )
        } catch is CancellationError {
            if let socket {
                await socket.cancel()
            } else if let pairingSocket {
                await pairingSocket.cancel()
            }
        } catch {
            if let socket {
                await socket.cancel()
            } else if let pairingSocket {
                await pairingSocket.cancel()
            }
            guard !Task.isCancelled else {
                return
            }
            pairingFailed(error, attemptID: attemptID)
        }
    }

    private func runJoinerPairing(
        _ invitation: Invitation,
        attemptID: UUID
    ) async {
        guard isCurrentPairingAttempt(attemptID) else {
            return
        }
        var socket: RelaySocket?
        do {
            let liveSocket = try await connectPairingSocketUntilPeerReady(
                route: invitation.pairRoute,
                attemptID: attemptID
            )
            socket = liveSocket
            try requireCurrentPairingAttempt(attemptID)

            let context = HandshakeContext.pairing(
                relayOrigin: try relayOrigin(),
                route: invitation.pairRoute
            )
            let hello = try await nextBinary(on: liveSocket)
            try requireCurrentPairingAttempt(attemptID)
            let response = try ResponderHandshake.respond(
                to: hello,
                context: context,
                psk: invitation.pairPSK
            )
            try await liveSocket.send(response.response)
            let confirmation = try await nextBinary(on: liveSocket)
            try requireCurrentPairingAttempt(attemptID)
            let material = try response.state.receive(confirmation)

            let pairRoot = try requirePairRoot(material)
            let pairID = try requirePairID(material)
            safetyCode = material.safetyCode
            isHostApprovalPending = false
            phase = .verifying
            let pending = PendingPair(
                version: SyncProtocol.version,
                pairRoot: pairRoot,
                pairID: pairID,
                role: .joiner,
                localDeviceID: deviceID.bytes,
                remoteDeviceID: nil,
                archiveHash: Data(),
                expiresAt: Date().addingTimeInterval(
                    SyncTiming.invitationTimeToLive
                ),
                finalizationState: .waitingForProvision,
                pairingArtifactID: pairID
            )
            try credentialStore.savePending(pending)
            try requireCurrentPairingAttempt(attemptID)
            beginPairingFinalization(
                pending,
                preserveSafetyCode: true
            )
            await liveSocket.cancel()
            pairingSocket = nil
            await runPairingFinalization(
                pending,
                attemptID: attemptID
            )
        } catch is CancellationError {
            if let socket {
                await socket.cancel()
            } else if let pairingSocket {
                await pairingSocket.cancel()
            }
        } catch {
            if let socket {
                await socket.cancel()
            } else if let pairingSocket {
                await pairingSocket.cancel()
            }
            guard !Task.isCancelled else {
                return
            }
            pairingFailed(error, attemptID: attemptID)
        }
    }

    /// Keep the invite alive across flaky Wi‑Fi, app suspend, and brief relay
    /// blips until peerReady or the pairing window ends.
    private func connectPairingSocketUntilPeerReady(
        route: Data,
        attemptID: UUID
    ) async throws -> RelaySocket {
        var delayNanoseconds: UInt64 = 500_000_000
        while true {
            try requireCurrentPairingAttempt(attemptID)
            if let expiresAt = invitationExpiresAt, Date() >= expiresAt {
                throw SyncError.invitationExpired
            }

            let socket = RelaySocket(url: relayURL, policy: endpointPolicy)
            pairingSocket = socket
            do {
                try await socket.connect(route: route)
                try requireCurrentPairingAttempt(attemptID)
                try await waitForPeer(on: socket)
                try requireCurrentPairingAttempt(attemptID)
                return socket
            } catch is CancellationError {
                await clearPairingSocketIfCurrent(socket)
                throw CancellationError()
            } catch {
                await clearPairingSocketIfCurrent(socket)
                guard isCurrentPairingAttempt(attemptID) else {
                    throw CancellationError()
                }
                if let expiresAt = invitationExpiresAt, Date() >= expiresAt {
                    throw SyncError.invitationExpired
                }
                guard SyncError.isRetriablePairingTransportFailure(error) else {
                    throw error
                }
                try await Task.sleep(nanoseconds: delayNanoseconds)
                delayNanoseconds = min(delayNanoseconds * 2, 4_000_000_000)
            }
        }
    }

    private func clearPairingSocketIfCurrent(_ socket: RelaySocket) async {
        await socket.cancel()
        if let current = pairingSocket,
           ObjectIdentifier(current) == ObjectIdentifier(socket)
        {
            pairingSocket = nil
        }
    }

    private func beginPairingFinalization(
        _ pending: PendingPair,
        preserveSafetyCode: Bool = false
    ) {
        pairingArtifactID = pending.pairingArtifactID
        pendingPairForRecovery = pending
        isPairingFinalizationLocked = true
        hasPairingReplicaConflict = false
        pairingExpiryTask?.cancel()
        pairingExpiryTask = nil
        invitationPhrase = nil
        invitationURL = nil
        invitationExpiresAt = nil
        if !preserveSafetyCode {
            safetyCode = nil
        }
        isHostApprovalPending = false
        errorMessage = nil
        phase = preserveSafetyCode ? .verifying : .finalizing
    }

    private func requestPendingPairingAbort() {
        guard
            let current = pendingPairForRecovery,
            (
                current.role == .host
                    && current.finalizationState
                        == .provisionMayHaveBeenStored
                || current.role == .joiner
                    && (
                        current.finalizationState
                            == .waitingForProvision
                        || current.finalizationState
                            == .provisionStagedAwaitingMergeApproval
                    )
            )
        else {
            return
        }
        var pending = current
        pending.remoteDeviceID = nil
        pending.archiveHash = Data()
        pending.finalizationState = .abortMayHaveBeenStored
        do {
            try credentialStore.savePending(pending)
        } catch {
            errorMessage =
                "\(Self.displayMessage(for: error)) Pairing has not been cancelled."
            return
        }
        pairingTask?.cancel()
        pairingTask = nil
        if let pairingSocket {
            Task {
                await pairingSocket.cancel()
            }
        }
        self.pairingSocket = nil
        beginPairingFinalization(pending)
        startPendingPairingFinalization()
    }

    private func startPendingPairingFinalization() {
        guard
            isPairingFinalizationLocked,
            !hasPairingReplicaConflict,
            pairingTask == nil,
            let pending = pendingPairForRecovery
        else {
            return
        }
        let attemptID = pairingAttemptID ?? UUID()
        pairingAttemptID = attemptID
        pairingTask = Task { [weak self] in
            await self?.runPairingFinalization(
                pending,
                attemptID: attemptID
            )
        }
    }

    private func runPairingFinalization(
        _: PendingPair,
        attemptID: UUID
    ) async {
        var failureCount = 0
        while isCurrentPairingAttempt(attemptID) {
            guard let pending = pendingPairForRecovery else {
                return
            }
            do {
                switch pending.role {
                case .host:
                    try await finalizeHostPairing(
                        pending,
                        attemptID: attemptID
                    )
                case .joiner:
                    try await finalizeJoinerPairing(
                        pending,
                        attemptID: attemptID
                    )
                }
                return
            } catch is CancellationError {
                return
            } catch PairingFinalizationRetry.stateAdvanced {
                failureCount = 0
                errorMessage = nil
                continue
            } catch PairingFinalizationRetry.waitingForPeerDecision {
                failureCount = 0
                errorMessage = nil
            } catch {
                if
                    pending.role == .joiner,
                    Self.isPairingReplicaConflict(error)
                {
                    pairingTask = nil
                    phase = .finalizing
                    await handleJoinerMergeDecision(pending)
                    return
                }
                failureCount += 1
                errorMessage =
                    "\(Self.displayMessage(for: error)) This saved step will retry."
            }
            guard isCurrentPairingAttempt(attemptID) else {
                return
            }
            phase = .finalizing
            let multiplier = UInt64(1 << min(failureCount, 3))
            let delay = pairingRetryDelayNanoseconds.multipliedReportingOverflow(
                by: max(1, multiplier)
            )
            do {
                try await Task.sleep(
                    nanoseconds: delay.overflow
                        ? UInt64.max
                        : delay.partialValue
                )
            } catch {
                return
            }
        }
    }

    private func finalizeHostPairing(
        _ pending: PendingPair,
        attemptID: UUID
    ) async throws {
        try requireCurrentPairingAttempt(attemptID)
        guard pending.role == .host else {
            throw SyncError.invalidCredentials
        }
        switch pending.finalizationState {
        case .abortAcknowledgementMayHaveBeenStored:
            try await finishConsumedPairingAbort(
                pending,
                attemptID: attemptID
            )
            return
        case .abortMayHaveBeenStored:
            let abortMailbox = try PairingAbortMailbox(
                pairRoot: pending.pairRoot,
                pairID: pending.pairID,
                senderRole: .host
            )
            let abort = try abortMailbox.seal(
                senderDeviceID: deviceID.bytes
            )
            let terminalAction = try TerminalPairingAction(
                kind: .abort,
                proof: pending,
                route: abortMailbox.route,
                authorization: abortMailbox.authorization,
                envelope: abort
            )
            try retainTerminalPairingAction(terminalAction)
            let receipts = try await mailboxTransport.put(
                route: abortMailbox.route,
                authorization: abortMailbox.authorization,
                messages: [abort]
            )
            try validatePairingPut(receipts, envelopes: [abort])
            try requireCurrentPairingAttempt(attemptID)
            try credentialStore.upsertTerminalPairingActionThenClearPending(
                terminalAction
            )
            terminalPairingActions =
                try credentialStore.terminalPairingActions()
            try finishCancelledPairing()
            return
        case .provisionMayHaveBeenStored:
            if let abort = try await fetchPairingAbort(
                pairRoot: pending.pairRoot,
                pairID: pending.pairID,
                senderRole: .joiner
            ) {
                try requireCurrentPairingAttempt(attemptID)
                try await persistAndFinishConsumedPairingAbort(
                    pending,
                    cursor: abort.cursor,
                    senderDeviceID: abort.senderDeviceID,
                    attemptID: attemptID
                )
                return
            }
            let archive = try replica.exportProvisioningArchive()
            guard
                archive.count <= ProtocolLimits.provisioningArchiveBytes,
                archive.sha256 == pending.archiveHash
            else {
                throw SyncError.pairingReplicaConflict
            }
            let provisionMailbox = try PairingProvisionMailbox(
                pairRoot: pending.pairRoot,
                pairID: pending.pairID
            )
            let groupProvision = try groupProvisionFields(
                forInvite: credentials
            )
            let envelopes = try provisionMailbox.seal(
                archive: archive,
                hostDeviceID: deviceID.bytes,
                groupID: groupProvision?.groupID,
                epoch: groupProvision?.epoch,
                groupRoot: groupProvision?.groupRoot,
                membershipGeneration: groupProvision?.membershipGeneration,
                memberDeviceIDs: groupProvision?.memberDeviceIDs
            )
            try await putPairingEnvelopes(
                envelopes,
                route: provisionMailbox.route,
                authorization: provisionMailbox.authorization
            )
            try requireCurrentPairingAttempt(attemptID)

            let readyMailbox = try PairingReadyMailbox(
                pairRoot: pending.pairRoot,
                pairID: pending.pairID,
                hostDeviceID: deviceID.bytes,
                archiveHash: pending.archiveHash
            )
            let ready = try await fetchPairingReady(
                from: readyMailbox
            )
            try requireCurrentPairingAttempt(attemptID)
            guard
                ready.record.joinerDeviceID.count == 16,
                ready.record.joinerDeviceID != deviceID.bytes
            else {
                throw SyncError.invalidPairMessage
            }
            var committed = pending
            committed.remoteDeviceID = ready.record.joinerDeviceID
            committed.finalizationState =
                .commitMarkerMayHaveBeenStored
            try credentialStore.savePending(committed)
            pendingPairForRecovery = committed
            throw PairingFinalizationRetry.stateAdvanced
        case .commitMarkerMayHaveBeenStored:
            if let abort = try await fetchPairingAbort(
                pairRoot: pending.pairRoot,
                pairID: pending.pairID,
                senderRole: .joiner
            ) {
                try requireCurrentPairingAttempt(attemptID)
                try await persistAndFinishConsumedPairingAbort(
                    pending,
                    cursor: abort.cursor,
                    senderDeviceID: abort.senderDeviceID,
                    attemptID: attemptID
                )
                return
            }
        case .waitingForProvision,
             .provisionStagedAwaitingMergeApproval,
             .readyMayHaveBeenStored,
             nil:
            throw SyncError.invalidCredentials
        }

        try requireCurrentPairingAttempt(attemptID)
        let record = try pairingCommitRecord(for: pending)
        let markerMailbox = try PairingCommitMailbox(
            pairRoot: pending.pairRoot,
            record: record,
            senderRole: .host
        )
        let marker = try markerMailbox.seal()
        let receipts = try await mailboxTransport.put(
            route: markerMailbox.route,
            authorization: markerMailbox.authorization,
            messages: [marker]
        )
        try validatePairingPut(receipts, envelopes: [marker])
        try requireCurrentPairingAttempt(attemptID)

        let resolvedCredentials = try groupCredentials(for: pending)
        if credentials != nil {
            try credentialStore.saveActive(resolvedCredentials)
            credentials = resolvedCredentials
            try await publishMembershipSnapshot(resolvedCredentials)
        } else {
            try credentialStore.clearMailboxCheckpoint()
            try credentialStore.saveActive(resolvedCredentials)
            credentials = resolvedCredentials
            isPaired = true
        }

        let receiptMailbox = try PairingCommitMailbox(
            pairRoot: pending.pairRoot,
            record: record,
            senderRole: .joiner
        )
        let receiptCursor = try await fetchPairingRecord(
            from: receiptMailbox
        )
        try requireCurrentPairingAttempt(attemptID)
        try credentialStore.clearPending()
        pendingPairForRecovery = nil
        pendingGroupJoinSnapshot = nil
        finishPairing(resolvedCredentials, attemptID: attemptID)
        cleanPairingMailboxes(
            pending: pending,
            markerMailbox: markerMailbox,
            receiptMailbox: receiptMailbox,
            receiptCursor: receiptCursor
        )
    }

    private func finalizeJoinerPairing(
        _ pending: PendingPair,
        attemptID: UUID
    ) async throws {
        try requireCurrentPairingAttempt(attemptID)
        guard pending.role == .joiner else {
            throw SyncError.invalidCredentials
        }
        switch pending.finalizationState {
        case .abortAcknowledgementMayHaveBeenStored:
            try await finishConsumedPairingAbort(
                pending,
                attemptID: attemptID
            )
            return
        case .abortMayHaveBeenStored:
            let abortMailbox = try PairingAbortMailbox(
                pairRoot: pending.pairRoot,
                pairID: pending.pairID,
                senderRole: .joiner
            )
            let abort = try abortMailbox.seal(
                senderDeviceID: deviceID.bytes
            )
            let terminalAction = try TerminalPairingAction(
                kind: .abort,
                proof: pending,
                route: abortMailbox.route,
                authorization: abortMailbox.authorization,
                envelope: abort
            )
            try retainTerminalPairingAction(terminalAction)
            let receipts = try await mailboxTransport.put(
                route: abortMailbox.route,
                authorization: abortMailbox.authorization,
                messages: [abort]
            )
            try validatePairingPut(receipts, envelopes: [abort])
            try requireCurrentPairingAttempt(attemptID)
            try credentialStore.upsertTerminalPairingActionThenClearPending(
                terminalAction
            )
            terminalPairingActions =
                try credentialStore.terminalPairingActions()
            try finishCancelledPairing()
            return
        case .waitingForProvision:
            if let abort = try await fetchPairingAbort(
                pairRoot: pending.pairRoot,
                pairID: pending.pairID,
                senderRole: .host
            ) {
                try requireCurrentPairingAttempt(attemptID)
                try await persistAndFinishConsumedPairingAbort(
                    pending,
                    cursor: abort.cursor,
                    senderDeviceID: abort.senderDeviceID,
                    attemptID: attemptID
                )
                return
            }
            let provisionMailbox = try PairingProvisionMailbox(
                pairRoot: pending.pairRoot,
                pairID: pending.pairID
            )
            let provision = try await fetchPairingProvision(
                from: provisionMailbox
            )
            try requireCurrentPairingAttempt(attemptID)
            guard
                provision.payload.archive.count
                    <= ProtocolLimits.provisioningArchiveBytes,
                provision.payload.archiveHash.count == 32,
                provision.payload.archive.sha256
                    == provision.payload.archiveHash,
                provision.payload.hostDeviceID.count == 16,
                provision.payload.hostDeviceID != deviceID.bytes
            else {
                throw SyncError.invalidPairMessage
            }
            let imported = try ReplicaProvisioningArchive.decodeCanonical(
                from: provision.payload.archive
            )
            guard imported.sourceDeviceID.bytes
                    == provision.payload.hostDeviceID
            else {
                throw SyncError.invalidPairMessage
            }
            if provision.payload.isGroupJoin {
                guard
                    let groupID = provision.payload.groupID,
                    let epoch = provision.payload.epoch,
                    let groupRoot = provision.payload.groupRoot,
                    let membershipGeneration =
                        provision.payload.membershipGeneration,
                    let memberDeviceIDs = provision.payload.memberDeviceIDs,
                    memberDeviceIDs.contains(provision.payload.hostDeviceID),
                    !memberDeviceIDs.contains(deviceID.bytes)
                else {
                    throw SyncError.invalidPairMessage
                }
                var roster = memberDeviceIDs
                roster.append(deviceID.bytes)
                pendingGroupJoinSnapshot = GroupProvisionFields(
                    groupID: groupID,
                    epoch: epoch,
                    groupRoot: groupRoot,
                    membershipGeneration: membershipGeneration,
                    memberDeviceIDs: roster
                )
            } else {
                pendingGroupJoinSnapshot = nil
            }
            if FileManager.default.fileExists(
                atPath: pairingStagingURL.path
            ) {
                let staged = try TaskReplica(
                    deviceID: deviceID,
                    persistenceURL: pairingStagingURL
                )
                guard try staged.matchesProvisioningArchive(
                    sourceDeviceID: imported.sourceDeviceID,
                    archiveHash: provision.payload.archiveHash
                ) else {
                    throw SyncError.invalidPairMessage
                }
            } else {
                _ = try TaskReplica.provision(
                    deviceID: deviceID,
                    from: provision.payload.archive,
                    persistenceURL: pairingStagingURL
                )
            }
            if FileManager.default.fileExists(atPath: pairingMergedURL.path) {
                try FileManager.default.removeItem(at: pairingMergedURL)
            }
            var staged = pending
            staged.remoteDeviceID = provision.payload.hostDeviceID
            staged.archiveHash = provision.payload.archiveHash
            let isAlreadyIdentical = try replica.matchesProvisioningArchive(
                sourceDeviceID: imported.sourceDeviceID,
                archiveHash: provision.payload.archiveHash
            )
            staged.finalizationState =
                replica.isEmpty || isAlreadyIdentical
                ? .readyMayHaveBeenStored
                : .provisionStagedAwaitingMergeApproval
            try credentialStore.savePending(staged)
            pendingPairForRecovery = staged
            safetyCode = nil
            phase = .finalizing
            if staged.finalizationState
                == .provisionStagedAwaitingMergeApproval
            {
                throw SyncError.pairingReplicaConflict
            }
            throw PairingFinalizationRetry.stateAdvanced
        case .provisionStagedAwaitingMergeApproval:
            if let abort = try await fetchPairingAbort(
                pairRoot: pending.pairRoot,
                pairID: pending.pairID,
                senderRole: .host
            ) {
                try requireCurrentPairingAttempt(attemptID)
                try await persistAndFinishConsumedPairingAbort(
                    pending,
                    cursor: abort.cursor,
                    senderDeviceID: abort.senderDeviceID,
                    attemptID: attemptID
                )
                return
            }
            _ = try validatedStagedJoinerReplica(pending)
            throw SyncError.pairingReplicaConflict
        case .readyMayHaveBeenStored:
            _ = try validatedPreparedJoinerReplica(pending)
            guard let hostDeviceID = pending.remoteDeviceID else {
                throw SyncError.invalidCredentials
            }
            let readyMailbox = try PairingReadyMailbox(
                pairRoot: pending.pairRoot,
                pairID: pending.pairID,
                hostDeviceID: hostDeviceID,
                archiveHash: pending.archiveHash
            )
            let ready = try readyMailbox.seal(
                joinerDeviceID: deviceID.bytes
            )
            let receipts = try await mailboxTransport.put(
                route: readyMailbox.route,
                authorization: readyMailbox.authorization,
                messages: [ready]
            )
            try validatePairingPut(receipts, envelopes: [ready])
            try requireCurrentPairingAttempt(attemptID)
        case .provisionMayHaveBeenStored,
             .commitMarkerMayHaveBeenStored,
             nil:
            throw SyncError.invalidCredentials
        }

        if let abort = try await fetchPairingAbort(
            pairRoot: pending.pairRoot,
            pairID: pending.pairID,
            senderRole: .host
        ) {
            try requireCurrentPairingAttempt(attemptID)
            try await persistAndFinishConsumedPairingAbort(
                pending,
                cursor: abort.cursor,
                senderDeviceID: abort.senderDeviceID,
                attemptID: attemptID
            )
            return
        }

        let record = try pairingCommitRecord(for: pending)
        let markerMailbox = try PairingCommitMailbox(
            pairRoot: pending.pairRoot,
            record: record,
            senderRole: .host
        )
        let resolvedCredentials = try groupCredentials(for: pending)
        var markerCursor: UInt64?

        if let credentials {
            guard credentials == resolvedCredentials else {
                throw SyncError.invalidCredentials
            }
            try validateInstalledJoinerReplica(pending)
        } else {
            markerCursor = try await fetchPairingRecord(
                from: markerMailbox
            )
            try requireCurrentPairingAttempt(attemptID)
            try installOrValidateStagedJoinerReplica(pending)
            try credentialStore.clearMailboxCheckpoint()
            try credentialStore.saveActive(resolvedCredentials)
            credentials = resolvedCredentials
            isPaired = true
        }

        let receiptMailbox = try PairingCommitMailbox(
            pairRoot: pending.pairRoot,
            record: record,
            senderRole: .joiner
        )
        let receipt = try receiptMailbox.seal()
        let terminalAction = try TerminalPairingAction(
            kind: .receipt,
            proof: pending,
            route: receiptMailbox.route,
            authorization: receiptMailbox.authorization,
            envelope: receipt
        )
        try retainTerminalPairingAction(terminalAction)
        let receipts = try await mailboxTransport.put(
            route: receiptMailbox.route,
            authorization: receiptMailbox.authorization,
            messages: [receipt]
        )
        try validatePairingPut(receipts, envelopes: [receipt])
        try requireCurrentPairingAttempt(attemptID)
        try credentialStore.upsertTerminalPairingActionThenClearPending(
            terminalAction
        )
        terminalPairingActions =
            try credentialStore.terminalPairingActions()
        pendingPairForRecovery = nil
        if FileManager.default.fileExists(atPath: pairingStagingURL.path) {
            try? FileManager.default.removeItem(at: pairingStagingURL)
        }
        if FileManager.default.fileExists(atPath: pairingMergedURL.path) {
            try? FileManager.default.removeItem(at: pairingMergedURL)
        }
        if FileManager.default.fileExists(
            atPath: pairingConflictBackupURL.path
        ) {
            try? FileManager.default.removeItem(
                at: pairingConflictBackupURL
            )
        }
        finishPairing(resolvedCredentials, attemptID: attemptID)

        if let markerCursor {
            Task {
                try? await mailboxTransport.acknowledge(
                    route: markerMailbox.route,
                    authorization: markerMailbox.authorization,
                    through: markerCursor
                )
            }
        }
    }

    private func pairingCommitRecord(
        for pending: PendingPair
    ) throws -> PairingCommitRecord {
        try Self.validate(pending, deviceID: deviceID)
        guard let remoteDeviceID = pending.remoteDeviceID else {
            throw SyncError.invalidCredentials
        }
        return try PairingCommitRecord(
            pairID: pending.pairID,
            hostDeviceID: pending.role == .host
                ? pending.localDeviceID
                : remoteDeviceID,
            joinerDeviceID: pending.role == .joiner
                ? pending.localDeviceID
                : remoteDeviceID,
            archiveHash: pending.archiveHash
        )
    }

    private func pairingCredentials(
        for pending: PendingPair
    ) throws -> PairCredentials {
        try Self.validate(pending, deviceID: deviceID)
        guard let remoteDeviceID = pending.remoteDeviceID else {
            throw SyncError.invalidCredentials
        }
        return PairCredentials(
            pairRoot: pending.pairRoot,
            pairID: pending.pairID,
            role: pending.role,
            localDeviceID: pending.localDeviceID,
            remoteDeviceID: remoteDeviceID,
            pairingArchiveHash: pending.role == .joiner
                ? pending.archiveHash
                : nil
        )
    }

    /// When already linked, provision carries the existing group secret + roster
    /// (including a placeholder slot for the joiner filled after ready).
    private func groupProvisionFields(
        forInvite existing: GroupCredentials?
    ) throws -> GroupProvisionFields? {
        guard let existing else {
            return nil
        }
        try existing.validate(deviceID: deviceID)
        guard !existing.isAtCapacity else {
            throw SyncError.groupAtCapacity
        }
        return GroupProvisionFields(
            groupID: existing.groupID,
            epoch: existing.epoch,
            groupRoot: existing.groupRoot,
            membershipGeneration: existing.membershipGeneration &+ 1,
            // Joiner ID is not known yet; host rewrites after ready using
            // full roster in groupCredentials(for:). Placeholder is issuer-only
            // so validation still includes host; joiner is appended later.
            memberDeviceIDs: existing.activeMemberDeviceIDs
        )
    }

    private func groupCredentials(
        for pending: PendingPair
    ) throws -> GroupCredentials {
        let pair = try pairingCredentials(for: pending)
        // Joiner admitted into an existing group via provision snapshot.
        if let snapshot = pendingGroupJoinSnapshot {
            guard snapshot.memberDeviceIDs.contains(deviceID.bytes) else {
                throw SyncError.invalidCredentials
            }
            let members = snapshot.memberDeviceIDs.map {
                GroupMember(deviceID: $0, joinedEpoch: snapshot.epoch)
            }
            return GroupCredentials(
                groupID: snapshot.groupID,
                epoch: snapshot.epoch,
                groupRoot: snapshot.groupRoot,
                localDeviceID: deviceID.bytes,
                members: members,
                membershipGeneration: snapshot.membershipGeneration,
                foundingPairRole: nil,
                pairingArchiveHash: pending.archiveHash
            )
        }
        // Issuer already linked — add joiner to existing group.
        if let existing = credentials, existing.activeMemberCount >= 2 {
            guard let joinerID = pending.remoteDeviceID else {
                throw SyncError.invalidCredentials
            }
            return try existing.addingMember(deviceID: joinerID)
        }
        // Founding ceremony: pair root becomes group root.
        return GroupCredentials(pair: pair)
    }

    private func publishMembershipSnapshot(
        _ credentials: GroupCredentials,
        rekeySeed: Data? = nil,
        previousGroupRoot: Data? = nil
    ) async throws {
        let signingKey = try credentials.signingPrivateKey()
        let roster = credentials.activeMembers.map(GroupMembershipRosterEntry.init(member:))
        let snapshot = try GroupMembershipSnapshot.signed(
            groupID: credentials.groupID,
            epoch: credentials.epoch,
            membershipGeneration: credentials.membershipGeneration,
            roster: roster,
            issuerDeviceID: credentials.localDeviceID,
            rekeySeed: rekeySeed,
            signingKey: signingKey
        )
        // Seal under previous epoch root when rekeying so peers still on old root can open.
        let sealRoot = previousGroupRoot ?? credentials.groupRoot
        let sealEpoch = rekeySeed == nil ? credentials.epoch : max(1, credentials.epoch &- 1)
        for remote in credentials.remoteActiveDeviceIDs {
            let mailbox = try GroupMembershipMailbox(
                groupRoot: sealRoot,
                groupID: credentials.groupID,
                epoch: sealEpoch,
                senderDeviceID: credentials.localDeviceID,
                recipientDeviceID: remote
            )
            let envelope = try mailbox.seal(snapshot)
            _ = try await mailboxTransport.put(
                route: mailbox.route,
                authorization: mailbox.authorization,
                messages: [envelope]
            )
        }
    }

    /// Voluntary leave: publish roster without self + rekey seed under the current root.
    private func publishLocalLeaveMembership(
        _ credentials: GroupCredentials
    ) async {
        do {
            let leave = try credentials.preparingLocalLeave()
            let signingKey = try credentials.signingPrivateKey()
            let snapshot = try GroupMembershipSnapshot.signed(
                groupID: credentials.groupID,
                epoch: leave.nextEpoch,
                membershipGeneration: leave.nextGeneration,
                roster: leave.remainingMembers.map(GroupMembershipRosterEntry.init(member:)),
                issuerDeviceID: credentials.localDeviceID,
                rekeySeed: leave.rekeySeed,
                signingKey: signingKey
            )
            for remote in leave.remainingMembers.map(\.deviceID) {
                let mailbox = try GroupMembershipMailbox(
                    groupRoot: credentials.groupRoot,
                    groupID: credentials.groupID,
                    epoch: credentials.epoch,
                    senderDeviceID: credentials.localDeviceID,
                    recipientDeviceID: remote
                )
                let envelope = try mailbox.seal(snapshot)
                _ = try await mailboxTransport.put(
                    route: mailbox.route,
                    authorization: mailbox.authorization,
                    messages: [envelope]
                )
            }
        } catch {
            // Best-effort; local leave already clears credentials.
        }
    }

    private func putPairingEnvelopes(
        _ envelopes: [StoredMailboxEnvelope],
        route: Data,
        authorization: Data
    ) async throws {
        for start in stride(from: 0, to: envelopes.count, by: 4) {
            let end = min(start + 4, envelopes.count)
            let batch = Array(envelopes[start..<end])
            let receipts = try await mailboxTransport.put(
                route: route,
                authorization: authorization,
                messages: batch
            )
            try validatePairingPut(receipts, envelopes: batch)
        }
    }

    private func validatePairingPut(
        _ receipts: [MailboxStoredReceipt],
        envelopes: [StoredMailboxEnvelope]
    ) throws {
        let expectedIDs = Set(envelopes.map(\.messageID))
        let receivedIDs = Set(receipts.map(\.messageID))
        guard
            receipts.count == envelopes.count,
            expectedIDs.count == envelopes.count,
            receivedIDs == expectedIDs,
            (receipts.allSatisfy { $0.cursor > 0 })
        else {
            throw MailboxTransportError.invalidResponse
        }
    }

    private func fetchPairingProvision(
        from mailbox: PairingProvisionMailbox
    ) async throws -> (
        payload: PairingProvisionPayload,
        cursor: UInt64
    ) {
        var cursor: UInt64 = 0
        var envelopes: [StoredMailboxEnvelope] = []
        while true {
            let page = try await mailboxTransport.fetch(
                route: mailbox.route,
                authorization: mailbox.authorization,
                after: cursor,
                limit: 4
            )
            envelopes.append(contentsOf: page.messages.map(\.envelope))
            cursor = page.nextCursor
            if !page.hasMore {
                break
            }
        }
        guard !envelopes.isEmpty else {
            throw PairingFinalizationRetry.waitingForPeerDecision
        }
        do {
            return (try mailbox.open(envelopes), cursor)
        } catch MailboxCryptoError.incompleteEnvelopeSet {
            throw PairingFinalizationRetry.waitingForPeerDecision
        }
    }

    private func fetchPairingReady(
        from mailbox: PairingReadyMailbox
    ) async throws -> (
        record: PairingReadyRecord,
        cursor: UInt64
    ) {
        let page = try await mailboxTransport.fetch(
            route: mailbox.route,
            authorization: mailbox.authorization,
            after: 0,
            limit: ProtocolLimits.mailboxFetchCount
        )
        guard !page.messages.isEmpty else {
            throw PairingFinalizationRetry.waitingForPeerDecision
        }
        var record: PairingReadyRecord?
        for message in page.messages {
            let opened = try mailbox.open(message.envelope)
            if let record, record != opened {
                throw SyncError.invalidPairMessage
            }
            record = opened
        }
        guard let record else {
            throw PairingFinalizationRetry.waitingForPeerDecision
        }
        return (record, page.nextCursor)
    }

    private func fetchPairingAbort(
        pairRoot: Data,
        pairID: Data,
        senderRole: DeviceRole
    ) async throws -> (cursor: UInt64, senderDeviceID: Data)? {
        let mailbox = try PairingAbortMailbox(
            pairRoot: pairRoot,
            pairID: pairID,
            senderRole: senderRole
        )
        let page = try await mailboxTransport.fetch(
            route: mailbox.route,
            authorization: mailbox.authorization,
            after: 0,
            limit: ProtocolLimits.mailboxFetchCount
        )
        guard !page.messages.isEmpty else {
            return nil
        }
        var senderDeviceID: Data?
        for message in page.messages {
            let record = try mailbox.open(message.envelope)
            guard
                record.senderRole == senderRole,
                record.senderDeviceID.count == 16,
                record.senderDeviceID != deviceID.bytes,
                senderDeviceID == nil
                    || senderDeviceID == record.senderDeviceID
            else {
                throw SyncError.invalidPairMessage
            }
            senderDeviceID = record.senderDeviceID
        }
        guard let senderDeviceID else {
            throw SyncError.invalidPairMessage
        }
        return (page.nextCursor, senderDeviceID)
    }

    private func persistAndFinishConsumedPairingAbort(
        _ pending: PendingPair,
        cursor: UInt64,
        senderDeviceID: Data,
        attemptID: UUID
    ) async throws {
        var recovery = pending
        if let remoteDeviceID = recovery.remoteDeviceID {
            guard remoteDeviceID == senderDeviceID else {
                throw SyncError.invalidPairMessage
            }
        } else {
            recovery.remoteDeviceID = senderDeviceID
        }
        recovery.finalizationState =
            .abortAcknowledgementMayHaveBeenStored
        recovery.abortAcknowledgementCursor = cursor
        try credentialStore.savePending(recovery)
        pendingPairForRecovery = recovery
        try await finishConsumedPairingAbort(
            recovery,
            attemptID: attemptID
        )
    }

    private func finishConsumedPairingAbort(
        _ pending: PendingPair,
        attemptID: UUID
    ) async throws {
        try Self.validate(pending, deviceID: deviceID)
        guard
            pending.finalizationState
                == .abortAcknowledgementMayHaveBeenStored,
            pending.abortAcknowledgementCursor != nil
        else {
            throw SyncError.invalidCredentials
        }
        let mailbox = try PairingAbortMailbox(
            pairRoot: pending.pairRoot,
            pairID: pending.pairID,
            senderRole: pending.role.opposite
        )
        guard let senderDeviceID = pending.remoteDeviceID else {
            throw SyncError.invalidCredentials
        }
        let envelope = try mailbox.seal(
            senderDeviceID: senderDeviceID
        )
        let stored = try await mailboxTransport.put(
            route: mailbox.route,
            authorization: mailbox.authorization,
            messages: [envelope]
        )
        try validatePairingPut(stored, envelopes: [envelope])
        guard let receipt = stored.first else {
            throw SyncError.invalidPairMessage
        }
        if !receipt.acknowledged {
            try await mailboxTransport.acknowledge(
                route: mailbox.route,
                authorization: mailbox.authorization,
                through: receipt.cursor
            )
            let verified = try await mailboxTransport.put(
                route: mailbox.route,
                authorization: mailbox.authorization,
                messages: [envelope]
            )
            try validatePairingPut(verified, envelopes: [envelope])
            guard verified.first?.acknowledged == true else {
                throw PairingFinalizationRetry.waitingForPeerDecision
            }
        }
        try requireCurrentPairingAttempt(attemptID)
        try finishCancelledPairing()
    }

    private func fetchPairingRecord(
        from mailbox: PairingCommitMailbox
    ) async throws -> UInt64 {
        let page = try await mailboxTransport.fetch(
            route: mailbox.route,
            authorization: mailbox.authorization,
            after: 0,
            limit: ProtocolLimits.mailboxFetchCount
        )
        guard !page.messages.isEmpty else {
            throw PairingFinalizationRetry.waitingForPeerDecision
        }
        for message in page.messages {
            _ = try mailbox.open(message.envelope)
        }
        return page.nextCursor
    }

    private func finishCancelledPairing() throws {
        try credentialStore.clearPending()
        if FileManager.default.fileExists(atPath: pairingStagingURL.path) {
            try? FileManager.default.removeItem(at: pairingStagingURL)
        }
        if FileManager.default.fileExists(atPath: pairingMergedURL.path) {
            try? FileManager.default.removeItem(at: pairingMergedURL)
        }
        if FileManager.default.fileExists(
            atPath: pairingConflictBackupURL.path
        ) {
            try? FileManager.default.removeItem(
                at: pairingConflictBackupURL
            )
        }
        pendingPairForRecovery = nil
        pairingArtifactID = nil
        pairingAttemptID = nil
        pairingTask = nil
        pairingExpiryTask?.cancel()
        pairingExpiryTask = nil
        pairingSocket = nil
        invitationPhrase = nil
        invitationURL = nil
        invitationExpiresAt = nil
        safetyCode = nil
        isHostApprovalPending = false
        isPairingFinalizationLocked = false
        hasPairingReplicaConflict = false
        errorMessage = nil
        if credentials != nil {
            phase = channelReady ? .synced : .connecting
            startSyncLoop()
            startMailboxLoop()
        } else {
            phase = .unpaired
        }
        startTerminalPairingLoop()
    }

    private func installOrValidateStagedJoinerReplica(
        _ pending: PendingPair
    ) throws {
        guard pending.role == .joiner else {
            throw SyncError.invalidCredentials
        }
        let prepared = try validatedPreparedJoinerReplica(pending)
        let installed = try TaskReplica(
            deviceID: deviceID,
            persistenceURL: persistenceURL
        )
        if try installed.containsHistory(from: prepared) {
            replica = installed
            publishReplica()
            return
        }
        try prepared.atomicArchiveData().write(
            to: persistenceURL,
            options: .atomic
        )
        try FileManager.default.setAttributes(
            ProtectedStorage.fileAttributes,
            ofItemAtPath: persistenceURL.path
        )
        try validateInstalledJoinerReplica(pending)
    }

    private func validateInstalledJoinerReplica(
        _ pending: PendingPair
    ) throws {
        guard pending.role == .joiner else {
            throw SyncError.invalidCredentials
        }
        let prepared = try validatedPreparedJoinerReplica(pending)
        let installed = try TaskReplica(
            deviceID: deviceID,
            persistenceURL: persistenceURL
        )
        guard try installed.containsHistory(from: prepared) else {
            throw SyncError.invalidPairMessage
        }
        replica = installed
        publishReplica()
    }

    private func validatedStagedJoinerReplica(
        _ pending: PendingPair
    ) throws -> TaskReplica {
        guard FileManager.default.fileExists(atPath: pairingStagingURL.path) else {
            throw SyncError.localStorageUnavailable
        }
        let sourceDeviceID = try ReplicaDeviceID(
            bytes: pending.remoteDeviceID ?? Data()
        )
        let staged = try TaskReplica(
            deviceID: deviceID,
            persistenceURL: pairingStagingURL
        )
        guard try staged.matchesProvisioningArchive(
            sourceDeviceID: sourceDeviceID,
            archiveHash: pending.archiveHash
        ) else {
            throw SyncError.invalidPairMessage
        }
        return staged
    }

    private func persistPreparedJoinerReplica(
        _ prepared: TaskReplica
    ) throws {
        try prepared.atomicArchiveData().write(
            to: pairingMergedURL,
            options: .atomic
        )
        try FileManager.default.setAttributes(
            ProtectedStorage.fileAttributes,
            ofItemAtPath: pairingMergedURL.path
        )
    }

    private func validatedPreparedJoinerReplica(
        _ pending: PendingPair
    ) throws -> TaskReplica {
        if !FileManager.default.fileExists(atPath: pairingStagingURL.path) {
            let sourceDeviceID = try ReplicaDeviceID(
                bytes: pending.remoteDeviceID ?? Data()
            )
            let matchesInstalledBaseline =
                try replica.matchesProvisioningArchive(
                    sourceDeviceID: sourceDeviceID,
                    archiveHash: pending.archiveHash
                )
            guard
                matchesInstalledBaseline,
                !FileManager.default.fileExists(
                    atPath: pairingMergedURL.path
                ),
                !FileManager.default.fileExists(
                    atPath: pairingConflictBackupURL.path
                )
            else {
                throw SyncError.localStorageUnavailable
            }
            return replica
        }
        let staged = try validatedStagedJoinerReplica(pending)
        if FileManager.default.fileExists(atPath: pairingMergedURL.path) {
            let merged = try TaskReplica(
                deviceID: deviceID,
                persistenceURL: pairingMergedURL
            )
            guard try merged.containsHistory(from: staged) else {
                throw SyncError.invalidPairMessage
            }
            return merged
        }
        if FileManager.default.fileExists(
            atPath: pairingConflictBackupURL.path
        ) {
            let local = try TaskReplica(
                deviceID: deviceID,
                persistenceURL: pairingConflictBackupURL
            )
            let merged = try TaskReplica.keepBothCandidate(
                staged: staged,
                local: local,
                pairID: pending.pairID
            )
            try persistPreparedJoinerReplica(merged)
            return merged
        }
        let sourceDeviceID = try ReplicaDeviceID(
            bytes: pending.remoteDeviceID ?? Data()
        )
        let isAlreadyIdentical = try replica.matchesProvisioningArchive(
            sourceDeviceID: sourceDeviceID,
            archiveHash: pending.archiveHash
        )
        guard replica.isEmpty || isAlreadyIdentical else {
            throw SyncError.pairingReplicaConflict
        }
        return staged
    }

    private func cleanPairingMailboxes(
        pending: PendingPair,
        markerMailbox: PairingCommitMailbox,
        receiptMailbox: PairingCommitMailbox,
        receiptCursor: UInt64
    ) {
        guard
            let remoteDeviceID = pending.remoteDeviceID,
            let provisionMailbox = try? PairingProvisionMailbox(
                pairRoot: pending.pairRoot,
                pairID: pending.pairID
            ),
            let readyMailbox = try? PairingReadyMailbox(
                pairRoot: pending.pairRoot,
                pairID: pending.pairID,
                hostDeviceID: pending.localDeviceID,
                archiveHash: pending.archiveHash
            ),
            let hostAbortMailbox = try? PairingAbortMailbox(
                pairRoot: pending.pairRoot,
                pairID: pending.pairID,
                senderRole: .host
            ),
            let joinerAbortMailbox = try? PairingAbortMailbox(
                pairRoot: pending.pairRoot,
                pairID: pending.pairID,
                senderRole: .joiner
            ),
            remoteDeviceID.count == 16
        else {
            return
        }
        Task {
            try? await mailboxTransport.acknowledge(
                route: receiptMailbox.route,
                authorization: receiptMailbox.authorization,
                through: receiptCursor
            )
            try? await mailboxTransport.forget(
                route: markerMailbox.route,
                authorization: markerMailbox.authorization
            )
            try? await mailboxTransport.forget(
                route: provisionMailbox.route,
                authorization: provisionMailbox.authorization
            )
            try? await mailboxTransport.forget(
                route: readyMailbox.route,
                authorization: readyMailbox.authorization
            )
            try? await mailboxTransport.forget(
                route: hostAbortMailbox.route,
                authorization: hostAbortMailbox.authorization
            )
            try? await mailboxTransport.forget(
                route: joinerAbortMailbox.route,
                authorization: joinerAbortMailbox.authorization
            )
        }
    }

    private func finishPairing(
        _ credentials: GroupCredentials,
        attemptID: UUID
    ) {
        guard isCurrentPairingAttempt(attemptID) else {
            return
        }
        self.credentials = credentials
        isPaired = true
        isPairingFinalizationLocked = false
        hasPairingReplicaConflict = false
        keepBothPreview = nil
        pendingPairForRecovery = nil
        pairingArtifactID = nil
        pairingAttemptID = nil
        pairingTask = nil
        pairingExpiryTask?.cancel()
        pairingExpiryTask = nil
        pairingSocket = nil
        invitationPhrase = nil
        invitationURL = nil
        invitationExpiresAt = nil
        safetyCode = nil
        isHostApprovalPending = false
        activePairingRole = nil
        errorMessage = nil
        // Preserve mailbox checkpoints when expanding an existing group.
        if uploadedThroughByRecipient.isEmpty {
            uploadedLocalSequence = 0
        }
        mailboxFailureCount = 0
        nextMailboxAttemptAt = .distantPast
        refreshPendingMailboxCount()
        phase = .connecting
        presentLinkCompleteCelebration()
        startSyncLoop()
        startMailboxLoop()
        startTerminalPairingLoop()
    }

    private func handleJoinerMergeDecision(_ pending: PendingPair) async {
        do {
            let staged = try validatedStagedJoinerReplica(pending)
            let preview = try TaskReplica.keepBothPreview(
                staged: staged,
                local: replica
            )
            keepBothPreview = preview
            if preview.isAdditiveOnly {
                hasPairingReplicaConflict = true
                resolvePairingReplicaConflictKeepingBoth()
                return
            }
            hasPairingReplicaConflict = true
            errorMessage = Self.displayMessage(
                for: SyncError.pairingReplicaConflict
            )
        } catch {
            hasPairingReplicaConflict = true
            errorMessage = Self.displayMessage(for: error)
        }
    }

    private func presentLinkCompleteCelebration() {
        showsLinkCompleteCelebration = true
        linkCompleteCelebrationTask?.cancel()
        linkCompleteCelebrationTask = Task { [weak self] in
            try? await Task.sleep(
                for: .seconds(SyncTiming.linkCompleteCelebrationDuration)
            )
            guard !Task.isCancelled else {
                return
            }
            self?.showsLinkCompleteCelebration = false
            self?.linkCompleteCelebrationTask = nil
        }
    }

    private func pairingFailed(_ error: Error, attemptID: UUID) {
        guard pairingAttemptID == attemptID else {
            return
        }
        if isPairingFinalizationLocked {
            pairingTask = nil
            pairingSocket = nil
            phase = .finalizing
            if Self.isPairingReplicaConflict(error) {
                Task { [weak self] in
                    guard let self, let pending = self.pendingPairForRecovery else {
                        return
                    }
                    await self.handleJoinerMergeDecision(pending)
                }
                return
            }
            errorMessage =
                "\(Self.displayMessage(for: error)) This saved step will retry."
            startPendingPairingFinalization()
            return
        }
        pairingAttemptID = nil
        pairingTask = nil
        pairingExpiryTask?.cancel()
        pairingExpiryTask = nil
        pairingSocket = nil
        invitationPhrase = nil
        invitationURL = nil
        invitationExpiresAt = nil
        isHostApprovalPending = false
        safetyCode = nil
        if isPaired {
            phase = .connecting
            startSyncLoop()
            startMailboxLoop()
        } else {
            do {
                try rollbackPendingPairing()
            } catch {
                hasDurableStorage = false
                phase = .failed
                errorMessage = Self.displayMessage(for: error)
                return
            }
            phase = .failed
            errorMessage = Self.displayMessage(
                for: SyncError.fromTransport(error)
            )
            activePairingRole = nil
        }
    }

    private func startSyncLoop() {
        guard
            appIsActive,
            hasDurableStorage,
            syncTask == nil,
            let credentials
        else {
            return
        }
        syncTask = Task { [weak self] in
            await self?.maintainSync(credentials)
        }
    }

    private func startTerminalPairingLoop() {
        guard
            appIsActive,
            hasDurableStorage,
            terminalPairingTask == nil,
            !terminalPairingActions.isEmpty
        else {
            return
        }
        let loopID = UUID()
        terminalPairingLoopID = loopID
        terminalPairingTask = Task { [weak self] in
            await self?.maintainTerminalPairingActions(loopID: loopID)
        }
    }

    private func maintainTerminalPairingActions(
        loopID: UUID
    ) async {
        var failureCount = 0
        while
            !Task.isCancelled,
            appIsActive,
            hasDurableStorage,
            terminalPairingLoopID == loopID
        {
            let primaryPairID = pendingPairForRecovery?.pairID
            let publishable = terminalPairingActions.filter {
                $0.pairID != primaryPairID
            }
            guard !publishable.isEmpty else {
                break
            }
            var encounteredFailure = false
            for action in publishable {
                do {
                    try action.validate()
                    let envelope = try action.envelope
                    let receipts = try await mailboxTransport.put(
                        route: action.route,
                        authorization: action.authorization,
                        messages: [envelope]
                    )
                    try validatePairingPut(
                        receipts,
                        envelopes: [envelope]
                    )
                    if receipts.contains(where: {
                        $0.messageID == action.messageID
                            && $0.acknowledged
                    }) {
                        try retireTerminalPairingAction(action)
                    }
                } catch is CancellationError {
                    encounteredFailure = true
                    break
                } catch {
                    encounteredFailure = true
                }
                guard
                    !Task.isCancelled,
                    terminalPairingLoopID == loopID
                else {
                    break
                }
            }
            guard
                !Task.isCancelled,
                appIsActive,
                hasDurableStorage,
                terminalPairingLoopID == loopID,
                !terminalPairingActions.isEmpty
            else {
                break
            }
            if encounteredFailure {
                failureCount = min(failureCount + 1, 8)
            } else {
                failureCount = 0
            }
            let delay: UInt64
            if failureCount == 0 {
                delay = 3_600_000_000_000
            } else {
                let multiplier = UInt64(1 << min(failureCount - 1, 5))
                let result =
                    pairingRetryDelayNanoseconds.multipliedReportingOverflow(
                        by: multiplier
                    )
                delay = result.overflow
                    ? UInt64.max
                    : result.partialValue
            }
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                break
            }
        }
        guard terminalPairingLoopID == loopID else {
            return
        }
        terminalPairingTask = nil
        terminalPairingLoopID = nil
    }

    private func retainTerminalPairingAction(
        _ action: TerminalPairingAction
    ) throws {
        try credentialStore.upsertTerminalPairingAction(action)
        terminalPairingActions =
            try credentialStore.terminalPairingActions()
    }

    private func confirmAuthenticatedPeerCompletion(
        _ credentials: GroupCredentials
    ) {
        guard
            self.credentials == credentials,
            let bridge = credentials.pairBridge,
            bridge.role == .joiner,
            let action = terminalPairingActions.first(where: {
                $0.kind == .receipt
                    && $0.pairID == bridge.pairID
                    && $0.role == bridge.role
                    && $0.localDeviceID == bridge.localDeviceID
                    && $0.remoteDeviceID == bridge.remoteDeviceID
            })
        else {
            return
        }
        do {
            try retireTerminalPairingAction(action)
        } catch {
            return
        }
    }

    private func retireTerminalPairingAction(
        _ action: TerminalPairingAction
    ) throws {
        try credentialStore.removeTerminalPairingAction(action.key)
        terminalPairingActions =
            try credentialStore.terminalPairingActions()
        let transport = mailboxTransport
        Task {
            try? await transport.forget(
                route: action.route,
                authorization: action.authorization
            )
        }
    }

    private func startMailboxLoop() {
        guard
            appIsActive,
            hasDurableStorage,
            mailboxPollTask == nil,
            credentials != nil
        else {
            return
        }
        requestMailboxCycle(force: true)
        mailboxPollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    return
                }
                guard
                    let self,
                    self.appIsActive,
                    self.hasDurableStorage,
                    self.credentials != nil
                else {
                    return
                }
                self.requestMailboxCycle(force: false)
            }
        }
    }

    private func requestMailboxCycle(
        force: Bool,
        allowInactive: Bool = false
    ) {
        guard
            hasDurableStorage,
            credentials != nil,
            appIsActive || allowInactive,
            force || Date() >= nextMailboxAttemptAt
        else {
            return
        }
        mailboxCycleRequested = true
        guard mailboxCycleTask == nil, let credentials else {
            return
        }
        let cycleID = UUID()
        mailboxCycleID = cycleID
        mailboxCycleTask = Task { [weak self] in
            await self?.drainMailboxCycles(
                credentials: credentials,
                cycleID: cycleID
            )
        }
    }

    private func drainMailboxCycles(
        credentials: GroupCredentials,
        cycleID: UUID
    ) async {
        while
            !Task.isCancelled,
            hasDurableStorage,
            self.credentials == credentials,
            mailboxCycleRequested
        {
            mailboxCycleRequested = false
            mailboxState = .syncing
            do {
                try await performMailboxCycle(credentials: credentials)
                mailboxFailureCount = 0
                nextMailboxAttemptAt = .distantPast
                mailboxErrorMessage = nil
                mailboxError = nil
                mailboxRequiresRepair = !terminalPairingJournalUsable
                mailboxCapacityReached = false
                mailboxState = .available
            } catch is CancellationError {
                break
            } catch {
                guard
                    !Task.isCancelled,
                    hasDurableStorage,
                    self.credentials == credentials,
                    mailboxCycleID == cycleID
                else {
                    break
                }
                mailboxFailureCount = min(mailboxFailureCount + 1, 16)
                let exponent = min(mailboxFailureCount - 1, 4)
                let retryDelay = min(
                    Double(2 * (1 << exponent)),
                    30
                ) + Double.random(in: 0...0.5)
                nextMailboxAttemptAt = Date().addingTimeInterval(retryDelay)
                mailboxError = SyncError.fromTransport(error) as? SyncError
                mailboxErrorMessage = Self.displayMessage(for: error)
                mailboxRequiresRepair = Self.requiresMailboxRepair(error)
                mailboxCapacityReached =
                    Self.isMailboxCapacityError(error)
                mailboxState = .unavailable
                if mailboxRequiresRepair {
                    nextMailboxAttemptAt = .distantFuture
                }
                mailboxCycleRequested = false
                break
            }
        }

        guard mailboxCycleID == cycleID else {
            return
        }
        mailboxCycleTask = nil
        mailboxCycleID = nil
        if mailboxCycleRequested,
           hasDurableStorage,
           self.credentials == credentials
        {
            requestMailboxCycle(
                force: true,
                allowInactive: !appIsActive
            )
        }
    }

    private func performMailboxCycle(
        credentials: GroupCredentials
    ) async throws {
        guard hasDurableStorage else {
            throw SyncError.localStorageUnavailable
        }
        try validate(credentials)
        let mailbox = try GroupMailbox(credentials: credentials)
        let uploadCompletion = MailboxUploadCompletion()
        async let uploadError = runMailboxUpload(
            mailbox,
            credentials: credentials,
            completion: uploadCompletion
        )
        async let receiveError = pollMailboxInbound(
            mailbox,
            credentials: credentials,
            until: uploadCompletion
        )
        let (outboundError, inboundError) = await (
            uploadError,
            receiveError
        )
        if Task.isCancelled
            || outboundError is CancellationError
            || inboundError is CancellationError
        {
            throw CancellationError()
        }
        if let outboundError {
            throw outboundError
        }
        if let inboundError {
            throw inboundError
        }
        try await receiveMembershipUpdates(credentials: credentials)
    }

    private func runMailboxUpload(
        _ mailbox: GroupMailbox,
        credentials: GroupCredentials,
        completion: MailboxUploadCompletion
    ) async -> Error? {
        let error = await mailboxOperationError {
            try await uploadMailboxOperations(
                mailbox,
                credentials: credentials
            )
        }
        await completion.finish()
        return error
    }

    private func pollMailboxInbound(
        _ mailbox: GroupMailbox,
        credentials: GroupCredentials,
        until uploadCompletion: MailboxUploadCompletion
    ) async -> Error? {
        while !Task.isCancelled {
            if let error = await mailboxOperationError({
                try await receiveMailboxOperations(
                    mailbox,
                    credentials: credentials
                )
            }) {
                return error
            }
            if await uploadCompletion.isFinished {
                return nil
            }
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return CancellationError()
            }
        }
        return CancellationError()
    }

    private func mailboxOperationError(
        _ operation: () async throws -> Void
    ) async -> Error? {
        do {
            try await operation()
            return nil
        } catch {
            return error
        }
    }

    private func uploadMailboxOperations(
        _ mailbox: GroupMailbox,
        credentials: GroupCredentials
    ) async throws {
        while !Task.isCancelled {
            let localSequence = replica.versionVector[deviceID]
            let recipients = credentials.remoteActiveDeviceIDs
            guard !recipients.isEmpty else {
                refreshPendingMailboxCount()
                return
            }

            var anyProgress = false
            for recipient in recipients {
                let uploaded = uploadedThroughByRecipient[recipient]
                    ?? uploadedLocalSequence
                guard uploaded <= localSequence else {
                    throw SyncError.invalidCredentials
                }
                let pending = replica.retainedOperations
                    .filter {
                        $0.originDeviceID == deviceID
                            && $0.originSequence > uploaded
                    }
                    .sorted {
                        $0.originSequence < $1.originSequence
                    }
                guard !pending.isEmpty else {
                    continue
                }
                guard pending[0].originSequence == uploaded + 1 else {
                    throw ReplicaError.sequenceGap(
                        origin: deviceID,
                        expected: uploaded + 1,
                        received: pending[0].originSequence
                    )
                }
                let operations = Array(
                    pending.prefix(ProtocolLimits.mailboxBatchCount)
                )
                for (offset, operation) in operations.enumerated() {
                    guard
                        operation.originSequence
                            == uploaded + UInt64(offset) + 1
                    else {
                        throw ReplicaError.sequenceGap(
                            origin: deviceID,
                            expected: uploaded + UInt64(offset) + 1,
                            received: operation.originSequence
                        )
                    }
                }
                guard let material = mailbox.outboundByRecipient[recipient] else {
                    throw SyncError.invalidCredentials
                }
                let envelopes = try operations.map {
                    try mailbox.seal($0, for: recipient)
                }
                _ = try await mailboxTransport.put(
                    route: material.route,
                    authorization: material.authorization,
                    messages: envelopes
                )
                try Task.checkCancellation()
                guard
                    self.credentials == credentials,
                    let lastSequence = operations.last?.originSequence
                else {
                    throw CancellationError()
                }
                uploadedThroughByRecipient[recipient] = lastSequence
                anyProgress = true
            }

            if anyProgress {
                let checkpoint = MailboxCheckpoint(
                    groupID: credentials.groupID,
                    uploadedThroughByRecipient: uploadedThroughByRecipient
                )
                try credentialStore.saveMailboxCheckpoint(checkpoint)
                uploadedLocalSequence = checkpoint.uploadedLocalSequence
                lastMailboxStoredAt = Date()
            }
            refreshPendingMailboxCount()
            if !anyProgress {
                return
            }
        }
        throw CancellationError()
    }

    private func receiveMailboxOperations(
        _ mailbox: GroupMailbox,
        credentials: GroupCredentials
    ) async throws {
        for (sender, material) in mailbox.inboundBySender {
            var afterCursor: UInt64 = 0
            while !Task.isCancelled {
                let page = try await mailboxTransport.fetch(
                    route: material.route,
                    authorization: material.authorization,
                    after: afterCursor,
                    limit: ProtocolLimits.mailboxFetchCount
                )
                try Task.checkCancellation()
                guard self.credentials == credentials else {
                    throw CancellationError()
                }
                guard !page.messages.isEmpty else {
                    break
                }

                let operations = try page.messages.map {
                    try mailbox.open($0.envelope, from: sender)
                }
                let accepted = try replica.applyRemote(operations)
                publishReplica()
                if accepted > 0 {
                    lastMailboxReceivedAt = Date()
                    lastSyncedAt = Date()
                }
                try await mailboxTransport.acknowledge(
                    route: material.route,
                    authorization: material.authorization,
                    through: page.nextCursor
                )
                afterCursor = page.nextCursor
                if !page.hasMore {
                    break
                }
            }
        }
    }

    private func receiveMembershipUpdates(
        credentials: GroupCredentials
    ) async throws {
        var current = credentials
        for sender in current.remoteActiveDeviceIDs {
            let mailbox = try GroupMembershipMailbox(
                groupRoot: current.groupRoot,
                groupID: current.groupID,
                epoch: current.epoch,
                senderDeviceID: sender,
                recipientDeviceID: current.localDeviceID
            )
            let page = try await mailboxTransport.fetch(
                route: mailbox.route,
                authorization: mailbox.authorization,
                after: 0,
                limit: ProtocolLimits.mailboxFetchCount
            )
            guard !page.messages.isEmpty else {
                continue
            }
            var highest: GroupMembershipSnapshot?
            for message in page.messages {
                let snapshot: GroupMembershipSnapshot
                do {
                    snapshot = try mailbox.open(message.envelope)
                } catch {
                    continue
                }
                guard snapshot.groupID == current.groupID else {
                    continue
                }
                if let highest,
                   snapshot.membershipGeneration <= highest.membershipGeneration
                {
                    continue
                }
                highest = snapshot
            }
            if let highest {
                do {
                    if let updated = try highest.acceptedUpdate(against: current) {
                        try credentialStore.saveActive(updated)
                        self.credentials = updated
                        current = updated
                    } else if highest.membershipGeneration > current.membershipGeneration,
                              !highest.members.contains(deviceID.bytes)
                    {
                        // Signed remove of self (stolen-phone / leave applied).
                        unlinkAndKeepTasks()
                        return
                    }
                } catch {
                    // Reject unsigned / foreign issuer / remove without rekey (C2/C3).
                }
            }
            if page.nextCursor > 0 {
                try await mailboxTransport.acknowledge(
                    route: mailbox.route,
                    authorization: mailbox.authorization,
                    through: page.nextCursor
                )
            }
        }
    }

    private func startBackgroundMailboxFlush() {
        guard credentials != nil, hasDurableStorage else {
            return
        }
        backgroundFlushTask = Task { [weak self] in
            await self?.performBackgroundMailboxFlushWork()
            guard !Task.isCancelled else {
                return
            }
            self?.backgroundFlushTask = nil
        }
    }

    private func maintainSync(_ credentials: GroupCredentials) async {
        var retryNanoseconds: UInt64 = 250_000_000
        while
            !Task.isCancelled,
            appIsActive,
            hasDurableStorage,
            self.credentials == credentials
        {
            do {
                try await runSyncConnection(credentials)
                retryNanoseconds = 250_000_000
            } catch is CancellationError {
                break
            } catch {
                channelReady = false
                pendingPings = [:]
                pingTask?.cancel()
                pingTask = nil
                outboundTask?.cancel()
                outboundTask = nil
                outboundDrainID = nil
                if
                    appIsActive,
                    hasDurableStorage,
                    self.credentials == credentials
                {
                    phase = .offline
                    errorMessage = Self.displayMessage(for: error)
                }
            }

            if let activeSocket {
                await activeSocket.cancel()
            }
            activeSocket = nil
            channelReady = false
            guard !Task.isCancelled else {
                break
            }
            let jitter = UInt64.random(in: 0...100_000_000)
            try? await Task.sleep(nanoseconds: retryNanoseconds + jitter)
            retryNanoseconds = min(retryNanoseconds * 2, 4_000_000_000)
        }
        syncTask = nil
        if appIsActive, hasDurableStorage, self.credentials == credentials {
            startSyncLoop()
        }
    }

    private func runSyncConnection(_ credentials: GroupCredentials) async throws {
        guard hasDurableStorage else {
            throw SyncError.localStorageUnavailable
        }
        try validate(credentials)
        // Live multi-peer rooms ship after mailbox fan-out; N>2 is mailbox-only.
        guard let pair = credentials.pairBridge else {
            phase = .synced
            return
        }
        phase = .connecting
        errorMessage = nil

        let route = SyncKeyDerivation.syncRoute(pairRoot: pair.pairRoot)
        let psk = SyncKeyDerivation.syncPSK(pairRoot: pair.pairRoot)
        let socket = RelaySocket(url: relayURL, policy: endpointPolicy)
        activeSocket = socket
        try await socket.connect(route: route)
        try await waitForPeer(on: socket)

        let hostDeviceID = pair.role == .host
            ? pair.localDeviceID
            : pair.remoteDeviceID
        let joinerDeviceID = pair.role == .joiner
            ? pair.localDeviceID
            : pair.remoteDeviceID
        let context = HandshakeContext.sync(
            relayOrigin: try relayOrigin(),
            route: route,
            pairID: pair.pairID,
            roleADeviceID: hostDeviceID,
            roleBDeviceID: joinerDeviceID
        )

        let material: HandshakeMaterial
        if pair.role == .host {
            let handshake = try InitiatorHandshake(context: context, psk: psk)
            try await socket.send(handshake.hello)
            let response = try await nextBinary(on: socket)
            let result = try handshake.receive(response)
            try await socket.send(result.confirm)
            material = result.material
        } else {
            let hello = try await nextBinary(on: socket)
            let response = try ResponderHandshake.respond(
                to: hello,
                context: context,
                psk: psk
            )
            try await socket.send(response.response)
            let confirmation = try await nextBinary(on: socket)
            material = try response.state.receive(confirmation)
        }

        try await socket.installSecureSession(
            material: material,
            role: pair.role
        )
        guard
            self.credentials == credentials,
            activeSocket === socket
        else {
            throw CancellationError()
        }
        confirmAuthenticatedPeerCompletion(credentials)
        channelReady = true
        deferredOperations = []
        phase = .reconciling
        try await sendSync(.hello(vector: replica.versionVector))
        startPingLoop(socket: socket)

        while !Task.isCancelled {
            let event = try await socket.receive()
            try Task.checkCancellation()
            guard
                self.credentials == credentials,
                activeSocket === socket
            else {
                throw CancellationError()
            }
            switch event {
            case .binary(let frame):
                guard channelReady else {
                    throw RelaySocketError.notConnected
                }
                let plaintext = try await socket.openEncrypted(frame)
                try Task.checkCancellation()
                guard
                    self.credentials == credentials,
                    activeSocket === socket,
                    channelReady
                else {
                    throw CancellationError()
                }
                let message = try WireCodec.decode(
                    SyncWireMessage.self,
                    from: plaintext
                )
                try await handleSync(
                    message,
                    credentials: credentials,
                    socket: socket
                )
            case .peerLeft:
                throw RelaySocketError.peerLeft
            case .peerReady:
                throw RelaySocketError.unexpectedControl
            case .error(let code):
                throw SyncError.mapRelayCode(code)
            }
        }
    }

    private func handleSync(
        _ message: SyncWireMessage,
        credentials: GroupCredentials,
        socket: RelaySocket
    ) async throws {
        guard hasDurableStorage else {
            throw SyncError.localStorageUnavailable
        }
        guard message.version == SyncProtocol.version else {
            throw WireMessageError.invalidVersion
        }
        switch message.kind {
        case .hello:
            guard
                let vector = message.vector,
                message.operations == nil,
                message.pingID == nil
            else {
                throw SyncError.invalidSyncMessage
            }
            try await sendMissingOperations(to: vector)
            try await sendSync(.acknowledgement(vector: replica.versionVector))
            try await flushDeferredOperations()
        case .operations:
            guard
                let operations = message.operations,
                operations.count <= ReplicaLimits.maxBatchOperations,
                message.vector == nil,
                message.pingID == nil
            else {
                throw SyncError.invalidSyncMessage
            }
            let accepted = try replica.applyRemote(operations)
            publishReplica()
            try await sendSync(.acknowledgement(vector: replica.versionVector))
            try requireActiveSync(credentials: credentials, socket: socket)
            if accepted > 0 {
                lastSyncedAt = Date()
            }
        case .acknowledgement:
            guard
                let vector = message.vector,
                message.operations == nil,
                message.pingID == nil
            else {
                throw SyncError.invalidSyncMessage
            }
            try await flushDeferredOperations()
            try requireActiveSync(credentials: credentials, socket: socket)
            if vector.isAtLeast(replica.versionVector) {
                phase = .synced
                if let activeSocket {
                    startOutboundDrain(on: activeSocket)
                }
            }
        case .ping:
            guard
                let pingID = message.pingID,
                pingID.count == 8,
                message.vector == nil,
                message.operations == nil
            else {
                throw SyncError.invalidSyncMessage
            }
            try await sendSync(.pong(id: pingID))
        case .pong:
            guard
                let pingID = message.pingID,
                pingID.count == 8,
                message.vector == nil,
                message.operations == nil,
                let started = pendingPings.removeValue(forKey: pingID)
            else {
                throw SyncError.invalidSyncMessage
            }
            let duration = ContinuousClock.now - started
            let components = duration.components
            lastRoundTripMilliseconds =
                Double(components.seconds) * 1_000
                + Double(components.attoseconds) / 1_000_000_000_000_000
        }
    }

    private func requireActiveSync(
        credentials: GroupCredentials,
        socket: RelaySocket
    ) throws {
        try Task.checkCancellation()
        guard
            self.credentials == credentials,
            activeSocket === socket,
            channelReady
        else {
            throw CancellationError()
        }
    }

    private func sendMissingOperations(
        to vector: ReplicaVersionVector
    ) async throws {
        let missing = replica.operations(missingFrom: vector)
        guard !missing.isEmpty else {
            return
        }
        for batch in try OperationBatcher.batches(missing) {
            try await sendSync(.operations(batch))
        }
    }

    private func sendImmediately(_ operations: [TaskOperation]) {
        guard hasDurableStorage else {
            return
        }
        deferredOperations.append(contentsOf: operations)
        refreshPendingMailboxCount()
        requestMailboxCycle(force: true)
        guard
            channelReady,
            phase == .synced,
            let activeSocket
        else {
            return
        }
        startOutboundDrain(on: activeSocket)
    }

    private func startOutboundDrain(on socket: RelaySocket) {
        guard
            hasDurableStorage,
            channelReady,
            phase == .synced,
            activeSocket === socket,
            outboundTask == nil,
            !deferredOperations.isEmpty
        else {
            return
        }
        let drainID = UUID()
        outboundDrainID = drainID
        outboundTask = Task { [weak self] in
            await self?.drainOutboundOperations(on: socket, drainID: drainID)
            self?.finishOutboundDrain(on: socket, drainID: drainID)
        }
    }

    private func drainOutboundOperations(
        on socket: RelaySocket,
        drainID: UUID
    ) async {
        do {
            while
                !Task.isCancelled,
                hasDurableStorage,
                channelReady,
                phase == .synced,
                activeSocket === socket,
                outboundDrainID == drainID,
                !deferredOperations.isEmpty
            {
                let operations = deferredOperations
                for batch in try OperationBatcher.batches(operations) {
                    try await sendSync(.operations(batch), on: socket)
                }
                guard
                    outboundDrainID == drainID,
                    activeSocket === socket,
                    deferredOperations.starts(with: operations)
                else {
                    return
                }
                deferredOperations.removeFirst(operations.count)
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = Self.displayMessage(for: error)
            if activeSocket === socket {
                channelReady = false
                await socket.cancel()
            }
        }
    }

    private func finishOutboundDrain(
        on socket: RelaySocket,
        drainID: UUID
    ) {
        guard outboundDrainID == drainID else {
            return
        }
        outboundTask = nil
        outboundDrainID = nil
        if
            hasDurableStorage,
            channelReady,
            phase == .synced,
            activeSocket === socket,
            !deferredOperations.isEmpty
        {
            startOutboundDrain(on: socket)
        }
    }

    private func flushDeferredOperations() async throws {
        guard !deferredOperations.isEmpty else {
            return
        }
        let operations = deferredOperations
        deferredOperations = []
        for batch in try OperationBatcher.batches(operations) {
            try await sendSync(.operations(batch))
        }
    }

    private func sendSync(
        _ message: SyncWireMessage,
        on expectedSocket: RelaySocket? = nil
    ) async throws {
        guard hasDurableStorage else {
            throw SyncError.localStorageUnavailable
        }
        guard
            let socket = expectedSocket ?? activeSocket,
            activeSocket === socket,
            channelReady
        else {
            throw RelaySocketError.notConnected
        }
        let plaintext = try WireCodec.encode(message)
        try await socket.sendEncrypted(plaintext)
    }

    private func startPingLoop(socket: RelaySocket) {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard
                    let self,
                    self.hasDurableStorage,
                    self.channelReady,
                    self.activeSocket === socket
                else {
                    return
                }
                do {
                    if let pending = self.pendingPings.first {
                        if ContinuousClock.now - pending.value > .seconds(6) {
                            self.errorMessage = "The encrypted link stopped responding."
                            await socket.cancel()
                            return
                        }
                    } else {
                        let pingID = try Data.secureRandom(count: 8)
                        self.pendingPings[pingID] = ContinuousClock.now
                        try await self.sendSync(.ping(id: pingID), on: socket)
                    }
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
            }
        }
    }

    private func waitForPeer(on socket: RelaySocket) async throws {
        while !Task.isCancelled {
            switch try await socket.receive() {
            case .peerReady:
                return
            case .peerLeft:
                continue
            case .error(let code):
                throw SyncError.mapRelayCode(code)
            case .binary:
                throw RelaySocketError.unexpectedControl
            }
        }
        throw CancellationError()
    }

    private func nextBinary(on socket: RelaySocket) async throws -> Data {
        while !Task.isCancelled {
            switch try await socket.receive() {
            case .binary(let data):
                return data
            case .peerLeft:
                throw SyncError.pairingDeclined
            case .error(let code):
                throw SyncError.mapRelayCode(code)
            case .peerReady:
                throw RelaySocketError.unexpectedControl
            }
        }
        throw CancellationError()
    }

    private func waitForApproval(attemptID: UUID) async -> Bool {
        guard isCurrentPairingAttempt(attemptID) else { return false }
        return await withCheckedContinuation { continuation in
            approvalContinuation = continuation
        }
    }

    private func isCurrentPairingAttempt(_ attemptID: UUID) -> Bool {
        pairingAttemptID == attemptID && !Task.isCancelled
    }

    private func requireCurrentPairingAttempt(_ attemptID: UUID) throws {
        guard isCurrentPairingAttempt(attemptID) else {
            throw CancellationError()
        }
    }

    private func relayOrigin() throws -> String {
        guard let origin = relayURL.canonicalRelayOrigin else {
            throw RelaySocketError.invalidRelayURL
        }
        return origin
    }

    private func requirePairRoot(_ material: HandshakeMaterial) throws -> Data {
        guard let pairRoot = material.pairRoot, pairRoot.count == 32 else {
            throw SyncError.invalidPairMessage
        }
        return pairRoot
    }

    private func requirePairID(_ material: HandshakeMaterial) throws -> Data {
        guard let pairID = material.pairID, pairID.count == 16 else {
            throw SyncError.invalidPairMessage
        }
        return pairID
    }

    private func validate(_ credentials: GroupCredentials) throws {
        try credentials.validate(deviceID: deviceID)
    }

    private static func validate(
        _ pending: PendingPair,
        deviceID: ReplicaDeviceID
    ) throws {
        guard
            pending.version == SyncProtocol.version,
            pending.pairRoot.count == 32,
            pending.pairID.count == 16,
            pending.localDeviceID == deviceID.bytes,
            pending.pairingVersion == SyncProtocol.pairingVersion
        else {
            throw SyncError.invalidCredentials
        }
        if let pairingArtifactID = pending.pairingArtifactID {
            guard
                pairingArtifactID.count == 16,
                pairingArtifactID == pending.pairID
            else {
                throw SyncError.invalidCredentials
            }
        }
        if let remoteDeviceID = pending.remoteDeviceID {
            guard
                remoteDeviceID.count == 16,
                remoteDeviceID != pending.localDeviceID
            else {
                throw SyncError.invalidCredentials
            }
        }
        if pending.finalizationState
            != .abortAcknowledgementMayHaveBeenStored,
           pending.abortAcknowledgementCursor != nil
        {
            throw SyncError.invalidCredentials
        }
        switch pending.finalizationState {
        case .waitingForProvision:
            guard
                pending.role == .joiner,
                pending.remoteDeviceID == nil,
                pending.archiveHash.isEmpty
            else {
                throw SyncError.invalidCredentials
            }
        case .provisionMayHaveBeenStored:
            guard
                pending.role == .host,
                pending.remoteDeviceID == nil,
                pending.archiveHash.count == 32
            else {
                throw SyncError.invalidCredentials
            }
        case .provisionStagedAwaitingMergeApproval:
            guard
                pending.role == .joiner,
                pending.remoteDeviceID != nil,
                pending.archiveHash.count == 32
            else {
                throw SyncError.invalidCredentials
            }
        case .readyMayHaveBeenStored:
            guard
                pending.role == .joiner,
                pending.remoteDeviceID != nil,
                pending.archiveHash.count == 32
            else {
                throw SyncError.invalidCredentials
            }
        case .commitMarkerMayHaveBeenStored:
            guard
                pending.role == .host,
                pending.remoteDeviceID != nil,
                pending.archiveHash.count == 32
            else {
                throw SyncError.invalidCredentials
            }
        case .abortMayHaveBeenStored:
            guard
                pending.remoteDeviceID == nil,
                pending.archiveHash.isEmpty
            else {
                throw SyncError.invalidCredentials
            }
        case .abortAcknowledgementMayHaveBeenStored:
            guard
                let cursor = pending.abortAcknowledgementCursor,
                cursor > 0,
                pending.remoteDeviceID != nil
            else {
                throw SyncError.invalidCredentials
            }
            switch pending.role {
            case .host:
                guard pending.archiveHash.count == 32 else {
                    throw SyncError.invalidCredentials
                }
            case .joiner:
                let waitingShape = pending.archiveHash.isEmpty
                let readyShape = pending.archiveHash.count == 32
                guard waitingShape || readyShape else {
                    throw SyncError.invalidCredentials
                }
            }
        case nil:
            guard pending.archiveHash.count == 32 else {
                throw SyncError.invalidCredentials
            }
        }
    }

    private static func finalizingPending(
        _ pending: PendingPair,
        active: GroupCredentials?,
        deviceID: ReplicaDeviceID
    ) throws -> PendingPair? {
        guard pending.pairingVersion == SyncProtocol.pairingVersion else {
            return nil
        }
        try validate(pending, deviceID: deviceID)
        var normalized = pending
        if let active {
            let foundingMatch =
                active.groupRoot == pending.pairRoot
                && active.groupID == pending.pairID
                && active.localDeviceID == pending.localDeviceID
            let groupInviteMatch =
                active.localDeviceID == pending.localDeviceID
                && active.activeMemberCount >= 2
            guard foundingMatch || groupInviteMatch else {
                throw SyncError.invalidCredentials
            }
            if normalized.finalizationState == nil {
                normalized.finalizationState = pending.role == .host
                    ? .commitMarkerMayHaveBeenStored
                    : .readyMayHaveBeenStored
            }
            return normalized
        }
        if normalized.finalizationState != nil {
            return normalized
        }
        return nil
    }

    private func publishReplica() {
        tasks = replica.tasks
    }

    private func refreshPendingMailboxCount() {
        let localSequence = replica.versionVector[deviceID]
        guard localSequence >= uploadedLocalSequence else {
            pendingMailboxOperationCount = 0
            pendingMailboxSince = nil
            showsSavingNotice = false
            savingNoticeRevealTask?.cancel()
            savingNoticeRevealTask = nil
            return
        }
        let pending = Int(localSequence - uploadedLocalSequence)
        if pending == 0 {
            pendingMailboxOperationCount = 0
            pendingMailboxSince = nil
            showsSavingNotice = false
            savingNoticeRevealTask?.cancel()
            savingNoticeRevealTask = nil
            return
        }
        if pendingMailboxOperationCount == 0 {
            pendingMailboxSince = Date()
            showsSavingNotice = false
            savingNoticeRevealTask?.cancel()
            savingNoticeRevealTask = Task { [weak self] in
                try? await Task.sleep(
                    for: .seconds(SyncTiming.savingNoticeDelay)
                )
                guard !Task.isCancelled else {
                    return
                }
                guard let self, self.pendingMailboxOperationCount > 0 else {
                    return
                }
                self.showsSavingNotice = true
                self.savingNoticeRevealTask = nil
            }
        }
        pendingMailboxOperationCount = pending
    }

    private func validateProvisioningArchiveSize() throws {
        let archive = try replica.exportProvisioningArchive()
        guard archive.count <= ProtocolLimits.provisioningArchiveBytes else {
            throw SyncError.archiveTooLarge
        }
    }

    private func validateTerminalPairingCapacity() throws {
        guard terminalPairingJournalUsable else {
            throw SyncError.pairingRecoveryJournalDamaged
        }
        guard
            terminalPairingActions.count
                < TerminalPairingActionJournal.maximumActionCount
        else {
            throw SyncError.pairingRecoveryHistoryFull
        }
    }

    private func rollbackPendingPairing() throws {
        guard
            !isPairingFinalizationLocked,
            credentials == nil,
            let pending = try credentialStore.pending()
        else {
            return
        }
        guard pending.role == .joiner else {
            try credentialStore.clearPending()
            pairingArtifactID = nil
            return
        }
        if FileManager.default.fileExists(atPath: pairingStagingURL.path) {
            try FileManager.default.removeItem(at: pairingStagingURL)
        }
        if FileManager.default.fileExists(atPath: pairingMergedURL.path) {
            try FileManager.default.removeItem(at: pairingMergedURL)
        }
        if FileManager.default.fileExists(
            atPath: pairingConflictBackupURL.path
        ) {
            try FileManager.default.removeItem(
                at: pairingConflictBackupURL
            )
        }
        replica = try TaskReplica(
            deviceID: deviceID,
            persistenceURL: persistenceURL
        )
        publishReplica()
        try credentialStore.clearPending()
        pairingArtifactID = nil
    }

    private func fail(_ error: Error) {
        errorMessage = Self.displayMessage(for: SyncError.fromTransport(error))
        phase = .failed
    }

    /// DEBUG: write invite phrase/URL into the app container for multi-sim automation.

    private static func isPairingReplicaConflict(_ error: Error) -> Bool {
        guard let syncError = error as? SyncError else {
            return false
        }
        if case .pairingReplicaConflict = syncError {
            return true
        }
        return false
    }

    private static func isReplicaCapacityError(_ error: Error) -> Bool {
        guard let replicaError = error as? ReplicaError else {
            return false
        }
        return switch replicaError {
        case .tooManyTasks, .tooManyOperations, .tooManyOrigins:
            true
        default:
            false
        }
    }

    private func handleLocalMutationFailure(_ error: Error) {
        errorMessage = Self.displayMessage(for: error)
        localEditErrorMessage = errorMessage
        let storageFailed = !(error is ReplicaError)
        if storageFailed {
            hasDurableStorage = false
        }
        guard isPaired else {
            phase = .failed
            return
        }
        guard storageFailed else {
            return
        }
        channelReady = false
        phase = .failed
        syncTask?.cancel()
        pingTask?.cancel()
        outboundTask?.cancel()
        mailboxPollTask?.cancel()
        mailboxCycleTask?.cancel()
        pingTask = nil
        outboundTask = nil
        mailboxPollTask = nil
        mailboxCycleTask = nil
        mailboxCycleID = nil
        mailboxCycleRequested = false
        outboundDrainID = nil
        pendingPings = [:]
        if let activeSocket {
            Task {
                await activeSocket.cancel()
            }
        }
    }

    private static func restoreActiveCredentials(
        store: CredentialStore,
        deviceID: ReplicaDeviceID
    ) throws -> GroupCredentials? {
        guard let active = try store.activeGroup() else {
            return nil
        }
        try active.validate(deviceID: deviceID)
        return active
    }

    private static func reconstructedReceiptAction(
        credentials: GroupCredentials
    ) throws -> TerminalPairingAction? {
        guard
            let bridge = credentials.pairBridge,
            bridge.role == .joiner,
            let archiveHash = credentials.pairingArchiveHash,
            archiveHash.count == 32
        else {
            return nil
        }
        let pending = PendingPair(
            version: SyncProtocol.version,
            pairRoot: bridge.pairRoot,
            pairID: bridge.pairID,
            role: .joiner,
            localDeviceID: bridge.localDeviceID,
            remoteDeviceID: bridge.remoteDeviceID,
            archiveHash: archiveHash,
            expiresAt: .distantFuture,
            finalizationState: .readyMayHaveBeenStored
        )
        let record = try PairingCommitRecord(
            pairID: bridge.pairID,
            hostDeviceID: bridge.remoteDeviceID,
            joinerDeviceID: bridge.localDeviceID,
            archiveHash: archiveHash
        )
        let mailbox = try PairingCommitMailbox(
            pairRoot: bridge.pairRoot,
            record: record,
            senderRole: .joiner
        )
        return try TerminalPairingAction(
            kind: .receipt,
            proof: pending,
            route: mailbox.route,
            authorization: mailbox.authorization,
            envelope: mailbox.seal()
        )
    }

    private static func persistEraseMarker(at markerURL: URL) throws {
        try Data([SyncProtocol.version]).write(to: markerURL, options: .atomic)
        try FileManager.default.setAttributes(
            ProtectedStorage.fileAttributes,
            ofItemAtPath: markerURL.path
        )
        let handle = try FileHandle(forWritingTo: markerURL)
        defer {
            try? handle.close()
        }
        try handle.synchronize()
    }

    private static func completeErase(
        store: CredentialStore,
        deviceID: ReplicaDeviceID,
        persistenceURL: URL,
        markerURL: URL
    ) throws -> TaskReplica {
        try store.clearPair()
        try removeAllPairingArtifacts(
            in: persistenceURL.deletingLastPathComponent()
        )
        if FileManager.default.fileExists(atPath: persistenceURL.path) {
            try FileManager.default.removeItem(at: persistenceURL)
        }
        let clearedReplica = try TaskReplica(
            deviceID: deviceID,
            persistenceURL: persistenceURL
        )
        if FileManager.default.fileExists(atPath: markerURL.path) {
            try FileManager.default.removeItem(at: markerURL)
        }
        return clearedReplica
    }

    private static func removeAllPairingArtifacts(in directory: URL) throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        for url in contents where isPairingArtifactName(url.lastPathComponent) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func isPairingArtifactName(_ name: String) -> Bool {
        for filename in pairingArtifactFilenames {
            if name == filename {
                return true
            }
            let prefix = "\(filename)."
            guard name.hasPrefix(prefix) else {
                continue
            }
            let suffix = String(name.dropFirst(prefix.count))
            guard
                let identifier = try? Data(base64URL: suffix),
                identifier.count == 16,
                identifier.base64URLString == suffix
            else {
                continue
            }
            return true
        }
        return false
    }

    private static func displayMessage(for error: Error) -> String {
        let mapped = SyncError.fromTransport(error)
        if let localized = mapped as? LocalizedError,
           let description = localized.errorDescription
        {
            return description
        }
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription
        {
            return description
        }
        return "Cannot reach the sync service."
    }

    private static func requiresMailboxRepair(_ error: Error) -> Bool {
        if let syncError = error as? SyncError, syncError == .unsupportedProtocolVersion { return false }
        if error is URLError {
            return false
        }
        if let mailboxError = error as? MailboxTransportError {
            switch mailboxError {
            case .unsupportedVersion:
                return false
            case .rejected(_, let code) where code == "unsupportedVersion":
                return false
            case .rejected(let status, _):
                return status != 408
                    && status != 429
                    && !(500...599).contains(status)
            case .invalidURL, .insecureTransport, .invalidRequest,
                 .invalidResponse, .responseTooLarge:
                return true
            case .requestTooLarge:
                return true
            }
        }
        if error is ReplicaError
            || error is SyncCryptoError
            || error is SyncError
        {
            return true
        }
        return false
    }

    private static func isMailboxCapacityError(_ error: Error) -> Bool {
        guard
            let mailboxError = error as? MailboxTransportError,
            case .rejected(let status, let code) = mailboxError
        else {
            return false
        }
        return status == 429 && code == "mailboxCapacity"
    }
}

private actor MailboxUploadCompletion {
    private(set) var isFinished = false

    public func finish() {
        isFinished = true
    }
}

private enum PairingFinalizationRetry: Error {
    case waitingForPeerDecision
    case stateAdvanced
}
