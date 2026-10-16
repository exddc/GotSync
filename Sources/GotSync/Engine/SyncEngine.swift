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
      "This link reached a storage limit. Keep your tasks and create a new link."
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
    error is URLError ? SyncError.privateSyncUnreachable : error
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
    let (stream, continuation) = AsyncStream<SyncState>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
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

  public let relayURL: URL
  public let mailboxURL: URL
  private let configuration: SyncConfiguration
  private let secretStore: any SecretStore
  private var deviceID: ReplicaDeviceID
  private var replica: TaskReplica
  private var driverTask: Task<WireMLS, Error>?
  private var loop: Task<Void, Never>?
  private var backgroundWork: Task<Void, Never>?
  private var action: Task<Void, Never>?
  private var storageAvailable = false
  private var members: [MLSMember] = []
  private var pending: MLSPairing?
  private var staged: TaskReplica?
  private var cycleActive = false
  private var cycleWaiters: [CheckedContinuation<Void, Never>] = []
  private var stagedInboxCount = 0
  private var snapshotBatches: [[TaskOperation]] = []
  private let backgroundMailboxScheduler: any BackgroundMailboxScheduling
  public private(set) var showsSavingNotice = false
  public private(set) var pairingFinalizationState: PairingFinalizationState?

  public init(
    configuration: SyncConfiguration, secretStore: any SecretStore,
    backgroundMailboxScheduler: (any BackgroundMailboxScheduling)? = nil,
    pairingRetryDelayNanoseconds: UInt64 = 1_000_000_000
  ) {
    self.configuration = configuration
    self.secretStore = secretStore
    self.relayURL = configuration.endpoints.relayURL
    self.mailboxURL = configuration.endpoints.mailboxURL
    self.backgroundMailboxScheduler = backgroundMailboxScheduler ?? NoopBackgroundMailboxScheduler()
    do {
      let identity = try InstallIdentity.loadOrCreate(store: secretStore)
      let id = try ReplicaDeviceID(bytes: identity.deviceID)
      deviceID = id
      replica = try TaskReplica(
        deviceID: id,
        persistenceURL: configuration.storageDirectory.appendingPathComponent("replica-v1.json"))
      var directory = configuration.storageDirectory
      var resources = URLResourceValues()
      resources.isExcludedFromBackup = true
      try directory.setResourceValues(resources)
      storageAvailable = true
    } catch {
      let id = ReplicaDeviceID(uuid: UUID())
      deviceID = id
      replica = try! TaskReplica(deviceID: id)
      errorMessage = SyncError.localStorageUnavailable.errorDescription
      phase = .failed
    }
    tasks = replica.tasks
    self.backgroundMailboxScheduler.register { [weak self] in
      await self?.performBackgroundMailboxFlushWork()
    }
    if storageAvailable {
      openDriver()
      startLoop()
    }
  }

  private func openDriver() {
    let directory = configuration.storageDirectory.appendingPathComponent(
      "wire-mls-v3", isDirectory: true)
    let relay = MLSRelay(
      url: mailboxURL.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("v3/mls"), policy: configuration.endpointPolicy)
    let store = secretStore
    let id = deviceID
    driverTask = Task {
      try await WireMLS.open(directory: directory, secretStore: store, deviceID: id, relay: relay)
    }
  }
  private func driver() async throws -> WireMLS {
    guard let driverTask else { throw SyncError.localStorageUnavailable }
    do { return try await driverTask.value } catch {
      self.driverTask = nil
      throw error
    }
  }
  private func startLoop() {
    guard loop == nil, storageAvailable else { return }
    loop = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        if self.action == nil { await self.cycle() }
        try? await Task.sleep(for: .milliseconds(500))
      }
    }
  }
  private func run(_ operation: @escaping @MainActor (SyncEngine, WireMLS) async throws -> Void) {
    guard action == nil, storageAvailable else { return }
    action = Task { [weak self] in
      guard let self else { return }
      if self.cycleActive { await withCheckedContinuation { self.cycleWaiters.append($0) } }
      do {
        try await operation(self, self.driver())
        self.errorMessage = nil
      } catch {
        self.errorMessage = error.localizedDescription
        self.phase = .failed
      }
      self.action = nil
    }
  }
  private func cycle() async {
    guard !cycleActive, action == nil else { return }
    cycleActive = true
    defer {
      cycleActive = false
      for waiter in cycleWaiters { waiter.resume() }
      cycleWaiters = []
    }
    do {
      let driver = try await driver()
      do { try await driver.pollPairing() } catch {
        mailboxErrorMessage = error.localizedDescription
      }
      let state = try await driver.synchronize(localOperations: replica.retainedOperations)
      guard !Task.isCancelled else { return }
      pending = state.pairing
      members = state.members
      if let pending { try present(pending) } else { clearPairingPresentation() }
      if !state.provisional {
        if state.awaitingInitialSnapshot {
          snapshotBatches = state.inbox
        } else if state.initialMergePending {
          var imported = try TaskReplica(deviceID: deviceID)
          let operations = state.inbox.flatMap { $0 }.sorted(by: ReplicaOrdering.operations)
          for start in stride(from: 0, to: operations.count, by: 256) {
            try imported.applyRemote(Array(operations[start..<min(start + 256, operations.count)]))
          }
          if !replica.isEmpty && !imported.isEmpty {
            staged = imported
            stagedInboxCount = state.inbox.count
            keepBothPreview = try TaskReplica.keepBothPreview(staged: imported, local: replica)
            hasPairingReplicaConflict = true
            isPairingFinalizationLocked = true
            pairingFinalizationState = .provisionStagedAwaitingMergeApproval
          } else {
            if !imported.isEmpty { try install(imported) }
            try await driver.acknowledgeInbox(
              through: state.inbox.count, initialMergeComplete: true)
            snapshotBatches = []
          }
        } else if !hasPairingReplicaConflict {
          for batch in state.inbox { try replica.applyRemote(batch) }
          try await driver.acknowledgeInbox(through: state.inbox.count)
        }
      }
      isPaired =
        state.group != nil && state.members.count >= 2 && !state.provisional
        && !state.awaitingInitialSnapshot && !state.initialMergePending && !state.removed
        && !hasPairingReplicaConflict
      mailboxCapacityReached = state.capacityBlocked
      if state.removed && state.leaveRequested {
        reset(erase: false)
        return
      }
      if state.leaveRequested {
        phase = .finalizing
        isPairingFinalizationLocked = true
      } else if state.removed {
        errorMessage = "This phone was removed. Your tasks are kept."
        phase = .failed
      } else if hasPairingReplicaConflict {
        phase = .provisioning
      } else if pending == nil {
        phase = isPaired ? .synced : .unpaired
      } else if state.provisional {
        phase = .finalizing
      }
      tasks = replica.tasks
      pendingMailboxOperationCount = Int(
        replica.versionVector[deviceID] - min(state.uploaded, replica.versionVector[deviceID]))
      showsSavingNotice = pendingMailboxOperationCount > 0
      mailboxState = isPaired ? .available : .idle
      mailboxErrorMessage = nil
      mailboxError = nil
      if isPaired {
        lastSyncedAt = Date()
        lastMailboxReceivedAt = Date()
      }
      backgroundMailboxScheduler.scheduleFlushIfNeeded(
        pendingOperationCount: pendingMailboxOperationCount)
    } catch {
      guard !Task.isCancelled else { return }
      mailboxState = .unavailable
      mailboxErrorMessage = error.localizedDescription
      if error is ReplicaError || error as? SyncError == .archiveTooLarge
        || error as? SyncError == .invalidSyncMessage || error as? SyncError == .safetyCodeMismatch
        || error as? SyncError == .invalidCredentials
      {
        mailboxRequiresRepair = true
        phase = .failed
        errorMessage = error.localizedDescription
      } else if isPaired {
        phase = .offline
      }
    }
  }
  private func present(_ pairing: MLSPairing) throws {
    pending = pairing
    activePairingRole = pairing.role
    invitationURL = try MLSQR(pairing).url(scheme: configuration.invitationURLScheme)
    invitationPhrase = invitationURL?.absoluteString
    invitationExpiresAt = pairing.expires
    if pairing.role == .joiner {
      safetyCode = "scan-response"
      phase = .verifying
    } else {
      safetyCode = pairing.verified ? nil : "scan-response"
      isHostApprovalPending = !pairing.verified
      phase = pairing.verified ? .provisioning : .waitingForPeer
    }
  }
  private func clearPairingPresentation() {
    pending = nil
    safetyCode = nil
    invitationPhrase = nil
    invitationURL = nil
    invitationExpiresAt = nil
    activePairingRole = nil
    isHostApprovalPending = false
    if !hasPairingReplicaConflict {
      isPairingFinalizationLocked = false
      pairingFinalizationState = nil
    }
  }

  public var linkedDeviceIDs: [Data] { members.map { $0.deviceID.bytes } }
  public var localDeviceID: Data { deviceID.bytes }
  public var linkedMemberCount: Int { members.count }
  public var isGroupAtCapacity: Bool { members.count >= 8 }
  public var isIssuingGroupInvite: Bool { isPaired && pending != nil }
  public var pairingRecoveryResetRequired: Bool { mailboxRequiresRepair }
  public var hasLocalReplicaHistory: Bool { !replica.isEmpty }
  public var canJoinExistingSync: Bool { storageAvailable && !isPaired && pending == nil }
  public var canEditLocalTasks: Bool { storageAvailable && !hasPairingReplicaConflict }
  public var canCancelPairing: Bool {
    pending != nil && phase != .finalizing && phase != .provisioning
  }

  public func createPrivateSync() {
    run { engine, driver in try engine.present(await driver.createInvitation()) }
  }
  public func inviteToGroup() { createPrivateSync() }
  public func joinPrivateSync(phrase: String) {
    guard let url = URL(string: phrase.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      errorMessage = SyncError.invalidPairMessage.errorDescription
      return
    }
    joinPrivateSync(url: url)
  }
  public func joinPrivateSync(url: URL) {
    run { engine, driver in
      let qr = try MLSQR.from(url: url, scheme: engine.configuration.invitationURLScheme)
      if qr.role == .joiner {
        try await driver.verifyResponse(qr)
        engine.safetyCode = nil
        engine.phase = .provisioning
      } else {
        try engine.present(await driver.join(qr))
      }
    }
  }
  public func approveSafetyCode() {}
  public func rejectSafetyCode() { cancelPairing() }
  public func regenerateInvitation() {
    run { engine, driver in
      try await driver.cancelPairing()
      try engine.present(await driver.createInvitation())
    }
  }
  public func cancelPairing(preserveLink: Bool = false) {
    run { engine, driver in
      try await driver.cancelPairing()
      engine.clearPairingPresentation()
      engine.phase = engine.isPaired ? .synced : .unpaired
    }
  }
  public func resolvePairingReplicaConflictKeepingBoth() {
    run { engine, driver in
      guard let staged = engine.staged else { throw SyncError.invalidPairMessage }
      let combined = try TaskReplica.keepBothCandidate(
        staged: staged, local: engine.replica, pairID: engine.deviceID.bytes)
      try engine.install(combined)
      try await driver.acknowledgeInbox(
        through: engine.stagedInboxCount, initialMergeComplete: true)
      engine.snapshotBatches = []
      engine.staged = nil
      engine.keepBothPreview = nil
      engine.hasPairingReplicaConflict = false
      engine.isPairingFinalizationLocked = false
      engine.pairingFinalizationState = nil
    }
  }
  private func install(_ candidate: TaskReplica) throws {
    let url = configuration.storageDirectory.appendingPathComponent("replica-v1.json")
    try durableWrite(candidate.atomicArchiveData(), to: url)
    replica = try TaskReplica(deviceID: deviceID, persistenceURL: url)
    tasks = replica.tasks
  }
  @discardableResult public func addTask(title: String) -> Bool {
    mutate { try $0.createTask(title: title) }
  }
  public func toggleTask(_ task: ReplicatedTask) {
    _ = mutate { try $0.setCompleted(taskID: task.id, completed: !(task.isCompleted ?? false)) }
  }
  public func deleteTasks(at offsets: IndexSet) {
    deleteTasks(ids: offsets.compactMap { tasks.indices.contains($0) ? tasks[$0].id : nil })
  }
  public func deleteTasks(ids: [UUID]) {
    for id in ids { _ = mutate { try $0.deleteTask(taskID: id) } }
  }
  private func mutate(_ operation: (inout TaskReplica) throws -> TaskOperation) -> Bool {
    guard canEditLocalTasks else { return false }
    do {
      _ = try operation(&replica)
      tasks = replica.tasks
      pendingMailboxOperationCount += 1
      localEditErrorMessage = nil
      return true
    } catch {
      localEditErrorMessage = error.localizedDescription
      return false
    }
  }
  public func clearLocalEditError() { localEditErrorMessage = nil }
  public func removeDevice(_ id: Data) {
    run { engine, driver in
      guard let member = engine.members.first(where: { $0.deviceID.bytes == id }) else {
        throw SyncError.invalidCredentials
      }
      try await driver.remove(member.clientID)
    }
  }
  public func leaveGroupAndKeepTasks() {
    run { engine, driver in
      try await driver.requestLeave()
      engine.isPaired = false
      engine.phase = .unpaired
    }
  }
  public func unlinkAndKeepTasks() { reset(erase: false) }
  public func eraseLocalData() { reset(erase: true) }
  private func reset(erase: Bool) {
    guard action == nil else { return }
    let running = loop
    loop?.cancel()
    loop = nil
    action = Task { [weak self] in
      guard let self else { return }
      await running?.value
      do {
        if let driver = try? await self.driver() { await driver.forgetTransport() }
        self.driverTask = nil
        try self.secretStore.delete(account: "wire-mls-v3-database-key")
        try WireDatabaseSalt(secrets: self.secretStore).removeAll()
        let directory = self.configuration.storageDirectory.appendingPathComponent("wire-mls-v3")
        if FileManager.default.fileExists(atPath: directory.path) {
          try FileManager.default.removeItem(at: directory)
        }
        if erase {
          let url = self.configuration.storageDirectory.appendingPathComponent("replica-v1.json")
          if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
          }
          self.replica = try TaskReplica(deviceID: self.deviceID, persistenceURL: url)
        }
        self.members = []
        self.isPaired = false
        self.clearPairingPresentation()
        self.tasks = self.replica.tasks
        self.mailboxRequiresRepair = false
        self.errorMessage = nil
        self.phase = .unpaired
        self.openDriver()
        self.action = nil
        self.startLoop()
      } catch {
        self.errorMessage = error.localizedDescription
        self.phase = .failed
        self.action = nil
      }
    }
  }
  public func waitForBackgroundWork() async {
    await backgroundWork?.value
    await action?.value
  }
  public func stopBackgroundWork() async {
    backgroundWork?.cancel()
    await backgroundWork?.value
    await stopLoop()
  }
  public func applicationDidBecomeActive() {
    Task { [weak self] in
      guard let self else { return }
      self.backgroundWork?.cancel()
      await self.backgroundWork?.value
      if !self.storageAvailable {
        do {
          self.deviceID = try ReplicaDeviceID(
            bytes: InstallIdentity.loadOrCreate(store: self.secretStore).deviceID)
          self.replica = try TaskReplica(
            deviceID: self.deviceID,
            persistenceURL: self.configuration.storageDirectory.appendingPathComponent(
              "replica-v1.json"))
          self.tasks = self.replica.tasks
          self.storageAvailable = true
          self.errorMessage = nil
        } catch {
          self.errorMessage = SyncError.localStorageUnavailable.errorDescription
          return
        }
      }
      if self.driverTask == nil { self.openDriver() }
      self.startLoop()
    }
  }
  public func applicationDidEnterBackground() {
    guard backgroundWork == nil else { return }
    backgroundWork = Task { [weak self] in
      guard let self else { return }
      await self.stopLoop()
      if !Task.isCancelled { await self.cycle() }
      self.backgroundWork = nil
    }
  }
  public func performBackgroundMailboxFlushWork() async { await cycle() }
  private func stopLoop() async {
    let running = loop
    loop?.cancel()
    loop = nil
    await running?.value
  }
  public func stop() async {
    backgroundWork?.cancel()
    await backgroundWork?.value
    await stopLoop()
    await action?.value
    backgroundMailboxScheduler.cancelFlush()
    for subscriber in stateSubscribers.values { subscriber.finish() }
    stateSubscribers = [:]
  }
}
