import Combine
import Foundation

enum SyncPhase: Equatable, Sendable {
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

enum SyncAppError: Error, LocalizedError {
    case invalidPairMessage
    case invalidSyncMessage
    case invalidCredentials
    case relay(String)
    case pairingDeclined
    case invitationExpired
    case archiveTooLarge
    case localStorageUnavailable

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
        }
    }
}

@MainActor
final class SyncAppModel: ObservableObject {
    static let eraseMarkerFilename = "erase-v1.pending"

    @Published private(set) var phase: SyncPhase = .unpaired
    @Published private(set) var tasks: [ReplicatedTask] = []
    @Published private(set) var invitationPhrase: String?
    @Published private(set) var invitationURL: URL?
    @Published private(set) var safetyCode: String?
    @Published private(set) var lastRoundTripMilliseconds: Double?
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isPaired = false
    @Published private(set) var isHostApprovalPending = false
    @Published private(set) var localEditErrorMessage: String?

    let relayURL = SyncProtocol.defaultRelayURL

    private let credentialStore: CredentialStore
    private let deviceID: ReplicaDeviceID
    private let persistenceURL: URL
    private let hasDurableIdentity: Bool
    private var hasDurableStorage: Bool
    private var replica: TaskReplica
    private var credentials: PairCredentials?
    private var pairingAttemptID: UUID?
    private var pairingTask: Task<Void, Never>?
    private var pairingExpiryTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var outboundTask: Task<Void, Never>?
    private var outboundDrainID: UUID?
    private var pairingSocket: RelaySocket?
    private var activeSocket: RelaySocket?
    private var channelReady = false
    private var approvalContinuation: CheckedContinuation<Bool, Never>?
    private var pendingPings: [Data: ContinuousClock.Instant] = [:]
    private var deferredOperations: [TaskOperation] = []
    private var appIsActive = true

    init(
        keychain: KeychainStore = KeychainStore(),
        baseDirectory: URL? = nil
    ) {
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

        if hasDurableIdentity, hasDurableStorage {
            do {
                credentials = try Self.restoreActiveCredentials(
                    store: credentialStore,
                    deviceID: deviceID
                )
                if credentials == nil, let pending = try credentialStore.pending() {
                    if pending.role == .joiner {
                        if FileManager.default.fileExists(atPath: persistenceURL.path) {
                            try FileManager.default.removeItem(at: persistenceURL)
                        }
                        replica = try TaskReplica(
                            deviceID: deviceID,
                            persistenceURL: persistenceURL
                        )
                    }
                    try credentialStore.clearPending()
                }
            } catch {
                bootError = bootError ?? error
                credentials = nil
                hasDurableStorage = false
            }
        } else {
            credentials = nil
        }

        tasks = replica.tasks
        isPaired = credentials != nil
        phase = isPaired ? .connecting : .unpaired
        if let bootError {
            phase = .failed
            errorMessage = Self.displayMessage(for: bootError)
        }

        if credentials != nil {
            Task { [weak self] in
                self?.startSyncLoop()
            }
        }
    }

    var statusTitle: String {
        switch phase {
        case .unpaired:
            "Not paired"
        case .waitingForPeer:
            "Waiting for the other iPhone"
        case .verifying:
            "Verify both devices"
        case .provisioning:
            "Creating the private link"
        case .connecting:
            "Connecting"
        case .reconciling:
            "Catching up"
        case .synced:
            "Synced live"
        case .offline:
            "Waiting to reconnect"
        case .failed:
            "Needs attention"
        }
    }

    var statusDetail: String {
        switch phase {
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
        case .connecting:
            "Looking for the paired device through the relay."
        case .reconciling:
            "Exchanging version vectors and missing operations."
        case .synced:
            "Changes are sent immediately while both apps are open."
        case .offline:
            "Local edits are safe and will reconcile when both apps return."
        case .failed:
            errorMessage ?? "Sync could not continue."
        }
    }

