import CryptoKit
import Foundation
import GotSyncMLS

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
    case relinkRequired
    case syncHistoryBlocked
    case removedFromGroup
    case approvalExpired

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
        case .relinkRequired:
            "This version uses a new sync protocol. Your tasks are safe on this iPhone. Create a new link to sync again."
        case .syncHistoryBlocked:
            "Sync stopped at an update this iPhone could not verify. Your tasks are safe. Unlink and create a new link to keep syncing."
        case .removedFromGroup:
            "This iPhone was removed from the sync group. Your tasks are safe on this iPhone."
        case .approvalExpired:
            "The safety code was not confirmed in time. Nothing was linked. Create a new invitation and try again."
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
        if let mls = error as? MLSRelayError {
            switch mls {
            case .unsupportedVersion:
                return SyncError.unsupportedProtocolVersion
            default:
                return SyncError.privateSyncUnreachable
            }
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
             .pairingRecoveryJournalDamaged, .invalidSyncMessage, .unsupportedProtocolVersion,
             .relinkRequired, .syncHistoryBlocked, .removedFromGroup, .approvalExpired:
            return false
        }
    }
}

@MainActor
public final class SyncEngine {
    private var stateSubscribers: [UUID: AsyncStream<SyncState>.Continuation] = [:]

    public var pairingFinalizationState: PairingFinalizationState? { nil }

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
            linkedMemberCount: linkedMemberCount,
            linkedDevices: linkedDevices
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
    static let pairingConflictBackupFilename = "replica-v1.pairing-local.json"
    private static let pairingArtifactFilenames = [
        pairingStagingFilename,
        pairingMergedFilename,
        pairingConflictBackupFilename,
    ]
    static let departuresDirectoryName = "mls-v2-departing"
    private static let maximumGroupSize = 8
    private static let maximumAddAttempts = 3
    private static let maximumRemovalAttempts = 8
    private static let maximumDepartures = 8

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
    public private(set) var showsSavingNotice = false { didSet { publishState() } }

    public let relayURL: URL
    public let mailboxURL: URL

    private let secretStore: any SecretStore
    private let credentialStore: CredentialStore
    private let mlsTransport: any MLSRelayTransport
    private let rendezvous: any PairingRendezvous
    private let backgroundMailboxScheduler: any BackgroundMailboxScheduling
    private let invitationURLScheme: String
    private let deviceID: ReplicaDeviceID
    private let persistenceURL: URL
    private let checkpointURL: URL
    private let mlsRoot: URL
    private var mlsDirectory: URL
    private let departuresDirectory: URL
    private let hasDurableIdentity: Bool
    private var hasDurableStorage: Bool
    private var replica: TaskReplica
    private var session: MLSSession?
    private var checkpoint: ReplicationCheckpoint? { didSet { publishState() } }
    private let pairingRetryDelayNanoseconds: UInt64
    private let syncIntervalNanoseconds: UInt64
    private let approvalTimeoutNanoseconds: UInt64
    private let provisionalMemberWindow: TimeInterval
    private let departureRetryDelayNanoseconds: ClosedRange<UInt64>

    private var pairingAttemptID: UUID?
    private var pairingDeadline: Date?
    private var pairingTask: Task<Void, Never>?
    private var pairingExpiryTask: Task<Void, Never>?
    private var pairingReaderTask: Task<Void, Never>?
    private var pairingConnection: (any PairingConnection)?
    private var activeInvitation: Invitation?
    private var approvalContinuation: CheckedContinuation<ApprovalOutcome, Never>?
    private var peerDecision: Bool?
    private var reconcileTask: Task<Void, Never>?
    private var syncLoopTask: Task<Void, Never>?
    private var syncCycleTask: Task<Void, Never>?
    private var backgroundFlushTask: Task<Void, Never>?
    private var departureTask: Task<Void, Never>?
    private var syncCycleID: UUID?
    private var syncCycleRequested = false
    private var syncFailureCount = 0
    private var nextSyncAttemptAt = Date.distantPast
    private var lastCycleSucceeded = false
    private var isHistoryBlocked = false
    private var appIsActive = true
    private var pendingMailboxSince: Date?
    private var savingNoticeRevealTask: Task<Void, Never>?
    private var linkCompleteCelebrationTask: Task<Void, Never>?

    public convenience init(
        configuration: SyncConfiguration,
        secretStore: any SecretStore,
        backgroundMailboxScheduler: (any BackgroundMailboxScheduling)? = nil,
        pairingRetryDelayNanoseconds: UInt64 = 1_000_000_000
    ) {
        self.init(
            configuration: configuration,
            secretStore: secretStore,
            backgroundMailboxScheduler: backgroundMailboxScheduler,
            pairingRetryDelayNanoseconds: pairingRetryDelayNanoseconds,
            mlsTransport: nil,
            rendezvous: nil
        )
    }

    init(
        configuration: SyncConfiguration,
        secretStore: any SecretStore,
        backgroundMailboxScheduler: (any BackgroundMailboxScheduling)?,
        pairingRetryDelayNanoseconds: UInt64,
        mlsTransport: (any MLSRelayTransport)?,
        rendezvous: (any PairingRendezvous)?,
        syncIntervalNanoseconds: UInt64 = 2_000_000_000,
        approvalTimeoutNanoseconds: UInt64 = SyncTiming.approvalTimeoutNanoseconds,
        provisionalMemberWindow: TimeInterval = SyncTiming.provisionalMemberWindow,
        departureRetryDelayNanoseconds: ClosedRange<UInt64> = 1_000_000_000...30_000_000_000
    ) {
        let baseDirectory = configuration.storageDirectory
        relayURL = configuration.endpoints.relayURL
        mailboxURL = configuration.endpoints.mailboxURL
        invitationURLScheme = configuration.invitationURLScheme
        self.secretStore = secretStore
        self.mlsTransport = mlsTransport
            ?? HTTPMLSRelayTransport(baseURL: configuration.endpoints.mlsURL, policy: configuration.endpointPolicy)
        self.rendezvous = rendezvous
            ?? RelayPairingRendezvous(url: configuration.endpoints.relayURL, policy: configuration.endpointPolicy)
        self.backgroundMailboxScheduler = backgroundMailboxScheduler ?? NoopBackgroundMailboxScheduler()
        self.pairingRetryDelayNanoseconds = pairingRetryDelayNanoseconds
        self.syncIntervalNanoseconds = syncIntervalNanoseconds
        self.approvalTimeoutNanoseconds = approvalTimeoutNanoseconds
        self.provisionalMemberWindow = provisionalMemberWindow
        self.departureRetryDelayNanoseconds = departureRetryDelayNanoseconds
        credentialStore = CredentialStore(keychain: secretStore)
        persistenceURL = baseDirectory.appendingPathComponent("replica-v1.json")
        checkpointURL = baseDirectory.appendingPathComponent(ReplicationCheckpoint.filename)
        mlsRoot = MLSSession.directory(in: baseDirectory)
        mlsDirectory = Self.currentMLSDirectory(in: mlsRoot)
        departuresDirectory = baseDirectory.appendingPathComponent(Self.departuresDirectoryName, isDirectory: true)

        var bootError: Error?
        let installData: Data
        do {
            installData = try InstallIdentity.loadOrCreate(store: secretStore).deviceID
            hasDurableIdentity = true
        } catch {
            bootError = error
            installData = ReplicaDeviceID(uuid: UUID()).bytes
            hasDurableIdentity = false
        }
        deviceID = try! ReplicaDeviceID(bytes: installData)

        var notice: SyncError?
        if hasDurableIdentity {
            do {
                try FileManager.default.createDirectory(
                    at: baseDirectory,
                    withIntermediateDirectories: true,
                    attributes: ProtectedStorage.directoryAttributes
                )
                try FileManager.default.setAttributes(ProtectedStorage.directoryAttributes, ofItemAtPath: baseDirectory.path)
                try? FileManager.default.setAttributes(ProtectedStorage.fileAttributes, ofItemAtPath: persistenceURL.path)
                let markerURL = baseDirectory.appendingPathComponent(Self.eraseMarkerFilename)
                if FileManager.default.fileExists(atPath: markerURL.path) {
                    replica = try Self.completeErase(
                        store: credentialStore,
                        secretStore: secretStore,
                        deviceID: deviceID,
                        persistenceURL: persistenceURL,
                        checkpointURL: checkpointURL,
                        mlsRoot: mlsRoot,
                        markerURL: markerURL
                    )
                } else {
                    replica = try TaskReplica(deviceID: deviceID, persistenceURL: persistenceURL)
                }
                hasDurableStorage = true
            } catch {
                bootError = bootError ?? error
                replica = try! TaskReplica(deviceID: deviceID)
                hasDurableStorage = false
            }
        } else {
            replica = try! TaskReplica(deviceID: deviceID)
            hasDurableStorage = false
        }

        if hasDurableStorage {
            do {
                if try credentialStore.hasPairingData() {
                    try credentialStore.clearAllPairingData()
                    notice = .relinkRequired
                }
                try Self.removeAllPairingArtifacts(in: baseDirectory)
                do {
                    checkpoint = try ReplicationCheckpoint.load(from: checkpointURL)
                } catch {
                    try ReplicationCheckpoint.remove(at: checkpointURL)
                    checkpoint = nil
                }
                do {
                    session = try openSession()
                } catch let error where Self.isUnrecoverableSessionState(error) {
                    try eraseCurrentMLSState()
                    session = try openSession()
                    if checkpoint != nil {
                        try ReplicationCheckpoint.remove(at: checkpointURL)
                        checkpoint = nil
                        notice = .relinkRequired
                    }
                }
            } catch {
                bootError = bootError ?? error
                session = nil
                checkpoint = nil
            }
        }

        tasks = replica.tasks
        isPaired = checkpoint != nil
        refreshPendingMailboxCount()
        if let bootError {
            phase = .failed
            errorMessage = Self.displayMessage(for: bootError)
        } else if isPaired {
            phase = .connecting
        } else {
            phase = .unpaired
            errorMessage = notice.map { Self.displayMessage(for: $0) }
        }
        if session != nil {
            reconcileTask = Task { [weak self] in
                await self?.reconcileSession()
            }
        }
        startDepartures()
        self.backgroundMailboxScheduler.register { [weak self] in
            await self?.performBackgroundMailboxFlushWork()
        }
    }

