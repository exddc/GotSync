import CryptoKit
import Foundation
import GotSyncMLS

public enum SyncPhase: Equatable, Sendable {
    case unpaired
    case waitingForPeer
    case verifying
    case provisioning
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
    case invalidCredentials
    /// Opaque/unmapped relay code — still user-outcome wording, not “check network.”
    case relay(String)
    /// Distinct taxonomy: other phone cancelled / declined.
    case pairingDeclined
    /// Distinct taxonomy: invitation or waiting-room window ended.
    case invitationExpired
    /// Distinct taxonomy: cannot reach private sync infrastructure.
    case privateSyncUnreachable
    case localStorageUnavailable
    case groupAtCapacity
    case taskHistoryAtCapacity
    case unsupportedProtocolVersion
    case relinkRequired
    case syncHistoryBlocked
    case syncHistoryExpired
    /// Another device sent an operation whose ID this device already holds
    /// with different content.
    case syncHistoryConflict
    case removedFromGroup
    case approvalExpired
    /// Linked devices sent valid changes that would exceed this device's task,
    /// change-history, or device-history limit. They are kept on this device,
    /// unapplied, until they fit or the link ends.
    case replicaCapacityReached
    /// The other device or the group uses a different application, data
    /// format, or device limit. Nothing was linked or changed.
    case incompatibleGroupProfile

    public var errorDescription: String? {
        switch self {
        case .invalidPairMessage:
            "Pairing could not continue. Create a new invitation and try again."
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
        case .localStorageUnavailable:
            "Local storage is unavailable. Restart the app after fixing storage."
        case .groupAtCapacity:
            "The group is at its device limit."
        case .taskHistoryAtCapacity:
            "This task history has no room for another device. It keeps changes from up to \(ReplicaLimits.maxOrigins) devices, counting removed devices, and keeps one slot for each linked device. Devices already linked keep syncing."
        case .unsupportedProtocolVersion:
            "The sync service uses an unsupported protocol version."
        case .relinkRequired:
            "This version uses a new sync protocol. Your tasks are safe on this iPhone. Create a new link to sync again."
        case .syncHistoryBlocked:
            "Sync stopped at an update this iPhone could not verify. Your tasks are safe. Unlink and create a new link to keep syncing."
        case .syncHistoryExpired:
            "This iPhone was offline longer than the sync service keeps updates. Your tasks are safe. Unlink and create a new link to keep syncing."
        case .syncHistoryConflict:
            "A linked device sent task changes that conflict with this iPhone's copy, so sync stopped. Your tasks are safe. This can happen when a device was erased with an earlier app version: unlink this iPhone, erase that device again, then link them again."
        case .removedFromGroup:
            "This iPhone was removed from the sync group. Your tasks are safe on this iPhone."
        case .approvalExpired:
            "The safety code was not confirmed in time. Nothing was linked. Create a new invitation and try again."
        case .replicaCapacityReached:
            "This iPhone reached its limit for tasks or sync history. Changes from your other devices are saved here but cannot be shown. Your tasks are safe."
        case .incompatibleGroupProfile:
            "This sync uses a different app, data format, or device limit. Your tasks are safe. Update both apps, then try again."
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
        if case MLSClientError.unsupportedGroupProfile = error {
            return SyncError.incompatibleGroupProfile
        }
        if case MLSSessionError.profileMismatch = error {
            return SyncError.incompatibleGroupProfile
        }
        if let mls = error as? MLSRelayError {
            switch mls {
            case .unsupportedVersion:
                return SyncError.unsupportedProtocolVersion
            case .historyExpired:
                return SyncError.syncHistoryExpired
            default:
                return SyncError.privateSyncUnreachable
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
        case .invitationExpired, .pairingDeclined, .groupAtCapacity, .taskHistoryAtCapacity,
             .invalidPairMessage, .invalidCredentials, .localStorageUnavailable,
             .unsupportedProtocolVersion, .relinkRequired, .syncHistoryBlocked,
             .syncHistoryExpired, .syncHistoryConflict, .removedFromGroup, .approvalExpired,
             .replicaCapacityReached, .incompatibleGroupProfile:
            return false
        }
    }
}

@MainActor
public final class SyncEngine {
    private var stateSubscribers: [UUID: AsyncStream<SyncState>.Continuation] = [:]

    public var state: SyncState {
        SyncState(
            phase: phase,
            tasks: tasks,
            invitationPhrase: invitationPhrase,
            invitationURL: invitationURL,
            invitationExpiresAt: invitationExpiresAt,
            safetyCode: safetyCode,
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
            unappliedRemoteOperationCount: unappliedRemoteOperationCount,
            showsLinkCompleteCelebration: showsLinkCompleteCelebration,
            activePairingRole: activePairingRole,
            showsSavingNotice: showsSavingNotice,
            linkEndedReason: linkEndedReason,
            linkedMemberCount: linkedMemberCount,
            memberLimit: memberLimit,
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
        let start = segmentHookForTesting == nil ? nil : ContinuousClock.now
        let snapshot = state
        for subscriber in stateSubscribers.values { subscriber.yield(snapshot) }
        if let start { segmentHookForTesting?("publish.state", ContinuousClock.now - start) }
    }

    /// Receives the main-actor duration of named engine segments, for
    /// runtime measurements; nil otherwise.
    var segmentHookForTesting: (@MainActor (String, Duration) -> Void)?

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
    /// Members a departing device added that never spoke, removed before it
    /// leaves.
    static let withdrawnMembersFilename = "withdrawn-members.json"
    @available(*, deprecated, message: "Use the engine's memberLimit, which follows its group profile")
    public nonisolated static let maximumGroupSize = SyncGroupProfile.legacyMemberLimit
    private static let maximumAddAttempts = 3
    private static let maximumAddResolutionAttempts = 5
    private static let maximumRemovalAttempts = 8
    private static let maximumDepartures = 8

    public private(set) var phase: SyncPhase = .unpaired { didSet { publishState() } }
    public private(set) var tasks: [ReplicatedTask] = [] { didSet { publishState() } }
    public private(set) var invitationPhrase: String? = nil { didSet { publishState() } }
    public private(set) var invitationURL: URL? = nil { didSet { publishState() } }
    public private(set) var invitationExpiresAt: Date? = nil { didSet { publishState() } }
    public private(set) var safetyCode: String? = nil { didSet { publishState() } }
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
    /// Valid remote operations kept on disk because applying them would exceed
    /// a replica limit. While nonzero, sync reports `.replicaCapacityReached`.
    public var unappliedRemoteOperationCount: Int {
        if let view = hostAdapter?.store?.view {
            return Int(view.undelivered + view.pendingCount + view.quarantineCount)
        }
        return taskAdapter?.deferredOperations.count ?? 0
    }
    private var isReplicaCapacityBlocked: Bool { (taskAdapter?.hasDeferredOperations ?? false) || isInboxBackpressured }
    public private(set) var showsLinkCompleteCelebration = false { didSet { publishState() } }
    /// Host vs joiner for the in-flight pairing attempt (presentation only).
    public private(set) var activePairingRole: DeviceRole? = nil { didSet { publishState() } }
    public private(set) var showsSavingNotice = false { didSet { publishState() } }
    /// Why this device stopped being linked without the user unlinking it:
    /// `.removedFromGroup` or `.relinkRequired`. Cleared when pairing starts.
    public private(set) var linkEndedReason: SyncError? = nil { didSet { publishState() } }

    public let relayURL: URL
    public let mailboxURL: URL
    /// The profile every group of this engine must carry.
    public let groupProfile: SyncGroupProfile

    private let secretStore: any SecretStore
    private let mlsTransport: any MLSRelayTransport
    private let rendezvous: any PairingRendezvous
    private let backgroundMailboxScheduler: any BackgroundMailboxScheduling
    private let invitationURLScheme: String
    private let deviceID: ReplicaDeviceID
    private let persistenceURL: URL
    private let checkpointURL: URL
    private let replyObligationURL: URL
    private let mlsRoot: URL
    private var mlsDirectory: URL
    private let departuresDirectory: URL
    private let hasDurableIdentity: Bool
    private var hasDurableStorage: Bool
    private let replication: any ReplicationData
    private var taskAdapter: TaskReplicationAdapter? { replication as? TaskReplicationAdapter }
    var hostAdapter: HostJournalAdapter? { replication as? HostJournalAdapter }
    /// Host-journal profiles carry opaque host records instead of demo tasks.
    let isHostMode: Bool
    /// The blob service's directory in host mode, nil otherwise.
    let blobDirectory: URL?
    let endpointPolicy: EndpointSecurityPolicy
    var blobService: BlobTransferService?
    var blobOpenTask: Task<BlobTransferService?, Never>?
    /// A retirement requested before the service finished opening.
    var blobRetirePending = false
    /// Bumped by every retirement, so a bind that started earlier is dropped.
    var blobBindingEpoch: UInt64 = 0
    /// The app's snapshot host; nil keeps full-history bootstrap.
    var snapshotHooks: HostSnapshotHooks?
    /// Library-owned snapshot staging and transfers in host mode, nil otherwise.
    let snapshotDirectory: URL?
    var snapshotService: BlobTransferService?
    var snapshotOpenTask: Task<BlobTransferService?, Never>?
    var snapshotRetirePending = false
    var snapshotUpdatesTask: Task<Void, Never>?
    /// Provider exports running, by recipient.
    var snapshotExportTasks: [Data: Task<Void, Never>] = [:]
    /// The recipient's fetch, install or cleanup step.
    var snapshotRecipientTask: Task<Void, Never>?
    let snapshotAdmission = HostSnapshotAdmission()
    /// The provider's export ledger, loaded on first use.
    var snapshotLedgerCache: HostSnapshotExportLedger?
    /// Offers whose fetched content was released in this process.
    var snapshotCleanedIDs: Set<Data> = []
    /// When the current offer's content was first seen unavailable.
    var snapshotUnavailableSince: ContinuousClock.Instant?
    var snapshotRelayProtocolsForTesting: [AnyClass]?
    /// The app's retention host; nil declines every floor.
    var retentionHooks: HostRetentionHooks?
    /// The open retention round, in memory only.
    var retentionRound: HostRetentionRound?
    /// The coordinator's checkpoint export or a member's vote.
    var retentionTask: Task<Void, Never>?
    /// Committed floors other members reported to this joiner, by sender.
    var retentionCorroborations: [Data: HostRetentionCorroboration] = [:]
    /// Joiners that asked for a snapshot and still wait for this member's floor.
    var retentionCorroborationRecipients: Set<Data> = []
    let checkpointFiles = HostCheckpointFiles()
    /// A member lacked a reclamation host; later rounds propose the floor only.
    var retentionReclaimDeclined = false
    var snapshotUnavailableLimitForTesting: Duration?
    private let hostJournalLimits: HostJournalLimits
    private(set) var hostLifecycle: HostLifecycle = .active { didSet { publishHostView() } }
    private var hostLifecycleTask: Task<Void, Never>?
    /// Set while `stop` settles work; nothing new may start meanwhile.
    private var isStopping = false
    private(set) var lastHostLifecycleError: Error?
    private(set) var hostRepair: HostRepair? { didSet { publishHostView() } }
    private var hostIntake: HostIntakeSummary = .unknown
    /// Live tasks that may use MLS; intake settles only when none is.
    private var activeHostWorkers = 0
    /// A settlement was refused because workers were live.
    private var settlementDeferred = false
    private var hostSettlementTask: Task<Void, Never>?
    /// Validates launch journals away from the main actor, then installs them.
    private var hostOpenTask: Task<Void, Never>?
    /// Journals no longer bound, until every accepted command settled and
    /// their connections closed.
    private var hostJournalShutdowns: [UUID: Task<Void, Never>] = [:]
    /// Opens a fresh writer generation for the journal `stop` closed.
    private var hostReopenTask: Task<Void, Error>?
    /// A pairing start that waits for opening to end.
    private var hostLaunchStartTask: Task<Void, Never>?
    /// The one host session reset in flight, by the session it replaces.
    private var hostSessionReset: (owner: ObjectIdentifier, task: Task<HostResetOutcome, Error>)?
    /// A reset session whose close was not proven; held with its files and key.
    private var hostRetainedSession: MLSSession?
    /// Awaited inside a reset before the old session closes, for tests that
    /// queue work on it.
    var resetQueuedWorkHookForTesting: (@MainActor (MLSSession) async -> Void)?
    var resetFinalInboxHookForTesting: (@Sendable ([MLSInboxMessage]) -> Void)?
    /// Receives the join parameters before a joiner commits, for tests.
    var beforeJoinHookForTesting: (@MainActor (_ group: Data, _ reference: Data, _ inviter: Data, _ profile: Data?) async -> Void)?
    /// The launch generation that owns opening, until it settled and its
    /// journals are bound, or stop or closing took over.
    private var hostLaunch: HostLaunch?
    private var hostCheckpointUnreadable = false
    private(set) var hostLaunchesForTesting = 0
    /// Awaited on the main actor before a launch applies its observation.
    var launchObservationHookForTesting: (@MainActor () async -> Void)?
    var preparedJournalHookForTesting: (@MainActor (URL) async -> Void)?
    private var hostViewSubscribers: [UUID: AsyncStream<UInt64>.Continuation] = [:]
    private var hostWorkersForTesting: [Task<Void, Never>] = []
    var settleReadHookForTesting: (@MainActor () async -> Void)?
    /// What a settled intake was checked against: the session, its MLS
    /// operation count and the journal generation. Any later MLS operation or
    /// generation change makes the summary unknown again.
    private var hostIntakeOwner: (session: ObjectIdentifier, operations: UInt64, journal: Data)?
    private var hostViewRevision: UInt64 = 0
    private var pendingHostLifecycle: HostLifecycleRecord?
    private var historyRequestCycles = 0
    static let hostLifecycleFilename = "host-lifecycle.json"
    static let hostJoinBudget: UInt64 = 8 * 1_024 * 1_024
    var session: MLSSession? {
        didSet {
            guard oldValue !== session else { return }
            hostSessionRevisionBase &+= (oldValue?.operationCount.started ?? 0) &+ 1
            publishHostView()
        }
    }
    func isCurrentBlobSession(_ candidate: MLSSession) -> Bool { session === candidate }

    /// Keeps the composed view's revision growing across session
    /// replacement, since a new session counts its operations from zero.
    private var hostSessionRevisionBase: UInt64 = 0
    private(set) var checkpoint: ReplicationCheckpoint? { didSet { publishState() } }
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
    /// Why the inviter refused this joiner, when it said.
    private var peerRefusal: SyncError?
    private(set) var lastPairingFailure: SyncError?
    private var reservationsInFlight: [OriginReservation.Attempt] = []
    private var lastKnownEpoch: UInt64 = 0
    private var reservationRequestCycles = 0
    private static let reservationRequestInterval = 5
    var reservationHookForTesting: (@MainActor () async -> Void)?
    var reservationSendHookForTesting: (@MainActor () async -> Void)?
    var afterAddHookForTesting: (@MainActor () throws -> Void)?
    /// Host only: awaited after the Add and before the joiner's decision is
    /// read, for tests that hold the inviter while the joiner declines.
    var afterAddGateForTesting: (@MainActor () async -> Void)?
    var peerDecisionForTesting: Bool? { peerDecision }
    var afterJoinHookForTesting: (@MainActor () async -> Void)?
    var beforeReservationRequestHookForTesting: (@MainActor () throws -> Void)?
    private var reconcileTask: Task<Void, Never>?
    private var reconcileTaskID: UUID?
    /// Settles a cancelled host join. While it runs no pairing may start,
    /// because only it may adopt or discard the session that attempt used.
    private var joinSettlementTask: Task<Void, Never>?
    private var syncLoopTask: Task<Void, Never>?
    private var syncCycleTask: Task<Void, Never>?
    private var backgroundFlushTask: Task<Void, Never>?
    private var departureTask: Task<Void, Never>?
    private var syncCycleID: UUID?
    var inboxReadHookForTesting: (@MainActor () async -> Void)?
    var memberReadHookForTesting: (@MainActor () async throws -> Void)?
    var drainMemberReadHookForTesting: (@MainActor () async throws -> Void)?
    /// Awaited after a host chunk intake returns, before anything is saved or acknowledged.
    var chunkIntakeHookForTesting: (@MainActor () async -> Void)?
    var replyBatchHookForTesting: (@MainActor () async -> Void)?
    var snapshotSendHookForTesting: (@MainActor () throws -> Void)?
    /// Runs before each closing step; throwing stops closing there, like a crash.
    var hostClosingHookForTesting: (@MainActor (String) async throws -> Void)?
    private var syncCycleRequested = false
    private var syncFailureCount = 0
    private var nextSyncAttemptAt = Date.distantPast
    private var lastCycleSucceeded = false
    /// The deferred or reply file exists but cannot be read. Sync stays off
    /// so neither is overwritten; unlinking or erasing discards both.
    private var isHeldSyncStateUnreadable = false
    /// The last drain left messages unacknowledged because their blocked
    /// operations did not fit.
    private var isInboxBackpressured = false
    private var answeredHeldHelloCursors: Set<UInt64> = []
    private(set) var replyObligation: ReplyObligation?
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
        departureRetryDelayNanoseconds: ClosedRange<UInt64> = 1_000_000_000...30_000_000_000,
        deferredOperationLimit: Int = DeferredOperationStore.maximumCount,
        hostJournalLimits: HostJournalLimits = .standard
    ) {
        Self.initScopeHookForTesting?("start")
        let baseDirectory = configuration.storageDirectory
        relayURL = configuration.endpoints.relayURL
        mailboxURL = configuration.endpoints.mailboxURL
        endpointPolicy = configuration.endpointPolicy
        invitationURLScheme = configuration.invitationURLScheme
        groupProfile = configuration.groupProfile
        self.secretStore = secretStore
        self.mlsTransport = mlsTransport
            ?? HTTPMLSRelayTransport(baseURL: configuration.endpoints.mailboxURL, policy: configuration.endpointPolicy)
        self.rendezvous = rendezvous
            ?? RelayPairingRendezvous(url: configuration.endpoints.relayURL, policy: configuration.endpointPolicy)
        self.backgroundMailboxScheduler = backgroundMailboxScheduler ?? NoopBackgroundMailboxScheduler()
        self.pairingRetryDelayNanoseconds = pairingRetryDelayNanoseconds
        self.syncIntervalNanoseconds = syncIntervalNanoseconds
        self.approvalTimeoutNanoseconds = approvalTimeoutNanoseconds
        self.departureRetryDelayNanoseconds = departureRetryDelayNanoseconds
        self.provisionalMemberWindow = provisionalMemberWindow
        persistenceURL = baseDirectory.appendingPathComponent("replica-v1.json")
        checkpointURL = baseDirectory.appendingPathComponent(ReplicationCheckpoint.filename)
        let deferredOperationsURL = baseDirectory.appendingPathComponent(DeferredOperationStore.filename)
        replyObligationURL = baseDirectory.appendingPathComponent(ReplyObligation.filename)
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
        Self.initScopeHookForTesting?("identity")

        var notice: SyncError?
        isHostMode = configuration.groupProfile.schema.isHostJournal
        blobDirectory = isHostMode ? baseDirectory.appendingPathComponent(BlobTransferService.directoryName, isDirectory: true) : nil
        snapshotDirectory = isHostMode ? baseDirectory.appendingPathComponent(Self.snapshotDirectoryName, isDirectory: true) : nil
        self.hostJournalLimits = hostJournalLimits
        if isHostMode {
            var erasePending = false
            if hasDurableIdentity {
                do {
                    try FileManager.default.createDirectory(
                        at: baseDirectory,
                        withIntermediateDirectories: true,
                        attributes: ProtectedStorage.directoryAttributes
                    )
                    try FileManager.default.setAttributes(ProtectedStorage.directoryAttributes, ofItemAtPath: baseDirectory.path)
                    erasePending = FileManager.default.fileExists(
                        atPath: baseDirectory.appendingPathComponent(Self.eraseMarkerFilename).path
                    )
                    hasDurableStorage = true
                } catch {
                    bootError = bootError ?? error
                    hasDurableStorage = false
                }
            } else {
                hasDurableStorage = false
            }
            Self.initScopeHookForTesting?("directories")
            let adapter = HostJournalAdapter(directory: baseDirectory, limits: hostJournalLimits)
            adapter.declaresAncestry = configuration.groupProfile.schema.allowsReclamation
            replication = adapter
            if hasDurableStorage {
                do {
                    if try LegacyLinkCredentials.exist(in: secretStore) {
                        try LegacyLinkCredentials.erase(from: secretStore)
                        notice = .relinkRequired
                    }
                    try Self.removeAllPairingArtifacts(in: baseDirectory)
                    Self.initScopeHookForTesting?("artifacts")
                    var checkpointUnreadable = false
                    do {
                        checkpoint = try ReplicationCheckpoint.load(from: checkpointURL)
                    } catch {
                        try Self.preserveUnreadable(checkpointURL)
                        checkpoint = nil
                        checkpointUnreadable = true
                    }
                    do {
                        replyObligation = try ReplyObligation.load(from: replyObligationURL)
                    } catch {
                        isHeldSyncStateUnreadable = true
                    }
                    do {
                        pendingHostLifecycle = try Self.loadHostLifecycleRecord(in: baseDirectory)
                    } catch {
                        hostRepair = .lifecycleUnreadable
                    }
                    if erasePending, pendingHostLifecycle == nil {
                        pendingHostLifecycle = HostLifecycleRecord(intent: .erase, journal: nil, group: nil)
                    }
                    hostCheckpointUnreadable = checkpointUnreadable
                    Self.initScopeHookForTesting?("stateFiles")
                } catch {
                    bootError = bootError ?? error
                    session = nil
                    checkpoint = nil
                }
            }
        } else {
            var replica: TaskReplica
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
                            secretStore: secretStore,
                            deviceID: deviceID,
                            persistenceURL: persistenceURL,
                            checkpointURL: checkpointURL,
                            mlsRoot: mlsRoot,
                            markerURL: markerURL
                        )
                    } else {
                        replica = try TaskReplica(
                            deviceID: deviceID,
                            persistenceURL: persistenceURL,
                            newOrigin: Self.newReplicaOrigin()
                        )
                    }
                    hasDurableStorage = true
                } catch {
                    bootError = bootError ?? error
                    replica = try! TaskReplica(deviceID: deviceID, newOrigin: Self.newReplicaOrigin())
                    hasDurableStorage = false
                }
            } else {
                replica = try! TaskReplica(deviceID: deviceID, newOrigin: Self.newReplicaOrigin())
                hasDurableStorage = false
            }
            let taskAdapter = TaskReplicationAdapter(
                replica: replica,
                deferredOperationsURL: deferredOperationsURL,
                deferredOperationLimit: deferredOperationLimit
            )
            replication = taskAdapter