    func createPrivateSync() {
        guard
            hasDurableIdentity,
            hasDurableStorage,
            !isPaired,
            pairingTask == nil
        else {
            return
        }
        do {
            try validateProvisioningArchiveSize()
            let invitation = try Invitation.generate()
            invitationPhrase = invitation.phrase
            invitationURL = invitation.url
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
            pairingTask == nil
        else {
            return
        }
        do {
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
            pairingTask == nil
        else {
            return
        }
        do {
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

    func cancelPairing() {
        guard !isPaired else {
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

    @discardableResult
    func addTask(title: String) -> Bool {
        guard hasDurableStorage else {
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
        guard hasDurableStorage else {
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
        guard hasDurableStorage else {
            return
        }
        for index in offsets.sorted(by: >) where tasks.indices.contains(index) {
            do {
                let operation = try replica.deleteTask(taskID: tasks[index].id)
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
        pairingTask?.cancel()
        pairingExpiryTask?.cancel()
        syncTask?.cancel()
        pingTask?.cancel()
        outboundTask?.cancel()
        pairingAttemptID = nil
        credentials = nil
        isPaired = false
        pairingTask = nil
        pairingExpiryTask = nil
        syncTask = nil
        pingTask = nil
        outboundTask = nil
        outboundDrainID = nil
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
        hasDurableStorage = false

        do {
            let markerURL = persistenceURL.deletingLastPathComponent()
                .appendingPathComponent(Self.eraseMarkerFilename)
            try Self.persistEraseMarker(at: markerURL)
            replica = try Self.completeErase(
                store: credentialStore,
                deviceID: deviceID,
                persistenceURL: persistenceURL,
                markerURL: markerURL
            )
            hasDurableStorage = true
            tasks = []
            invitationPhrase = nil
            invitationURL = nil
            safetyCode = nil
            lastRoundTripMilliseconds = nil
            lastSyncedAt = nil
            errorMessage = nil
            localEditErrorMessage = nil
            phase = .unpaired
        } catch {
            fail(error)
        }
    }

    func applicationDidBecomeActive() {
        appIsActive = true
        if isPaired {
            startSyncLoop()
        }
    }

    func applicationDidEnterBackground() {
        appIsActive = false
        syncTask?.cancel()
        pingTask?.cancel()
        outboundTask?.cancel()
        pingTask = nil
        outboundTask = nil
        outboundDrainID = nil
        if let activeSocket {
            Task { await activeSocket.cancel() }
        }
        activeSocket = nil
        channelReady = false
        if isPaired {
            phase = .offline
        }
    }

    private func beginJoin(with invitation: Invitation) {
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

            safetyCode = result.material.safetyCode
            isHostApprovalPending = true
            phase = .verifying
            let approved = await waitForApproval()
            try requireCurrentPairingAttempt(attemptID)
            guard approved else {
                throw SyncAppError.pairingDeclined
            }

            let pairRoot = try requirePairRoot(result.material)
            let pairID = try requirePairID(result.material)
            let archive = try replica.exportProvisioningArchive()
            guard archive.count <= ProtocolLimits.provisioningArchiveBytes else {
                throw SyncAppError.archiveTooLarge
            }
            let archiveHash = archive.sha256
            var pending = PendingPair(
                version: SyncProtocol.version,
                pairRoot: pairRoot,
                pairID: pairID,
                role: .host,
                localDeviceID: deviceID.bytes,
                remoteDeviceID: nil,
                archiveHash: archiveHash,
                expiresAt: Date().addingTimeInterval(120)
            )
            try credentialStore.savePending(pending)
            try requireCurrentPairingAttempt(attemptID)
            phase = .provisioning

            var secureSession = try result.material.makeSecureSession(role: .host)
            try await sendPair(
                .provision(
                    archive: archive,
                    archiveHash: archiveHash,
                    hostDeviceID: deviceID.bytes
                ),
                session: &secureSession,
                socket: socket
            )

            let ready = try await receivePair(session: &secureSession, socket: socket)
            try requireCurrentPairingAttempt(attemptID)
            guard
                ready.version == SyncProtocol.version,
                ready.kind == .ready,
                ready.archiveHash == archiveHash,
                ready.archive == nil,
                ready.hostDeviceID == nil,
                ready.pairID == nil,
                let remoteDeviceID = ready.joinerDeviceID,
                remoteDeviceID.count == 16,
                remoteDeviceID != deviceID.bytes
            else {
                throw SyncAppError.invalidPairMessage
            }

            pending.remoteDeviceID = remoteDeviceID
            try credentialStore.savePending(pending)
            try requireCurrentPairingAttempt(attemptID)
            let credentials = PairCredentials(
                pairRoot: pairRoot,
                pairID: pairID,
                role: .host,
                localDeviceID: deviceID.bytes,
                remoteDeviceID: remoteDeviceID
            )
            try credentialStore.saveActive(credentials)
            self.credentials = credentials
            isPaired = true
            try await sendPair(
                .commit(pairID: pairID),
                session: &secureSession,
                socket: socket
            )

            let receipt = try await receivePair(session: &secureSession, socket: socket)
            try requireCurrentPairingAttempt(attemptID)
            guard
                receipt.version == SyncProtocol.version,
                receipt.kind == .receipt,
                receipt.pairID == pairID,
                receipt.archive == nil,
                receipt.archiveHash == nil,
                receipt.hostDeviceID == nil,
                receipt.joinerDeviceID == nil
            else {
                throw SyncAppError.invalidPairMessage
            }
            try credentialStore.clearPending()
            await socket.cancel()
            finishPairing(credentials, attemptID: attemptID)
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
            var secureSession = try material.makeSecureSession(role: .joiner)

            safetyCode = material.safetyCode
            isHostApprovalPending = false
            phase = .verifying

            let provision = try await receivePair(
                session: &secureSession,
                socket: socket
            )
            try requireCurrentPairingAttempt(attemptID)
            guard
                provision.version == SyncProtocol.version,
                provision.kind == .provision,
                let archive = provision.archive,
                archive.count <= ProtocolLimits.provisioningArchiveBytes,
                let archiveHash = provision.archiveHash,
                archiveHash.count == 32,
                archive.sha256 == archiveHash,
                let hostDeviceData = provision.hostDeviceID,
                hostDeviceData.count == 16,
                hostDeviceData != deviceID.bytes,
                provision.joinerDeviceID == nil,
                provision.pairID == nil
            else {
                throw SyncAppError.invalidPairMessage
            }
            let imported = try ReplicaProvisioningArchive.decodeCanonical(from: archive)
            guard imported.sourceDeviceID.bytes == hostDeviceData else {
                throw SyncAppError.invalidPairMessage
            }

            let pairRoot = try requirePairRoot(material)
            let pairID = try requirePairID(material)
            let pending = PendingPair(
                version: SyncProtocol.version,
                pairRoot: pairRoot,
                pairID: pairID,
                role: .joiner,
                localDeviceID: deviceID.bytes,
                remoteDeviceID: hostDeviceData,
                archiveHash: archiveHash,
                expiresAt: Date().addingTimeInterval(120)
            )
            try credentialStore.savePending(pending)
            try requireCurrentPairingAttempt(attemptID)
            phase = .provisioning
            replica = try TaskReplica.provision(
                deviceID: deviceID,
                from: archive,
                persistenceURL: persistenceURL
            )
            publishReplica()

            try await sendPair(
                .ready(
                    archiveHash: archiveHash,
                    joinerDeviceID: deviceID.bytes
                ),
                session: &secureSession,
                socket: socket
            )
            let commit = try await receivePair(
                session: &secureSession,
                socket: socket
            )
            try requireCurrentPairingAttempt(attemptID)
            guard
                commit.version == SyncProtocol.version,
                commit.kind == .commit,
                commit.pairID == pairID,
                commit.archive == nil,
                commit.archiveHash == nil,
                commit.hostDeviceID == nil,
                commit.joinerDeviceID == nil
            else {
                throw SyncAppError.invalidPairMessage
            }

            let credentials = PairCredentials(
                pairRoot: pairRoot,
                pairID: pairID,
                role: .joiner,
                localDeviceID: deviceID.bytes,
                remoteDeviceID: hostDeviceData
            )
            try credentialStore.saveActive(credentials)
            self.credentials = credentials
            isPaired = true
            try credentialStore.clearPending()
            try await sendPair(
                .receipt(pairID: pairID),
                session: &secureSession,
                socket: socket
            )
            try requireCurrentPairingAttempt(attemptID)
            await socket.cancel()
            finishPairing(credentials, attemptID: attemptID)
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

    private func finishPairing(
        _ credentials: PairCredentials,
        attemptID: UUID
    ) {
        guard isCurrentPairingAttempt(attemptID) else {
            return
        }
        self.credentials = credentials
        isPaired = true
        pairingAttemptID = nil
        pairingTask = nil
        pairingExpiryTask?.cancel()
        pairingExpiryTask = nil
        pairingSocket = nil
        invitationPhrase = nil
        invitationURL = nil
        safetyCode = nil
        isHostApprovalPending = false
        phase = .connecting
        startSyncLoop()
    }

    private func pairingFailed(_ error: Error, attemptID: UUID) {
        guard pairingAttemptID == attemptID else {
            return
        }
        pairingAttemptID = nil
        pairingTask = nil
        pairingExpiryTask?.cancel()
        pairingExpiryTask = nil
        pairingSocket = nil
        invitationPhrase = nil
        invitationURL = nil
        isHostApprovalPending = false
        safetyCode = nil
        if isPaired {
            phase = .connecting
            startSyncLoop()
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
        channelReady = true
        deferredOperations = []
        phase = .reconciling
        try await sendSync(.hello(vector: replica.versionVector))
        startPingLoop(socket: socket)

        while !Task.isCancelled {
            let event = try await socket.receive()
            switch event {
            case .binary(let frame):
                guard channelReady else {
                    throw RelaySocketError.notConnected
                }
                let plaintext = try await socket.openEncrypted(frame)
                let message = try WireCodec.decode(
                    SyncWireMessage.self,
                    from: plaintext
                )
                try await handleSync(message)
            case .peerLeft:
                throw RelaySocketError.peerLeft
            case .peerReady:
                throw RelaySocketError.unexpectedControl
            case .error(let code):
                throw SyncAppError.relay(code)
            }
        }
    }

    private func handleSync(_ message: SyncWireMessage) async throws {
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
            _ = try replica.applyRemote(operations)
            publishReplica()
            try await sendSync(.acknowledgement(vector: replica.versionVector))
            if phase == .synced {
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
            if vector.isAtLeast(replica.versionVector) {
                phase = .synced
                lastSyncedAt = Date()
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

    private func sendPair(
        _ message: PairWireMessage,
        session: inout SecureSession,
        socket: RelaySocket
    ) async throws {
        let plaintext = try WireCodec.encode(message)
        try await socket.send(session.seal(plaintext))
    }

    private func receivePair(
        session: inout SecureSession,
        socket: RelaySocket
    ) async throws -> PairWireMessage {
        let frame = try await nextBinary(on: socket)
        let plaintext = try session.open(frame)
        return try WireCodec.decode(PairWireMessage.self, from: plaintext)
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
            credentials.remoteDeviceID != credentials.localDeviceID
        else {
            throw SyncAppError.invalidCredentials
        }
    }

    private func publishReplica() {
        tasks = replica.tasks
    }

    private func validateProvisioningArchiveSize() throws {
        let archive = try replica.exportProvisioningArchive()
        guard archive.count <= ProtocolLimits.provisioningArchiveBytes else {
            throw SyncAppError.archiveTooLarge
        }
    }

    private func rollbackPendingPairing() throws {
        guard credentials == nil, let pending = try credentialStore.pending() else {
            return
        }
        guard pending.role == .joiner else {
            try credentialStore.clearPending()
            return
        }
        if FileManager.default.fileExists(atPath: persistenceURL.path) {
            try FileManager.default.removeItem(at: persistenceURL)
        }
        replica = try TaskReplica(
            deviceID: deviceID,
            persistenceURL: persistenceURL
        )
        publishReplica()
        try credentialStore.clearPending()
    }

    private func fail(_ error: Error) {
        errorMessage = Self.displayMessage(for: error)
        phase = .failed
    }

    private func handleLocalMutationFailure(_ error: Error) {
        errorMessage = Self.displayMessage(for: error)
        localEditErrorMessage = errorMessage
        guard isPaired else {
            phase = .failed
            return
        }
        guard !(error is ReplicaError) else {
            return
        }
        hasDurableStorage = false
        channelReady = false
        phase = .failed
        syncTask?.cancel()
        pingTask?.cancel()
        outboundTask?.cancel()
        pingTask = nil
        outboundTask = nil
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
                active.remoteDeviceID != active.localDeviceID
            else {
                throw SyncAppError.invalidCredentials
            }
            try store.clearPending()
            return active
        }
        return nil
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

    private static func displayMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription
        {
            return description
        }
        return "The connection ended unexpectedly."
    }
}
