import Combine
import Foundation
import UIKit

enum SyncPhase: Equatable, Sendable {
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

enum MailboxSyncState: Equatable, Sendable {
    case idle
    case syncing
    case available
    case unavailable
}

enum SyncNoticeKind: Equatable, Sendable {
    case saving
    case retrying
    case repair
}

struct SyncNotice: Equatable, Sendable {
    let kind: SyncNoticeKind
    let title: String
    let detail: String
}

enum SyncAppError: Error, LocalizedError {
    case invalidPairMessage
    case invalidSyncMessage
    case invalidCredentials
    case relay(String)
    case pairingDeclined
    case invitationExpired
    case archiveTooLarge
    case localStorageUnavailable
    case safetyCodeMismatch
    case pairingReplicaConflict
    case pairingMergeTooLarge
    case legacyPairingNeedsRelink
    case pairingRecoveryHistoryFull
    case pairingRecoveryJournalDamaged

    var errorDescription: String? {
        switch self {
        case .invalidPairMessage:
            "The pairing message was invalid."
        case .invalidSyncMessage:
            "The sync message was invalid."
        case .invalidCredentials:
            "The saved sync credentials were invalid."
        case .relay(let code):
            "The relay rejected this connection (\(code))."
        case .pairingDeclined:
            "Pairing was cancelled."
        case .invitationExpired:
            "The one-time invitation expired. Create a new one."
        case .archiveTooLarge:
            "This proof of concept cannot provision an archive larger than 280 KiB."
        case .localStorageUnavailable:
            "Local storage is unavailable. Restart the app after fixing storage."
        case .safetyCodeMismatch:
            "The safety codes did not match. Nothing was linked. Create a new invitation and try again."
        case .pairingReplicaConflict:
            "Local tasks changed while the private link was finishing. Got Done preserved both copies and paused finalization."
        case .pairingMergeTooLarge:
            "These task histories cannot be safely combined on this device. Nothing was linked, and your local tasks are unchanged."
        case .legacyPairingNeedsRelink:
            "An older pairing stopped during its final step. Your tasks are safe, but the private link must be created again."
        case .pairingRecoveryHistoryFull:
            "Too many unfinished pairing proofs are still retained. Keep your tasks and reset Private Sync before creating another link."
        case .pairingRecoveryJournalDamaged:
            "Saved pairing recovery data is damaged. Your tasks are safe; reset Private Sync before creating another link."
        }
    }
}

@MainActor
final class SyncAppModel: ObservableObject {
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

    @Published private(set) var phase: SyncPhase = .unpaired
    @Published private(set) var tasks: [ReplicatedTask] = []
    @Published private(set) var invitationPhrase: String?
    @Published private(set) var invitationURL: URL?
    @Published private(set) var invitationExpiresAt: Date?
    @Published private(set) var safetyCode: String?
    @Published private(set) var lastRoundTripMilliseconds: Double?
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isPaired = false
    @Published private(set) var isHostApprovalPending = false
    @Published private(set) var localEditErrorMessage: String?
    @Published private(set) var mailboxState: MailboxSyncState = .idle
    @Published private(set) var pendingMailboxOperationCount = 0
    @Published private(set) var lastMailboxStoredAt: Date?
    @Published private(set) var lastMailboxReceivedAt: Date?
    @Published private(set) var mailboxErrorMessage: String?
    @Published private(set) var mailboxRequiresRepair = false
    @Published private(set) var mailboxCapacityReached = false
    @Published private(set) var isPairingFinalizationLocked = false
    @Published private(set) var hasPairingReplicaConflict = false

    let relayURL: URL
    let mailboxURL: URL

    private let credentialStore: CredentialStore
    private let mailboxTransport: any MailboxTransport
    private let deviceID: ReplicaDeviceID
    private let persistenceURL: URL
    private let pairingArtifactsDirectory: URL
    private var pairingArtifactID: Data?
    private let hasDurableIdentity: Bool
    private var hasDurableStorage: Bool
    private var replica: TaskReplica
    private var credentials: PairCredentials?
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
    private var mailboxCycleRequested = false
    private var mailboxFailureCount = 0
    private var nextMailboxAttemptAt = Date.distantPast
    private var backgroundTaskIdentifier = UIBackgroundTaskIdentifier.invalid
    private var appIsActive = true
    private var terminalPairingActions: [TerminalPairingAction] = []
    private var terminalPairingJournalUsable = true
    private let pairingRetryDelayNanoseconds: UInt64

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

    init(
        keychain: KeychainStore = KeychainStore(),
        baseDirectory: URL? = nil,
        relayURL: URL = SyncProtocol.defaultRelayURL,
        mailboxURL: URL = SyncProtocol.defaultMailboxURL,
        mailboxTransport: (any MailboxTransport)? = nil,
        pairingRetryDelayNanoseconds: UInt64 = 1_000_000_000
    ) {
        self.relayURL = relayURL
        self.mailboxURL = mailboxURL
        self.mailboxTransport = mailboxTransport
            ?? HTTPMailboxTransport(baseURL: mailboxURL)
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
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("GotDoneRelay", isDirectory: true)
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
                    attributes: [.protectionKey: FileProtectionType.complete]
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
                            bootError ?? SyncAppError.legacyPairingNeedsRelink
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
                                checkpoint.pairID == credentials.pairID,
                                checkpoint.uploadedLocalSequence
                                    <= replica.versionVector[deviceID]
                            else {
                                throw SyncAppError.invalidCredentials
                            }
                            uploadedLocalSequence =
                                checkpoint.uploadedLocalSequence
                        }
                    } catch {
                        uploadedLocalSequence = 0
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
                    bootError ?? SyncAppError.pairingRecoveryJournalDamaged
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
    }