    /// Active members in the linked group (including this iPhone).
    public var linkedDeviceIDs: [Data] { checkpoint?.memberDeviceIDs ?? [] }
    public var localDeviceID: Data { deviceID.bytes }

    public var linkedMemberCount: Int {
        isPaired ? linkedDeviceIDs.count : 0
    }

    public var isGroupAtCapacity: Bool {
        linkedMemberCount >= Self.maximumGroupSize
    }

    public var linkedDevices: [LinkedDevice] {
        guard isPaired, let checkpoint else { return [] }
        return checkpoint.members.map {
            LinkedDevice(
                deviceID: $0.deviceID,
                fingerprint: $0.fingerprint,
                isCurrentDevice: $0.deviceID == deviceID.bytes,
                isRemovalPending: checkpoint.pendingRemovals.contains($0.fingerprint)
            )
        }
    }

    public func leaveGroupAndKeepTasks() {
        unlinkAndKeepTasks()
    }

    /// Removes another device from the group with an MLS commit. The request
    /// is saved first and retried by sync cycles, including after a restart,
    /// until the device is no longer a member.
    @discardableResult
    public func removeDevice(_ device: LinkedDevice) -> Bool {
        removeDevice(fingerprint: device.fingerprint)
    }

    @discardableResult
    public func removeDevice(fingerprint: Data) -> Bool {
        guard
            hasDurableStorage,
            isPaired,
            var current = checkpoint,
            let member = current.members.first(where: { $0.fingerprint == fingerprint }),
            member.deviceID != deviceID.bytes
        else {
            return false
        }
        if !current.pendingRemovals.contains(fingerprint) {
            current.pendingRemovals.append(fingerprint)
            do {
                try saveCheckpoint(current)
            } catch {
                handleLocalMutationFailure(error)
                return false
            }
        }
        requestSyncCycle(force: true, allowInactive: true)
        return true
    }

    /// Whether the invitation UI is an in-group invite (vs founding).
    public var isIssuingGroupInvite: Bool {
        isPaired && invitationPhrase != nil
    }

    public var pairingRecoveryResetRequired: Bool { false }

    public var hasLocalReplicaHistory: Bool {
        !replica.isEmpty
    }

    public var canJoinExistingSync: Bool {
        hasDurableIdentity && hasDurableStorage && session != nil && !isPaired && pairingTask == nil
    }

    public var canEditLocalTasks: Bool {
        hasDurableStorage
    }

    public var canCancelPairing: Bool {
        pairingTask != nil
    }

    /// Found a new group (unlinked) or invite another iPhone into the current group.
    public func createPrivateSync() {
        if isPaired {
            inviteToGroup()
            return
        }
        guard hasDurableIdentity, hasDurableStorage, pairingTask == nil else {
            return
        }
        beginInvitation(linked: false)
    }

    /// Any linked member can issue a join invite into the existing group.
    public func inviteToGroup() {
        guard hasDurableIdentity, hasDurableStorage, isPaired, pairingTask == nil else {
            return
        }
        if isGroupAtCapacity {
            fail(SyncError.groupAtCapacity)
            return
        }
        beginInvitation(linked: true)
    }

    public func joinPrivateSync(phrase: String) {
        guard canJoinExistingSync else {
            return
        }
        do {
            beginJoin(with: try Invitation.from(phrase: phrase))
        } catch {
            fail(error)
        }
    }

    public func joinPrivateSync(url: URL) {
        guard canJoinExistingSync else {
            return
        }
        do {
            beginJoin(with: try Invitation.from(url: url, scheme: invitationURLScheme))
        } catch {
            fail(error)
        }
    }

    public func approveSafetyCode() {
        guard isHostApprovalPending else {
            return
        }
        resolveApproval(.approved)
    }

    public func rejectSafetyCode() {
        guard safetyCode != nil else {
            return
        }
        if isHostApprovalPending {
            resolveApproval(.rejected)
            return
        }
        cancelPairing(preserveLink: isPaired)
    }