            if hasDurableStorage {
                do {
                    if try LegacyLinkCredentials.exist(in: secretStore) {
                        try LegacyLinkCredentials.erase(from: secretStore)
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
                        try taskAdapter.loadDeferredOperations()
                        replyObligation = try ReplyObligation.load(from: replyObligationURL)
                    } catch {
                        isHeldSyncStateUnreadable = true
                    }
                    do {
                        session = try openSession()
                    } catch let error where Self.isUnrecoverableSessionState(error) {
                        try eraseCurrentMLSState()
                        session = try openSession()
                        if checkpoint != nil {
                            try ReplicationCheckpoint.remove(at: checkpointURL)
                            try taskAdapter.removeDeferredOperationsFile()
                            try ReplyObligation.remove(at: replyObligationURL)
                            checkpoint = nil
                            taskAdapter.forgetDeferredOperations()
                            replyObligation = nil
                            notice = .relinkRequired
                        }
                    }
                } catch {
                    bootError = bootError ?? error
                    session = nil
                    checkpoint = nil
                }
            }
        }

        tasks = self.taskAdapter?.tasks ?? []
        isPaired = checkpoint != nil
        refreshPendingMailboxCount()
        if let bootError {
            phase = .failed
            errorMessage = Self.displayMessage(for: bootError)
        } else if isHeldSyncStateUnreadable || hostRepair != nil {
            phase = .failed
            mailboxError = .localStorageUnavailable
            mailboxErrorMessage = Self.displayMessage(for: SyncError.localStorageUnavailable)
            mailboxRequiresRepair = isPaired || hostRepair != nil
            mailboxState = .unavailable
            errorMessage = mailboxErrorMessage
        } else if isPaired {
            phase = .connecting
        } else {
            phase = .unpaired
            errorMessage = notice.map { Self.displayMessage(for: $0) }
            linkEndedReason = notice
        }
        if isHostMode, hasDurableStorage, bootError == nil {
            startHostLaunch()
        } else {
            continueHostLaunch()
        }
        startDepartures()
        self.backgroundMailboxScheduler.register { [weak self] in
            await self?.performBackgroundMailboxFlushWork()
        }
        self.taskAdapter?.deferredOperationsChanged = { [weak self] in self?.publishState() }
        hostAdapter?.store?.changed = { [weak self] in self?.publishHostView() }
        Self.initScopeHookForTesting?("end")
    }

    /// Receives the name of each launch step as `init` passes it, for timing
    /// tests; nil otherwise.
    static var initScopeHookForTesting: ((String) -> Void)?

    /// Active members in the linked group (including this iPhone).
    public var linkedDeviceIDs: [Data] { checkpoint?.memberDeviceIDs ?? [] }
    public var localDeviceID: Data { deviceID.bytes }

    public var linkedMemberCount: Int {
        isPaired ? linkedDeviceIDs.count : 0
    }

    /// How many devices a group of this engine admits, from its profile.
    public var memberLimit: Int { groupProfile.memberLimit }

    public var isGroupAtCapacity: Bool {
        linkedMemberCount >= memberLimit
    }

    /// Whether linking one more device could leave the replica unable to
    /// accept a new origin from that device or a current member. Every
    /// retained origin holds a slot, and every current member, including this
    /// device, reserves one more whether or not it has edited yet.
    public var isTaskHistoryAtCapacity: Bool {
        guard checkpoint?.reservationsOverflowed != true, hostAdmissionAllowed(linked: false) else {
            return true
        }
        let roster = Set(checkpoint?.members.map(\.fingerprint) ?? [])
        let claims = (checkpoint?.originReservations ?? []).filter { $0.isActive(roster: roster, epoch: lastKnownEpoch) }
        guard claims.count < OriginReservation.maximumActive else {
            return true
        }
        return originSlotsInUse(
            memberCount: roster.union(claims.map(\.member)).count,
            pending: Set(claims.flatMap(\.origins))
        ) >= ReplicaLimits.maxOrigins
    }

    private func originSlotsInUse(memberCount: Int, pending: Set<ReplicaDeviceID> = []) -> Int {
        Self.originSlots(retained: replication.heldOrigins, pending: pending, memberCount: memberCount)
    }

    static func originSlots(
        retained: [ReplicaDeviceID],
        pending: Set<ReplicaDeviceID>,
        memberCount: Int
    ) -> Int {
        Set(retained).union(pending).count + max(memberCount, 1)
    }

    private struct AdmissionView {
        var pending: Set<ReplicaDeviceID> = []
        /// A message in the inbox could not be read, so its origins are unknown.
        var unknownOrigins = false
        var reservations: [OriginReservation] = []
    }

    /// Origins the group has already committed to but this replica has not
    /// retained: operations and hello vectors delivered but not applied yet,
    /// plus every reservation known from the inbox or the checkpoint. The
    /// inbox is read before the checkpoint because a drain saves reservations
    /// before it acknowledges the inbox. Any received operation the engine
    /// holds without applying must add its origin to `pending` here too.
    private func admissionView(session: MLSSession) async throws -> AdmissionView {
        var view = AdmissionView()
        var updates: [ReservationUpdate] = []
        for message in try await session.inbox() {
            let (control, decoded) = replication.decode(message.plaintext)
            guard let origins = replication.committedOrigins(in: decoded, control: control) else {
                view.unknownOrigins = true
                continue
            }
            view.pending.formUnion(origins)
            if let control, ReservationUpdate.kinds.contains(control.kind) {
                updates.append(ReservationUpdate(cursor: message.cursor, sender: message.sender, message: control))
            }
        }
        view.reservations = Self.merge(updates, into: checkpoint?.originReservations ?? [], snapshotsFor: nil)
        return view
    }

    private enum Admission {
        case fits
        case taskHistoryFull
        case groupFull
    }

    /// Counts the joiner against every origin and member slot the group has
    /// committed to. With `before`, only claims earlier in the relay log
    /// count, so of two claims the later one always counts the earlier.
    private func admission(
        of joiner: Data,
        origins joinerOrigins: Set<ReplicaDeviceID>,
        session: MLSSession,
        linked: Bool,
        before cursor: UInt64?
    ) async throws -> Admission {
        let hostLinked = linked && checkpoint != nil
        guard checkpoint?.reservationsOverflowed != true, hostAdmissionAllowed(linked: hostLinked) else {
            return .taskHistoryFull
        }
        var roster: Set<Data> = [try await session.fingerprint()]
        var view = AdmissionView()
        var epoch: UInt64 = 0
        if linked {
            epoch = try await session.epoch()
            view = try await admissionView(session: session)
            roster = Set(try await session.members().map(\.fingerprint))
            lastKnownEpoch = max(lastKnownEpoch, epoch)
            guard !view.unknownOrigins, hostAdmissionAllowed(linked: hostLinked) else {
                return .taskHistoryFull
            }
        }
        guard roster.isDisjoint(with: checkpoint?.membersWithUnknownHistory ?? []) else {
            return .taskHistoryFull
        }
        let claims = view.reservations.filter { claim in
            claim.isActive(roster: roster, epoch: epoch) && cursor.map { claim.cursor < $0 } ?? true
        }
        guard claims.count < OriginReservation.maximumActive else {
            return .taskHistoryFull
        }
        let members = roster.union(claims.map(\.member)).union([joiner])
        guard members.count <= memberLimit else {
            return .groupFull
        }
        let pending = view.pending.union(claims.flatMap(\.origins)).union(joinerOrigins)
        return originSlotsInUse(memberCount: members.count, pending: pending) <= ReplicaLimits.maxOrigins
            ? .fits : .taskHistoryFull
    }

    private func requireAdmission(
        of joiner: Data,
        origins: Set<ReplicaDeviceID>,
        session: MLSSession,
        linked: Bool,
        before cursor: UInt64?,
        connection: any PairingConnection,
        invitation: Invitation
    ) async throws {
        switch try await admission(of: joiner, origins: origins, session: session, linked: linked, before: cursor) {
        case .fits:
            return
        case .taskHistoryFull:
            try await refuseJoinerForTaskHistory(on: connection, invitation: invitation)
        case .groupFull:
            throw SyncError.groupAtCapacity
        }
    }

    /// Publishes a claim for `joiner` and returns it as recorded at its log
    /// position. A linked inviter saves the attempt before sending it, so a
    /// claim whose send fails can still be found in the log and released.
    private func reserve(
        _ joiner: Data,
        origins: Set<ReplicaDeviceID>,
        session: MLSSession
    ) async throws -> OriginReservation {
        invalidateHostIntake()
        try await prepareToReserve(session: session)
        let epoch = try await session.epoch()
        let message = ReplicationMessage.reservation(member: joiner, origins: Array(origins), epoch: epoch)
        let attempt = OriginReservation.Attempt(
            member: joiner, origins: message.origins ?? [], epoch: epoch, after: try await session.cursor()
        )
        try Task.checkCancellation()
        if var current = checkpoint {
            current.reservationAttempts = (current.reservationAttempts ?? []) + [attempt]
            try saveCheckpoint(current)
            reservationsInFlight.append(attempt)
        }
        await reservationSendHookForTesting?()
        let cursor: UInt64
        do {
            guard case .accepted(let accepted) = try await session.send(replication.encode(message), tracked: true) else {
                throw SyncCycleError.notDelivered
            }
            cursor = accepted
            reservationsInFlight.removeAll { $0 == attempt }
        } catch {
            reservationsInFlight.removeAll { $0 == attempt }
            try? await resolveReservationAttempts(session: session)
            throw error
        }
        let claim = OriginReservation(
            member: joiner, owner: try await session.fingerprint(), origins: attempt.origins,
            epoch: epoch, cursor: cursor
        )
        if var current = checkpoint {
            current.originReservations = Self.upserting(claim, into: current.originReservations ?? [])
            current.reservationAttempts?.removeAll { $0 == attempt }
            try saveCheckpoint(current)
        } else {
            guard let founding = try loadFoundingClaims() else {
                throw SyncError.localStorageUnavailable
            }
            try saveFoundingClaims(Self.upserting(claim, into: founding))
        }
        return claim
    }

    /// A linked inviter starts no claim while an earlier attempt is
    /// unresolved. A founding inviter refuses a claims file that no longer
    /// decodes.
    private func prepareToReserve(session: MLSSession) async throws {
        guard checkpoint != nil else {
            guard try loadFoundingClaims() != nil else {
                throw SyncError.localStorageUnavailable
            }
            return
        }
        for _ in 0..<2 where !(checkpoint?.reservationAttempts ?? []).isEmpty {
            try await resolveReservationAttempts(session: session)
        }
        guard checkpoint?.reservationAttempts?.isEmpty ?? true else {
            throw SyncError.privateSyncUnreachable
        }
    }

    /// Turns each saved attempt into a claim at the cursor where it landed,
    /// or drops it once nothing is left to deliver and it never landed.
    /// Attempts whose send is still running wait for a later call.
    private func resolveReservationAttempts(session: MLSSession) async throws {
        guard let group = checkpoint?.group else {
            return
        }
        let attempts = (checkpoint?.reservationAttempts ?? []).filter { !reservationsInFlight.contains($0) }
        guard !attempts.isEmpty else {
            return
        }
        if try await session.pendingDelivery() != nil {
            _ = try await session.flush()
        }
        guard try await session.pendingDelivery() == nil else {
            return
        }
        let owner = try await session.fingerprint()
        var known = Set((checkpoint?.originReservations ?? []).map(\.cursor))
        var outcomes: [(attempt: OriginReservation.Attempt, claim: OriginReservation?)] = []
        for attempt in attempts {
            let landed = try await session.sentCursors(of: replication.encode(attempt.message))
            let cursor = landed.first { $0 > attempt.after && !known.contains($0) }
            if let cursor {
                known.insert(cursor)
            }
            outcomes.append((attempt, cursor.map {
                OriginReservation(
                    member: attempt.member, owner: owner, origins: attempt.origins, epoch: attempt.epoch, cursor: $0
                )
            }))
        }
        guard var current = checkpoint, current.group == group else {
            return
        }
        let saved = current.reservationAttempts ?? []
        let resolved = outcomes.filter { saved.contains($0.attempt) }
        current.originReservations = resolved.compactMap(\.claim).reduce(current.originReservations ?? []) {
            Self.upserting($1, into: $0)
        }
        current.reservationAttempts?.removeAll { attempt in resolved.contains { $0.attempt == attempt } }
        try saveCheckpoint(current)
    }

    /// Withdraws a claim. A device never receives its own messages, so the
    /// claim is also marked released here.
    private func releaseReservation(_ claim: OriginReservation, session: MLSSession) async {
        let message = ReplicationMessage.release(member: claim.member, reservation: claim.cursor)
        guard (try? await session.send(replication.encode(message))).map({ if case .accepted = $0 { true } else { false } }) == true else {
            return
        }
        var released = claim
        released.released = true
        if var current = checkpoint {
            current.originReservations = Self.upserting(released, into: current.originReservations ?? [], replacing: true)
            try? saveCheckpoint(current)
        } else {
            if let founding = try? loadFoundingClaims() {
                try? saveFoundingClaims(Self.upserting(released, into: founding, replacing: true))
            }
        }
    }

    /// Releases this device's own claims that no pairing will use: their
    /// device never joined, the lease still runs, and no Add is waiting to be
    /// sent.
    private func releaseAbandonedReservations(session: MLSSession) async throws {
        guard pairingTask == nil, !(checkpoint?.originReservations ?? []).isEmpty else {
            return
        }
        let own = try await session.fingerprint()
        let epoch = try await session.epoch()
        let roster = Set(try await session.members().map(\.fingerprint))
        guard try await session.pendingDelivery() == nil, pairingTask == nil else {
            return
        }
        let abandoned = (checkpoint?.originReservations ?? []).filter {
            $0.owner == own && !$0.released && !$0.admitted && !roster.contains($0.member) && $0.allowsAdd(atEpoch: epoch)
        }
        for claim in abandoned {
            await releaseReservation(claim, session: session)
        }
    }

    /// A new member still waiting for reservations asks again every few sync
    /// cycles, moving to the next member each time. Only members that have
    /// their own reservations answer, so any snapshot addressed to this member
    /// is complete. Repeating the request also recovers one that was never
    /// sent, for example after a restart.
    private func requestReservationsIfStillWaiting(session: MLSSession) async throws {
        guard let current = checkpoint, current.reservationsVisible == false, !current.joinPending else {
            reservationRequestCycles = 0
            return
        }
        let own = try await session.fingerprint()
        let roster = try await session.members().map(\.fingerprint)
            .filter { $0 != own }
            .sorted { $0.lexicographicallyPrecedes($1) }
        let providerLeft = current.reservationsProvider.map { !roster.contains($0) } ?? true
        reservationRequestCycles += 1
        guard !roster.isEmpty, providerLeft || reservationRequestCycles >= Self.reservationRequestInterval else {
            return
        }
        reservationRequestCycles = 0
        let next = current.reservationsProvider
            .flatMap { provider in roster.first { !$0.lexicographicallyPrecedes(provider) && $0 != provider } }
            ?? roster[0]
        guard var latest = checkpoint, latest.group == current.group, latest.reservationsVisible == false else {
            return
        }
        latest.reservationsProvider = next
        try saveCheckpoint(latest)
        try beforeReservationRequestHookForTesting?()
        try await send(.hello(vector: replication.helloVector, provider: next), session: session)
    }

    private var foundingClaimsURL: URL {
        checkpointURL.deletingLastPathComponent().appendingPathComponent(ReplicationCheckpoint.foundingClaimsFilename)
    }

    private var unreadableFoundingClaimsURL: URL {
        checkpointURL.deletingLastPathComponent()
            .appendingPathComponent(ReplicationCheckpoint.unreadableFoundingClaimsFilename)
    }

    /// `nil` when the file exists but does not decode. A file that cannot be
    /// opened throws, so a locked device retries instead of losing claims.
    private func loadFoundingClaims() throws -> [OriginReservation]? {
        guard FileManager.default.fileExists(atPath: foundingClaimsURL.path) else {
            return []
        }
        let data = try Data(contentsOf: foundingClaimsURL)
        return try? ReplicaCanonicalJSON.decode([OriginReservation].self, from: data)
    }

    private static func membersWithUnknownHistory(roster: [Data], known: Set<Data>) -> [Data]? {
        let unknown = roster.filter { !known.contains($0) }
        return unknown.isEmpty ? nil : unknown
    }

    /// Whether an unpaired device that created a group added someone to it.
    /// A member besides this device proves it; concluding it is alone needs
    /// a settled log, so an Add whose answer was lost cannot be missed.
    private func adoptFoundingGroupIfJoined(session: MLSSession) async throws -> Bool {
        guard let group = try await session.group() else {
            try requireCurrent(session)
            try retireFoundingClaims(readable: try loadFoundingClaims() != nil)
            return false
        }
        if (try? ReplicationCheckpoint.load(from: joinIntentURL))?.group == group {
            scheduleReconcile()
            throw SyncError.privateSyncUnreachable
        }
        let settled = await settle(group, session: session)
        if case .failure(let error) = settled, let ended = Self.endedGroupError(error) {
            try requireCurrent(session)
            try retireFoundingClaims(readable: try loadFoundingClaims() != nil)
            if isHostMode {
                let outcome = try await resetHostSession(owner: session) { final in
                    guard let final, final.group == group else { return false }
                    return ended != .removedFromGroup || final.removed
                }
                guard outcome == .replaced else {
                    scheduleReconcile()
                    throw SyncError.privateSyncUnreachable
                }
            } else {
                try resetSession()
            }
            throw ended
        }
        let roster = try await session.members()
        let own = try await session.fingerprint()
        try requireCurrent(session)
        guard roster.count > 1 else {
            try settled.get()
            guard try await session.pendingDelivery() == nil else {
                throw SyncError.privateSyncUnreachable
            }
            let profile = try await session.groupProfile()
            try requireCurrent(session)
            try retireFoundingClaims(readable: try loadFoundingClaims() != nil)
            if profile != groupProfile.descriptor {
                if isHostMode {
                    let outcome = try await resetHostSession(owner: session) { final in
                        guard let final else { return false }
                        return final.group == group && final.profile == profile && final.memberCount <= 1 && final.inboxCount == 0
                    }
                    guard outcome == .replaced else {
                        scheduleReconcile()
                        throw SyncError.privateSyncUnreachable
                    }
                } else {
                    try resetSession()
                }
            }
            return false
        }
        if checkpoint?.group != group {
            if isHostMode {
                try await rebuildHostCheckpoint(group: group, roster: roster, own: own, session: session)
            } else {
                try rebuildCheckpoint(group: group, roster: roster, own: own)
            }
        }
        isPaired = true
        startSyncLoop()
        if let refusal = linkedInviteRefusal {
            throw refusal
        }
        return true
    }

    /// Catches up with the log and delivers anything pending, registering the
    /// group again if the relay never saw it.
    private func settle(_ group: Data, session: MLSSession) async -> Result<Void, Error> {
        do {
            do {
                try await session.synchronize()
            } catch MLSRelayError.unauthorized {
                try await session.createGroup(group, profile: session.groupProfile())
                try await session.synchronize()
            }
            if try await session.isRemoved() {
                throw MLSSessionError.removed
            }
            _ = try await session.flush()
            try await session.synchronize()
            return .success(())
        } catch is CancellationError {
            return .failure(CancellationError())
        } catch {
            return .failure(Self.endedGroupError(error) ?? SyncError.privateSyncUnreachable)
        }
    }

    /// Fails unless the group this session holds carries `groupProfile`.
    /// The profile is read from the authenticated MLS group context, never
    /// from local files.
    private func requireGroupProfile(session: MLSSession) async throws {
        guard try await session.groupProfile() == groupProfile.descriptor else {
            throw SyncError.incompatibleGroupProfile
        }
    }

    private static func endedGroupError(_ error: Error) -> SyncError? {
        switch error {
        case MLSSessionError.removed, SyncError.removedFromGroup: .removedFromGroup
        case MLSRelayError.historyExpired, SyncError.syncHistoryExpired: .syncHistoryExpired
        default: nil
        }
    }

    /// A cancelled host join may already be in the group, and its MLS state
    /// then owns whatever arrived. Once the attempt ends, a joined session
    /// becomes the link as at launch; only a join that never committed is
    /// discarded with its journal and intent.
    private func settleCancelledJoin(after attempt: Task<Void, Never>?) {
        guard let owner = session else { return }
        let journal = hostAdapter?.store?.view.journalID
        beginHostWorker()
        joinSettlementTask = Task { [weak self] in
            defer { self?.endHostWorker() }
            await attempt?.value
            await self?.settleCancelledJoin(owner: owner, journal: journal)
            self?.joinSettlementTask = nil
        }
    }

    /// Decides the cancelled attempt's session `owner` once nothing else can
    /// change it. A stop or an unreadable state leaves everything for the
    /// next launch.
    private func settleCancelledJoin(owner: MLSSession, journal: Data?) async {
        guard session === owner, !isPaired else { return }
        invalidateHostIntake()
        let joined: Bool
        do {
            joined = try await owner.group() != nil
        } catch {
            return
        }
        guard !Task.isCancelled, session === owner, !isPaired else { return }
        if joined {
            await reconcileSession()
            return
        }
        let outcome: HostResetOutcome
        do {
            outcome = try await resetHostSession(owner: owner) { final in
                guard let final else { return false }
                return final.group == nil && final.inboxCount == 0
            }
        } catch {
            return
        }
        guard outcome == .replaced else {
            if !Task.isCancelled {
                await reconcileSession()
            }
            return
        }
        guard !Task.isCancelled, !isPaired else { return }
        if let journal, hostAdapter?.store?.view.journalID == journal {
            try? await abandonHostJournal()
        }
        if let intent = try? ReplicationCheckpoint.load(from: joinIntentURL), intent.hostJournal == journal {
            try? ReplicationCheckpoint.remove(at: joinIntentURL)
        }
    }

    private func scheduleReconcile() {
        guard session != nil, reconcileTask == nil else {
            return
        }
        startReconcile()
    }

    /// Only the task that started last clears the handle, so an earlier one
    /// finishing late cannot drop its replacement.
    private func startReconcile() {
        let id = UUID()
        reconcileTaskID = id
        beginHostWorker()
        reconcileTask = Task { [weak self] in
            defer { self?.endHostWorker() }
            await self?.reconcileSession()
            guard let self, self.reconcileTaskID == id else { return }
            self.reconcileTask = nil
            self.reconcileTaskID = nil
        }
    }

    /// Why a linked device cannot invite right now, if it cannot.
    private var linkedInviteRefusal: SyncError? {
        if isGroupAtCapacity {
            return .groupAtCapacity
        }
        if checkpoint?.reservationsVisible == false || checkpoint?.membersWithUnknownHistory != nil {
            return .privateSyncUnreachable
        }
        return isTaskHistoryAtCapacity ? .taskHistoryAtCapacity : nil
    }

    /// Builds the checkpoint for a group this device is in but has no
    /// checkpoint for.
    private func rebuildCheckpoint(group: Data, roster: [MLSMember], own: Data) throws {
        let intent = (try? ReplicationCheckpoint.load(from: joinIntentURL)).flatMap { $0.group == group ? $0 : nil }
        let (rebuilt, readable) = try rebuiltCheckpoint(group: group, roster: roster, own: own, intent: intent)
        try saveCheckpoint(rebuilt)
        try ReplicationCheckpoint.remove(at: joinIntentURL)
        try retireFoundingClaims(readable: readable)
    }

    /// As `rebuildCheckpoint`, referencing the group's journal, which is
    /// created or reopened first; nothing is saved if the session or the
    /// checkpoint changed meanwhile.
    private func rebuildHostCheckpoint(group: Data, roster: [MLSMember], own: Data, session: MLSSession) async throws {
        let intent = (try? ReplicationCheckpoint.load(from: joinIntentURL)).flatMap { $0.group == group ? $0 : nil }
        let hostJournal = try await hostJournalID(for: group, founder: intent == nil)
        try requireCurrent(session)
        guard checkpoint?.group != group else { return }
        var (rebuilt, readable) = try rebuiltCheckpoint(group: group, roster: roster, own: own, intent: intent)
        rebuilt.hostJournal = hostJournal
        try saveCheckpoint(rebuilt)
        try await markHostJournalEstablished(rebuilt)
        try ReplicationCheckpoint.remove(at: joinIntentURL)
        try retireFoundingClaims(readable: readable)
    }

    private func rebuiltCheckpoint(
        group: Data, roster: [MLSMember], own: Data, intent: ReplicationCheckpoint?
    ) throws -> (ReplicationCheckpoint, readable: Bool) {
        var rebuilt = ReplicationCheckpoint(
            group: group,
            members: roster.map(ReplicationCheckpoint.Member.init),
            joinPending: true,
            provider: intent?.provider
        )
        rebuilt.reservationsVisible = intent?.reservationsVisible
        rebuilt.reservationsProvider = intent?.reservationsProvider
        let readable = try adoptFoundingClaims(into: &rebuilt, roster: roster.map(\.fingerprint), known: [own])
        return (rebuilt, readable)
    }

    /// Adds the founding claims to `checkpoint` and returns `true`. When the
    /// file does not decode, returns `false` and counts the history of every
    /// member outside `known` as unknown. Members added by this founding
    /// device, or of unknown history, are provisional, so they are removed if
    /// they never send a message.
    private func adoptFoundingClaims(
        into checkpoint: inout ReplicationCheckpoint,
        roster: [Data],
        known: Set<Data>
    ) throws -> Bool {
        guard let founding = try loadFoundingClaims() else {
            let unknown = Self.membersWithUnknownHistory(roster: roster, known: known)
            checkpoint.membersWithUnknownHistory = unknown
            let deadline = Date().addingTimeInterval(provisionalMemberWindow)
            for member in unknown ?? [] where !checkpoint.provisionalMembers.contains(where: { $0.fingerprint == member }) {
                checkpoint.provisionalMembers.append(ReplicationCheckpoint.ProvisionalMember(fingerprint: member, deadline: deadline))
            }
            return false
        }
        if !founding.isEmpty {
            checkpoint.originReservations = founding.reduce(checkpoint.originReservations ?? []) { Self.upserting($1, into: $0) }
        }
        let added = Set(founding.filter { !$0.released }.map(\.member)).intersection(roster).subtracting(known)
        let deadline = Date().addingTimeInterval(provisionalMemberWindow)
        for member in added where !checkpoint.provisionalMembers.contains(where: { $0.fingerprint == member }) {
            checkpoint.provisionalMembers.append(ReplicationCheckpoint.ProvisionalMember(fingerprint: member, deadline: deadline))
        }
        return true
    }

    /// Removes the founding claims file once a saved checkpoint holds its
    /// claims, keeping the bytes of a file that did not decode.
    private func retireFoundingClaims(readable: Bool) throws {
        if readable {
            try ReplicationCheckpoint.remove(at: foundingClaimsURL)
        } else {
            try setAsideFoundingClaims()
        }
    }

    /// Removes a claims file left from before this device was linked, keeping
    /// the bytes if it does not decode and leaving it if it cannot be read.
    private func retireStaleFoundingClaims() {
        let decoded: [OriginReservation]?
        do {
            decoded = try loadFoundingClaims()
        } catch {
            return
        }
        try? retireFoundingClaims(readable: decoded != nil)
    }

    /// Keeps the bytes of a founding claims file that does not decode where
    /// nothing reads them again.
    private func setAsideFoundingClaims() throws {
        try ReplicationCheckpoint.remove(at: unreadableFoundingClaimsURL)
        try FileManager.default.moveItem(at: foundingClaimsURL, to: unreadableFoundingClaimsURL)
    }

    private func saveFoundingClaims(_ claims: [OriginReservation]) throws {
        try ProtectedStorage.write(ReplicaCanonicalJSON.encode(claims), to: foundingClaimsURL)
    }

    static func upserting(
        _ claim: OriginReservation,
        into entries: [OriginReservation],
        replacing: Bool = false
    ) -> [OriginReservation] {
        if let index = entries.firstIndex(where: { $0.cursor == claim.cursor }) {
            guard replacing else {
                return entries
            }
            var result = entries
            result[index] = claim
            return result
        }
        return (entries + [claim]).sorted { $0.cursor < $1.cursor }
    }

    struct ReservationUpdate {
        static let kinds: Set<ReplicationMessage.Kind> = [.reservation, .release, .reservations]

        let cursor: UInt64
        let sender: Data
        let message: ReplicationMessage
    }

    /// Adds claims by their original log position. A claim already known keeps
    /// its local state, so a late or repeated snapshot cannot undo a release
    /// or an admission. Only a claim's owner can release it, and a release
    /// for a claim not yet known is kept so a later snapshot cannot revive
    /// it. Snapshots apply only to the member named by `snapshotsFor`.
    static func merge(
        _ updates: [ReservationUpdate],
        into stored: [OriginReservation],
        snapshotsFor member: Data?
    ) -> [OriginReservation] {
        var entries: [OriginReservation] = []
        func insert(_ entry: OriginReservation) {
            if !entries.contains(where: { $0.cursor == entry.cursor }) {
                entries.append(entry)
            }
        }
        stored.forEach(insert)
        for update in updates.sorted(by: { $0.cursor < $1.cursor }) {
            let message = update.message
            switch message.kind {
            case .reservation:
                if let member = message.member, let origins = message.origins, let epoch = message.epoch {
                    insert(OriginReservation(
                        member: member, owner: update.sender, origins: origins, epoch: epoch, cursor: update.cursor
                    ))
                }
            case .release:
                guard let releasedMember = message.member, let cursor = message.reservation, cursor < update.cursor else {
                    break
                }
                if let index = entries.firstIndex(where: { $0.cursor == cursor }) {
                    if entries[index].member == releasedMember && entries[index].owner == update.sender {
                        entries[index].released = true
                    }
                } else {
                    insert(OriginReservation(
                        member: releasedMember, owner: update.sender, origins: [], epoch: 0, cursor: cursor, released: true
                    ))
                }
            case .reservations:
                guard let member, message.member == member else {
                    break
                }
                (message.reservations ?? []).filter { $0.cursor < update.cursor }.forEach(insert)
            case .operations, .hello:
                break
            }
        }
        return entries.sorted { $0.cursor < $1.cursor }
    }

    /// Drops a claim once it can no longer matter: its device left after
    /// joining, its retained history covers it, it was released, or its Add
    /// can no longer happen. A member still waiting for its snapshot keeps
    /// releases. `overflowed` reports claims beyond what a checkpoint stores.
    static func prune(
        _ entries: [OriginReservation],
        roster: Set<Data>,
        epoch: UInt64,
        retained: Set<ReplicaDeviceID>,
        keepReleases: Bool
    ) -> (kept: [OriginReservation], overflowed: Bool) {
        let kept = entries.compactMap { entry -> OriginReservation? in
            var entry = entry
            if roster.contains(entry.member) {
                entry.admitted = true
                return Set(entry.origins).isSubset(of: retained) ? nil : entry
            }
            if entry.released {
                return keepReleases ? entry : nil
            }
            return entry.isActive(roster: roster, epoch: epoch) ? entry : nil
        }
        return (Array(kept.prefix(OriginReservation.maximumStored)), kept.count > OriginReservation.maximumStored)
    }

    private func refuseJoinerForTaskHistory(
        on connection: any PairingConnection,
        invitation: Invitation
    ) async throws -> Never {
        if let frame = try? PairingFrame.historyFull.seal(for: invitation, from: .fromInviter) {
            try? await connection.send(frame)
        }
        await connection.cancel()
        throw SyncError.taskHistoryAtCapacity
    }

    /// Tells the peer that the profiles differ and stops before anything is
    /// published, added, or shown for approval.
    private func refuseMismatchedProfile(
        on connection: any PairingConnection,
        invitation: Invitation,
        from direction: PairingFrame.Direction
    ) async throws -> Never {
        if let frame = try? PairingFrame.profileMismatch.seal(for: invitation, from: direction) {
            try? await connection.send(frame)
        }
        await connection.cancel()
        throw SyncError.incompatibleGroupProfile
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

    public var hasLocalReplicaHistory: Bool {
        if let view = hostAdapter?.store?.view {
            return view.ownHead > 0 || view.retainedCount > 0
        }
        return !(taskAdapter?.isEmpty ?? true)
    }

    public var canJoinExistingSync: Bool {
        hasDurableIdentity && hasDurableStorage && session != nil && !isPaired && pairingTask == nil && joinSettlementTask == nil
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
        guard hasDurableIdentity, hasDurableStorage, pairingTask == nil, joinSettlementTask == nil else {
            return
        }
        beginInvitation(linked: false)
    }

    /// Whether local membership, history and host prerequisites allow an invitation now.
    public var canInviteToGroup: Bool {
        guard hasDurableIdentity, hasDurableStorage, session != nil, isPaired,
              pairingTask == nil, joinSettlementTask == nil, retentionParticipationReady,
              !isHeldSyncStateUnreadable, hostWorkAllowed, linkedInviteRefusal == nil
        else { return false }
        if isHostMode {
            guard let view = hostAdapter?.store?.view, view.isReady, !view.controlRepair else { return false }
        }
        return true
    }

    /// Any linked member can issue a join invite into the existing group.
    public func inviteToGroup() {
        guard hasDurableIdentity, hasDurableStorage, isPaired, pairingTask == nil, joinSettlementTask == nil else {
            return
        }
        if let refusal = linkedInviteRefusal {
            fail(refusal)
            return
        }
        beginInvitation(linked: true)
    }

    public func joinPrivateSync(phrase: String) {
        if isHostMode, hostLifecycle == .opening {
            startAfterHostLaunch { $0.joinPrivateSync(phrase: phrase) }
            return
        }
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
        if isHostMode, hostLifecycle == .opening {
            startAfterHostLaunch { $0.joinPrivateSync(url: url) }
            return
        }
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
        let attempt = pairingTask
        declinePeer()
        endPairingAttempt()
        if wasJoining && !isPaired {
            if isHostMode {
                settleCancelledJoin(after: attempt)
            } else {
                try? resetSession()
            }
        } else if !isPaired {
            scheduleReconcile()
        }
        errorMessage = nil
        restorePhaseAfterPairing()
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
            guard let taskAdapter else { return false }
            try taskAdapter.createTask(title: normalized)
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
            try taskAdapter?.setCompleted(taskID: task.id, completed: !completed)
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
            guard let task = taskAdapter?.task(id: id), !task.isDeleted else {
                continue
            }
            do {
                try taskAdapter?.deleteTask(taskID: id)
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
        if isHostMode {
            beginHostClosing(.erase)
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
            taskAdapter?.replaceReplica(try Self.completeErase(
                secretStore: secretStore,
                deviceID: deviceID,
                persistenceURL: persistenceURL,
                checkpointURL: checkpointURL,
                mlsRoot: mlsRoot,
                markerURL: markerURL
            ))
            taskAdapter?.forgetDeferredOperations()
            replyObligation = nil
            isHeldSyncStateUnreadable = false
            isInboxBackpressured = false
            answeredHeldHelloCursors = []
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
        if isHostMode {
            beginHostClosing(.unlink)
            return
        }
        dropLink(departing: true)
    }

    private func dropLink(departing: Bool) {
        cancelAllWork()
        do {
            try LegacyLinkCredentials.erase(from: secretStore)
            session = nil
            if departing {
                try stageDeparture()
            }
            try ReplicationCheckpoint.remove(at: checkpointURL)
            try ReplicationCheckpoint.remove(at: joinIntentURL)
            try discardDeferredOperations()
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
        resumeStoppedHostLaunch()
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
        guard isPaired, pairingTask == nil, !isHistoryBlocked, !isHeldSyncStateUnreadable else {
            return
        }
        phase = .offline
        startBackgroundMailboxFlush()
        backgroundMailboxScheduler.scheduleFlushIfNeeded(pendingOperationCount: pendingMailboxOperationCount)
    }

    /// Invoked by BGProcessingTask and UIBackgroundTask flush loops.
    public func performBackgroundMailboxFlushWork() async {
        guard isPaired, hasDurableStorage, session != nil, hostWorkAllowed else {
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
        isStopping = true
        defer { isStopping = false }
        var settled: Set<Task<Void, Never>> = []
        while true {
            let running = Set([
                pairingTask, pairingExpiryTask, pairingReaderTask, reconcileTask, joinSettlementTask,
                syncLoopTask, syncCycleTask, backgroundFlushTask, departureTask, hostLifecycleTask, hostSettlementTask,
                hostOpenTask, hostLaunchStartTask, snapshotRecipientTask, retentionTask,
            ].compactMap { $0 } + Array(snapshotExportTasks.values) + hostWorkersForTesting).subtracting(settled)
            guard !running.isEmpty else { break }
            for task in running {
                task.cancel()
            }
            if let pairingConnection {
                await pairingConnection.cancel()
            }
            for task in running {
                await task.value
            }
            settled.formUnion(running)
        }
        if isHostMode {
            _ = await hostSessionReset?.task.result
            _ = await hostReopenTask?.result
            if let store = hostAdapter?.store {
                store.changed = nil
                await store.shutdown()
            }
            await awaitHostJournalShutdowns()
        }
        pairingTask = nil
        pairingExpiryTask = nil
        pairingReaderTask = nil
        pairingConnection = nil
        reconcileTask = nil
        reconcileTaskID = nil
        joinSettlementTask = nil
        hostSettlementTask = nil
        hostOpenTask = nil
        hostLaunch = nil
        hostLaunchStartTask = nil
        hostWorkersForTesting = []
        settlementDeferred = false
        for subscriber in hostViewSubscribers.values { subscriber.finish() }
        hostViewSubscribers.removeAll()
        snapshotRecipientTask = nil
        snapshotExportTasks = [:]
        retentionTask = nil
        retentionRound = nil
        retentionCorroborations = [:]
        retentionCorroborationRecipients = []
        syncLoopTask = nil
        syncCycleTask = nil
        syncCycleID = nil
        backgroundFlushTask = nil
        departureTask = nil
        hostLifecycleTask = nil
        for subscriber in stateSubscribers.values { subscriber.finish() }
        stateSubscribers.removeAll()
    }

    // MARK: - Pairing

    private func beginInvitation(linked: Bool) {
        if isHostMode, hostLifecycle == .opening {
            startAfterHostLaunch { $0.beginInvitation(linked: linked) }
            return
        }
        guard retentionParticipationReady else {
            fail(SyncError.incompatibleGroupProfile)
            return
        }
        guard let session, !isHeldSyncStateUnreadable, hostWorkAllowed else {
            fail(SyncError.localStorageUnavailable)
            return
        }
        if isHostMode {
            if checkpoint != nil || hostAdapter?.store != nil {
                guard let view = hostAdapter?.store?.view, view.isReady, !view.controlRepair else {
                    fail(HostEngineError.notReady)
                    return
                }
            } else if !hostArchivesAdmitLink() {
                fail(HostEngineError.archiveLimit)
                return
            }
        }
        if isTaskHistoryAtCapacity {
            fail(SyncError.taskHistoryAtCapacity)
            return
        }
        let deadline = Date().addingTimeInterval(SyncTiming.invitationTimeToLive)
        safetyCode = nil
        errorMessage = nil
        linkEndedReason = nil
        invitationExpiresAt = deadline
        activePairingRole = .host
        phase = .waitingForPeer
        let attemptID = startPairingAttempt(deadline: deadline)
        beginHostWorker()
        pairingTask = Task { [weak self] in
            defer { self?.endHostWorker() }
            if self?.isHostMode == true {
                do {
                    try await self?.ensureHostJournalOpen()
                } catch {
                    self?.pairingFailed(error, attemptID: attemptID)
                    return
                }
            }
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
        if isHostMode, hostLifecycle == .opening {
            startAfterHostLaunch { $0.beginJoin(with: invitation) }
            return
        }
        guard retentionParticipationReady else {
            fail(SyncError.incompatibleGroupProfile)
            return
        }
        guard let session, !isHeldSyncStateUnreadable, hostWorkAllowed else {
            fail(SyncError.localStorageUnavailable)
            return
        }
        if isHostMode, !hostArchivesAdmitLink() {
            fail(HostEngineError.archiveLimit)
            return
        }
        if isTaskHistoryAtCapacity {
            fail(SyncError.taskHistoryAtCapacity)
            return
        }
        invitationPhrase = nil
        invitationURL = nil
        invitationExpiresAt = nil
        safetyCode = nil
        errorMessage = nil
        linkEndedReason = nil
        activePairingRole = .joiner
        phase = .waitingForPeer
        activeInvitation = invitation
        let attemptID = startPairingAttempt(deadline: Date().addingTimeInterval(SyncTiming.invitationTimeToLive))
        beginHostWorker()
        pairingTask = Task { [weak self] in
            defer { self?.endHostWorker() }
            if self?.isHostMode == true {
                do {
                    try await self?.ensureHostJournalOpen()
                } catch {
                    self?.pairingFailed(error, attemptID: attemptID)
                    return
                }
            }
            await self?.runJoinerPairing(invitation, session: session, attemptID: attemptID)
        }
    }

    private func startPairingAttempt(deadline: Date) -> UUID {
        let attemptID = UUID()
        pairingAttemptID = attemptID
        pairingDeadline = deadline
        peerDecision = nil
        peerRefusal = nil
        lastPairingFailure = nil
        return attemptID
    }

    private func runInviterPairing(session: MLSSession, linked: Bool, attemptID: UUID) async {
        var linked = linked
        var session = session
        invalidateHostIntake()
        do {
            if !linked {
                if try await adoptFoundingGroupIfJoined(session: session) {
                    try requireCurrentPairingAttempt(attemptID)
                    linked = true
                    if isHostMode, hostAdapter?.store?.view.isReady != true {
                        throw HostEngineError.notReady
                    }
                } else {
                    try requireCurrentPairingAttempt(attemptID)
                    guard let current = self.session else { throw SyncError.localStorageUnavailable }
                    session = current
                }
            }
            let existingGroup = try await session.group()
            if linked || existingGroup != nil {
                try await requireGroupProfile(session: session)
            }
            let profile = groupProfile.descriptor
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

            let offer = try PairingFrame.offer(groupID: groupID, inviterFingerprint: fingerprint, profile: profile)
                .seal(for: invitation, from: .fromInviter)
            let response = try await awaitJoinerResponse(
                invitation: invitation, groupID: groupID, inviterFingerprint: fingerprint, offer: offer, attemptID: attemptID
            )
            let connection = response.connection
            let reference = response.keyPackageReference
            let joinerFingerprint = response.joinerFingerprint
            let joinerOrigins = Set(response.origins)
            try await requireAdmission(
                of: joinerFingerprint, origins: joinerOrigins, session: session, linked: linked,
                before: nil, connection: connection, invitation: invitation
            )
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
                joinerNonce: response.joinerNonce,
                profile: profile
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
                try await processRemovals(session: session, removesSilentMembers: !isInboxBackpressured)
                try await requireAdmission(
                    of: joinerFingerprint, origins: joinerOrigins, session: session, linked: true,
                    before: nil, connection: connection, invitation: invitation
                )
            } else {
                try await session.createGroup(groupID, profile: profile)
            }
            let claim = try await reserve(joinerFingerprint, origins: joinerOrigins, session: session)
            await reservationHookForTesting?()
            try requireCurrentPairingAttempt(attemptID)
            if linked {
                do {
                    try await requireAdmission(
                        of: joinerFingerprint, origins: joinerOrigins, session: session, linked: true,
                        before: claim.cursor, connection: connection, invitation: invitation
                    )
                } catch {
                    await releaseReservation(claim, session: session)
                    throw error
                }
            }
            if linked {
                try markProvisional(joinerFingerprint)
            }
            var added = false
            for _ in 0..<Self.maximumAddAttempts where !added {
                try requireCurrentPairingAttempt(attemptID)
                do {
                    if case .accepted = try await session.add(
                        keyPackage: keyPackage, verifiedFingerprint: joinerFingerprint, reference: reference,
                        beforeEpoch: claim.epoch &+ OriginReservation.leaseEpochs
                    ) {
                        added = true
                    }
                } catch let error where Self.isTransientTransportFailure(error) || error as? MLSClientError == .capacityReached {
                    added = try await resolveAdd(
                        of: joinerFingerprint, reference: reference, session: session, attemptID: attemptID, failure: error
                    )
                }
            }
            guard added else {
                await releaseReservation(claim, session: session)
                throw SyncError.invalidPairMessage
            }
            try afterAddHookForTesting?()
            if isHostMode, let gate = afterAddGateForTesting {
                await gate()
                try requireCurrentPairingAttempt(attemptID)
            }
            pairingReaderTask?.cancel()
            pairingReaderTask = nil
            let declined = peerDecision == false
            if declined && !linked {
                await connection.cancel()
                if isHostMode {
                    _ = try await resetHostSession(owner: session) { _ in true }
                } else {
                    try resetSession()
                }
                throw SyncError.pairingDeclined
            }
            let roster = try await session.members().map(ReplicationCheckpoint.Member.init)
            let overflow = try await admission(
                of: joinerFingerprint, origins: joinerOrigins, session: session, linked: true, before: claim.cursor
            )
            let overflowed = overflow != .fits
            let createdJournal = isHostMode && checkpoint.flatMap({ $0.group == groupID ? $0 : nil })?.hostJournal == nil
                ? try await hostJournalID(for: groupID, founder: true) : nil
            try requireCurrentPairingAttempt(attemptID)
            let founding = checkpoint?.group != groupID
            var current = checkpoint.flatMap { $0.group == groupID ? $0 : nil }
                ?? ReplicationCheckpoint(group: groupID, members: roster, joinPending: false, provider: nil)
            current.members = roster
            let readable = try !founding || adoptFoundingClaims(
                into: &current, roster: roster.map(\.fingerprint), known: [fingerprint, joinerFingerprint]
            )
            current.originReservations = Self.upserting(claim, into: current.originReservations ?? [])
            if declined || overflowed {
                current.pendingRemovals.append(joinerFingerprint)
            } else {
                current.provisionalMembers.removeAll { $0.fingerprint == joinerFingerprint }
                current.provisionalMembers.append(ReplicationCheckpoint.ProvisionalMember(
                    fingerprint: joinerFingerprint, deadline: Date().addingTimeInterval(provisionalMemberWindow)
                ))
            }
            if isHostMode, current.hostJournal == nil {
                guard let createdJournal else { throw HostEngineError.generationChanged }
                current.hostJournal = createdJournal
            }
            try saveCheckpoint(current)
            if isHostMode {
                try await markHostJournalEstablished(current)
            }
            if founding {
                try retireFoundingClaims(readable: readable)
            } else {
                retireStaleFoundingClaims()
            }
            if declined {
                await connection.cancel()
                throw SyncError.pairingDeclined
            }
            if overflow == .taskHistoryFull {
                try await refuseJoinerForTaskHistory(on: connection, invitation: invitation)
            }
            if overflow == .groupFull {
                if let frame = try? PairingFrame.decision(approved: false).seal(for: invitation, from: .fromInviter) {
                    try? await connection.send(frame)
                }
                await connection.cancel()
                throw SyncError.groupAtCapacity
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

    /// Settles an Add whose delivery failed by sending it again a few times;
    /// the relay deduplicates the copies. Returns `true` once the joiner is a
    /// member and rethrows `failure` otherwise. An Add still pending stays
    /// pending, and the provisional record made before it was sent removes
    /// the device if it is admitted later and never sends a message.
    private func resolveAdd(
        of joiner: Data,
        reference: Data,
        session: MLSSession,
        attemptID: UUID,
        failure: Error
    ) async throws -> Bool {
        var delayNanoseconds = pairingRetryDelayNanoseconds
        for _ in 0..<Self.maximumAddResolutionAttempts {
            guard try await session.pendingDelivery()?.keyPackageReference == reference else {
                guard try await session.members().contains(where: { $0.fingerprint == joiner }) else { throw failure }
                return true
            }
            try requireCurrentPairingAttempt(attemptID)
            try await Task.sleep(nanoseconds: delayNanoseconds)
            delayNanoseconds = min(delayNanoseconds * 2, 4_000_000_000)
            _ = try? await session.flush()
        }
        throw failure
    }

    /// Records `member` as provisional, with a fresh deadline.
    private func markProvisional(_ member: Data) throws {
        guard var current = checkpoint else { return }
        current.provisionalMembers.removeAll { $0.fingerprint == member }
        current.provisionalMembers.append(ReplicationCheckpoint.ProvisionalMember(
            fingerprint: member, deadline: Date().addingTimeInterval(provisionalMemberWindow)
        ))
        try saveCheckpoint(current)
    }

    private struct JoinerResponse {
        let connection: any PairingConnection
        let keyPackageReference: Data
        let joinerFingerprint: Data
        let inviterNonce: Data
        let joinerNonce: Data
        let origins: [ReplicaDeviceID]
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
                        case .response(let reference, let fingerprint, let joinerNonce, let origins, let profile):
                            guard profile == groupProfile.descriptor else {
                                try await refuseMismatchedProfile(on: connection, invitation: invitation, from: .fromInviter)
                            }
                            guard let bound, PairingSafetyCode.commitment(
                                groupID: groupID,
                                inviterFingerprint: inviterFingerprint,
                                keyPackageReference: reference,
                                joinerFingerprint: fingerprint,
                                joinerNonce: joinerNonce,
                                profile: profile
                            ) == bound.commitment else {
                                throw SyncError.invalidPairMessage
                            }
                            return JoinerResponse(
                                connection: connection,
                                keyPackageReference: reference,
                                joinerFingerprint: fingerprint,
                                inviterNonce: bound.nonce,
                                joinerNonce: joinerNonce,
                                origins: origins
                            )
                        case .decision:
                            throw SyncError.pairingDeclined
                        case .profileMismatch:
                            throw SyncError.incompatibleGroupProfile
                        case .offer, .nonce, .historyFull:
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
        invalidateHostIntake()
        do {
            if isHostMode, try await session.group() != nil {
                throw HostEngineError.unsettledJoin
            }
            try requireCurrentPairingAttempt(attemptID)
            if isHostMode {
                let outcome = try await resetHostSession(owner: session) { final in
                    guard let final else { return false }
                    return final.group == nil && final.inboxCount == 0
                }
                try requireCurrentPairingAttempt(attemptID)
                guard outcome == .replaced else { throw HostEngineError.unsettledJoin }
            } else {
                try resetSession()
            }
            guard let session = self.session else { throw SyncError.localStorageUnavailable }
            let (connection, groupID, inviterFingerprint, offeredProfile) = try await awaitInviterOffer(
                invitation: invitation, attemptID: attemptID
            )
            if let expectedGroup = invitation.groupID, let expectedFingerprint = invitation.inviterFingerprint {
                guard groupID == expectedGroup, inviterFingerprint == expectedFingerprint else {
                    await connection.cancel()
                    throw SyncError.invalidPairMessage
                }
            }
            let profile = groupProfile.descriptor
            guard offeredProfile == profile else {
                try await refuseMismatchedProfile(on: connection, invitation: invitation, from: .fromJoiner)
            }
            let published = try await session.publishKeyPackage(pairingToken: invitation.pairingToken, profile: profile)
            try requireCurrentPairingAttempt(attemptID)
            let joinerNonce = try Data.secureRandom(count: 32)
            let commitment = try PairingFrame.commitment(PairingSafetyCode.commitment(
                groupID: groupID,
                inviterFingerprint: inviterFingerprint,
                keyPackageReference: published.reference,
                joinerFingerprint: published.fingerprint,
                joinerNonce: joinerNonce,
                profile: profile
            )).seal(for: invitation, from: .fromJoiner)
            try await connection.send(commitment)
            let inviterNonce = try await awaitInviterNonce(
                on: connection, invitation: invitation, commitment: commitment, attemptID: attemptID
            )
            try await connection.send(
                PairingFrame.response(
                    keyPackageReference: published.reference,
                    joinerFingerprint: published.fingerprint,
                    joinerNonce: joinerNonce,
                    origins: replication.heldOrigins,
                    profile: profile
                ).seal(for: invitation, from: .fromJoiner)
            )
            safetyCode = PairingSafetyCode.code(
                groupID: groupID,
                inviterFingerprint: inviterFingerprint,
                joinerFingerprint: published.fingerprint,
                inviterNonce: inviterNonce,
                joinerNonce: joinerNonce,
                profile: profile
            )
            var joinIntent = ReplicationCheckpoint(
                group: groupID, members: [], joinPending: true, provider: inviterFingerprint
            )
            joinIntent.reservationsVisible = false
            joinIntent.reservationsProvider = inviterFingerprint
            if isHostMode {
                joinIntent.hostJournal = try await hostJournalID(for: groupID, founder: false)
                try requireCurrentPairingAttempt(attemptID)
            }
            try joinIntent.save(to: joinIntentURL)
            phase = .verifying
            listenForInviterDecision(on: connection, invitation: invitation, attemptID: attemptID)

            await beforeJoinHookForTesting?(groupID, published.reference, inviterFingerprint, profile)
            while true {
                try requireCurrentPairingAttempt(attemptID)
                if let deadline = pairingDeadline, Date() >= deadline {
                    throw SyncError.invitationExpired
                }
                if peerDecision == false {
                    throw peerRefusal ?? SyncError.pairingDeclined
                }
                do {
                    if try await session.join(
                        group: groupID,
                        keyPackageReference: published.reference,
                        verifiedInviterFingerprint: inviterFingerprint,
                        profile: profile
                    ) {
                        break
                    }
                } catch let error where Self.isTransientTransportFailure(error) {}
                try await Task.sleep(nanoseconds: pairingRetryDelayNanoseconds)
            }
            await afterJoinHookForTesting?()
            pairingReaderTask?.cancel()
            pairingReaderTask = nil
            await connection.cancel()
            try requireCurrentPairingAttempt(attemptID)
            let roster = try await session.members()
            var joined = joinIntent
            joined.members = roster.map(ReplicationCheckpoint.Member.init)
            try saveCheckpoint(joined)
            if isHostMode {
                try await markHostJournalEstablished(joined)
            }
            try ReplicationCheckpoint.remove(at: joinIntentURL)
            finishPairing(attemptID: attemptID)
        } catch {
            if isHostMode {
                pairingFailed(error, attemptID: attemptID)
                return
            }
            let admitted = (try? await self.session?.group()) != nil
            pairingFailed(error, attemptID: attemptID, admitted: admitted)
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
                case .historyFull:
                    throw SyncError.taskHistoryAtCapacity
                case .profileMismatch:
                    throw SyncError.incompatibleGroupProfile
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
    ) async throws -> (any PairingConnection, Data, Data, Data?) {
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
                        case .offer(let group, let fingerprint, let profile):
                            return (connection, group, fingerprint, profile)
                        case .decision:
                            throw SyncError.pairingDeclined
                        case .historyFull:
                            throw SyncError.taskHistoryAtCapacity
                        case .profileMismatch:
                            throw SyncError.incompatibleGroupProfile
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
                guard case .binary(let frame) = event else { continue }
                let approved: Bool
                var refusal: SyncError?
                switch try? PairingFrame.open(frame, for: invitation, from: .fromInviter) {
                case .decision(let decision)?:
                    approved = decision
                case .historyFull?:
                    (approved, refusal) = (false, .taskHistoryAtCapacity)
                case .profileMismatch?:
                    (approved, refusal) = (false, .incompatibleGroupProfile)
                default:
                    continue
                }
                guard let self, self.pairingAttemptID == attemptID else { return }
                if let refusal { self.peerRefusal = refusal }
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
        peerRefusal = nil
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

    private func pairingFailed(_ error: Error, attemptID: UUID, admitted: Bool = false) {
        guard pairingAttemptID == attemptID, !(error is CancellationError) else {
            return
        }
        let attempt = pairingTask
        pairingTask = nil
        let wasJoining = activePairingRole == .joiner
        declinePeer()
        endPairingAttempt()
        if wasJoining && !isPaired {
            if isHostMode {
                settleCancelledJoin(after: attempt)
            } else if !admitted {
                try? resetSession()
            }
        }
        if !wasJoining && !isPaired {
            scheduleReconcile()
        }
        let mapped = SyncError.fromTransport(error)
        lastPairingFailure = mapped as? SyncError ?? .invalidPairMessage
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
            phase = lastCycleSucceeded && !isReplicaCapacityBlocked ? .synced : .connecting
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
        invalidateHostIntake()
        guard let session else {
            return
        }
        do {
            if isHostMode {
                try await ensureHostJournalOpen()
            }
            if try await session.isRemoved() {
                handleRemoval()
                return
            }
            let group = try await session.group()
            guard self.session === session, pairingTask == nil || isPaired else {
                return
            }
            let intent = try? ReplicationCheckpoint.load(from: joinIntentURL)
            if let group, checkpoint?.group != group, intent?.group != group {
                _ = await settle(group, session: session)
                try requireCurrent(session)
                if try await session.isRemoved() {
                    return
                }
            }
            let roster = group == nil ? [] : try await session.members()
            let own = try await session.fingerprint()
            guard self.session === session, pairingTask == nil || isPaired else {
                return
            }
            if let group, roster.count >= 2 || checkpoint?.group == group {
                if var current = checkpoint, current.group == group {
                    current.members = roster.map(ReplicationCheckpoint.Member.init)
                    try saveCheckpoint(current)
                } else {
                    if isHostMode {
                        try await rebuildHostCheckpoint(group: group, roster: roster, own: own, session: session)
                    } else {
                        try rebuildCheckpoint(group: group, roster: roster, own: own)
                    }
                }
                if !isPaired {
                    isPaired = true
                    phase = .connecting
                }
                startSyncLoop()
            } else if checkpoint != nil {
                try ReplicationCheckpoint.remove(at: checkpointURL)
                try discardDeferredOperations()
                checkpoint = nil
                isPaired = false
                phase = .unpaired
                errorMessage = Self.displayMessage(for: SyncError.relinkRequired)
                linkEndedReason = .relinkRequired
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
            !isHistoryBlocked,
            !isHeldSyncStateUnreadable,
            hostWorkAllowed
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

    func requestSyncCycle(force: Bool, allowInactive: Bool = false) {
        guard
            hasDurableStorage,
            isPaired,
            !isHistoryBlocked,
            !isHeldSyncStateUnreadable,
            hostWorkAllowed,
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
        let blocked: SyncError? = isReplicaCapacityBlocked ? .replicaCapacityReached : nil
        let message = blocked.map { Self.displayMessage(for: $0) }
        if mailboxError != blocked { mailboxError = blocked }
        if mailboxErrorMessage != message { mailboxErrorMessage = message }
        if mailboxRequiresRepair { mailboxRequiresRepair = false }
        if mailboxCapacityReached { mailboxCapacityReached = false }
        if mailboxState != .available { mailboxState = .available }
        guard pairingTask == nil, appIsActive else {
            return
        }
        let settled: SyncPhase = blocked == nil ? .synced : .failed
        if errorMessage != message { errorMessage = message }
        if phase != settled { phase = settled }
    }

    private func syncFailed(_ error: Error) {
        lastCycleSucceeded = false
        switch Self.classifySyncFailure(error) {
        case .cancelled:
            return
        case .removed:
            handleRemoval()
        case .blocked(let reason):
            isHistoryBlocked = true
            syncLoopTask?.cancel()
            syncLoopTask = nil
            mailboxError = reason
            mailboxErrorMessage = Self.displayMessage(for: reason)
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
        if isHostMode {
            try await ensureHostJournalOpen()
            try requireCurrent(session)
        }
        if try await !session.isRemoved() {
            try await requireGroupProfile(session: session)
            if isHostMode {
                await bindBlobService(session)
            }
        }
        invalidateHostIntake()
        var flushed = true
        do {
            _ = try await session.flush()
        } catch MLSClientError.capacityReached, MLSRelayError.capacityReached, MLSRelayError.rateLimited {
            flushed = false
        }
        if flushed {
            try await resolveReservationAttempts(session: session)
        }
        try await drainInbox(session: session, retriesDeferred: false)
        var synchronized = false
        for _ in 0..<4 where !synchronized {
            do {
                try await session.synchronize()
                synchronized = true
            } catch MLSClientError.capacityReached {
                guard try await drainInbox(session: session) else {
                    break
                }
            }
        }
        if try await session.isRemoved() {
            throw MLSSessionError.removed
        }
        try await drainInbox(session: session)
        if !flushed {
            _ = try await session.flush()
            try await resolveReservationAttempts(session: session)
        }
        if isHostMode {
            try await advanceSnapshotBootstrap(session: session)
            try await advanceRetention(session: session)
        }
        try await sendReplies(session: session)
        let controlRepair = hostAdapter?.store?.view.controlRepair ?? false
        try await processRemovals(
            session: session, removesSilentMembers: synchronized && !isInboxBackpressured && !controlRepair
        )
        try await releaseAbandonedReservations(session: session)
        try await requestReservationsIfStillWaiting(session: session)
        try await requestHistoryIfIncomplete(session: session)
        if checkpoint?.joinPending == true {
            try await announceJoin(session: session)
        }
        try await uploadLocalOperations(session: session)
        if isHostMode {
            try await settleHostIntake(session: session)
        }
    }

    /// Counts the inbox messages the journal does not own, when no MLS
    /// operation ran meanwhile and the checkpoint references the bound journal.
    private func settleHostIntake(session: MLSSession) async throws {
        let blocked = activeHostWorkers > 0
        let before = session.operationCount
        let held = try await session.inbox().count
        await settleReadHookForTesting?()
        try requireCurrent(session)
        if !blocked, activeHostWorkers == 0, before == session.operationCount, before.isIdle,
           let store = hostAdapter?.store, !store.isIntakeOutstanding, !store.isClosed,
           checkpoint?.hostJournal == store.view.journalID {
            let journal = store.view.journalID
            hostIntake = .settled(held: held)
            hostIntakeOwner = (ObjectIdentifier(session), before.started, journal)
        } else {
            hostIntake = .unknown
            hostIntakeOwner = nil
            if activeHostWorkers > 0 {
                settlementDeferred = true
            } else if blocked {
                startDeferredSettlement()
            }
        }
        publishHostView()
    }

    /// Counts a task that may use MLS while it runs. Settlement waits for
    /// the last one, whose end starts one fresh settlement.
    private func beginHostWorker() {
        guard isHostMode else { return }
        activeHostWorkers += 1
    }

    private func endHostWorker() {
        guard isHostMode else { return }
        activeHostWorkers -= 1
        if activeHostWorkers == 0, settlementDeferred {
            startDeferredSettlement()
        }
    }

    /// Settles intake once without any MLS operation or network request; it
    /// only reads the inbox.
    private func startDeferredSettlement() {
        guard !isStopping, hostSettlementTask == nil, hostWorkAllowed, let session else { return }
        settlementDeferred = false
        hostSettlementTask = Task { [weak self] in
            try? await self?.settleHostIntake(session: session)
            self?.hostSettlementTask = nil
        }
    }

    /// Engine work about to use MLS may change the inbox; observers learn
    /// that the settled intake no longer holds before the work begins.
    private func invalidateHostIntake() {
        guard isHostMode, case .settled = hostIntake else { return }
        hostIntake = .unknown
        hostIntakeOwner = nil
        publishHostView()
    }

    private var currentHostIntake: HostIntakeSummary {
        guard case .settled = hostIntake, let owner = hostIntakeOwner, let session,
              ObjectIdentifier(session) == owner.session, session.operationCount.started == owner.operations,
              hostAdapter?.store?.view.journalID == owner.journal
        else {
            return .unknown
        }
        return hostIntake
    }

    /// `retriesDeferred` allows a retry of deferred operations with an empty
    /// inbox. Pass `false` before fetching, so that a fetched copy of a
    /// deferred operation is compared with it before either applies.
    /// Returns whether any message was acknowledged. Hellos become a saved
    /// reply obligation before acknowledgement and are answered by
    /// `sendReplies`, so no send can hold messages in the inbox.
    @discardableResult
    private func drainInbox(session: MLSSession, retriesDeferred: Bool = true) async throws -> Bool {
        let messages = try await session.inbox()
        guard !messages.isEmpty
            || (retriesDeferred && replication.retriesHeldWithoutMessages)
        else {
            if isHostMode {
                try await promotePending(session: session)
            }
            return false
        }
        let fingerprint = try await session.fingerprint()
        await inboxReadHookForTesting?()
        try requireCurrent(session)
        let senders = Set(messages.map(\.sender))
        if var current = checkpoint, current.provisionalMembers.contains(where: { senders.contains($0.fingerprint) }) {
            current.provisionalMembers.removeAll { senders.contains($0.fingerprint) }
            try saveCheckpoint(current)
        }
        var window: [ReplicationWindowItem] = []
        window.reserveCapacity(messages.count)
        var decodedBytes = 0
        var decodeStart = segmentHookForTesting == nil ? nil : ContinuousClock.now
        for message in messages {
            if isHostMode, decodedBytes >= HostJournalAdapter.chunkEnvelopeBytes || (window.count > 0 && window.count % HostJournalAdapter.chunkArrivals == 0) {
                if let start = decodeStart { segmentHookForTesting?("drain.decode", ContinuousClock.now - start) }
                await Task.yield()
                try requireCurrent(session)
                decodedBytes = 0
                decodeStart = segmentHookForTesting == nil ? nil : ContinuousClock.now
            }
            let (control, decoded) = replication.decode(message.plaintext)
            window.append(ReplicationWindowItem(message: message, fromSelf: message.sender == fingerprint, control: control, decoded: decoded))
            decodedBytes += message.plaintext.count
        }
        if let start = decodeStart { segmentHookForTesting?("drain.decode", ContinuousClock.now - start) }
        if isHostMode {
            guard try await proveWindow(window, session: session) else {
                requestSyncCycle(force: true)
                return false
            }
        }
        var held = 0
        var requestsHello = false
        for range in replication.chunks(of: window) {
            let chunk = Array(window[range])
            let chunkHeld: (held: Int, requestsHello: Bool)
            do {
                chunkHeld = try await drainChunk(chunk, before: held, of: messages.count, fingerprint: fingerprint, session: session)
            } catch JournalStoreError.proofStale {
                guard try await proveWindow(Array(window[range.lowerBound...]), session: session) else {
                    requestSyncCycle(force: true)
                    break
                }
                chunkHeld = try await drainChunk(chunk, before: held, of: messages.count, fingerprint: fingerprint, session: session)
            }
            held += chunkHeld.held
            requestsHello = requestsHello || chunkHeld.requestsHello
            guard chunkHeld.held == chunk.count else {
                break
            }
        }
        if requestsHello {
            try await send(.hello(vector: replication.helloVector, provider: nil), session: session)
        }
        if isHostMode {
            try await promotePending(session: session)
        }
        return held > 0
    }

    /// Proves a frozen window in bounded steps, yielding between them. A
    /// commit the proof did not cover restarts it; after three restarts the
    /// window waits for a later cycle.
    private func proveWindow(_ window: [ReplicationWindowItem], session: MLSSession) async throws -> Bool {
        guard let host = hostAdapter else { return true }
        let binding = try hostBinding(session)
        for _ in 0..<3 {
            try await host.beginWindowProof(window)
            try requireHostBinding(binding, session)
            do {
                while try await !host.extendWindowProof() {
                    try requireHostBinding(binding, session)
                }
                try requireHostBinding(binding, session)
                return true
            } catch JournalStoreError.proofStale {
                try requireHostBinding(binding, session)
            }
        }
        return false
    }

    /// Moves pending records that continue a received head into the
    /// journal, one bounded transaction at a time.
    private func promotePending(session: MLSSession) async throws {
        guard let store = hostAdapter?.store, store.hasPromotable, hostWorkAllowed else { return }
        let binding = try hostBinding(session)
        while store.hasPromotable {
            try await store.promote()
            try requireHostBinding(binding, session)
        }
    }

    /// What host work captured before suspending: the session, the bound
    /// writer generation and its journal.
    struct HostBinding {
        let generation: UUID
        let journal: Data
    }

    func hostBinding(_ session: MLSSession) throws -> HostBinding {
        try requireCurrent(session)
        guard hostWorkAllowed, let store = hostAdapter?.store else { throw HostEngineError.generationChanged }
        return HostBinding(generation: store.generation, journal: store.view.journalID)
    }

    /// The session, writer generation and journal are still the captured
    /// ones and host work is still allowed.
    func requireHostBinding(_ binding: HostBinding, _ session: MLSSession) throws {
        try requireCurrent(session)
        guard hostWorkAllowed, let store = hostAdapter?.store, store.generation == binding.generation,
              store.view.journalID == binding.journal
        else {
            throw HostEngineError.generationChanged
        }
    }

    /// Takes ownership of one chunk of the inbox window, saves the control
    /// state its messages carry, and acknowledges its owned prefix.
    private func drainChunk(
        _ chunk: [ReplicationWindowItem],
        before earlier: Int,
        of total: Int,
        fingerprint: Data,
        session: MLSSession
    ) async throws -> (held: Int, requestsHello: Bool) {
        var hellos: [(index: Int, cursor: UInt64, sender: Data, message: ReplicationMessage)] = []
        var updates: [ReservationUpdate] = []
        for (index, item) in chunk.enumerated() {
            guard let control = item.control else {
                continue
            }
            switch control.kind {
            case .hello where !item.fromSelf:
                hellos.append((index, item.message.cursor, item.message.sender, control))
            case .reservation, .release, .reservations:
                updates.append(ReservationUpdate(cursor: item.message.cursor, sender: item.message.sender, message: control))
            case .operations, .hello:
                break
            }
        }
        let application: ReplicationChunkIntake
        var binding: HostBinding?
        if let host = hostAdapter {
            binding = try hostBinding(session)
            application = try await host.intake(chunk)
            await chunkIntakeHookForTesting?()
        } else {
            application = try taskAdapter!.intake(chunk)
        }
        let epoch = try await session.epoch()
        let roster = Set(try await session.members().map(\.fingerprint))
        try await drainMemberReadHookForTesting?()
        lastKnownEpoch = max(lastKnownEpoch, epoch)
        try requireCurrent(session)
        if let host = hostAdapter, let captured = binding {
            try requireHostBinding(captured, session)
            for item in chunk.prefix(application.heldMessages) where !item.fromSelf && roster.contains(item.message.sender) {
                if case .hostRetention(let message) = item.decoded {
                    receiveRetention(message, sender: item.message.sender, roster: roster, epoch: epoch, me: fingerprint)
                }
                if case .hostComplete(let member, let through) = item.decoded, member == fingerprint {
                    try await host.recordCompletion(provider: item.message.sender, through: through, plaintext: item.message.plaintext)
                    try requireHostBinding(captured, session)
                }
            }
        }
        let continuationStart = segmentHookForTesting == nil ? nil : ContinuousClock.now
        if var current = checkpoint,
           !updates.isEmpty || !(current.originReservations ?? []).isEmpty || current.membersWithUnknownHistory != nil {
            let waiting = current.reservationsVisible == false
            let snapshot = waiting ? updates.first {
                $0.message.kind == .reservations && $0.message.member == fingerprint
            } : nil
            var merged = Self.merge(
                updates.filter { $0.message.kind != .reservations || $0.cursor == snapshot?.cursor },
                into: current.originReservations ?? [],
                snapshotsFor: waiting ? fingerprint : nil
            )
            if let unknown = current.membersWithUnknownHistory {
                let heard = hellos.filter { unknown.contains($0.sender) && $0.message.vector != nil }
                for hello in heard {
                    merged = Self.upserting(OriginReservation(
                        member: hello.sender, owner: fingerprint, origins: hello.message.vector?.origins.sorted() ?? [],
                        epoch: epoch, cursor: hello.cursor, admitted: true
                    ), into: merged)
                }
                current.membersWithUnknownHistory = Self.membersWithUnknownHistory(
                    roster: unknown.filter(roster.contains), known: Set(heard.map(\.sender))
                )
            }
            let pruned = Self.prune(
                merged, roster: roster, epoch: epoch,
                retained: Set(replication.retainedOrigins), keepReleases: waiting && snapshot == nil
            )
            current.originReservations = pruned.kept
            if pruned.overflowed || snapshot?.message.overflowed == true {
                current.reservationsOverflowed = true
            }
            if snapshot != nil {
                current.reservationsVisible = true
                current.reservationsProvider = nil
            }
            if current != checkpoint {
                try saveCheckpoint(current)
            }
        }
        if application.accepted > 0 {
            replicationChanged()
            lastSyncedAt = Date()
            lastMailboxReceivedAt = Date()
        }
        let held = application.heldMessages
        isInboxBackpressured = earlier + held < total
        var obligation = replyObligation ?? ReplyObligation()
        var answeredHeld: [UInt64] = []
        for hello in hellos {
            guard hello.index < held || !answeredHeldHelloCursors.contains(hello.cursor),
                  let vector = hello.message.vector
            else {
                continue
            }
            let isProvider = hello.message.provider == fingerprint
            obligation.merge(vector, provider: isProvider)
            if isProvider, roster.contains(hello.sender) {
                obligation.addRecipient(hello.sender)
                if isHostMode {
                    let request = (try? HostJournalMessage.decode(chunk[hello.index].message.plaintext))?.snapshotSchema
                    obligation.addBootstrap(hello.sender, from: vector, snapshot: request)
                }
            }
            if isHostMode, roster.contains(hello.sender),
               (try? HostJournalMessage.decode(chunk[hello.index].message.plaintext))?.snapshotSchema != nil {
                noteCorroborationRecipient(hello.sender)
            }
            obligation.retain(origins: replication.retainedOrigins)
            if hello.index >= held {
                answeredHeld.append(hello.cursor)
            }
        }
        if obligation != (replyObligation ?? ReplyObligation()) {
            try ReplyObligation.save(obligation, to: replyObligationURL)
            replyObligation = obligation
        }
        answeredHeldHelloCursors.formUnion(answeredHeld)
        if let continuationStart { segmentHookForTesting?("drain.continuation", ContinuousClock.now - continuationStart) }
        if held > 0 {
            let acknowledged = chunk[held - 1].message.cursor
            try await session.acknowledgeInbox(through: acknowledged)
            answeredHeldHelloCursors = answeredHeldHelloCursors.filter { $0 > acknowledged }
        }
        return (held, application.requestsHello)
    }

    func requireCurrent(_ session: MLSSession) throws {
        guard !Task.isCancelled, hasDurableStorage, self.session === session else {
            throw CancellationError()
        }
    }

    private func discardDeferredOperations() throws {
        try taskAdapter?.removeDeferredOperationsFile()
        try ReplyObligation.remove(at: replyObligationURL)
        taskAdapter?.forgetDeferredOperations()
        replyObligation = nil
        isHeldSyncStateUnreadable = false
        isInboxBackpressured = false
        answeredHeldHelloCursors = []
    }

    /// Sends what saved hellos asked for: this device's uploaded operations,
    /// and every origin for a hello that named this device as provider. Each
    /// provider requester then gets a reservations snapshot, sent only after
    /// the whole history, while this device knows every claim and holds no
    /// operation it has not applied.
    private func sendReplies(session: MLSSession) async throws {
        let snapshot = isHostMode ? replication.helloVector : nil
        if isHostMode {
            try await prepareSnapshotExports(session: session)
        }
        while var obligation = replyObligation, let current = checkpoint {
            var answered: Data?
            if let index = obligation.bootstrap?.firstIndex(where: { $0.cut == nil && isSnapshotExportResolved($0) }),
               try await hostMayCertify(session: session) {
                let entry = obligation.bootstrap![index]
                obligation.bootstrap![index].cut = replication.helloVector
                obligation.merge(entry.from, provider: true)
                obligation.retain(origins: replication.retainedOrigins)
            } else if obligation.own != nil || obligation.provided != nil {
                let bound = snapshot.map { Self.replyBound(obligation.bootstrap, snapshot: $0) }
                let selected: (plaintext: Data, records: [(ReplicaDeviceID, UInt64)])?
                if let host = hostAdapter {
                    let binding = try hostBinding(session)
                    selected = try await host.reply(for: obligation, uploadedThrough: uploadedLocalSequence(in: current), bound: bound)
                    try requireHostBinding(binding, session)
                    guard replyObligation == obligation, checkpoint == current else { continue }
                } else {
                    selected = try taskAdapter!.reply(for: obligation, uploadedThrough: uploadedLocalSequence(in: current), bound: bound)
                }
                if let reply = selected {
                    await replyBatchHookForTesting?()
                    try await send(plaintext: reply.plaintext, session: session)
                    try requireCurrent(session)
                    obligation.advance(past: reply.records)
                    obligation.retain(origins: replication.retainedOrigins)
                } else {
                    obligation.completeHistory()
                }
            } else if let entry = obligation.bootstrap?.first(where: { $0.cut != nil }), let cut = entry.cut {
                let roster = Set(try await session.members().map(\.fingerprint))
                try requireCurrent(session)
                if roster.contains(entry.member) {
                    guard try await hostMayCertify(session: session) else {
                        return
                    }
                    let export = entry.snapshot == nil ? nil : snapshotExport(for: entry.member)
                    let message = HostJournalMessage.complete(
                        member: entry.member, through: cut, snapshot: export?.offer, refusal: export?.refusal
                    )
                    try await send(plaintext: message.encoded(), session: session)
                    try requireCurrent(session)
                }
                obligation.removeBootstrap(entry.member)
                answered = entry.member
            } else if let recipient = obligation.recipients?.first {
                if obligation.bootstrap?.contains(where: { $0.member == recipient }) == true {
                    return
                }
                let roster = Set(try await session.members().map(\.fingerprint))
                try requireCurrent(session)
                if roster.contains(recipient) {
                    guard let latest = checkpoint, latest.reservationsVisible != false,
                          latest.membersWithUnknownHistory == nil, !isReplicaCapacityBlocked
                    else {
                        return
                    }
                    if isHostMode, try await !hostMayCertify(session: session) {
                        return
                    }
                    try snapshotSendHookForTesting?()
                    try await send(
                        .reservations(
                            latest.originReservations ?? [],
                            overflowed: latest.reservationsOverflowed == true,
                            for: recipient
                        ),
                        session: session
                    )
                    try requireCurrent(session)
                }
                obligation.removeRecipient(recipient)
            } else {
                return
            }
            let next: ReplyObligation? = obligation.isEmpty ? nil : obligation
            try ReplyObligation.save(next, to: replyObligationURL)
            replyObligation = next
            if let answered {
                await finishSnapshotExport(for: answered)
            }
        }
    }

    private func announceJoin(session: MLSSession) async throws {
        guard let announced = checkpoint else {
            return
        }
        let vector: ReplicaVersionVector
        let messages: [Data]
        var binding: HostBinding?
        if let host = hostAdapter {
            let captured = try hostBinding(session)
            binding = captured
            (vector, messages) = try await host.joinAnnouncement()
            try requireHostBinding(captured, session)
            if let provider = announced.provider, let store = host.store {
                try await store.setHistoryProvider(provider)
                try requireHostBinding(captured, session)
            }
            try await requestSnapshotBootstrap(binding: captured, session: session)
            guard checkpoint?.joinPending == true, checkpoint?.group == announced.group else {
                throw CancellationError()
            }
        } else {
            (vector, messages) = try taskAdapter!.joinAnnouncement()
        }
        try await send(.hello(vector: vector, provider: announced.provider), session: session)
        for message in messages {
            try await send(plaintext: message, session: session)
        }
        try requireCurrent(session)
        if let binding {
            try requireHostBinding(binding, session)
        }
        guard var current = checkpoint, current.group == announced.group else {
            throw CancellationError()
        }
        current.joinPending = false
        current.provider = nil
        if let origin = replication.ownOrigin {
            current.setUploadedThrough(max(uploadedLocalSequence(in: current), vector[origin]), origin: origin)
        }
        try saveCheckpoint(current)
        lastMailboxStoredAt = Date()
        refreshPendingMailboxCount()
    }

    /// A host uploads at most through the own head it held when the loop
    /// began, so ongoing submissions cannot keep the loop running.
    private func uploadLocalOperations(session: MLSSession) async throws {
        let ceiling = isHostMode ? replication.localSequence : .max
        while var current = checkpoint, let origin = replication.ownOrigin {
            let localSequence = replication.localSequence
            var uploadedThrough = uploadedLocalSequence(in: current)
            if uploadedThrough > localSequence {
                uploadedThrough = localSequence
                current.setUploadedThrough(localSequence, origin: origin)
                try saveCheckpoint(current)
            }
            guard uploadedThrough < min(localSequence, ceiling) else {
                break
            }
            let plaintext: Data
            let last: UInt64
            var binding: HostBinding?
            if let host = hostAdapter {
                let captured = try hostBinding(session)
                binding = captured
                (plaintext, last) = try await host.upload(after: uploadedThrough)
                try requireHostBinding(captured, session)
                guard checkpoint == current else { continue }
            } else {
                (plaintext, last) = try taskAdapter!.upload(after: uploadedThrough)
            }
            try await send(plaintext: plaintext, session: session)
            try requireCurrent(session)
            if let binding {
                try requireHostBinding(binding, session)
            }
            guard var latest = checkpoint, latest.group == current.group else {
                throw CancellationError()
            }
            latest.setUploadedThrough(max(uploadedLocalSequence(in: latest), last), origin: origin)
            try saveCheckpoint(latest)
            lastMailboxStoredAt = Date()
            refreshPendingMailboxCount()
        }
        refreshPendingMailboxCount()
    }

    private func send(_ message: ReplicationMessage, session: MLSSession) async throws {
        try await send(plaintext: replication.encode(message), session: session)
    }

    func send(plaintext: Data, session: MLSSession) async throws {
        invalidateHostIntake()
        guard case .accepted = try await session.send(plaintext) else {
            throw SyncCycleError.notDelivered
        }
    }

    /// Reads every session fact first and only then copies the checkpoint,
    /// so a change saved while those reads were suspended is kept.
    @discardableResult
    private func refreshMembers(session: MLSSession) async throws -> [MLSMember] {
        let roster = try await session.members()
        let addPending = try await session.pendingDelivery()?.welcome != nil
        let spoken = try await session.spokenMembers()
        try await memberReadHookForTesting?()
        try requireCurrent(session)
        let fingerprints = roster.map(\.fingerprint)
        guard var current = checkpoint else {
            return roster
        }
        let previous = current
        current.members = roster.map(ReplicationCheckpoint.Member.init)
        current.pendingRemovals.removeAll { !fingerprints.contains($0) }
        let now = Date()
        let known = Set(previous.members.map(\.fingerprint))
        // A device not yet a member keeps its record while an Add for it may
        // still land, and its window starts again when it first appears. A
        // member that sent a message has joined.
        current.provisionalMembers = current.provisionalMembers.compactMap { entry in
            guard fingerprints.contains(entry.fingerprint) else {
                return addPending || entry.deadline > now ? entry : nil
            }
            guard !spoken.contains(entry.fingerprint) else { return nil }
            guard !known.contains(entry.fingerprint) else { return entry }
            return ReplicationCheckpoint.ProvisionalMember(
                fingerprint: entry.fingerprint, deadline: max(entry.deadline, now.addingTimeInterval(provisionalMemberWindow))
            )
        }
        current.membersWithUnknownHistory = current.membersWithUnknownHistory.flatMap {
            Self.membersWithUnknownHistory(roster: $0.filter(fingerprints.contains), known: [])
        }
        if current != previous {
            try saveCheckpoint(current)
        }
        return roster
    }

    /// Commits removals requested with `removeDevice`, members whose leave
    /// proposal this device received, and added members that never joined.
    /// The last only with `removesSilentMembers`, after the log was read to
    /// its head, so a member whose messages wait unread is not removed.
    private func processRemovals(session: MLSSession, removesSilentMembers: Bool) async throws {
        var triedSilent: Set<Data> = []
        for _ in 0..<Self.maximumRemovalAttempts {
            let roster = try await refreshMembers(session: session)
            guard let current = checkpoint else { return }
            let now = Date()
            let silent = removesSilentMembers
                ? current.provisionalMembers.filter { $0.deadline <= now && !triedSilent.contains($0.fingerprint) }.map(\.fingerprint)
                : []
            let requested = current.pendingRemovals + (try await session.departures())
            guard let target = (requested + silent).first(where: { candidate in
                roster.contains { $0.fingerprint == candidate && $0.deviceID != deviceID.bytes }
            }) else {
                return
            }
            let onlyIfSilent = !requested.contains(target)
            if onlyIfSilent {
                triedSilent.insert(target)
            }
            _ = try await session.remove(fingerprint: target, onlyIfSilent: onlyIfSilent)
        }
        try await refreshMembers(session: session)
    }

    private func handleRemoval() {
        if isHostMode {
            beginHostClosing(.removed)
            return
        }
        guard isPaired || checkpoint != nil else {
            try? resetSession()
            return
        }
        if isHostMode {
            beginHostClosing(.removed)
            return
        }
        dropLink(departing: false)
        errorMessage = Self.displayMessage(for: SyncError.removedFromGroup)
        linkEndedReason = .removedFromGroup
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

    /// Moves the MLS state and its key into a new departure slot, with the
    /// provisional members the departing device must remove before leaving.
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
        if let provisional = checkpoint?.provisionalMembers.map(\.fingerprint), !provisional.isEmpty {
            try ProtectedStorage.write(
                ReplicaCanonicalJSON.encode(provisional),
                to: mlsDirectory.appendingPathComponent(Self.withdrawnMembersFilename)
            )
        }
        try FileManager.default.moveItem(at: mlsDirectory, to: departuresDirectory.appendingPathComponent(name, isDirectory: true))
        mlsDirectory = Self.freshMLSDirectory(in: mlsRoot)
        try secretStore.delete(account: SecretStoreMLSStateKey.account)
    }

    private func startDepartures() {
        guard hasDurableIdentity, !isStopping, departureTask == nil, !departureSlots().isEmpty else { return }
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

    /// Returns whether every departure slot was published or settled.
    private func publishDepartures() async -> Bool {
        var complete = true
        for slot in departureSlots() {
            let account = Self.departureKeyAccount(slot.lastPathComponent)
            do {
                let departing = try MLSSession(
                    directory: slot, deviceID: deviceID.bytes, secretStore: secretStore, keyAccount: account, transport: mlsTransport
                )
                let withdrawn = try? ReplicaCanonicalJSON.decode(
                    [Data].self, from: Data(contentsOf: slot.appendingPathComponent(Self.withdrawnMembersFilename))
                )
                try await departing.leave(withdrawing: withdrawn ?? [])
            } catch is CancellationError {
                return false
            } catch let error where !Self.isSettledDeparture(error) {
                complete = false
                continue
            } catch {}
            try? MLSSession.erase(directory: slot, secretStore: secretStore, keyAccount: account)
        }
        return complete
    }

    /// Whether a failed leave can never succeed: the MLS state or the relay
    /// already excludes the departing identity, the history it must process
    /// has expired, or its state can no longer be decrypted. Any other
    /// failure keeps its slot for a retry.
    private static func isSettledDeparture(_ error: Error) -> Bool {
        switch error {
        case MLSSessionError.removed, MLSSessionError.notInGroup, MLSRelayError.unauthorized, MLSRelayError.historyExpired,
             MLSStoreError.unreadable:
            return true
        default:
            return false
        }
    }

    private func startBackgroundMailboxFlush() {
        guard isPaired, hasDurableStorage, hostWorkAllowed else {
            return
        }
        beginHostWorker()
        backgroundFlushTask = Task { [weak self] in
            defer { self?.endHostWorker() }
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

    /// The MLS state a reset decides on, read after the old session's
    /// accepted work finished and in the same client turn as its close.
    struct HostResetFinal: Sendable {
        let group: Data?
        let removed: Bool
        let profile: Data?
        let memberCount: Int
        let inboxCount: Int
    }

    enum HostResetOutcome: Sendable {
        /// The old state was erased and a new session installed.
        case replaced
        /// The settled state no longer qualified for discarding; the closed
        /// original state was reopened for adoption.
        case keptForAdoption
    }

    /// Host only. Detaches `owner`, lets its accepted MLS work finish, then
    /// reads the final state and closes it in one client turn. `discard`
    /// decides on that final state, nil when it could not be read: erase and
    /// reopen fresh, or reopen the proven-closed original. A close that did
    /// not prove itself keeps the owner held with every file and key and
    /// stops host work. A second request for the same owner joins the first.
    private func resetHostSession(
        owner: MLSSession, discard: @escaping @MainActor (HostResetFinal?) -> Bool
    ) async throws -> HostResetOutcome {
        if let running = hostSessionReset, running.owner == ObjectIdentifier(owner) {
            let outcome = try await running.task.value
            try Task.checkCancellation()
            return outcome
        }
        guard session === owner, hostWorkAllowed, !isStopping, hostRetainedSession == nil else {
            throw CancellationError()
        }
        session = nil
        let task = Task { @MainActor [weak self] () -> HostResetOutcome in
            guard let self else { throw CancellationError() }
            defer {
                if self.hostSessionReset?.owner == ObjectIdentifier(owner) { self.hostSessionReset = nil }
            }
            await self.resetQueuedWorkHookForTesting?(owner)
            let finalInbox = self.resetFinalInboxHookForTesting
            let (read, closed) = await owner.close { client in
                let group = try client.group()
                let inbox = try client.inbox()
                finalInbox?(inbox)
                return HostResetFinal(
                    group: group, removed: try client.isRemoved(), profile: group == nil ? nil : try client.groupProfile(),
                    memberCount: group == nil ? 0 : try client.members().count, inboxCount: inbox.count
                )
            }
            guard closed else {
                self.hostRetainedSession = owner
                self.hostRepair = self.hostRepair ?? .sessionCloseUncertain
                throw HostEngineError.sessionCloseUncertain
            }
            let replace = discard(try? read.get())
            if replace {
                do {
                    try self.eraseCurrentMLSState()
                } catch {
                    self.hostRepair = self.hostRepair ?? .mlsUnreadable
                    throw error
                }
            }
            do {
                self.session = try self.openSession()
            } catch {
                self.hostRepair = self.hostRepair ?? .mlsUnreadable
                throw error
            }
            return replace ? .replaced : .keptForAdoption
        }
        hostSessionReset = (ObjectIdentifier(owner), task)
        let outcome = try await task.value
        try Task.checkCancellation()
        return outcome
    }

    private var joinIntentURL: URL {
        checkpointURL.deletingLastPathComponent().appendingPathComponent(ReplicationCheckpoint.joinIntentFilename)
    }

    /// Each session generation gets a new directory. A closed-over session
    /// that is still open can then never create journal files next to the
    /// database of the session that replaced it.
    private func eraseCurrentMLSState() throws {
        retireBlobBinding()
        try ReplicationCheckpoint.remove(at: foundingClaimsURL)
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

    private func uploadedLocalSequence(in checkpoint: ReplicationCheckpoint) -> UInt64 {
        guard let origin = replication.ownOrigin else {
            return 0
        }
        if let journal = hostAdapter?.store?.view.journalID, checkpoint.hostJournal != journal {
            return 0
        }
        return checkpoint.uploadedThrough(origin: origin, deviceID: deviceID)
    }

    private func saveCheckpoint(_ value: ReplicationCheckpoint) throws {
        let start = segmentHookForTesting == nil ? nil : ContinuousClock.now
        try value.save(to: checkpointURL)
        checkpoint = value
        publishHostView()
        if let start { segmentHookForTesting?("checkpoint.save", ContinuousClock.now - start) }
    }

    private func cancelAllWork() {
        endPairingAttempt()
        reconcileTask?.cancel()
        joinSettlementTask?.cancel()
        hostSettlementTask?.cancel()
        hostLaunchStartTask?.cancel()
        hostOpenTask?.cancel()
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
        linkEndedReason = nil
        checkpoint = nil
        isPaired = false
        isHistoryBlocked = false
        lastCycleSucceeded = false
        syncFailureCount = 0
        nextSyncAttemptAt = .distantPast
        lastSyncedAt = nil
        lastMailboxStoredAt = nil
        lastMailboxReceivedAt = nil
        errorMessage = nil
        mailboxErrorMessage = nil
        mailboxError = nil
        mailboxRequiresRepair = false
        mailboxCapacityReached = false
        mailboxState = .idle
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
        tasks = taskAdapter?.tasks ?? []
    }

    /// Publishes remote data that intake accepted.
    private func replicationChanged() {
        publishReplica()
        publishHostView()
    }

    private func refreshPendingMailboxCount() {
        let localSequence = replication.localSequence
        let uploaded = checkpoint.map(uploadedLocalSequence) ?? 0
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
        case blocked(SyncError)
        case storage
        case transient
    }

    private static func classifySyncFailure(_ error: Error) -> SyncFailure {
        switch error {
        case is CancellationError:
            return .cancelled
        case MLSSessionError.removed:
            return .removed
        case SyncError.incompatibleGroupProfile, MLSClientError.unsupportedGroupProfile:
            return .blocked(.incompatibleGroupProfile)
        case MLSRelayError.historyExpired:
            return .blocked(.syncHistoryExpired)
        case ReplicaError.operationFork, JournalStoreError.fork, JournalStoreError.foreignOwnOrigin,
             JournalStoreError.retainedRecordMissing:
            return .blocked(.syncHistoryConflict)
        case is JournalStoreError, is HostEngineError:
            return .storage
        case MLSSessionError.unresolvedConflict, is SyncCycleError:
            return .transient
        case MLSClientError.storageUnavailable, MLSClientError.capacityReached, is MLSStoreError:
            return .transient
        case is ReplicaError, is CocoaError, SyncError.localStorageUnavailable:
            return .storage
        case _ where isTransientTransportFailure(error):
            return .transient
        default:
            return .blocked(.syncHistoryBlocked)
        }
    }

    private static func isTransientTransportFailure(_ error: Error) -> Bool {
        error is URLError || error is MLSRelayError || error is RelaySocketError
            || (error as NSError).domain == NSURLErrorDomain
            || (error as NSError).domain == NSPOSIXErrorDomain
    }

    nonisolated private static func isUnrecoverableSessionState(_ error: Error) -> Bool {
        if case MLSStoreError.unreadable = error { return true }
        if case MLSClientError.invalidState = error { return true }
        return false
    }

    /// A new archive never reuses an origin whose operations peers may hold.
    private static func newReplicaOrigin() -> ReplicaDeviceID {
        ReplicaDeviceID(uuid: UUID())
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
        secretStore: any SecretStore,
        deviceID: ReplicaDeviceID,
        persistenceURL: URL,
        checkpointURL: URL,
        mlsRoot: URL,
        markerURL: URL
    ) throws -> TaskReplica {
        try LegacyLinkCredentials.erase(from: secretStore)
        try removeAllPairingArtifacts(in: persistenceURL.deletingLastPathComponent())
        try ReplicationCheckpoint.remove(at: checkpointURL)
        try ReplicationCheckpoint.remove(
            at: checkpointURL.deletingLastPathComponent().appendingPathComponent(ReplicationCheckpoint.joinIntentFilename)
        )
        for filename in [ReplicationCheckpoint.foundingClaimsFilename, ReplicationCheckpoint.unreadableFoundingClaimsFilename] {
            try ReplicationCheckpoint.remove(at: checkpointURL.deletingLastPathComponent().appendingPathComponent(filename))
        }
        try MLSSession.erase(directory: mlsRoot, secretStore: secretStore)
        try DeferredOperationStore.remove(
            at: persistenceURL.deletingLastPathComponent().appendingPathComponent(DeferredOperationStore.filename)
        )
        try ReplyObligation.remove(
            at: persistenceURL.deletingLastPathComponent().appendingPathComponent(ReplyObligation.filename)
        )
        if FileManager.default.fileExists(atPath: persistenceURL.path) {
            try FileManager.default.removeItem(at: persistenceURL)
        }
        let clearedReplica = try TaskReplica(
            deviceID: deviceID,
            persistenceURL: persistenceURL,
            newOrigin: newReplicaOrigin()
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
    var awaitsReservationsForTesting: Bool { checkpoint?.reservationsVisible == false }
    var reservationsForTesting: [OriginReservation] { checkpoint?.originReservations ?? [] }
    var provisionalMembersForTesting: [Data] { checkpoint?.provisionalMembers.map(\.fingerprint) ?? [] }
    func refreshMembersForTesting() async throws {
        try await reopenStoppedHostJournalForTesting()
        guard let session else { throw SyncError.localStorageUnavailable }
        _ = try await refreshMembers(session: session)
    }
    func drainInboxForTesting() async throws {
        try await reopenStoppedHostJournalForTesting()
        guard let session else { throw SyncError.localStorageUnavailable }
        try await drainInbox(session: session)
    }
    func markProvisionalForTesting(_ member: Data, deadline: Date) throws {
        guard var current = checkpoint else { return }
        current.provisionalMembers.append(ReplicationCheckpoint.ProvisionalMember(fingerprint: member, deadline: deadline))
        try saveCheckpoint(current)
    }
    var reservationsProviderForTesting: Data? { checkpoint?.reservationsProvider }
    var membersWithUnknownHistoryForTesting: [Data]? { checkpoint?.membersWithUnknownHistory }
    var reservationAttemptsForTesting: [OriginReservation.Attempt] { checkpoint?.reservationAttempts ?? [] }
    var mlsDirectoryForTesting: URL { mlsDirectory }
    var replicaForTesting: TaskReplica { taskAdapter!.replica }
}

// MARK: - Host journal

extension SyncEngine {
    /// Committed host state; nil for task profiles.
    var hostView: HostEngineView? {
        guard isHostMode else { return nil }
        let journal = hostAdapter?.store?.view
        var uploaded: UInt64 = 0
        if let journal, let current = checkpoint {
            uploaded = uploadedLocalSequence(in: current)
            if current.hostJournal != journal.journalID {
                uploaded = 0
            }
        }
        return HostEngineView(
            revision: hostViewRevision &+ hostSessionRevisionBase &+ (session?.operationCount.started ?? 0),
            journal: journal, uploadedThrough: uploaded,
            intake: currentHostIntake, lifecycle: hostLifecycle, repair: hostRepair,
            journalSettled: hostAdapter?.store?.isSettled ?? true
        )
    }

    /// The handle of the current journal generation while host work may
    /// start; nil while opening, closing, failed, repaired or stopped. A
    /// handle is never re-bound: after a change, read this again.
    public var hostJournal: HostJournal? {
        guard hostWorkAllowed, let store = hostAdapter?.store, store.fence == .open else { return nil }
        return store
    }

    /// The directory holding this engine's journal files; nil for task profiles.
    var hostJournalDirectory: URL? { hostAdapter?.directory }

    func hostJournalListings() throws -> [HostJournalListing] {
        guard let directory = hostAdapter?.directory else { return [] }
        return try HostJournalFiles.discover(in: directory)
    }

    func exportHostJournal(_ url: URL, after cursor: HostJournalExportCursor?, limit: Int) throws -> HostJournalExportPage {
        try HostJournalFiles.export(url, after: cursor, limit: limit)
    }

    /// Waits until no writer of that journal remains open, so the file is
    /// never removed under a connection.
    func discardRetiredHostJournal(_ journalID: Data, confirming: Data) async throws {
        guard let directory = hostAdapter?.directory else { return }
        await awaitHostJournalShutdowns()
        if let bound = hostAdapter?.store, bound.view.journalID == journalID, !bound.isClosed {
            throw JournalStoreError.notArchived
        }
        try HostJournalFiles.discard(in: directory, journalID: journalID, confirming: confirming)
    }

    var hostWorkAllowed: Bool {
        !isHostMode || (hostLifecycle == .active && hostRepair == nil)
    }

    /// `stop` closes the bound journal's connection. Engine work opens a
    /// fresh writer generation for it before touching the journal; old
    /// handles stay closed.
    private func ensureHostJournalOpen() async throws {
        if isHostMode, hostLifecycle == .opening {
            resumeStoppedHostLaunch()
            await hostOpenTask?.value
        }
        while isHostMode, hostWorkAllowed, let store = hostAdapter?.store, store.isClosed {
            if let reopening = hostReopenTask {
                try await reopening.value
                continue
            }
            let task = Task { [weak self] in
                defer { self?.hostReopenTask = nil }
                await self?.awaitHostJournalShutdowns()
                guard let self else { return }
                let fresh = try await HostJournal.open(
                    store.url, limits: self.hostJournalLimits, resumedEnrollment: store.resumedEnrollment
                )
                guard self.hostAdapter?.store === store, !self.isStopping else {
                    await fresh.shutdown()
                    throw CancellationError()
                }
                self.bindHostJournal(fresh)
            }
            hostReopenTask = task
            try await task.value
        }
    }

    private func publishHostView() {
        guard isHostMode else { return }
        let start = segmentHookForTesting == nil ? nil : ContinuousClock.now
        hostViewRevision += 1
        if let revision = hostView?.revision {
            for subscriber in hostViewSubscribers.values { subscriber.yield(revision) }
        }
        publishState()
        if let start { segmentHookForTesting?("publish.hostView", ContinuousClock.now - start) }
    }

    /// An independent stream of composed-view revisions: the current one
    /// first, then the newest on every publication, until `stop`.
    public func hostViewChanges() -> AsyncStream<UInt64> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<UInt64>.makeStream(bufferingPolicy: .bufferingNewest(1))
        hostViewSubscribers[id] = continuation
        if let revision = hostView?.revision {
            continuation.yield(revision)
        }
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.hostViewSubscribers.removeValue(forKey: id) }
        }
        return stream
    }

    func settleHostIntakeForTesting() async throws {
        try await reopenStoppedHostJournalForTesting()
        guard let session else { throw SyncError.localStorageUnavailable }
        try await settleHostIntake(session: session)
    }

    func hostJournalIDForTesting(group: Data) async throws -> Data {
        try await hostJournalID(for: group, founder: false)
    }

    func abandonHostJournalForTesting() async throws {
        try await abandonHostJournal()
    }

    /// Closes the bound generation once its commands settled and binds a
    /// fresh one for the same file, as stop and a later start would.
    func replaceHostJournalGenerationForTesting() async throws {
        guard let store = hostAdapter?.store else { return }
        await store.shutdown()
        try await ensureHostJournalOpen()
    }

    func uploadLocalOperationsForTesting() async throws {
        try await reopenStoppedHostJournalForTesting()
        guard let session else { throw SyncError.localStorageUnavailable }
        try await uploadLocalOperations(session: session)
    }

    /// Opens a fresh writer generation for the journal `stop` closed,
    /// without starting any work, for tests that drive a stopped engine.
    var hostRetainedSessionForTesting: MLSSession? { hostRetainedSession }

    /// Resets `owner`, the current host session by default, through the owned reset path.
    func resetHostSessionForTesting(owner: MLSSession? = nil, discard: Bool) async throws -> HostResetOutcome {
        guard let owner = owner ?? session else { throw SyncError.localStorageUnavailable }
        return try await resetHostSession(owner: owner) { _ in discard }
    }

    /// The journal `stop` closed, for reading its last adopted view.
    var stoppedHostJournalForTesting: HostJournal? {
        hostAdapter?.store?.isClosed == true ? hostAdapter?.store : nil
    }

    func reopenStoppedHostJournalForTesting() async throws {
        try await ensureHostJournalOpen()
    }

    /// Runs `body` as a live host worker, as pairing or reconcile would.
    @discardableResult
    func runHostWorkerForTesting(_ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        beginHostWorker()
        let task = Task { [weak self] in
            defer { self?.endHostWorker() }
            await body()
        }
        hostWorkersForTesting.append(task)
        return task
    }

    /// Whether this host may count a new member against its history.
    private func hostAdmissionAllowed(linked: Bool) -> Bool {
        guard isHostMode else { return true }
        guard hostRepair == nil else { return false }
        guard let store = hostAdapter?.store else { return !linked }
        let view = store.view
        return !store.isIntakeOutstanding && view.quarantineCount == 0 && view.retainedBytes <= Self.hostJoinBudget && !view.controlRepair
            && (!linked || view.isReady)
    }

    private func hostArchivesAdmitLink() -> Bool {
        guard let listings = try? hostJournalListings() else { return false }
        return HostJournalFiles.admitsNewLink(listings)
    }

    /// A provider may choose a completion cut only once its own history is
    /// complete, it declared readiness, and nothing it holds is unresolved.
    /// A command whose outcome is not yet adopted makes the view too old to certify.
    private var hostProviderEligible: Bool {
        guard isHostMode, hostWorkAllowed, let store = hostAdapter?.store, store.isSettled, let current = checkpoint,
              current.hostJournal == store.view.journalID, !store.view.isRetired
        else {
            return false
        }
        let view = store.view
        return view.historyComplete && view.isReady && !view.controlRepair && view.pendingCount == 0
            && view.quarantineCount == 0 && !isInboxBackpressured
            && current.reservationsVisible != false && current.membersWithUnknownHistory == nil
    }

    /// Whether this provider may certify history or a reservations
    /// snapshot right now. Checked again immediately before each send, so a
    /// saved cut or snapshot request stays queued while control state is
    /// incomplete.
    func hostMayCertify(session: MLSSession) async throws -> Bool {
        guard hostProviderEligible else { return false }
        let unknownOrigins = try await admissionView(session: session).unknownOrigins
        try requireCurrent(session)
        return !unknownOrigins && hostProviderEligible
    }

    /// The highest record a bootstrap reply may carry: every chosen cut, or
    /// what this device held when the replies began while no cut is chosen.
    private static func replyBound(_ bootstrap: [ReplyObligation.Bootstrap]?, snapshot: ReplicaVersionVector) -> ReplicaVersionVector {
        let cuts = (bootstrap ?? []).compactMap(\.cut)
        guard !cuts.isEmpty else { return snapshot }
        var bound = ReplicaVersionVector()
        for cut in cuts {
            for origin in cut.origins {
                bound.setSequence(max(bound[origin], cut[origin]), for: origin)
            }
        }
        return bound
    }

    /// The journal of `group`, created when none is bound. A bound journal
    /// of another group that never became established is abandoned first.
    private func hostJournalID(for group: Data, founder: Bool) async throws -> Data {
        guard let host = hostAdapter else { throw HostEngineError.journalUnbound }
        if let store = host.store {
            if store.view.group == group, !store.view.isRetired {
                try await ensureHostJournalOpen()
                return store.view.journalID
            }
            guard !store.view.established else { throw HostEngineError.generationChanged }
            try await abandonHostJournal()
        }
        let store = try await HostJournal.create(in: host.directory, group: group, founder: founder, limits: hostJournalLimits)
        guard hostAdapter?.store == nil else {
            await store.shutdown()
            throw HostEngineError.generationChanged
        }
        bindHostJournal(store)
        return store.view.journalID
    }

    /// Binds `store`. A previous journal is fenced and, unless the caller
    /// owns its shutdown, closed once its accepted commands settled.
    private func bindHostJournal(_ store: HostJournal?, shutsDownPrevious: Bool = true) {
        if let previous = hostAdapter?.store, previous !== store {
            previous.fenceHost()
            previous.changed = nil
            if shutsDownPrevious {
                shutDownHostJournal(previous)
            }
        }
        store?.changed = { [weak self] in self?.publishHostView() }
        hostAdapter?.bind(store)
        publishHostView()
    }

    /// Keeps `store` owned until its accepted commands settled and its
    /// connection closed; `stop`, erase, discard and any later open of a
    /// journal wait for it.
    private func shutDownHostJournal(_ store: HostJournal) {
        guard hostJournalShutdowns[store.generation] == nil else { return }
        hostJournalShutdowns[store.generation] = Task { [weak self] in
            await store.shutdown()
            self?.hostJournalShutdowns[store.generation] = nil
        }
    }

    private func awaitHostJournalShutdowns() async {
        while let pending = hostJournalShutdowns.values.first {
            await pending.value
        }
    }

    /// Records that the saved `checkpoint` references the bound journal,
    /// unless the binding changed while saving.
    private func markHostJournalEstablished(_ saved: ReplicationCheckpoint) async throws {
        guard let store = hostAdapter?.store, store.view.journalID == saved.hostJournal, !store.isClosed else { return }
        try await store.markEstablished()
    }

    /// Drops a journal no checkpoint ever referenced: deleted when it owns
    /// nothing, otherwise retired. Emptiness is decided from the state its
    /// last accepted command left, and the file is removed only after its
    /// connection closed.
    private func abandonHostJournal() async throws {
        try await ensureHostJournalOpen()
        guard let store = hostAdapter?.store, !store.view.established else { return }
        bindHostJournal(nil, shutsDownPrevious: false)
        let owner = Task { [weak self] () -> Error? in
            await store.drainClosing()
            let view = store.view
            var failure: Error?
            if view.established {
                failure = HostEngineError.generationChanged
            } else if view.enrollment != .none || view.retainedCount > 0 || view.quarantineCount > 0, !view.isRetired {
                do {
                    try await store.retire(.orphaned, heldInbox: [])
                } catch {
                    failure = error
                }
            }
            await store.shutdown()
            if failure == nil, !view.established, view.enrollment == .none, view.retainedCount == 0, view.quarantineCount == 0 {
                do {
                    try FileManager.default.removeItem(at: store.url)
                } catch {
                    failure = error
                }
            }
            self?.hostJournalShutdowns[store.generation] = nil
            return failure
        }
        hostJournalShutdowns[store.generation] = Task { _ = await owner.value }
        if let failure = await owner.value {
            throw failure
        }
    }

    /// Binds the journal this link's checkpoint or join intent references.
    /// A missing or unreadable referenced journal stops sync preserving
    /// everything; unreferenced journals are deleted only when they own
    /// nothing. An established journal without its checkpoint keeps its
    /// generation under control repair.
    /// Journals the launch opens away from the main actor: the referenced
    /// one, or a single established orphan under control repair, and
    /// orphans to retire.
    /// Journals a launch opens away from the main actor: the referenced one,
    /// or a single established orphan under control repair, orphans to
    /// retire, and unreferenced journals that looked empty.
    struct HostLaunchOpen: Sendable, Equatable {
        var bind: URL?
        var controlRepair = false
        var retire: [URL] = []
        /// Deleted only if still empty once their writer drained.
        var emptyCandidates: [URL] = []
    }

    /// The launch inputs a classification depends on; a launch applies its
    /// observation only while they are unchanged.
    struct HostLaunchInputs: Sendable, Equatable {
        var checkpointGroup: Data?
        var checkpointJournal: Data?
        var intentGroup: Data?
        var intentJournal: Data?
        var checkpointUnreadable: Bool
        var pendingLifecycle: HostLifecycleRecord?
        var repair: HostRepair?
    }

    /// What classification proposes from one observation; nothing is
    /// applied while it is computed.
    struct HostLaunchProposal: Sendable {
        var plan = HostLaunchOpen()
        var repair: HostRepair?
        var lifecycle: HostLifecycleRecord?
    }

    enum HostSessionResult: Sendable {
        case built(MLSSession)
        case alreadyOwned
        case unrecoverable
        case failed(any Error)
    }

    struct PreparedHostLaunch: Sendable {
        let session: HostSessionResult
        let listings: Result<[HostJournalListing], any Error>
    }

    enum HostLaunchOutcome: Sendable {
        case proceed(HostLaunchOpen)
        /// Stop, closing or a newer launch took over; nothing was applied
        /// beyond the session.
        case dropped
        case failed
    }

    /// One launch generation. Its preparation is joined by every waiter
    /// through one settlement, which applies the result exactly once and
    /// then releases it.
    @MainActor
    final class HostLaunch {
        let id = UUID()
        var inputs: HostLaunchInputs
        var preparation: Task<PreparedHostLaunch, Never>?
        var settlement: Task<HostLaunchOutcome, Never>?

        init(inputs: HostLaunchInputs) {
            self.inputs = inputs
        }
    }

    private var currentHostLaunchInputs: HostLaunchInputs {
        let intent = try? ReplicationCheckpoint.load(from: joinIntentURL)
        return HostLaunchInputs(
            checkpointGroup: checkpoint?.group, checkpointJournal: checkpoint?.hostJournal,
            intentGroup: intent?.group, intentJournal: intent?.hostJournal,
            checkpointUnreadable: hostCheckpointUnreadable, pendingLifecycle: pendingHostLifecycle, repair: hostRepair
        )
    }

    /// Starts a launch generation: one detached preparation builds the MLS
    /// session, unless one is installed, and observes the journal
    /// directory; the launch task settles it and opens the journals.
    private func startHostLaunch() {
        guard let directory = hostAdapter?.directory else { return }
        hostLaunchesForTesting += 1
        let launch = HostLaunch(inputs: currentHostLaunchInputs)
        let build = session == nil
            ? (mlsDirectory, deviceID.bytes, secretStore, mlsTransport) as (URL, Data, any SecretStore, any MLSRelayTransport)?
            : nil
        launch.preparation = Task.detached(priority: .userInitiated) {
            await Self.prepareHostLaunch(build: build, directory: directory)
        }
        hostLaunch = launch
        hostLifecycle = .opening
        beginHostWorker()
        hostOpenTask = Task { [weak self] in
            defer { self?.endHostWorker() }
            await self?.runHostLaunch(launch)
        }
    }

    /// Both parts always run to completion; the group joins them whichever fails.
    nonisolated private static func prepareHostLaunch(
        build: (URL, Data, any SecretStore, any MLSRelayTransport)?, directory: URL
    ) async -> PreparedHostLaunch {
        async let session: HostSessionResult = {
            guard let (mls, deviceID, secrets, transport) = build else { return .alreadyOwned }
            do {
                return .built(try MLSSession(directory: mls, deviceID: deviceID, secretStore: secrets, transport: transport))
            } catch where isUnrecoverableSessionState(error) {
                return .unrecoverable
            } catch {
                return .failed(error)
            }
        }()
        async let listings = Result { try HostJournalFiles.discover(in: directory) }
        return PreparedHostLaunch(session: await session, listings: await listings)
    }

    private func runHostLaunch(_ launch: HostLaunch) async {
        defer {
            if hostLaunch === launch { hostLaunch = nil }
        }
        switch await settleHostLaunch(launch) {
        case .proceed(let plan) where hostLaunchIsCurrent(launch):
            await openLaunchJournals(plan, launch: launch)
        case .failed where hostLaunchIsCurrent(launch):
            completeHostLaunch()
        default:
            return
        }
    }

    /// The one settlement of `launch`: every waiter gets the same outcome,
    /// and only the first applies it.
    @discardableResult
    private func settleHostLaunch(_ launch: HostLaunch) async -> HostLaunchOutcome {
        if let settlement = launch.settlement {
            return await settlement.value
        }
        let settlement = Task { @MainActor [weak self] () -> HostLaunchOutcome in
            guard let preparation = launch.preparation else { return .dropped }
            let prepared = await preparation.value
            launch.preparation = nil
            guard let self else { return .dropped }
            return await self.applyHostLaunch(launch, prepared)
        }
        launch.settlement = settlement
        return await settlement.value
    }

    private func hostLaunchIsCurrent(_ launch: HostLaunch) -> Bool {
        hostLaunch === launch && hostLifecycle == .opening && !isStopping && !Task.isCancelled
    }

    /// Installs a built session whatever the lifecycle, so stop and closing
    /// receive it. Applies the observation only while the same launch is
    /// still opening; changed inputs are observed again, three times at most.
    private func applyHostLaunch(_ launch: HostLaunch, _ prepared: PreparedHostLaunch) async -> HostLaunchOutcome {
        let current = hostLaunch === launch && !isStopping
        switch prepared.session {
        case .built(let built):
            if session == nil {
                session = built
            } else {
                try? await built.close()
            }
        case .alreadyOwned:
            break
        case .unrecoverable:
            if current {
                hostRepair = hostRepair ?? .mlsUnreadable
                launch.inputs.repair = hostRepair
            }
        case .failed(let error):
            if current {
                failHostLaunch(error)
            }
            return .failed
        }
        var listings = prepared.listings
        var attempts = 1
        while true {
            guard hostLaunch === launch, hostLifecycle == .opening, !isStopping else { return .dropped }
            await launchObservationHookForTesting?()
            guard hostLaunch === launch, hostLifecycle == .opening, !isStopping else { return .dropped }
            let inputs = currentHostLaunchInputs
            if inputs == launch.inputs { break }
            guard attempts < 3 else {
                hostRepair = hostRepair ?? .launchInputsChanged
                return .failed
            }
            attempts += 1
            launch.inputs = inputs
            guard let directory = hostAdapter?.directory else { return .dropped }
            listings = await Task.detached { Result { try HostJournalFiles.discover(in: directory) } }.value
        }
        let observed: [HostJournalListing]
        switch listings {
        case .success(let value):
            observed = value
        case .failure(let error):
            failHostLaunch(error)
            return .failed
        }
        guard let directory = hostAdapter?.directory else { return .dropped }
        let proposal = Self.proposeHostLaunch(observed, inputs: launch.inputs, directory: directory)
        if let repair = proposal.repair, hostRepair == nil {
            hostRepair = repair
        }
        if let lifecycle = proposal.lifecycle, pendingHostLifecycle == nil {
            pendingHostLifecycle = lifecycle
        }
        launch.inputs = currentHostLaunchInputs
        return .proceed(proposal.plan)
    }

    /// A launch that cannot complete stops host work with a repair, so the
    /// host never looks active.
    private func failHostLaunch(_ error: Error) {
        hostRepair = hostRepair ?? .launchFailed("\(error)")
    }

    /// Decides from journal metadata which journal this link's checkpoint or
    /// join intent references. A missing or unreadable referenced journal
    /// stops sync preserving everything; unreferenced journals that look
    /// empty are proposed for deletion, decided again once their writer
    /// drained. An established journal without its checkpoint keeps its
    /// generation under control repair.
    nonisolated private static func proposeHostLaunch(
        _ listings: [HostJournalListing], inputs: HostLaunchInputs, directory: URL
    ) -> HostLaunchProposal {
        var proposal = HostLaunchProposal()
        let referenced = inputs.checkpointJournal ?? (inputs.checkpointGroup == nil ? inputs.intentJournal : nil)
        if let referenced {
            let url = HostJournalStore.fileURL(in: directory, journalID: referenced)
            let listing = listings.first {
                switch $0 {
                case .journal(let candidate, _), .unreadable(let candidate, _): candidate == url
                case .incomplete: false
                }
            }
            switch listing {
            case .journal(_, let view)? where view.isRetired:
                proposal.lifecycle = HostLifecycleRecord(
                    intent: view.retirement == .unlink ? .unlink : .removed, journal: referenced, group: view.group
                )
            case .journal?:
                proposal.plan.bind = url
            case .unreadable(_, let reason)?:
                proposal.repair = .journalUnreadable(reason)
            case .incomplete?, nil:
                proposal.repair = .journalMissing
            }
        }
        var orphans: [URL] = []
        for listing in listings {
            guard case .journal(let url, let view) = listing, view.journalID != referenced, !view.isRetired else { continue }
            if !view.established, view.enrollment == .none, view.retainedCount == 0, view.quarantineCount == 0 {
                proposal.plan.emptyCandidates.append(url)
            } else if view.established, referenced == nil {
                orphans.append(url)
            } else {
                proposal.plan.retire.append(url)
            }
        }
        if orphans.count == 1, proposal.plan.bind == nil, referenced == nil {
            proposal.plan.bind = orphans[0]
            proposal.plan.controlRepair = true
        } else if orphans.count > 1 {
            proposal.repair = proposal.repair ?? .ambiguousJournal
        }
        if inputs.checkpointUnreadable {
            proposal.plan.controlRepair = true
        }
        return proposal
    }

    /// Deletes, retires and binds the launch journals through their own
    /// writers, checking before each step that the launch still owns
    /// opening and its inputs are unchanged, then continues the launch.
    private func openLaunchJournals(_ plan: HostLaunchOpen, launch: HostLaunch) async {
        func stillOwned() -> Bool {
            hostLaunchIsCurrent(launch) && currentHostLaunchInputs == launch.inputs
        }
        do {
            await awaitHostJournalShutdowns()
            for url in plan.emptyCandidates {
                guard stillOwned() else { return }
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let store = try await prepareAndInstall(url)
                await store.drainClosing()
                let view = store.view
                let empty = !view.established && !view.isRetired && view.enrollment == .none
                    && view.retainedCount == 0 && view.quarantineCount == 0
                if !empty, !view.isRetired {
                    do {
                        try await store.retire(.orphaned, heldInbox: [])
                    } catch {
                        await store.shutdown()
                        throw error
                    }
                }
                await store.shutdown()
                guard stillOwned() else { return }
                if empty {
                    try FileManager.default.removeItem(at: url)
                }
            }
            for url in plan.retire {
                guard stillOwned() else { return }
                let store = try await prepareAndInstall(url)
                store.fenceHost()
                do {
                    try await store.retire(.orphaned, heldInbox: [])
                } catch {
                    await store.shutdown()
                    throw error
                }
                await store.shutdown()
            }
            if let url = plan.bind {
                guard stillOwned() else { return }
                let store = try await prepareAndInstall(url)
                guard stillOwned() else {
                    await store.shutdown()
                    return
                }
                if plan.controlRepair, !store.view.controlRepair {
                    do {
                        try await store.enterControlRepair()
                    } catch {
                        await store.shutdown()
                        throw error
                    }
                }
                guard stillOwned() else {
                    await store.shutdown()
                    return
                }
                bindHostJournal(store)
            }
        } catch {
            guard hostLaunchIsCurrent(launch) else { return }
            hostRepair = hostRepair ?? .journalUnreadable("\(error)")
        }
        guard hostLaunchIsCurrent(launch) else { return }
        completeHostLaunch()
    }

    /// Ends opening: publishes any repair as a failure, then continues.
    private func completeHostLaunch() {
        hostLaunch = nil
        hostOpenTask = nil
        hostLifecycle = .active
        if hostRepair != nil, phase != .failed {
            phase = .failed
            mailboxError = .localStorageUnavailable
            mailboxErrorMessage = Self.displayMessage(for: SyncError.localStorageUnavailable)
            mailboxRequiresRepair = true
            mailboxState = .unavailable
            errorMessage = mailboxErrorMessage
        }
        continueHostLaunch()
    }

    /// Starts the pending closing or reconciles the link, as launch does
    /// once its journal is bound.
    private func continueHostLaunch() {
        if let record = pendingHostLifecycle {
            hostAdapter?.store?.beginClosing()
            hostLifecycle = .closing(record.intent)
            beginHostWorker()
            hostLifecycleTask = Task { [weak self] in
                defer { self?.endHostWorker() }
                await self?.runHostClosing(record)
            }
        } else if session != nil, hostRepair == nil {
            startReconcile()
        }
    }

    /// Starts pairing that was asked for while the launch was opening once
    /// opening ended; pairing then checks the settled state as it always does.
    private func startAfterHostLaunch(_ start: @escaping @MainActor (SyncEngine) -> Void) {
        guard hostLaunchStartTask == nil else { return }
        hostLaunchStartTask = Task { [weak self] in
            guard let self else { return }
            self.resumeStoppedHostLaunch()
            await self.hostOpenTask?.value
            self.hostLaunchStartTask = nil
            guard !Task.isCancelled, !self.isStopping, self.hostLifecycle != .opening else { return }
            start(self)
        }
    }

    /// After `stop` interrupted opening, starts one fresh launch generation
    /// with the installed session; later calls join it.
    private func resumeStoppedHostLaunch() {
        guard isHostMode, hasDurableStorage, hostLifecycle == .opening, hostLaunch == nil, hostOpenTask == nil, !isStopping,
              hostRetainedSession == nil
        else {
            return
        }
        startHostLaunch()
    }

    /// Validates and binds `url` on a new writer, away from the main actor.
    /// A journal opened after cancellation is closed again before returning.
    private func prepareAndInstall(_ url: URL) async throws -> HostJournal {
        let store = try await HostJournal.open(url, limits: hostJournalLimits, prepared: preparedJournalHookForTesting)
        guard !Task.isCancelled else {
            await store.shutdown()
            throw CancellationError()
        }
        return store
    }

    private static func preserveUnreadable(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let preserved = url.deletingPathExtension().appendingPathExtension("unreadable-\(UUID().uuidString.lowercased()).json")
        try FileManager.default.moveItem(at: url, to: preserved)
        try? FileManager.default.setAttributes(ProtectedStorage.fileAttributes, ofItemAtPath: preserved.path)
    }

    private static func loadHostLifecycleRecord(in directory: URL) throws -> HostLifecycleRecord? {
        let url = directory.appendingPathComponent(hostLifecycleFilename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try ReplicaCanonicalJSON.decode(HostLifecycleRecord.self, from: Data(contentsOf: url))
    }

    private var hostLifecycleURL: URL {
        checkpointURL.deletingLastPathComponent().appendingPathComponent(Self.hostLifecycleFilename)
    }

    private var eraseMarkerURL: URL {
        checkpointURL.deletingLastPathComponent().appendingPathComponent(Self.eraseMarkerFilename)
    }

    /// Persists the closing intent, fences new work and hands cleanup to a
    /// worker that waits for the cancelled tasks, so no caller waits on
    /// itself. A failure to persist the intent changes nothing.
    private func beginHostClosing(_ intent: HostLifecycleIntent) {
        if case .closing = hostLifecycle {
            return
        }
        retireBlobBinding()
        hostAdapter?.store?.beginClosing()
        let joinIntent = checkpoint == nil ? try? ReplicationCheckpoint.load(from: joinIntentURL) : nil
        let record = HostLifecycleRecord(
            intent: intent,
            journal: hostAdapter?.store?.view.journalID ?? checkpoint?.hostJournal ?? joinIntent?.hostJournal,
            group: checkpoint?.group ?? hostAdapter?.store?.view.group ?? joinIntent?.group
        )
        do {
            try ProtectedStorage.write(ReplicaCanonicalJSON.encode(record), to: hostLifecycleURL)
        } catch {
            lastHostLifecycleError = error
            hostLifecycle = .failed(intent)
            return
        }
        lastHostLifecycleError = nil
        let running = [
            pairingTask, pairingExpiryTask, pairingReaderTask, reconcileTask, joinSettlementTask,
            syncLoopTask, syncCycleTask, backgroundFlushTask, hostLifecycleTask, hostOpenTask,
        ].compactMap { $0 }
        hostLifecycle = .closing(intent)
        cancelAllWork()
        beginHostWorker()
        let reset = hostSessionReset?.task
        hostLifecycleTask = Task { [weak self] in
            defer { self?.endHostWorker() }
            for task in running {
                await task.value
            }
            _ = await reset?.result
            await self?.runHostClosing(record)
        }
    }

    /// Unlink and removal hand the held inbox to the closing generation's
    /// journal, then make MLS control-only before any other cleanup. Erase
    /// destroys library-owned journals and link state. Every step after a
    /// suspension first checks for cancellation, so a stopped worker leaves
    /// its durable intent for the next launch and starts nothing new.
    private func runHostClosing(_ record: HostLifecycleRecord) async {
        let intent = record.intent
        invalidateHostIntake()
        do {
            try await hostClosingHookForTesting?("start")
            try Task.checkCancellation()
            switch intent {
            case .unlink, .removed:
                try await handOffHostInbox(record)
                try await hostClosingHookForTesting?("retired")
                try Task.checkCancellation()
                try await session?.setControlOnly()
                try await hostClosingHookForTesting?("controlOnly")
                try Task.checkCancellation()
                try await finishHostUnlink(departing: intent == .unlink)
            case .erase:
                guard hostRetainedSession == nil else { throw HostEngineError.sessionCloseUncertain }
                try Self.persistEraseMarker(at: eraseMarkerURL)
                try await hostClosingHookForTesting?("marked")
                try Task.checkCancellation()
                if hostRepair != .mlsUnreadable {
                    try await session?.setControlOnly()
                }
                try await hostClosingHookForTesting?("controlOnly")
                try Task.checkCancellation()
                try await finishHostErase()
            }
        } catch {
            lastHostLifecycleError = error
            hostLifecycle = .failed(intent)
            hostLifecycleTask = nil
            return
        }
        hostLifecycleTask = nil
        hostLifecycle = .active
        if intent == .removed {
            errorMessage = Self.displayMessage(for: SyncError.removedFromGroup)
            linkEndedReason = .removedFromGroup
        }
        startDepartures()
    }

    /// Makes the closing generation's journal the owner of every message
    /// in the MLS inbox: retires it with them, or finds it already retired
    /// holding the same bytes. Anything else, including a missing, unreadable
    /// or different journal, throws before any MLS or link state changes.
    private func handOffHostInbox(_ record: HostLifecycleRecord) async throws {
        if hostRepair == .mlsUnreadable {
            throw HostEngineError.mlsUnreadable
        }
        guard hostRepair == nil, let session, let journalID = record.journal, let directory = hostAdapter?.directory else {
            throw HostEngineError.handoffUnproven
        }
        if let current = checkpoint, current.hostJournal != journalID {
            throw HostEngineError.handoffUnproven
        }
        let mlsGroup = try await session.group()
        let inbox = try await session.inbox()
        try requireCurrent(session)
        let held = inbox.map { HostJournalHeldMessage(sender: $0.sender, cursor: $0.cursor, plaintext: $0.plaintext) }
        if let bound = hostAdapter?.store, bound.view.journalID == journalID, !bound.isClosed {
            try await handOff(held, to: bound, record: record, mlsGroup: mlsGroup)
            return
        }
        await awaitHostJournalShutdowns()
        let journal = try await prepareAndInstall(HostJournalStore.fileURL(in: directory, journalID: journalID))
        journal.beginClosing()
        do {
            try await handOff(held, to: journal, record: record, mlsGroup: mlsGroup)
        } catch {
            await journal.shutdown()
            throw error
        }
        await journal.shutdown()
    }

    /// Decides from the state every command accepted before closing left.
    private func handOff(
        _ held: [HostJournalHeldMessage], to journal: HostJournal, record: HostLifecycleRecord, mlsGroup: Data?
    ) async throws {
        await journal.drainClosing()
        let group = journal.view.group
        guard journal.view.journalID == record.journal, record.group.map({ $0 == group }) ?? true,
              mlsGroup.map({ $0 == group }) ?? true
        else {
            throw HostEngineError.handoffUnproven
        }
        if !journal.view.isRetired {
            try await journal.retire(record.intent == .unlink ? .unlink : .removed, heldInbox: held)
        }
        guard try await journal.holdsInbox(held) else {
            throw HostEngineError.handoffUnproven
        }
    }

    /// The session's store is closed before its files are staged or
    /// erased, so no write of the old session can follow.
    private func finishHostUnlink(departing: Bool) async throws {
        try await session?.close()
        try LegacyLinkCredentials.erase(from: secretStore)
        session = nil
        if departing {
            try stageDeparture()
        }
        try ReplicationCheckpoint.remove(at: checkpointURL)
        try ReplicationCheckpoint.remove(at: joinIntentURL)
        try discardDeferredOperations()
        try eraseCurrentMLSState()
        session = try openSession()
        bindHostJournal(nil)
        try ReplicationCheckpoint.remove(at: hostLifecycleURL)
        resetLinkState()
    }

    private func finishHostErase() async throws {
        if let store = hostAdapter?.store {
            bindHostJournal(nil)
            await store.shutdown()
        }
        await awaitHostJournalShutdowns()
        try Task.checkCancellation()
        try await session?.close()
        session = nil
        if hostRepair != .mlsUnreadable {
            try stageDeparture()
        }
        let directory = checkpointURL.deletingLastPathComponent()
        let manager = FileManager.default
        for name in try manager.contentsOfDirectory(atPath: directory.path)
        where name.hasPrefix(HostJournalStore.filePrefix) || name.hasPrefix("sync-v2.unreadable-") {
            try manager.removeItem(at: directory.appendingPathComponent(name))
        }
        try LegacyLinkCredentials.erase(from: secretStore)
        try Self.removeAllPairingArtifacts(in: directory)
        try ReplicationCheckpoint.remove(at: checkpointURL)
        try ReplicationCheckpoint.remove(at: joinIntentURL)
        for filename in [ReplicationCheckpoint.foundingClaimsFilename, ReplicationCheckpoint.unreadableFoundingClaimsFilename] {
            try ReplicationCheckpoint.remove(at: directory.appendingPathComponent(filename))
        }
        try MLSSession.erase(directory: mlsRoot, secretStore: secretStore)
        try discardDeferredOperations()
        mlsDirectory = Self.freshMLSDirectory(in: mlsRoot)
        session = try openSession()
        hostRepair = nil
        if manager.fileExists(atPath: eraseMarkerURL.path) {
            try manager.removeItem(at: eraseMarkerURL)
        }
        try ReplicationCheckpoint.remove(at: hostLifecycleURL)
        resetLinkState()
        tasks = []
        localEditErrorMessage = nil
    }

    /// While its history is incomplete, a joiner asks the next member every
    /// few cycles, whether or not reservations are visible.
    private func requestHistoryIfIncomplete(session: MLSSession) async throws {
        guard let store = hostAdapter?.store, hostWorkAllowed, !store.view.historyComplete, checkpoint?.joinPending == false else {
            historyRequestCycles = 0
            return
        }
        historyRequestCycles += 1
        guard historyRequestCycles >= Self.reservationRequestInterval else { return }
        historyRequestCycles = 0
        let own = try await session.fingerprint()
        let others = try await session.members().map(\.fingerprint).filter { $0 != own }
            .sorted { $0.lexicographicallyPrecedes($1) }
        try requireCurrent(session)
        guard let first = others.first else {
            if store.view.isDeliveryHeld {
                let binding = try hostBinding(session)
                try await store.refuseSnapshot(.noProvider, in: [.requested])
                try requireHostBinding(binding, session)
            }
            return
        }
        let next = store.view.historyProvider.flatMap { previous in
            others.first { previous.lexicographicallyPrecedes($0) }
        } ?? first
        let binding = try hostBinding(session)
        try await store.setHistoryProvider(next)
        try requireHostBinding(binding, session)
        try await requestSnapshotBootstrap(binding: binding, session: session)
        try await send(.hello(vector: replication.helloVector, provider: next), session: session)
    }
}

extension SyncEngine {
    var replyObligationForTesting: ReplyObligation? { replyObligation }
    func sendRepliesForTesting() async throws {
        try await reopenStoppedHostJournalForTesting()
        guard let session else { throw SyncError.localStorageUnavailable }
        try await sendReplies(session: session)
    }
}