    var syncNotice: SyncNotice? {
        if phase == .failed || mailboxRequiresRepair {
            return SyncNotice(
                kind: .repair,
                title: "Sync needs repair",
                detail: "Your tasks are safe on this iPhone. Keep them here while replacing the private link."
            )
        }
        if mailboxState == .unavailable {
            if mailboxCapacityReached {
                return SyncNotice(
                    kind: .retrying,
                    title: "Encrypted mailbox storage limit reached",
                    detail: "Changes are saved on this iPhone. Got Done will retry while the app is open and encrypted mailbox storage is unavailable."
                )
            }
            return SyncNotice(
                kind: .retrying,
                title: "Sync temporarily unavailable — retrying",
                detail: pendingMailboxOperationCount > 0
                    ? "Changes are saved on this iPhone. Keep Got Done open while secure upload retries."
                    : "Changes remain safe on this iPhone. Got Done will retry while the app is open."
            )
        }
        if pendingMailboxOperationCount > 0 {
            return SyncNotice(
                kind: .saving,
                title: "Saving securely…",
                detail: "Changes are saved on this iPhone. Keep Got Done open until secure upload finishes."
            )
        }
        return nil
    }

    var pairingRecoveryResetRequired: Bool {
        !terminalPairingJournalUsable
            || terminalPairingActions.count
                >= TerminalPairingActionJournal.maximumActionCount
    }

    var hasLocalReplicaHistory: Bool {
        !replica.isEmpty
    }

    var canJoinExistingSync: Bool {
        hasDurableIdentity
            && hasDurableStorage
            && !isPaired
            && !isPairingFinalizationLocked
            && pairingTask == nil
    }

    var canEditLocalTasks: Bool {
        hasDurableStorage && !isPairingFinalizationLocked
    }