    public func regenerateInvitation() {
        guard invitationPhrase != nil else {
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

    public func cancelPairing(preserveLink: Bool = false) {
        let keepLink = isPaired && (preserveLink || invitationPhrase != nil)
        if isPaired && !keepLink {
            return
        }
        if isHostApprovalPending {
            resolveApproval(.rejected)
            return
        }
        let wasJoining = activePairingRole == .joiner
        declinePeer()
        endPairingAttempt()
        if wasJoining && !isPaired {
            try? resetSession()
        }
        errorMessage = nil
        restorePhaseAfterPairing()
    }

    public func resolvePairingReplicaConflictKeepingBoth() {}

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
            try replica.createTask(title: normalized)
            localEditErrorMessage = nil
            localReplicaChanged()
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
        guard canEditLocalTasks, let completed = task.isCompleted else {
            return
        }
        do {
            try replica.setCompleted(taskID: task.id, completed: !completed)
            localReplicaChanged()
        } catch {
            handleLocalMutationFailure(error)
        }
    }

    public func deleteTasks(at offsets: IndexSet) {
        deleteTasks(ids: offsets.compactMap { tasks.indices.contains($0) ? tasks[$0].id : nil })
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
                try replica.deleteTask(taskID: id)
            } catch {
                handleLocalMutationFailure(error)
                break
            }
        }
        localReplicaChanged()
    }

    public func eraseLocalData() {
        guard hasDurableIdentity else {
            return
        }
        cancelAllWork()
        hasDurableStorage = false
        do {
            session = nil
            try stageDeparture()
            let markerURL = persistenceURL.deletingLastPathComponent()
                .appendingPathComponent(Self.eraseMarkerFilename)
            try Self.persistEraseMarker(at: markerURL)
            replica = try Self.completeErase(
                store: credentialStore,
                secretStore: secretStore,
                deviceID: deviceID,
                persistenceURL: persistenceURL,
                checkpointURL: checkpointURL,
                mlsRoot: mlsRoot,
                markerURL: markerURL
            )
            mlsDirectory = Self.freshMLSDirectory(in: mlsRoot)
            session = try openSession()
            hasDurableStorage = true
            tasks = []
            resetLinkState()
            localEditErrorMessage = nil
        } catch {
            fail(error)
        }
        startDepartures()
    }

    /// Leaves the group and keeps local tasks. The MLS state moves to a
    /// departure journal until the relay accepts a proposal removing this
    /// device, then it is erased.
    public func unlinkAndKeepTasks() {
        guard hasDurableIdentity, isPaired else {
            return
        }
        dropLink(departing: true)
    }

    private func dropLink(departing: Bool) {
        cancelAllWork()
        do {
            try credentialStore.clearAllPairingData()
            session = nil
            if departing {
                try stageDeparture()
            }
            try ReplicationCheckpoint.remove(at: checkpointURL)
            try eraseCurrentMLSState()
            session = try openSession()
        } catch {
            checkpoint = nil
            isPaired = false
            session = nil
            fail(error)
            return
        }
        resetLinkState()
        if departing {
            startDepartures()
        }
    }

    public func waitForBackgroundWork() async {
        await backgroundFlushTask?.value
    }

    public func stopBackgroundWork() async {
        syncCycleTask?.cancel()
        backgroundFlushTask?.cancel()
    }

    public func applicationDidBecomeActive() {
        appIsActive = true
        backgroundFlushTask?.cancel()
        backgroundFlushTask = nil
        startDepartures()
        if isPaired {
            isHistoryBlocked = false
            nextSyncAttemptAt = .distantPast
            startSyncLoop()
        }
    }

    public func applicationDidEnterBackground() {
        appIsActive = false
        syncLoopTask?.cancel()
        syncLoopTask = nil
        guard isPaired, pairingTask == nil, !isHistoryBlocked else {
            return
        }
        phase = .offline
        startBackgroundMailboxFlush()
        backgroundMailboxScheduler.scheduleFlushIfNeeded(pendingOperationCount: pendingMailboxOperationCount)
    }

    /// Invoked by BGProcessingTask and UIBackgroundTask flush loops.
    public func performBackgroundMailboxFlushWork() async {
        guard isPaired, hasDurableStorage, session != nil else {
            backgroundMailboxScheduler.cancelFlush()
            return
        }
        refreshPendingMailboxCount()
        guard pendingMailboxOperationCount > 0 else {
            backgroundMailboxScheduler.cancelFlush()
            return
        }
        var attempts = 0
        while !Task.isCancelled, pendingMailboxOperationCount > 0, attempts < 8 {
            attempts += 1
            requestSyncCycle(force: true, allowInactive: true)
            guard let cycle = syncCycleTask else {
                break
            }
            await cycle.value
            refreshPendingMailboxCount()
            if pendingMailboxOperationCount > 0 {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        if pendingMailboxOperationCount > 0 {
            backgroundMailboxScheduler.scheduleFlushIfNeeded(pendingOperationCount: pendingMailboxOperationCount)
        } else {
            backgroundMailboxScheduler.cancelFlush()
        }
    }

    public func stop() async {
        appIsActive = false
        pairingAttemptID = nil
        resolveApproval(.rejected)
        cancelPresentationTasks()
        syncCycleRequested = false
        let running = [
            pairingTask, pairingExpiryTask, pairingReaderTask, reconcileTask,
            syncLoopTask, syncCycleTask, backgroundFlushTask, departureTask,
        ].compactMap { $0 }
        for task in running {
            task.cancel()
        }
        if let pairingConnection {
            await pairingConnection.cancel()
        }
        for task in running {
            await task.value
        }
        pairingTask = nil
        pairingExpiryTask = nil
        pairingReaderTask = nil
        pairingConnection = nil
        reconcileTask = nil
        syncLoopTask = nil
        syncCycleTask = nil
        syncCycleID = nil
        backgroundFlushTask = nil
        departureTask = nil
        for subscriber in stateSubscribers.values { subscriber.finish() }
        stateSubscribers.removeAll()
    }

    // MARK: - Pairing

    private func beginInvitation(linked: Bool) {
        guard let session else {
            fail(SyncError.localStorageUnavailable)
            return
        }
        let deadline = Date().addingTimeInterval(SyncTiming.invitationTimeToLive)
        safetyCode = nil
        errorMessage = nil
        invitationExpiresAt = deadline
        activePairingRole = .host
        phase = .waitingForPeer
        let attemptID = startPairingAttempt(deadline: deadline)
        pairingTask = Task { [weak self] in
            await self?.runInviterPairing(session: session, linked: linked, attemptID: attemptID)
        }
        pairingExpiryTask = Task { [weak self] in
            guard (try? await Task.sleep(nanoseconds: SyncTiming.invitationTimeToLiveNanoseconds)) != nil,
                  let self, self.pairingAttemptID == attemptID, self.safetyCode == nil
            else {
                return
            }
            self.pairingFailed(SyncError.invitationExpired, attemptID: attemptID)
        }
    }

    private func beginJoin(with invitation: Invitation) {
        guard let session else {
            fail(SyncError.localStorageUnavailable)
            return
        }
        invitationPhrase = nil
        invitationURL = nil
        invitationExpiresAt = nil
        safetyCode = nil
        errorMessage = nil
        activePairingRole = .joiner
        phase = .waitingForPeer
        activeInvitation = invitation
        let attemptID = startPairingAttempt(deadline: Date().addingTimeInterval(SyncTiming.invitationTimeToLive))
        pairingTask = Task { [weak self] in
            await self?.runJoinerPairing(invitation, session: session, attemptID: attemptID)
        }
    }

    private func startPairingAttempt(deadline: Date) -> UUID {
        let attemptID = UUID()
        pairingAttemptID = attemptID
        pairingDeadline = deadline
        peerDecision = nil
        return attemptID
    }

    private func runInviterPairing(session: MLSSession, linked: Bool, attemptID: UUID) async {
        do {
            let fingerprint = try await session.fingerprint()
            let groupID: Data
            if linked {
                guard let group = checkpoint?.group else { throw SyncError.invalidCredentials }
                groupID = group
            } else {
                groupID = try await session.group() ?? .secureRandom(count: 32)
            }
            let invitation = try Invitation.generate(groupID: groupID, inviterFingerprint: fingerprint)
            try requireCurrentPairingAttempt(attemptID)
            activeInvitation = invitation
            invitationPhrase = invitation.phrase
            invitationURL = try invitation.url(scheme: invitationURLScheme)

            let offer = try PairingFrame.offer(groupID: groupID, inviterFingerprint: fingerprint)
                .seal(for: invitation, from: .fromInviter)
            let response = try await awaitJoinerResponse(
                invitation: invitation, groupID: groupID, inviterFingerprint: fingerprint, offer: offer, attemptID: attemptID
            )
            let connection = response.connection
            let reference = response.keyPackageReference
            let joinerFingerprint = response.joinerFingerprint
            pairingExpiryTask?.cancel()
            pairingExpiryTask = nil
            guard
                let keyPackage = try await session.fetchKeyPackage(reference: reference, pairingToken: invitation.pairingToken),
                Data(SHA256.hash(data: keyPackage)) == reference
            else {
                throw SyncError.invalidPairMessage
            }
            try requireCurrentPairingAttempt(attemptID)
            invitationPhrase = nil
            invitationURL = nil
            invitationExpiresAt = nil
            safetyCode = PairingSafetyCode.code(
                groupID: groupID,
                inviterFingerprint: fingerprint,
                joinerFingerprint: joinerFingerprint,
                inviterNonce: response.inviterNonce,
                joinerNonce: response.joinerNonce
            )
            isHostApprovalPending = true
            phase = .verifying
            listenForJoinerCancellation(on: connection, invitation: invitation, attemptID: attemptID)
            let outcome = await waitForApproval(attemptID: attemptID)
            try requireCurrentPairingAttempt(attemptID)
            guard outcome == .approved else {
                pairingReaderTask?.cancel()
                pairingReaderTask = nil
                if let frame = try? PairingFrame.decision(approved: false).seal(for: invitation, from: .fromInviter) {
                    try? await connection.send(frame)
                }
                await connection.cancel()
                if outcome == .expired {
                    throw SyncError.approvalExpired
                }
                if peerDecision == false {
                    throw SyncError.pairingDeclined
                }
                endPairingAttempt()
                restorePhaseAfterPairing()
                return
            }

            phase = .provisioning
            if linked {
                try await session.synchronize()
                try await processRemovals(session: session)
            } else {
                try await session.createGroup(groupID)
            }
            var added = false
            for _ in 0..<Self.maximumAddAttempts where !added {
                try requireCurrentPairingAttempt(attemptID)
                if case .accepted = try await session.add(
                    keyPackage: keyPackage, verifiedFingerprint: joinerFingerprint, reference: reference
                ) {
                    added = true
                }
            }
            guard added else { throw SyncError.invalidPairMessage }
            pairingReaderTask?.cancel()
            pairingReaderTask = nil
            let declined = peerDecision == false
            if declined && !linked {
                await connection.cancel()
                try resetSession()
                throw SyncError.pairingDeclined
            }
            let roster = try await session.members().map(ReplicationCheckpoint.Member.init)
            var current = checkpoint.flatMap { $0.group == groupID ? $0 : nil }
                ?? ReplicationCheckpoint(group: groupID, members: roster, joinPending: false, provider: nil)
            current.members = roster
            if declined {
                current.pendingRemovals.append(joinerFingerprint)
            } else {
                current.provisionalMembers.append(ReplicationCheckpoint.ProvisionalMember(
                    fingerprint: joinerFingerprint, deadline: Date().addingTimeInterval(provisionalMemberWindow)
                ))
            }
            try saveCheckpoint(current)
            if declined {
                await connection.cancel()
                throw SyncError.pairingDeclined
            }
            if let frame = try? PairingFrame.decision(approved: true).seal(for: invitation, from: .fromInviter) {
                try? await connection.send(frame)
            }
            await connection.cancel()
            finishPairing(attemptID: attemptID)
        } catch {
            pairingFailed(error, attemptID: attemptID)
        }
    }

    private struct JoinerResponse {
        let connection: any PairingConnection
        let keyPackageReference: Data
        let joinerFingerprint: Data
        let inviterNonce: Data
        let joinerNonce: Data
    }

    /// Accepts exactly one joiner commitment per invitation and answers it
    /// with the same nonce on every reconnect, so the joiner cannot pick its
    /// KeyPackage after seeing the nonce.
    private func awaitJoinerResponse(
        invitation: Invitation,
        groupID: Data,
        inviterFingerprint: Data,
        offer: Data,
        attemptID: UUID
    ) async throws -> JoinerResponse {
        var delayNanoseconds: UInt64 = 500_000_000
        var bound: (commitment: Data, nonce: Data)?
        while true {
            let connection = try await connectPairing(route: invitation.route, attemptID: attemptID)
            do {
                while true {
                    let event = try await connection.receive()
                    try requireCurrentPairingAttempt(attemptID)
                    switch event {
                    case .peerReady:
                        try await connection.send(offer)
                    case .peerLeft:
                        continue
                    case .binary(let frame):
                        switch try PairingFrame.open(frame, for: invitation, from: .fromJoiner) {
                        case .commitment(let commitment):
                            if let bound, bound.commitment != commitment {
                                throw SyncError.invalidPairMessage
                            }
                            let nonce = try bound?.nonce ?? Data.secureRandom(count: 32)
                            bound = (commitment, nonce)
                            try await connection.send(PairingFrame.nonce(nonce).seal(for: invitation, from: .fromInviter))
                        case .response(let reference, let fingerprint, let joinerNonce):
                            guard let bound, PairingSafetyCode.commitment(
                                groupID: groupID,
                                inviterFingerprint: inviterFingerprint,
                                keyPackageReference: reference,
                                joinerFingerprint: fingerprint,
                                joinerNonce: joinerNonce
                            ) == bound.commitment else {
                                throw SyncError.invalidPairMessage
                            }
                            return JoinerResponse(
                                connection: connection,
                                keyPackageReference: reference,
                                joinerFingerprint: fingerprint,
                                inviterNonce: bound.nonce,
                                joinerNonce: joinerNonce
                            )
                        case .decision:
                            throw SyncError.pairingDeclined
                        case .offer, .nonce:
                            throw SyncError.invalidPairMessage
                        }
                    case .error(let code):
                        throw SyncError.mapRelayCode(code)
                    }
                }
            } catch {
                await connection.cancel()
                try retryPairingAfter(error, attemptID: attemptID)
                try await Task.sleep(nanoseconds: delayNanoseconds)
                delayNanoseconds = min(delayNanoseconds * 2, 4_000_000_000)
            }
        }
    }

    private func runJoinerPairing(_ invitation: Invitation, session: MLSSession, attemptID: UUID) async {
        do {
            try resetSession()
            guard let session = self.session else { throw SyncError.localStorageUnavailable }
            let (connection, groupID, inviterFingerprint) = try await awaitInviterOffer(
                invitation: invitation, attemptID: attemptID
            )
            if let expectedGroup = invitation.groupID, let expectedFingerprint = invitation.inviterFingerprint {
                guard groupID == expectedGroup, inviterFingerprint == expectedFingerprint else {
                    await connection.cancel()
                    throw SyncError.invalidPairMessage
                }
            }
            let published = try await session.publishKeyPackage(pairingToken: invitation.pairingToken)
            try requireCurrentPairingAttempt(attemptID)
            let joinerNonce = try Data.secureRandom(count: 32)
            let commitment = try PairingFrame.commitment(PairingSafetyCode.commitment(
                groupID: groupID,
                inviterFingerprint: inviterFingerprint,
                keyPackageReference: published.reference,
                joinerFingerprint: published.fingerprint,
                joinerNonce: joinerNonce
            )).seal(for: invitation, from: .fromJoiner)
            try await connection.send(commitment)
            let inviterNonce = try await awaitInviterNonce(
                on: connection, invitation: invitation, commitment: commitment, attemptID: attemptID
            )
            try await connection.send(
                PairingFrame.response(
                    keyPackageReference: published.reference,
                    joinerFingerprint: published.fingerprint,
                    joinerNonce: joinerNonce
                ).seal(for: invitation, from: .fromJoiner)
            )
            safetyCode = PairingSafetyCode.code(
                groupID: groupID,
                inviterFingerprint: inviterFingerprint,
                joinerFingerprint: published.fingerprint,
                inviterNonce: inviterNonce,
                joinerNonce: joinerNonce
            )
            phase = .verifying
            listenForInviterDecision(on: connection, invitation: invitation, attemptID: attemptID)

            while true {
                try requireCurrentPairingAttempt(attemptID)
                if let deadline = pairingDeadline, Date() >= deadline {
                    throw SyncError.invitationExpired
                }
                if peerDecision == false {
                    throw SyncError.pairingDeclined
                }
                do {
                    if try await session.join(
                        group: groupID,
                        keyPackageReference: published.reference,
                        verifiedInviterFingerprint: inviterFingerprint
                    ) {
                        break
                    }
                } catch let error where Self.isTransientTransportFailure(error) {}
                try await Task.sleep(nanoseconds: pairingRetryDelayNanoseconds)
            }
            pairingReaderTask?.cancel()
            pairingReaderTask = nil
            await connection.cancel()
            try requireCurrentPairingAttempt(attemptID)
            let roster = try await session.members()
            try saveCheckpoint(ReplicationCheckpoint(
                group: groupID,
                members: roster.map(ReplicationCheckpoint.Member.init),
                joinPending: true,
                provider: inviterFingerprint
            ))
            finishPairing(attemptID: attemptID)
        } catch {
            pairingFailed(error, attemptID: attemptID)
        }
    }

    private func awaitInviterNonce(
        on connection: any PairingConnection,
        invitation: Invitation,
        commitment: Data,
        attemptID: UUID
    ) async throws -> Data {
        while true {
            let event = try await connection.receive()
            try requireCurrentPairingAttempt(attemptID)
            switch event {
            case .peerReady:
                try await connection.send(commitment)
            case .peerLeft:
                continue
            case .binary(let frame):
                switch try PairingFrame.open(frame, for: invitation, from: .fromInviter) {
                case .nonce(let nonce):
                    return nonce
                case .offer:
                    continue
                case .decision:
                    throw SyncError.pairingDeclined
                case .commitment, .response:
                    throw SyncError.invalidPairMessage
                }
            case .error(let code):
                throw SyncError.mapRelayCode(code)
            }
        }
    }

    private func awaitInviterOffer(
        invitation: Invitation,
        attemptID: UUID
    ) async throws -> (any PairingConnection, Data, Data) {
        var delayNanoseconds: UInt64 = 500_000_000
        while true {
            let connection = try await connectPairing(route: invitation.route, attemptID: attemptID)
            do {
                while true {
                    let event = try await connection.receive()
                    try requireCurrentPairingAttempt(attemptID)
                    switch event {
                    case .peerReady, .peerLeft:
                        continue
                    case .binary(let frame):
                        switch try PairingFrame.open(frame, for: invitation, from: .fromInviter) {
                        case .offer(let group, let fingerprint):
                            return (connection, group, fingerprint)
                        case .decision:
                            throw SyncError.pairingDeclined
                        case .commitment, .nonce, .response:
                            throw SyncError.invalidPairMessage
                        }
                    case .error(let code):
                        throw SyncError.mapRelayCode(code)
                    }
                }
            } catch {
                await connection.cancel()
                try retryPairingAfter(error, attemptID: attemptID)
                try await Task.sleep(nanoseconds: delayNanoseconds)
                delayNanoseconds = min(delayNanoseconds * 2, 4_000_000_000)
            }
        }
    }

    private func connectPairing(route: Data, attemptID: UUID) async throws -> any PairingConnection {
        var delayNanoseconds: UInt64 = 500_000_000
        while true {
            try requireCurrentPairingAttempt(attemptID)
            do {
                let connection = try await rendezvous.connect(route: route)
                guard isCurrentPairingAttempt(attemptID) else {
                    await connection.cancel()
                    throw CancellationError()
                }
                pairingConnection = connection
                return connection
            } catch {
                try retryPairingAfter(error, attemptID: attemptID)
                try await Task.sleep(nanoseconds: delayNanoseconds)
                delayNanoseconds = min(delayNanoseconds * 2, 4_000_000_000)
            }
        }
    }

    private func retryPairingAfter(_ error: Error, attemptID: UUID) throws {
        guard isCurrentPairingAttempt(attemptID), !(error is CancellationError) else {
            throw CancellationError()
        }
        if let deadline = pairingDeadline, Date() >= deadline {
            throw SyncError.invitationExpired
        }
        guard Self.isTransientTransportFailure(error) || SyncError.fromTransport(error) as? SyncError == .privateSyncUnreachable else {
            throw error
        }
    }

    private func listenForJoinerCancellation(on connection: any PairingConnection, invitation: Invitation, attemptID: UUID) {
        pairingReaderTask?.cancel()
        pairingReaderTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let event = try? await connection.receive() else { return }
                guard
                    case .binary(let frame) = event,
                    case .decision(false)? = try? PairingFrame.open(frame, for: invitation, from: .fromJoiner)
                else {
                    continue
                }
                guard let self, self.pairingAttemptID == attemptID else { return }
                self.peerDecision = false
                self.resolveApproval(.rejected)
                return
            }
        }
    }

    private func listenForInviterDecision(on connection: any PairingConnection, invitation: Invitation, attemptID: UUID) {
        pairingReaderTask?.cancel()
        pairingReaderTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let event = try? await connection.receive() else { return }
                guard
                    case .binary(let frame) = event,
                    case .decision(let approved)? = try? PairingFrame.open(frame, for: invitation, from: .fromInviter)
                else {
                    continue
                }
                guard let self, self.pairingAttemptID == attemptID else { return }
                self.peerDecision = approved
                if approved { return }
            }
        }
    }

    private enum ApprovalOutcome {
        case approved
        case rejected
        case expired
    }

    /// The wait ends before the relay discards the joiner's KeyPackage, so an
    /// approval can always be provisioned.
    private func waitForApproval(attemptID: UUID) async -> ApprovalOutcome {
        guard isCurrentPairingAttempt(attemptID) else { return .rejected }
        let timeout = approvalTimeoutNanoseconds
        let timer = Task { [weak self] in
            guard (try? await Task.sleep(nanoseconds: timeout)) != nil,
                  let self, self.pairingAttemptID == attemptID
            else {
                return
            }
            self.resolveApproval(.expired)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation in
            approvalContinuation = continuation
        }
    }

    private func resolveApproval(_ outcome: ApprovalOutcome) {
        if isHostApprovalPending {
            isHostApprovalPending = false
        }
        guard let continuation = approvalContinuation else { return }
        approvalContinuation = nil
        continuation.resume(returning: outcome)
    }

    private func isCurrentPairingAttempt(_ attemptID: UUID) -> Bool {
        pairingAttemptID == attemptID && !Task.isCancelled
    }

    private func requireCurrentPairingAttempt(_ attemptID: UUID) throws {
        guard isCurrentPairingAttempt(attemptID) else {
            throw CancellationError()
        }
    }

    private func declinePeer() {
        guard let connection = pairingConnection, let invitation = activeInvitation, let role = activePairingRole else {
            return
        }
        pairingConnection = nil
        let direction: PairingFrame.Direction = role == .host ? .fromInviter : .fromJoiner
        Task {
            if let frame = try? PairingFrame.decision(approved: false).seal(for: invitation, from: direction) {
                try? await connection.send(frame)
            }
            await connection.cancel()
        }
    }

    private func endPairingAttempt() {
        pairingTask?.cancel()
        pairingExpiryTask?.cancel()
        pairingReaderTask?.cancel()
        if let pairingConnection {
            Task { await pairingConnection.cancel() }
        }
        resolveApproval(.rejected)
        pairingAttemptID = nil
        pairingDeadline = nil
        pairingTask = nil
        pairingExpiryTask = nil
        pairingReaderTask = nil
        pairingConnection = nil
        activeInvitation = nil
        peerDecision = nil
        invitationPhrase = nil
        invitationURL = nil
        invitationExpiresAt = nil
        safetyCode = nil
        isHostApprovalPending = false
        activePairingRole = nil
    }

    private func finishPairing(attemptID: UUID) {
        guard pairingAttemptID == attemptID else {
            return
        }
        pairingTask = nil
        endPairingAttempt()
        errorMessage = nil
        isPaired = true
        lastCycleSucceeded = false
        syncFailureCount = 0
        nextSyncAttemptAt = .distantPast
        refreshPendingMailboxCount()
        phase = .connecting
        presentLinkCompleteCelebration()
        startSyncLoop()
    }

    private func pairingFailed(_ error: Error, attemptID: UUID) {
        guard pairingAttemptID == attemptID, !(error is CancellationError) else {
            return
        }
        pairingTask = nil
        let wasJoining = activePairingRole == .joiner
        declinePeer()
        endPairingAttempt()
        if wasJoining && !isPaired {
            try? resetSession()
        }
        let mapped = SyncError.fromTransport(error)
        errorMessage = Self.displayMessage(for: mapped is SyncError ? mapped : SyncError.invalidPairMessage)
        if isPaired {
            restorePhaseAfterPairing()
        } else {
            phase = .failed
        }
    }

    private func restorePhaseAfterPairing() {
        guard isPaired else {
            phase = .unpaired
            return
        }
        if isHistoryBlocked {
            phase = .failed
        } else {
            phase = lastCycleSucceeded ? .synced : .connecting
            startSyncLoop()
        }
    }

    private func presentLinkCompleteCelebration() {
        showsLinkCompleteCelebration = true
        linkCompleteCelebrationTask?.cancel()
        linkCompleteCelebrationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(SyncTiming.linkCompleteCelebrationDuration))
            guard !Task.isCancelled else {
                return
            }
            self?.showsLinkCompleteCelebration = false
            self?.linkCompleteCelebrationTask = nil
        }
    }

    // MARK: - Replication

    private func reconcileSession() async {
        defer { reconcileTask = nil }
        guard let session else {
            return
        }
        do {
            if try await session.isRemoved() {
                handleRemoval()
                return
            }
            let group = try await session.group()
            let roster = group == nil ? [] : try await session.members()
            guard self.session === session, pairingTask == nil || isPaired else {
                return
            }
            if let group, roster.count >= 2 || checkpoint?.group == group {
                if var current = checkpoint, current.group == group {
                    current.members = roster.map(ReplicationCheckpoint.Member.init)
                    try saveCheckpoint(current)
                } else {
                    try saveCheckpoint(ReplicationCheckpoint(
                        group: group,
                        members: roster.map(ReplicationCheckpoint.Member.init),
                        joinPending: true,
                        provider: nil
                    ))
                }
                if !isPaired {
                    isPaired = true
                    phase = .connecting
                }
                startSyncLoop()
            } else if checkpoint != nil {
                try ReplicationCheckpoint.remove(at: checkpointURL)
                checkpoint = nil
                isPaired = false
                phase = .unpaired
                errorMessage = Self.displayMessage(for: SyncError.relinkRequired)
            }
        } catch is CancellationError {
            return
        } catch {
            if isPaired {
                startSyncLoop()
            }
        }
    }

    private func startSyncLoop() {
        guard
            appIsActive,
            hasDurableStorage,
            isPaired,
            session != nil,
            !isHistoryBlocked
        else {
            return
        }
        requestSyncCycle(force: true)
        guard syncLoopTask == nil else {
            return
        }
        let interval = syncIntervalNanoseconds
        syncLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard (try? await Task.sleep(nanoseconds: interval)) != nil else {
                    return
                }
                guard let self, self.appIsActive, self.isPaired else {
                    self?.syncLoopTask = nil
                    return
                }
                self.requestSyncCycle(force: false)
            }
        }
    }

    private func requestSyncCycle(force: Bool, allowInactive: Bool = false) {
        guard
            hasDurableStorage,
            isPaired,
            !isHistoryBlocked,
            appIsActive || allowInactive,
            force || Date() >= nextSyncAttemptAt,
            let session
        else {
            return
        }
        syncCycleRequested = true
        guard syncCycleTask == nil else {
            return
        }
        let cycleID = UUID()
        syncCycleID = cycleID
        syncCycleTask = Task { [weak self] in
            await self?.drainSyncCycles(session: session, cycleID: cycleID)
        }
    }

    private func drainSyncCycles(session: MLSSession, cycleID: UUID) async {
        while !Task.isCancelled, syncCycleID == cycleID, syncCycleRequested, self.session === session, isPaired {
            syncCycleRequested = false
            if mailboxState != .syncing {
                mailboxState = .syncing
            }
            do {
                try await performSyncCycle(session: session)
                guard syncCycleID == cycleID else { break }
                syncSucceeded()
            } catch {
                guard !Task.isCancelled, syncCycleID == cycleID, self.session === session else {
                    break
                }
                syncFailed(error)
                break
            }
        }
        guard syncCycleID == cycleID else {
            return
        }
        syncCycleTask = nil
        syncCycleID = nil
        if syncCycleRequested, isPaired, !isHistoryBlocked {
            requestSyncCycle(force: true, allowInactive: !appIsActive)
        }
    }

    private func syncSucceeded() {
        syncFailureCount = 0
        nextSyncAttemptAt = .distantPast
        lastCycleSucceeded = true
        if mailboxError != nil { mailboxError = nil }
        if mailboxErrorMessage != nil { mailboxErrorMessage = nil }
        if mailboxRequiresRepair { mailboxRequiresRepair = false }
        if mailboxCapacityReached { mailboxCapacityReached = false }
        if mailboxState != .available { mailboxState = .available }
        guard pairingTask == nil, appIsActive else {
            return
        }
        if errorMessage != nil { errorMessage = nil }
        if phase != .synced { phase = .synced }
    }

    private func syncFailed(_ error: Error) {
        lastCycleSucceeded = false
        switch Self.classifySyncFailure(error) {
        case .cancelled:
            return
        case .removed:
            handleRemoval()
        case .blocked:
            isHistoryBlocked = true
            syncLoopTask?.cancel()
            syncLoopTask = nil
            mailboxError = .syncHistoryBlocked
            mailboxErrorMessage = Self.displayMessage(for: SyncError.syncHistoryBlocked)
            mailboxRequiresRepair = true
            mailboxState = .unavailable
            errorMessage = mailboxErrorMessage
            if pairingTask == nil {
                phase = .failed
            }
        case .storage where appIsActive:
            handleLocalMutationFailure(error)
        case .storage, .transient:
            syncFailureCount = min(syncFailureCount + 1, 16)
            let exponent = min(syncFailureCount - 1, 4)
            nextSyncAttemptAt = Date().addingTimeInterval(min(Double(2 * (1 << exponent)), 30) + Double.random(in: 0...0.5))
            mailboxError = SyncError.fromTransport(error) as? SyncError
            mailboxErrorMessage = Self.displayMessage(for: error)
            mailboxCapacityReached = (error as? MLSRelayError) == .capacityReached
            mailboxState = .unavailable
            if pairingTask == nil, appIsActive {
                phase = .offline
                errorMessage = mailboxErrorMessage
            }
        }
    }

    private func performSyncCycle(session: MLSSession) async throws {
        guard hasDurableStorage else {
            throw SyncError.localStorageUnavailable
        }
        _ = try await session.flush()
        try await drainInbox(session: session)
        var synchronized = false
        for _ in 0..<4 where !synchronized {
            do {
                try await session.synchronize()
                synchronized = true
            } catch MLSClientError.capacityReached {
                try await drainInbox(session: session)
            }
        }
        if try await session.isRemoved() {
            throw MLSSessionError.removed
        }
        try await drainInbox(session: session)
        try await processRemovals(session: session)
        if checkpoint?.joinPending == true {
            try await announceJoin(session: session)
        }
        try await uploadLocalOperations(session: session)
    }

    private func drainInbox(session: MLSSession) async throws {
        let messages = try await session.inbox()
        guard let last = messages.last else {
            return
        }
        let fingerprint = try await session.fingerprint()
        let senders = Set(messages.map(\.sender))
        if var current = checkpoint, current.provisionalMembers.contains(where: { senders.contains($0.fingerprint) }) {
            current.provisionalMembers.removeAll { senders.contains($0.fingerprint) }
            try saveCheckpoint(current)
        }
        var pool: [TaskOperation] = []
        var hellos: [ReplicationMessage] = []
        for message in messages where message.sender != fingerprint {
            guard let decoded = try? ReplicationMessage.decode(message.plaintext) else {
                continue
            }
            switch decoded.kind {
            case .operations:
                pool.append(contentsOf: decoded.operations ?? [])
            case .hello:
                hellos.append(decoded)
            }
        }
        let accepted = try applyRemoteOperations(&pool)
        if accepted > 0 {
            publishReplica()
            lastSyncedAt = Date()
            lastMailboxReceivedAt = Date()
        }
        for hello in hellos {
            try await answer(hello, fingerprint: fingerprint, session: session)
        }
        if !pool.isEmpty {
            try await send(.hello(vector: replica.versionVector, provider: nil), session: session)
        }
        try await session.acknowledgeInbox(through: last.cursor)
    }

    /// Applies every operation whose origin sequence is next, repeating until
    /// no more apply. Operations still waiting on a gap remain in `pool`.
    private func applyRemoteOperations(_ pool: inout [TaskOperation]) throws -> Int {
        var remaining = pool.sorted(by: ReplicaOrdering.operations)
        var accepted = 0
        while !remaining.isEmpty {
            var vector = replica.versionVector
            var ready: [TaskOperation] = []
            var waiting: [TaskOperation] = []
            for operation in remaining {
                let current = vector[operation.originDeviceID]
                if operation.originSequence <= current {
                    continue
                } else if operation.originSequence == current + 1 {
                    ready.append(operation)
                    vector.setSequence(operation.originSequence, for: operation.originDeviceID)
                } else {
                    waiting.append(operation)
                }
            }
            guard !ready.isEmpty else {
                remaining = waiting
                break
            }
            for batch in try OperationBatcher.batches(ready) {
                do {
                    accepted += try replica.applyRemote(batch)
                } catch is ReplicaError {
                    for operation in batch {
                        do {
                            accepted += try replica.applyRemote([operation])
                        } catch is ReplicaError {}
                    }
                }
            }
            remaining = waiting
        }
        pool = remaining
        return accepted
    }

    private func answer(_ hello: ReplicationMessage, fingerprint: Data, session: MLSSession) async throws {
        guard let vector = hello.vector, let uploadedThrough = checkpoint?.uploadedThrough else {
            return
        }
        let isProvider = hello.provider == fingerprint
        let operations = replica.operations(missingFrom: vector).filter {
            if $0.originDeviceID == deviceID {
                return $0.originSequence <= uploadedThrough
            }
            return isProvider
        }
        try await send(operations, session: session)
    }

    private func announceJoin(session: MLSSession) async throws {
        guard let announced = checkpoint else {
            return
        }
        let vector = replica.versionVector
        let operations = replica.retainedOperations
        try await send(.hello(vector: vector, provider: announced.provider), session: session)
        try await send(operations, session: session)
        guard var current = checkpoint, current.group == announced.group else {
            throw CancellationError()
        }
        current.joinPending = false
        current.provider = nil
        current.uploadedThrough = max(current.uploadedThrough, vector[deviceID])
        try saveCheckpoint(current)
        lastMailboxStoredAt = Date()
        refreshPendingMailboxCount()
    }

    private func uploadLocalOperations(session: MLSSession) async throws {
        while var current = checkpoint {
            let localSequence = replica.versionVector[deviceID]
            if current.uploadedThrough > localSequence {
                current.uploadedThrough = localSequence
                try saveCheckpoint(current)
            }
            guard current.uploadedThrough < localSequence else {
                break
            }
            let pending = replica.retainedOperations.filter {
                $0.originDeviceID == deviceID && $0.originSequence > current.uploadedThrough
            }
            guard pending.first?.originSequence == current.uploadedThrough + 1,
                  let batch = try OperationBatcher.batches(pending).first,
                  let last = batch.last
            else {
                throw ReplicaError.sequenceGap(
                    origin: deviceID,
                    expected: current.uploadedThrough + 1,
                    received: pending.first?.originSequence ?? 0
                )
            }
            try await send(.operations(batch), session: session)
            guard var latest = checkpoint, latest.group == current.group else {
                throw CancellationError()
            }
            latest.uploadedThrough = max(latest.uploadedThrough, last.originSequence)
            try saveCheckpoint(latest)
            lastMailboxStoredAt = Date()
            refreshPendingMailboxCount()
        }
        refreshPendingMailboxCount()
    }

    private func send(_ operations: [TaskOperation], session: MLSSession) async throws {
        for batch in try OperationBatcher.batches(operations) {
            try await send(.operations(batch), session: session)
        }
    }

    private func send(_ message: ReplicationMessage, session: MLSSession) async throws {
        guard case .accepted = try await session.send(message.encoded()) else {
            throw SyncCycleError.notDelivered
        }
    }

    @discardableResult
    private func refreshMembers(session: MLSSession) async throws -> [MLSMember] {
        let roster = try await session.members()
        let fingerprints = roster.map(\.fingerprint)
        guard var current = checkpoint else {
            return roster
        }
        let previous = current
        current.members = roster.map(ReplicationCheckpoint.Member.init)
        current.pendingRemovals.removeAll { !fingerprints.contains($0) }
        current.provisionalMembers.removeAll { !fingerprints.contains($0.fingerprint) }
        if current != previous {
            try saveCheckpoint(current)
        }
        return roster
    }

    /// Commits removals requested with `removeDevice`, members whose leave
    /// proposal this device received, and added members that never joined.
    private func processRemovals(session: MLSSession) async throws {
        for _ in 0..<Self.maximumRemovalAttempts {
            let roster = try await refreshMembers(session: session)
            guard let current = checkpoint else { return }
            let now = Date()
            let candidates = current.pendingRemovals
                + (try await session.departures())
                + current.provisionalMembers.filter { $0.deadline <= now }.map(\.fingerprint)
            guard let target = candidates.first(where: { candidate in
                roster.contains { $0.fingerprint == candidate && $0.deviceID != deviceID.bytes }
            }) else {
                return
            }
            _ = try await session.remove(fingerprint: target)
        }
        try await refreshMembers(session: session)
    }

    private func handleRemoval() {
        guard isPaired || checkpoint != nil else {
            try? resetSession()
            return
        }
        dropLink(departing: false)
        errorMessage = Self.displayMessage(for: SyncError.removedFromGroup)
    }

    // MARK: - Departures

    private static func departureKeyAccount(_ name: String) -> String {
        "\(SecretStoreMLSStateKey.account).departing.\(name)"
    }

    private func departureSlots() -> [URL] {
        let slots = (try? FileManager.default.contentsOfDirectory(
            at: departuresDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []
        return slots.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return lhs < rhs
        }
    }

    /// Moves the MLS state and its key into a new departure slot.
    private func stageDeparture() throws {
        guard FileManager.default.fileExists(atPath: mlsDirectory.path) else { return }
        guard let key = try secretStore.read(account: SecretStoreMLSStateKey.account) else {
            try eraseCurrentMLSState()
            return
        }
        for stale in departureSlots().dropLast(Self.maximumDepartures - 1) {
            try MLSSession.erase(
                directory: stale, secretStore: secretStore, keyAccount: Self.departureKeyAccount(stale.lastPathComponent)
            )
        }
        let name = UUID().uuidString.lowercased()
        try FileManager.default.createDirectory(
            at: departuresDirectory,
            withIntermediateDirectories: true,
            attributes: ProtectedStorage.directoryAttributes
        )
        try secretStore.write(key, account: Self.departureKeyAccount(name), accessibility: .afterFirstUnlockThisDeviceOnly)
        try FileManager.default.moveItem(at: mlsDirectory, to: departuresDirectory.appendingPathComponent(name, isDirectory: true))
        mlsDirectory = Self.freshMLSDirectory(in: mlsRoot)
        try secretStore.delete(account: SecretStoreMLSStateKey.account)
    }

    private func startDepartures() {
        guard hasDurableIdentity, departureTask == nil, !departureSlots().isEmpty else { return }
        let delays = departureRetryDelayNanoseconds
        departureTask = Task { [weak self] in
            var delayNanoseconds = delays.lowerBound
            while true {
                guard let self, !Task.isCancelled else { return }
                if await self.publishDepartures() { break }
                guard (try? await Task.sleep(nanoseconds: delayNanoseconds)) != nil else { return }
                delayNanoseconds = min(delayNanoseconds * 2, delays.upperBound)
            }
            self?.departureTask = nil
        }
    }

    /// Returns whether every departure slot was published or discarded.
    private func publishDepartures() async -> Bool {
        var complete = true
        for slot in departureSlots() {
            let account = Self.departureKeyAccount(slot.lastPathComponent)
            do {
                let departing = try MLSSession(
                    directory: slot, deviceID: deviceID.bytes, secretStore: secretStore, keyAccount: account, transport: mlsTransport
                )
                try await departing.leave()
            } catch is CancellationError {
                return false
            } catch let error where Self.isRetriableDeparture(error) {
                complete = false
                continue
            } catch {}
            try? MLSSession.erase(directory: slot, secretStore: secretStore, keyAccount: account)
        }
        return complete
    }

    private static func isRetriableDeparture(_ error: Error) -> Bool {
        switch error {
        case MLSRelayError.unauthorized, MLSRelayError.invalidRequest, MLSRelayError.unsupportedVersion:
            return false
        case MLSSessionError.unresolvedConflict, MLSClientError.storageUnavailable:
            return true
        default:
            return isTransientTransportFailure(error)
        }
    }

    private func startBackgroundMailboxFlush() {
        guard isPaired, hasDurableStorage else {
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

    private func localReplicaChanged() {
        publishReplica()
        refreshPendingMailboxCount()
        requestSyncCycle(force: true)
    }

    // MARK: - Local state

    private func openSession() throws -> MLSSession {
        try MLSSession(directory: mlsDirectory, deviceID: deviceID.bytes, secretStore: secretStore, transport: mlsTransport)
    }

    private func resetSession() throws {
        session = nil
        try eraseCurrentMLSState()
        session = try openSession()
    }

    /// Each session generation gets a new directory. A closed-over session
    /// that is still open can then never create journal files next to the
    /// database of the session that replaced it.
    private func eraseCurrentMLSState() throws {
        try MLSSession.erase(directory: mlsDirectory, secretStore: secretStore)
        mlsDirectory = Self.freshMLSDirectory(in: mlsRoot)
    }

    private static func freshMLSDirectory(in root: URL) -> URL {
        root.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    }

    private static func currentMLSDirectory(in root: URL) -> URL {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []
        let generations = entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let newest = generations.max {
            let lhs = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return lhs < rhs
        }
        return newest ?? freshMLSDirectory(in: root)
    }

    private func saveCheckpoint(_ value: ReplicationCheckpoint) throws {
        try value.save(to: checkpointURL)
        checkpoint = value
    }

    private func cancelAllWork() {
        endPairingAttempt()
        reconcileTask?.cancel()
        syncLoopTask?.cancel()
        syncCycleTask?.cancel()
        backgroundFlushTask?.cancel()
        reconcileTask = nil
        syncLoopTask = nil
        syncCycleTask = nil
        syncCycleID = nil
        backgroundFlushTask = nil
        syncCycleRequested = false
        cancelPresentationTasks()
    }

    private func resetLinkState() {
        checkpoint = nil
        isPaired = false
        isHistoryBlocked = false
        lastCycleSucceeded = false
        syncFailureCount = 0
        nextSyncAttemptAt = .distantPast
        lastRoundTripMilliseconds = nil
        lastSyncedAt = nil
        lastMailboxStoredAt = nil
        lastMailboxReceivedAt = nil
        errorMessage = nil
        mailboxErrorMessage = nil
        mailboxError = nil
        mailboxRequiresRepair = false
        mailboxCapacityReached = false
        mailboxState = .idle
        keepBothPreview = nil
        hasPairingReplicaConflict = false
        showsLinkCompleteCelebration = false
        showsSavingNotice = false
        pendingMailboxSince = nil
        refreshPendingMailboxCount()
        backgroundMailboxScheduler.cancelFlush()
        phase = .unpaired
    }

    private func cancelPresentationTasks() {
        savingNoticeRevealTask?.cancel()
        savingNoticeRevealTask = nil
        linkCompleteCelebrationTask?.cancel()
        linkCompleteCelebrationTask = nil
    }

    private func publishReplica() {
        tasks = replica.tasks
    }

    private func refreshPendingMailboxCount() {
        let localSequence = replica.versionVector[deviceID]
        let uploaded = checkpoint?.uploadedThrough ?? 0
        let pending = localSequence > uploaded ? Int(localSequence - uploaded) : 0
        if pending == 0 {
            if pendingMailboxOperationCount != 0 { pendingMailboxOperationCount = 0 }
            pendingMailboxSince = nil
            if showsSavingNotice { showsSavingNotice = false }
            savingNoticeRevealTask?.cancel()
            savingNoticeRevealTask = nil
            return
        }
        if pendingMailboxOperationCount == 0 {
            pendingMailboxSince = Date()
            showsSavingNotice = false
            savingNoticeRevealTask?.cancel()
            savingNoticeRevealTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(SyncTiming.savingNoticeDelay))
                guard !Task.isCancelled, let self, self.pendingMailboxOperationCount > 0 else {
                    return
                }
                self.showsSavingNotice = true
                self.savingNoticeRevealTask = nil
            }
        }
        if pendingMailboxOperationCount != pending {
            pendingMailboxOperationCount = pending
        }
    }

    private func fail(_ error: Error) {
        errorMessage = Self.displayMessage(for: SyncError.fromTransport(error))
        phase = .failed
    }

    private func handleLocalMutationFailure(_ error: Error) {
        errorMessage = Self.displayMessage(for: error)
        localEditErrorMessage = errorMessage
        guard !(error is ReplicaError) else {
            return
        }
        hasDurableStorage = false
        phase = .failed
        syncLoopTask?.cancel()
        syncCycleTask?.cancel()
        syncLoopTask = nil
        syncCycleTask = nil
        syncCycleID = nil
        syncCycleRequested = false
    }

    private enum SyncFailure {
        case cancelled
        case removed
        case blocked
        case storage
        case transient
    }

    private static func classifySyncFailure(_ error: Error) -> SyncFailure {
        switch error {
        case is CancellationError:
            return .cancelled
        case MLSSessionError.removed:
            return .removed
        case MLSSessionError.unresolvedConflict, is SyncCycleError:
            return .transient
        case MLSClientError.storageUnavailable, MLSClientError.capacityReached, is MLSStoreError:
            return .transient
        case is ReplicaError, is CocoaError, SyncError.localStorageUnavailable:
            return .storage
        case _ where isTransientTransportFailure(error):
            return .transient
        default:
            return .blocked
        }
    }

    private static func isTransientTransportFailure(_ error: Error) -> Bool {
        error is URLError || error is MLSRelayError || error is RelaySocketError
            || (error as NSError).domain == NSURLErrorDomain
            || (error as NSError).domain == NSPOSIXErrorDomain
    }

    private static func isUnrecoverableSessionState(_ error: Error) -> Bool {
        if case MLSStoreError.unreadable = error { return true }
        if case MLSClientError.invalidState = error { return true }
        return false
    }

    private static func persistEraseMarker(at markerURL: URL) throws {
        try Data([SyncProtocol.version]).write(to: markerURL, options: .atomic)
        try FileManager.default.setAttributes(ProtectedStorage.fileAttributes, ofItemAtPath: markerURL.path)
        let handle = try FileHandle(forWritingTo: markerURL)
        defer {
            try? handle.close()
        }
        try handle.synchronize()
    }

    private static func completeErase(
        store: CredentialStore,
        secretStore: any SecretStore,
        deviceID: ReplicaDeviceID,
        persistenceURL: URL,
        checkpointURL: URL,
        mlsRoot: URL,
        markerURL: URL
    ) throws -> TaskReplica {
        try store.clearPair()
        try removeAllPairingArtifacts(in: persistenceURL.deletingLastPathComponent())
        try ReplicationCheckpoint.remove(at: checkpointURL)
        try MLSSession.erase(directory: mlsRoot, secretStore: secretStore)
        if FileManager.default.fileExists(atPath: persistenceURL.path) {
            try FileManager.default.removeItem(at: persistenceURL)
        }
        let clearedReplica = try TaskReplica(deviceID: deviceID, persistenceURL: persistenceURL)
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
        if let localized = mapped as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "Cannot reach the sync service."
    }
}

private enum SyncCycleError: Error {
    case notDelivered
}

extension ReplicationCheckpoint.Member {
    init(_ member: MLSMember) {
        self.init(deviceID: member.deviceID, fingerprint: member.fingerprint)
    }
}

extension SyncEngine {
    var mlsSessionForTesting: MLSSession? { session }
    var mlsDirectoryForTesting: URL { mlsDirectory }
}