    var canCancelPairing: Bool {
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

    var finalizationAnnouncement: String? {
        guard isPairingFinalizationLocked else {
            return nil
        }
        return "\(statusTitle). \(statusDetail)"
    }

    var statusTitle: String {
        if isPaired, phase != .failed {
            if pendingMailboxOperationCount > 0 {
                return phase == .synced
                    ? "Live · saving offline copy"
                    : "Saving encrypted changes"
            }
            if mailboxState == .unavailable {
                return phase == .synced
                    ? "Live · offline delivery unavailable"
                    : "Sync temporarily unavailable"
            }
        }
        if isPaired, phase != .synced, phase != .failed {
            switch mailboxState {
            case .syncing:
                return "Checking for changes"
            case .available:
                return lastMailboxStoredAt == nil
                    ? "Async sync ready"
                    : "Saved for offline delivery"
            case .unavailable:
                return "Sync temporarily unavailable"
            case .idle:
                break
            }
        }
        return switch phase {
        case .unpaired:
            "Not paired"
        case .waitingForPeer:
            "Waiting for the other iPhone"
        case .verifying:
            "Verify both devices"
        case .provisioning:
            "Creating the private link"
        case .finalizing:
            if hasPairingReplicaConflict {
                "Choose how to recover"
            } else {
                switch pendingPairForRecovery?.finalizationState {
                case .waitingForProvision:
                    "Waiting for the main iPhone"
                case .provisionMayHaveBeenStored:
                    "Sharing the encrypted archive"
                case .provisionStagedAwaitingMergeApproval:
                    "Choose how to combine tasks"
                case .readyMayHaveBeenStored:
                    "Confirming the imported archive"
                case .abortMayHaveBeenStored:
                    "Cancelling pairing"
                case .abortAcknowledgementMayHaveBeenStored:
                    "Confirming cancellation"
                case .commitMarkerMayHaveBeenStored, nil:
                    "Finishing the private link"
                }
            }
        case .connecting:
            "Connecting"
        case .reconciling:
            "Catching up"
        case .synced:
            "Synced live"
        case .offline:
            "Sync temporarily unavailable"
        case .failed:
            "Needs attention"
        }
    }

    var statusDetail: String {
        if isPaired, phase != .failed {
            if pendingMailboxOperationCount > 0 {
                return phase == .synced
                    ? "Live sync is active; saving ciphertext before this app can safely close."
                    : pendingMailboxOperationCount == 1
                        ? "Encrypting and saving one change for the other iPhone."
                        : "Encrypting and saving \(pendingMailboxOperationCount) changes for the other iPhone."
            }
            if mailboxState == .unavailable {
                return phase == .synced
                    ? "Live sync works, but offline delivery is unavailable. Keep this app open until it returns."
                    : "Local edits are safe here and upload when this app next opens and reconnects."
            }
        }
        if isPaired, phase != .synced, phase != .failed {
            switch mailboxState {
            case .syncing:
                return "Checking the private mailbox for encrypted changes."
            case .available:
                return lastMailboxStoredAt == nil
                    ? "This iPhone checks for encrypted changes even when its peer is offline."
                    : "Stored ciphertext is no longer served after the other iPhone durably applies it."
            case .unavailable:
                break
            case .idle:
                break
            }
        }
        return switch phase {
        case .unpaired:
            "No account, cloud database, or tracking identifier."
        case .waitingForPeer:
            "Keep this screen open while the second device joins."
        case .verifying:
            isHostApprovalPending
                ? "Confirm that the same six digits appear on both devices."
                : "The main device must approve the matching code."
        case .provisioning:
            "The initial task archive is encrypted end to end."
        case .finalizing:
            if let errorMessage {
                errorMessage
            } else {
                switch pendingPairForRecovery?.finalizationState {
                case .waitingForProvision:
                    "The secure handshake is saved. Waiting for the main iPhone to approve or decline."
                case .provisionMayHaveBeenStored:
                    "The approval is saved. Got Done is making the encrypted task archive available to the other iPhone."
                case .provisionStagedAwaitingMergeApproval:
                    "The encrypted archive is staged, but nothing will be linked until the complete combined copy is safe."
                case .readyMayHaveBeenStored:
                    "The imported copy is safe. Waiting for the main iPhone’s encrypted confirmation."
                case .abortMayHaveBeenStored:
                    "No link will be created. Got Done is securely notifying the other iPhone."
                case .abortAcknowledgementMayHaveBeenStored:
                    "No link will be created. The other iPhone’s cancellation is safely acknowledged."
                case .commitMarkerMayHaveBeenStored, nil:
                    "The private decision is saved. Got Done safely resumes this step after a restart or lost connection."
                }
            }
        case .connecting:
            "Looking for the paired device through the relay."
        case .reconciling:
            "Exchanging version vectors and missing operations."
        case .synced:
            "Changes travel live and are also protected for offline delivery."
        case .offline:
            mailboxErrorMessage
                ?? "Local edits are safe here and upload when this app next opens and reconnects."
        case .failed:
            errorMessage ?? "Sync could not continue."
        }
    }

    func createPrivateSync() {
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
            try validateProvisioningArchiveSize()
            let invitation = try Invitation.generate()
            invitationPhrase = invitation.phrase
            invitationURL = invitation.url
            invitationExpiresAt = Date().addingTimeInterval(120)
            safetyCode = nil
            errorMessage = nil
            phase = .waitingForPeer
            let attemptID = UUID()
            pairingAttemptID = attemptID
            pairingTask = Task { [weak self] in
                await self?.runHostPairing(invitation, attemptID: attemptID)
            }
            pairingExpiryTask = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: 120_000_000_000)
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
                    self.fail(SyncAppError.invitationExpired)
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

    func joinPrivateSync(phrase: String) {
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

    func joinPrivateSync(url: URL) {
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
            let invitation = try Invitation.from(url: url)
            beginJoin(with: invitation)
        } catch {
            fail(error)
        }
    }

    func approveSafetyCode() {
        guard isHostApprovalPending else {
            return
        }
        isHostApprovalPending = false
        approvalContinuation?.resume(returning: true)
        approvalContinuation = nil
    }

    func rejectSafetyCode() {
        guard
            safetyCode != nil,
            !isPaired
        else {
            return
        }
        if isHostApprovalPending {
            isHostApprovalPending = false
            approvalContinuation?.resume(returning: false)
            approvalContinuation = nil
            return
        }
        cancelPairing()
    }

    func regenerateInvitation() {
        guard
            invitationPhrase != nil,
            !isPaired,
            !isPairingFinalizationLocked
        else {
            return
        }
        cancelPairing()
        createPrivateSync()
    }

    func cancelPairing() {
        guard !isPaired else {
            return
        }
        if isPairingFinalizationLocked {
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
        do {
            try rollbackPendingPairing()
            errorMessage = nil
            phase = .unpaired
        } catch {
            hasDurableStorage = false
            fail(error)
        }
    }

    func resolvePairingReplicaConflictKeepingBoth() {
        guard
            isPairingFinalizationLocked,
            hasPairingReplicaConflict,
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
                ? SyncAppError.pairingMergeTooLarge
                : error
            errorMessage =
                "\(Self.displayMessage(for: displayError)) You can cancel pairing and keep this iPhone unchanged."
            return
        }
        hasPairingReplicaConflict = false
        errorMessage = nil
        startPendingPairingFinalization()
    }

    @discardableResult
    func addTask(title: String) -> Bool {
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

    func clearLocalEditError() {
        localEditErrorMessage = nil
    }

    func toggleTask(_ task: ReplicatedTask) {
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

    func deleteTasks(at offsets: IndexSet) {
        deleteTasks(
            ids: offsets.compactMap {
                tasks.indices.contains($0) ? tasks[$0].id : nil
            }
        )
    }

    func deleteTasks(ids: [UUID]) {
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

    func eraseLocalProofOfConcept() {
        guard hasDurableIdentity else {
            return
        }
        let mailboxToForget = credentials.flatMap {
            try? PairMailbox(credentials: $0)
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
        endBackgroundFlush()

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
        hasDurableStorage = false

        if let mailboxToForget {
            let transport = mailboxTransport
            Task {
                await mailboxCycleToFinish?.value
                try? await transport.forget(
                    route: mailboxToForget.outbound.route,
                    authorization: mailboxToForget.outbound.authorization
                )
                try? await transport.forget(
                    route: mailboxToForget.inbound.route,
                    authorization: mailboxToForget.inbound.authorization
                )
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
            mailboxRequiresRepair = false
            mailboxCapacityReached = false
            localEditErrorMessage = nil
            mailboxState = .idle
            pendingMailboxOperationCount = 0
            phase = .unpaired
        } catch {
            fail(error)
        }
    }

    func unlinkAndKeepTasks() {
        let resetsPairingRecovery = pairingRecoveryResetRequired
        guard
            hasDurableIdentity,
            isPaired || resetsPairingRecovery,
            !isPairingFinalizationLocked
        else {
            return
        }
        let mailboxToForget = credentials.flatMap {
            try? PairMailbox(credentials: $0)
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
        endBackgroundFlush()

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
        if resetsPairingRecovery {
            terminalPairingActions = []
            terminalPairingJournalUsable = true
        }

        if let mailboxToForget {
            let transport = mailboxTransport
            Task {
                await mailboxCycleToFinish?.value
                try? await transport.forget(
                    route: mailboxToForget.outbound.route,
                    authorization: mailboxToForget.outbound.authorization
                )
                try? await transport.forget(
                    route: mailboxToForget.inbound.route,
                    authorization: mailboxToForget.inbound.authorization
                )
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
        mailboxRequiresRepair = false
        mailboxCapacityReached = false
        localEditErrorMessage = nil
        mailboxState = .idle
        pendingMailboxOperationCount = 0
        phase = .unpaired
        if !resetsPairingRecovery {
            startTerminalPairingLoop()
        }
    }

    func applicationDidBecomeActive() {
        appIsActive = true
        backgroundFlushTask?.cancel()
        backgroundFlushTask = nil
        endBackgroundFlush()
        if isPairingFinalizationLocked {
            startPendingPairingFinalization()
        } else if isPaired {
            startSyncLoop()
            startMailboxLoop()
        }
        startTerminalPairingLoop()
    }

    func applicationDidEnterBackground() {
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
            startBackgroundMailboxFlush()
        }
    }

    #if DEBUG
    func confirmAuthenticatedPeerCompletionForTesting() {
        guard let credentials else {
            return
        }
        confirmAuthenticatedPeerCompletion(credentials)
    }

    func stopRuntimeForTesting() async {
        appIsActive = false
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
        endBackgroundFlush()
    }
    #endif

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
        let socket = RelaySocket(url: relayURL)
        pairingSocket = socket
        do {
            try await socket.connect(route: invitation.pairRoute)
            try await waitForPeer(on: socket)
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
            try await socket.send(handshake.hello)
            let response = try await nextBinary(on: socket)
            try requireCurrentPairingAttempt(attemptID)
            let result = try handshake.receive(response)
            try await socket.send(result.confirm)

            let pairRoot = try requirePairRoot(result.material)
            let pairID = try requirePairID(result.material)
            safetyCode = result.material.safetyCode
            isHostApprovalPending = true
            phase = .verifying
            let approved = await waitForApproval()
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
                    expiresAt: Date().addingTimeInterval(120),
                    finalizationState: .abortMayHaveBeenStored,
                    pairingArtifactID: pairID
                )
                try credentialStore.savePending(pending)
                beginPairingFinalization(pending)
                await socket.cancel()
                pairingSocket = nil
                await runPairingFinalization(
                    pending,
                    attemptID: attemptID
                )
                return
            }

            let archive = try replica.exportProvisioningArchive()
            guard archive.count <= ProtocolLimits.provisioningArchiveBytes else {
                throw SyncAppError.archiveTooLarge
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
                expiresAt: Date().addingTimeInterval(120),
                finalizationState: .provisionMayHaveBeenStored,
                pairingArtifactID: pairID
            )
            try credentialStore.savePending(pending)
            try requireCurrentPairingAttempt(attemptID)
            beginPairingFinalization(pending)
            await socket.cancel()
            pairingSocket = nil
            await runPairingFinalization(
                pending,
                attemptID: attemptID
            )
        } catch is CancellationError {
            await socket.cancel()
        } catch {
            await socket.cancel()
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
        let socket = RelaySocket(url: relayURL)
        pairingSocket = socket
        do {
            try await socket.connect(route: invitation.pairRoute)
            try await waitForPeer(on: socket)
            try requireCurrentPairingAttempt(attemptID)

            let context = HandshakeContext.pairing(
                relayOrigin: try relayOrigin(),
                route: invitation.pairRoute
            )
            let hello = try await nextBinary(on: socket)
            try requireCurrentPairingAttempt(attemptID)
            let response = try ResponderHandshake.respond(
                to: hello,
                context: context,
                psk: invitation.pairPSK
            )
            try await socket.send(response.response)
            let confirmation = try await nextBinary(on: socket)
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
                expiresAt: Date().addingTimeInterval(120),
                finalizationState: .waitingForProvision,
                pairingArtifactID: pairID
            )
            try credentialStore.savePending(pending)
            try requireCurrentPairingAttempt(attemptID)
            beginPairingFinalization(
                pending,
                preserveSafetyCode: true
            )
            await socket.cancel()
            pairingSocket = nil
            await runPairingFinalization(
                pending,
                attemptID: attemptID
            )
        } catch is CancellationError {
            await socket.cancel()
        } catch {
            await socket.cancel()
            guard !Task.isCancelled else {
                return
            }
            pairingFailed(error, attemptID: attemptID)
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
            credentials == nil,
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
                "\(Self.displayMessage(for: error)) Got Done has not cancelled pairing."
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
                    hasPairingReplicaConflict = true
                    errorMessage = Self.displayMessage(for: error)
                    phase = .finalizing
                    return
                }
                failureCount += 1
                errorMessage =
                    "\(Self.displayMessage(for: error)) Got Done will retry this saved step."
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
            throw SyncAppError.invalidCredentials
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
                throw SyncAppError.pairingReplicaConflict
            }
            let provisionMailbox = try PairingProvisionMailbox(
                pairRoot: pending.pairRoot,
                pairID: pending.pairID
            )
            let envelopes = try provisionMailbox.seal(
                archive: archive,
                hostDeviceID: deviceID.bytes
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
                throw SyncAppError.invalidPairMessage
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
            throw SyncAppError.invalidCredentials
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

        let resolvedCredentials = try pairingCredentials(for: pending)
        if let credentials {
            guard credentials == resolvedCredentials else {
                throw SyncAppError.invalidCredentials
            }
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
            throw SyncAppError.invalidCredentials
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
                throw SyncAppError.invalidPairMessage
            }
            let imported = try ReplicaProvisioningArchive.decodeCanonical(
                from: provision.payload.archive
            )
            guard imported.sourceDeviceID.bytes
                    == provision.payload.hostDeviceID
            else {
                throw SyncAppError.invalidPairMessage
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
                    throw SyncAppError.invalidPairMessage
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
                throw SyncAppError.pairingReplicaConflict
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
            throw SyncAppError.pairingReplicaConflict
        case .readyMayHaveBeenStored:
            _ = try validatedPreparedJoinerReplica(pending)
            guard let hostDeviceID = pending.remoteDeviceID else {
                throw SyncAppError.invalidCredentials
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
            throw SyncAppError.invalidCredentials
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
        let resolvedCredentials = try pairingCredentials(for: pending)
        var markerCursor: UInt64?

        if let credentials {
            guard credentials == resolvedCredentials else {
                throw SyncAppError.invalidCredentials
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
            throw SyncAppError.invalidCredentials
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
            throw SyncAppError.invalidCredentials
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
                throw SyncAppError.invalidPairMessage
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
                throw SyncAppError.invalidPairMessage
            }
            senderDeviceID = record.senderDeviceID
        }
        guard let senderDeviceID else {
            throw SyncAppError.invalidPairMessage
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
                throw SyncAppError.invalidPairMessage
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
            throw SyncAppError.invalidCredentials
        }
        let mailbox = try PairingAbortMailbox(
            pairRoot: pending.pairRoot,
            pairID: pending.pairID,
            senderRole: pending.role.opposite
        )
        guard let senderDeviceID = pending.remoteDeviceID else {
            throw SyncAppError.invalidCredentials
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
            throw SyncAppError.invalidPairMessage
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
        phase = .unpaired
        startTerminalPairingLoop()
    }

    private func installOrValidateStagedJoinerReplica(
        _ pending: PendingPair
    ) throws {
        guard pending.role == .joiner else {
            throw SyncAppError.invalidCredentials
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
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: persistenceURL.path
        )
        try validateInstalledJoinerReplica(pending)
    }

    private func validateInstalledJoinerReplica(
        _ pending: PendingPair
    ) throws {
        guard pending.role == .joiner else {
            throw SyncAppError.invalidCredentials
        }
        let prepared = try validatedPreparedJoinerReplica(pending)
        let installed = try TaskReplica(
            deviceID: deviceID,
            persistenceURL: persistenceURL
        )
        guard try installed.containsHistory(from: prepared) else {
            throw SyncAppError.invalidPairMessage
        }
        replica = installed
        publishReplica()
    }

    private func validatedStagedJoinerReplica(
        _ pending: PendingPair
    ) throws -> TaskReplica {
        guard FileManager.default.fileExists(atPath: pairingStagingURL.path) else {
            throw SyncAppError.localStorageUnavailable
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
            throw SyncAppError.invalidPairMessage
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
            [.protectionKey: FileProtectionType.complete],
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
                throw SyncAppError.localStorageUnavailable
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
                throw SyncAppError.invalidPairMessage
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
            throw SyncAppError.pairingReplicaConflict
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
        _ credentials: PairCredentials,
        attemptID: UUID
    ) {
        guard isCurrentPairingAttempt(attemptID) else {
            return
        }
        self.credentials = credentials
        isPaired = true
        isPairingFinalizationLocked = false
        hasPairingReplicaConflict = false
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
        errorMessage = nil
        uploadedLocalSequence = 0
        mailboxFailureCount = 0
        nextMailboxAttemptAt = .distantPast
        refreshPendingMailboxCount()
        phase = .connecting
        startSyncLoop()
        startMailboxLoop()
        startTerminalPairingLoop()
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
                hasPairingReplicaConflict = true
                errorMessage = Self.displayMessage(for: error)
                return
            }
            errorMessage =
                "\(Self.displayMessage(for: error)) Got Done will retry this saved step."
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
            errorMessage = Self.displayMessage(for: error)
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
        _ credentials: PairCredentials
    ) {
        guard
            self.credentials == credentials,
            credentials.role == .joiner,
            let action = terminalPairingActions.first(where: {
                $0.kind == .receipt
                    && $0.pairID == credentials.pairID
                    && $0.role == credentials.role
                    && $0.localDeviceID == credentials.localDeviceID
                    && $0.remoteDeviceID == credentials.remoteDeviceID
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
        credentials: PairCredentials,
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
        credentials: PairCredentials
    ) async throws {
        guard hasDurableStorage else {
            throw SyncAppError.localStorageUnavailable
        }
        try validate(credentials)
        let mailbox = try PairMailbox(credentials: credentials)
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
    }

    private func runMailboxUpload(
        _ mailbox: PairMailbox,
        credentials: PairCredentials,
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
        _ mailbox: PairMailbox,
        credentials: PairCredentials,
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
        _ mailbox: PairMailbox,
        credentials: PairCredentials
    ) async throws {
        while !Task.isCancelled {
            let localSequence = replica.versionVector[deviceID]
            guard uploadedLocalSequence <= localSequence else {
                throw SyncAppError.invalidCredentials
            }
            let pending = replica.retainedOperations
                .filter {
                    $0.originDeviceID == deviceID
                        && $0.originSequence > uploadedLocalSequence
                }
                .sorted {
                    $0.originSequence < $1.originSequence
                }
            guard !pending.isEmpty else {
                refreshPendingMailboxCount()
                return
            }
            guard pending[0].originSequence == uploadedLocalSequence + 1 else {
                throw ReplicaError.sequenceGap(
                    origin: deviceID,
                    expected: uploadedLocalSequence + 1,
                    received: pending[0].originSequence
                )
            }

            let operations = Array(
                pending.prefix(ProtocolLimits.mailboxBatchCount)
            )
            for (offset, operation) in operations.enumerated() {
                guard
                    operation.originSequence
                        == uploadedLocalSequence + UInt64(offset) + 1
                else {
                    throw ReplicaError.sequenceGap(
                        origin: deviceID,
                        expected: uploadedLocalSequence + UInt64(offset) + 1,
                        received: operation.originSequence
                    )
                }
            }
            let envelopes = try operations.map(mailbox.seal)
            _ = try await mailboxTransport.put(
                route: mailbox.outbound.route,
                authorization: mailbox.outbound.authorization,
                messages: envelopes
            )

            try Task.checkCancellation()
            guard
                self.credentials == credentials,
                let lastSequence = operations.last?.originSequence
            else {
                throw CancellationError()
            }
            let checkpoint = MailboxCheckpoint(
                pairID: credentials.pairID,
                uploadedLocalSequence: lastSequence
            )
            try credentialStore.saveMailboxCheckpoint(checkpoint)
            uploadedLocalSequence = lastSequence
            lastMailboxStoredAt = Date()
            refreshPendingMailboxCount()
        }
        throw CancellationError()
    }

    private func receiveMailboxOperations(
        _ mailbox: PairMailbox,
        credentials: PairCredentials
    ) async throws {
        var afterCursor: UInt64 = 0
        while !Task.isCancelled {
            let page = try await mailboxTransport.fetch(
                route: mailbox.inbound.route,
                authorization: mailbox.inbound.authorization,
                after: afterCursor,
                limit: ProtocolLimits.mailboxFetchCount
            )
            try Task.checkCancellation()
            guard self.credentials == credentials else {
                throw CancellationError()
            }
            guard !page.messages.isEmpty else {
                return
            }

            let operations = try page.messages.map {
                try mailbox.open($0.envelope)
            }
            let accepted = try replica.applyRemote(operations)
            publishReplica()
            if accepted > 0 {
                lastMailboxReceivedAt = Date()
                lastSyncedAt = Date()
            }
            try await mailboxTransport.acknowledge(
                route: mailbox.inbound.route,
                authorization: mailbox.inbound.authorization,
                through: page.nextCursor
            )

            guard page.hasMore else {
                return
            }
            afterCursor = page.nextCursor
        }
        throw CancellationError()
    }

    private func startBackgroundMailboxFlush() {
        guard credentials != nil, hasDurableStorage else {
            return
        }
        endBackgroundFlush()
        backgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(
            withName: "Encrypted mailbox flush"
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.mailboxCycleTask?.cancel()
                self?.backgroundFlushTask?.cancel()
                self?.endBackgroundFlush()
            }
        }
        requestMailboxCycle(force: true, allowInactive: true)
        guard let cycleTask = mailboxCycleTask else {
            endBackgroundFlush()
            return
        }
        backgroundFlushTask = Task { [weak self] in
            await cycleTask.value
            guard !Task.isCancelled else {
                return
            }
            self?.endBackgroundFlush()
            self?.backgroundFlushTask = nil
        }
    }

    private func endBackgroundFlush() {
        guard backgroundTaskIdentifier != .invalid else {
            return
        }
        let identifier = backgroundTaskIdentifier
        backgroundTaskIdentifier = .invalid
        UIApplication.shared.endBackgroundTask(identifier)
    }

    private func maintainSync(_ credentials: PairCredentials) async {
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

    private func runSyncConnection(_ credentials: PairCredentials) async throws {
        guard hasDurableStorage else {
            throw SyncAppError.localStorageUnavailable
        }
        try validate(credentials)
        phase = .connecting
        errorMessage = nil

        let route = SyncKeyDerivation.syncRoute(pairRoot: credentials.pairRoot)
        let psk = SyncKeyDerivation.syncPSK(pairRoot: credentials.pairRoot)
        let socket = RelaySocket(url: relayURL)
        activeSocket = socket
        try await socket.connect(route: route)
        try await waitForPeer(on: socket)

        let hostDeviceID = credentials.role == .host
            ? credentials.localDeviceID
            : credentials.remoteDeviceID
        let joinerDeviceID = credentials.role == .joiner
            ? credentials.localDeviceID
            : credentials.remoteDeviceID
        let context = HandshakeContext.sync(
            relayOrigin: try relayOrigin(),
            route: route,
            pairID: credentials.pairID,
            roleADeviceID: hostDeviceID,
            roleBDeviceID: joinerDeviceID
        )

        let material: HandshakeMaterial
        if credentials.role == .host {
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
            role: credentials.role
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
                throw SyncAppError.relay(code)
            }
        }
    }

    private func handleSync(
        _ message: SyncWireMessage,
        credentials: PairCredentials,
        socket: RelaySocket
    ) async throws {
        guard hasDurableStorage else {
            throw SyncAppError.localStorageUnavailable
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
                throw SyncAppError.invalidSyncMessage
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
                throw SyncAppError.invalidSyncMessage
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
                throw SyncAppError.invalidSyncMessage
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
                throw SyncAppError.invalidSyncMessage
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
                throw SyncAppError.invalidSyncMessage
            }
            let duration = ContinuousClock.now - started
            let components = duration.components
            lastRoundTripMilliseconds =
                Double(components.seconds) * 1_000
                + Double(components.attoseconds) / 1_000_000_000_000_000
        }
    }

    private func requireActiveSync(
        credentials: PairCredentials,
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
            throw SyncAppError.localStorageUnavailable
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
                throw SyncAppError.relay(code)
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
                throw RelaySocketError.peerLeft
            case .error(let code):
                throw SyncAppError.relay(code)
            case .peerReady:
                throw RelaySocketError.unexpectedControl
            }
        }
        throw CancellationError()
    }

    private func waitForApproval() async -> Bool {
        await withCheckedContinuation { continuation in
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
            throw SyncAppError.invalidPairMessage
        }
        return pairRoot
    }

    private func requirePairID(_ material: HandshakeMaterial) throws -> Data {
        guard let pairID = material.pairID, pairID.count == 16 else {
            throw SyncAppError.invalidPairMessage
        }
        return pairID
    }

    private func validate(_ credentials: PairCredentials) throws {
        guard
            credentials.version == SyncProtocol.version,
            credentials.pairRoot.count == 32,
            credentials.pairID.count == 16,
            credentials.localDeviceID == deviceID.bytes,
            credentials.remoteDeviceID.count == 16,
            credentials.remoteDeviceID != credentials.localDeviceID,
            credentials.pairingArchiveHash == nil
                || (
                    credentials.role == .joiner
                        && credentials.pairingArchiveHash?.count == 32
                )
        else {
            throw SyncAppError.invalidCredentials
        }
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
            throw SyncAppError.invalidCredentials
        }
        if let pairingArtifactID = pending.pairingArtifactID {
            guard
                pairingArtifactID.count == 16,
                pairingArtifactID == pending.pairID
            else {
                throw SyncAppError.invalidCredentials
            }
        }
        if let remoteDeviceID = pending.remoteDeviceID {
            guard
                remoteDeviceID.count == 16,
                remoteDeviceID != pending.localDeviceID
            else {
                throw SyncAppError.invalidCredentials
            }
        }
        if pending.finalizationState
            != .abortAcknowledgementMayHaveBeenStored,
           pending.abortAcknowledgementCursor != nil
        {
            throw SyncAppError.invalidCredentials
        }
        switch pending.finalizationState {
        case .waitingForProvision:
            guard
                pending.role == .joiner,
                pending.remoteDeviceID == nil,
                pending.archiveHash.isEmpty
            else {
                throw SyncAppError.invalidCredentials
            }
        case .provisionMayHaveBeenStored:
            guard
                pending.role == .host,
                pending.remoteDeviceID == nil,
                pending.archiveHash.count == 32
            else {
                throw SyncAppError.invalidCredentials
            }
        case .provisionStagedAwaitingMergeApproval:
            guard
                pending.role == .joiner,
                pending.remoteDeviceID != nil,
                pending.archiveHash.count == 32
            else {
                throw SyncAppError.invalidCredentials
            }
        case .readyMayHaveBeenStored:
            guard
                pending.role == .joiner,
                pending.remoteDeviceID != nil,
                pending.archiveHash.count == 32
            else {
                throw SyncAppError.invalidCredentials
            }
        case .commitMarkerMayHaveBeenStored:
            guard
                pending.role == .host,
                pending.remoteDeviceID != nil,
                pending.archiveHash.count == 32
            else {
                throw SyncAppError.invalidCredentials
            }
        case .abortMayHaveBeenStored:
            guard
                pending.remoteDeviceID == nil,
                pending.archiveHash.isEmpty
            else {
                throw SyncAppError.invalidCredentials
            }
        case .abortAcknowledgementMayHaveBeenStored:
            guard
                let cursor = pending.abortAcknowledgementCursor,
                cursor > 0,
                pending.remoteDeviceID != nil
            else {
                throw SyncAppError.invalidCredentials
            }
            switch pending.role {
            case .host:
                guard pending.archiveHash.count == 32 else {
                    throw SyncAppError.invalidCredentials
                }
            case .joiner:
                let waitingShape = pending.archiveHash.isEmpty
                let readyShape = pending.archiveHash.count == 32
                guard waitingShape || readyShape else {
                    throw SyncAppError.invalidCredentials
                }
            }
        case nil:
            guard pending.archiveHash.count == 32 else {
                throw SyncAppError.invalidCredentials
            }
        }
    }

    private static func finalizingPending(
        _ pending: PendingPair,
        active: PairCredentials?,
        deviceID: ReplicaDeviceID
    ) throws -> PendingPair? {
        guard pending.pairingVersion == SyncProtocol.pairingVersion else {
            return nil
        }
        try validate(pending, deviceID: deviceID)
        var normalized = pending
        if let active {
            guard
                active.pairRoot == pending.pairRoot,
                active.pairID == pending.pairID,
                active.role == pending.role,
                active.localDeviceID == pending.localDeviceID,
                active.remoteDeviceID == pending.remoteDeviceID
            else {
                throw SyncAppError.invalidCredentials
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
            return
        }
        pendingMailboxOperationCount = Int(
            localSequence - uploadedLocalSequence
        )
    }

    private func validateProvisioningArchiveSize() throws {
        let archive = try replica.exportProvisioningArchive()
        guard archive.count <= ProtocolLimits.provisioningArchiveBytes else {
            throw SyncAppError.archiveTooLarge
        }
    }

    private func validateTerminalPairingCapacity() throws {
        guard terminalPairingJournalUsable else {
            throw SyncAppError.pairingRecoveryJournalDamaged
        }
        guard
            terminalPairingActions.count
                < TerminalPairingActionJournal.maximumActionCount
        else {
            throw SyncAppError.pairingRecoveryHistoryFull
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
        errorMessage = Self.displayMessage(for: error)
        phase = .failed
    }

    private static func isPairingReplicaConflict(_ error: Error) -> Bool {
        guard let syncError = error as? SyncAppError else {
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
    ) throws -> PairCredentials? {
        if let active = try store.active() {
            guard
                active.version == SyncProtocol.version,
                active.pairRoot.count == 32,
                active.pairID.count == 16,
                active.localDeviceID == deviceID.bytes,
                active.remoteDeviceID.count == 16,
                active.remoteDeviceID != active.localDeviceID,
                active.pairingArchiveHash == nil
                    || (
                        active.role == .joiner
                            && active.pairingArchiveHash?.count == 32
                    )
            else {
                throw SyncAppError.invalidCredentials
            }
            return active
        }
        return nil
    }

    private static func reconstructedReceiptAction(
        credentials: PairCredentials
    ) throws -> TerminalPairingAction? {
        guard
            credentials.role == .joiner,
            let archiveHash = credentials.pairingArchiveHash,
            archiveHash.count == 32
        else {
            return nil
        }
        let pending = PendingPair(
            version: SyncProtocol.version,
            pairRoot: credentials.pairRoot,
            pairID: credentials.pairID,
            role: .joiner,
            localDeviceID: credentials.localDeviceID,
            remoteDeviceID: credentials.remoteDeviceID,
            archiveHash: archiveHash,
            expiresAt: .distantFuture,
            finalizationState: .readyMayHaveBeenStored
        )
        let record = try PairingCommitRecord(
            pairID: credentials.pairID,
            hostDeviceID: credentials.remoteDeviceID,
            joinerDeviceID: credentials.localDeviceID,
            archiveHash: archiveHash
        )
        let mailbox = try PairingCommitMailbox(
            pairRoot: credentials.pairRoot,
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
            [.protectionKey: FileProtectionType.complete],
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
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription
        {
            return description
        }
        return "The connection ended unexpectedly."
    }

    private static func requiresMailboxRepair(_ error: Error) -> Bool {
        if error is URLError {
            return false
        }
        if let mailboxError = error as? MailboxTransportError {
            switch mailboxError {
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
            || error is SyncAppError
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

    func finish() {
        isFinished = true
    }
}

private enum PairingFinalizationRetry: Error {
    case waitingForPeerDecision
    case stateAdvanced
}
