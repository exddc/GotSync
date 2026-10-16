import Foundation
import WireCoreCryptoUniffi

private actor MLSCommand<Value: Sendable>: CoreCryptoCommand {
  let block: @Sendable (CoreCryptoContext) async throws -> Value
  var result: Value?
  var failure: (any Error)?
  init(_ block: @escaping @Sendable (CoreCryptoContext) async throws -> Value) {
    self.block = block
  }
  func execute(context: CoreCryptoContext) async throws {
    do { result = try await block(context) } catch {
      failure = error
      throw error
    }
  }
  func value() throws -> Value {
    if let failure { throw failure }
    guard let result else { throw SyncError.localStorageUnavailable }
    return result
  }
}

private actor CommitCapture: MlsTransport {
  var bundle: CommitBundle?
  func sendCommitBundle(commitBundle: CommitBundle) async throws { bundle = commitBundle }
  func prepareForTransport(historySecret: HistorySecret) async -> MlsTransportData { Data() }
  func take() -> CommitBundle? {
    defer { bundle = nil }
    return bundle
  }
}

private struct MLSDatabase: Sendable {
  let path: URL
  let database: Database
  let crypto: CoreCryptoFfi
  let capture: CommitCapture

  static func open(
    _ path: URL, key: Data, client: ClientId, salt: WireDatabaseSalt, existing: Bool = false
  ) async throws -> MLSDatabase {
    if existing && !FileManager.default.fileExists(atPath: path.path) {
      throw SyncError.invalidCredentials
    }
    try salt.prepare(path)
    let db = try await openDatabase(location: path.path, key: DatabaseKey(bytes: key))
    try salt.capture(path)
    let result = MLSDatabase(
      path: path, database: db, crypto: try coreCryptoNew(database: db), capture: CommitCapture())
    try await result.transaction { context in
      try await context.mlsInit(clientId: client, transport: result.capture)
    }
    return result
  }

  func transaction<Value: Sendable>(
    durable: Bool = true, _ block: @escaping @Sendable (CoreCryptoContext) async throws -> Value
  ) async throws -> Value {
    let command = MLSCommand(block)
    do { try await crypto.transactionFfi(command: command) } catch {
      _ = try await command.value()
      throw error
    }
    let value = try await command.value()
    if durable {
      for suffix in ["", "-wal"] {
        let file = URL(fileURLWithPath: path.path + suffix)
        if FileManager.default.fileExists(atPath: file.path) { try synchronizeFile(file) }
      }
    }
    return value
  }
}

struct MLSMember: Codable, Equatable, Sendable {
  let clientID: Data
  let deviceID: ReplicaDeviceID
  let fingerprint: String
}

struct MLSPairing: Codable, Sendable {
  let route: String
  let token: Data
  let role: DeviceRole
  let group: String
  let local: MLSDescriptor
  var remote: MLSDescriptor?
  var verified = false
  let expires: Date
  var localToken: Data? = nil
  var directoryPublished = false
}

struct MLSOutbox: Codable, Sendable {
  let event: MLSEvent
  let plaintext: Data?
  let sequence: UInt64
  var snapshotOffset: Int? = nil
}

struct MLSData: Codable, Sendable {
  var group: String?
  var token: Data?
  var cursor: UInt64 = 0
  var members: [MLSMember] = []
  var removed = false
  var provisional = false
  var pairing: MLSPairing?
  var inbox: [[TaskOperation]] = []
  var outbox: MLSOutbox?
  var candidate: String?
  var uploaded: UInt64 = 0
  var needsSnapshot = false
  var snapshotOffset = 0
  var awaitingInitialSnapshot = false
  var initialMergePending = false
  var snapshotPairing: String? = nil
  var leaveRequested = false
  var leaveDelivered = false
  var removals: [Data] = []
  var capacityBlocked = false
}

struct MLSApplication: Codable, Sendable {
  let version: Int
  let kind: String
  var pairing: String? = nil
  var keyPackageHash: Data? = nil
  var operations: [TaskOperation] = []
  var final: Bool? = nil
}

actor WireMLS {
  private let now: @Sendable () -> Date
  private let directory: URL
  private let key: Data
  let client: ClientId
  let deviceID: ReplicaDeviceID
  private var db: MLSDatabase
  private var filename: String
  private var locked = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private let relay: any MLSDelivery
  private let salt: WireDatabaseSalt

  private init(
    directory: URL, key: Data, client: ClientId, deviceID: ReplicaDeviceID, db: MLSDatabase,
    filename: String, relay: any MLSDelivery, salt: WireDatabaseSalt,
    now: @escaping @Sendable () -> Date
  ) {
    self.directory = directory
    self.key = key
    self.client = client
    self.deviceID = deviceID
    self.db = db
    self.filename = filename
    self.relay = relay
    self.salt = salt
    self.now = now
  }

  static func open(
    directory: URL, secretStore: any SecretStore, deviceID: ReplicaDeviceID, relay: any MLSDelivery,
    now: @escaping @Sendable () -> Date = { Date() }
  ) async throws -> WireMLS {
    var directory = directory
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: ProtectedStorage.directoryAttributes)
    var resources = URLResourceValues()
    resources.isExcludedFromBackup = true
    try directory.setResourceValues(resources)
    let account = "wire-mls-v3-database-key"
    let key: Data
    if let existing = try secretStore.read(account: account) {
      key = existing
    } else {
      guard
        !FileManager.default.fileExists(atPath: directory.appendingPathComponent("current").path)
      else { throw SyncError.invalidCredentials }
      key = try .secureRandom(count: 32)
      try secretStore.write(key, account: account)
    }
    guard key.count == 32 else { throw SyncError.invalidCredentials }
    let uuid = UUID(uuid: deviceID.bytes.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) })
    let client = ClientId(
      userId: try Uuid(uuid: uuid.uuidString), deviceId: DeviceId(id: 1), domain: "gotsync.invalid")
    let pointer = directory.appendingPathComponent("current")
    let filename =
      FileManager.default.fileExists(atPath: pointer.path)
      ? String(decoding: try Data(contentsOf: pointer), as: UTF8.self) : UUID().uuidString + ".db"
    guard filename.hasSuffix(".db"), UUID(uuidString: String(filename.dropLast(3))) != nil else {
      throw SyncError.invalidCredentials
    }
    let salt = WireDatabaseSalt(secrets: secretStore)
    let db = try await MLSDatabase.open(
      directory.appendingPathComponent(filename), key: key, client: client, salt: salt,
      existing: FileManager.default.fileExists(atPath: pointer.path))
    try await db.transaction { context in
      let identity = ConversationId(bytes: Data("gotsync-local-identity-v3".utf8))
      if try await !context.conversationExists(conversationId: identity) {
        let credential = try await context.addCredential(
          credential: Credential.basic(
            cipherSuite: .mls128Dhkemx25519Aes128gcmSha256Ed25519, clientId: client))
        try await context.createConversation(
          conversationId: identity, credentialRef: credential, externalSender: nil)
        try await context.setData(data: CanonicalJSON.encoder.encode(MLSData()))
      }
    }
    if !FileManager.default.fileExists(atPath: pointer.path) {
      try durableWrite(Data(filename.utf8), to: pointer)
    }
    let state = try await db.transaction(durable: false) { try Self.decode(await $0.getData()) }
    let retained = Set([filename, state.candidate].compactMap { $0 })
    try salt.retain(Set(retained.map { directory.appendingPathComponent($0).path }))
    for file in try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    {
      let name = file.lastPathComponent
      let base = name.hasSuffix("-wal") || name.hasSuffix("-shm") ? String(name.dropLast(4)) : name
      if base.hasSuffix(".db"), UUID(uuidString: String(base.dropLast(3))) != nil,
        !retained.contains(base)
      {
        try FileManager.default.removeItem(at: file)
        if name == base { try salt.remove(file) }
      }
    }
    return WireMLS(
      directory: directory, key: key, client: client, deviceID: deviceID, db: db,
      filename: filename, relay: relay, salt: salt, now: now)
  }

  private func acquire() async {
    if locked { await withCheckedContinuation { waiters.append($0) } } else { locked = true }
  }
  private func release() {
    if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
  }
  private func read() async throws -> MLSData {
    try await db.transaction(durable: false) { try Self.decode(await $0.getData()) }
  }
  private static func decode(_ data: Data?) throws -> MLSData {
    guard let data else { throw SyncError.invalidCredentials }
    return try CanonicalJSON.decoder.decode(MLSData.self, from: data)
  }
  private func write(_ state: MLSData) async throws {
    try await db.transaction { try await $0.setData(data: CanonicalJSON.encoder.encode(state)) }
  }
  func snapshot() async throws -> MLSData {
    await acquire()
    defer { release() }
    return try await read()
  }
  private static func credential(_ context: CoreCryptoContext) async throws -> CredentialRef {
    try await context.conversationCredential(
      conversationId: ConversationId(bytes: Data("gotsync-local-identity-v3".utf8)))
  }
  private static func roster(_ context: CoreCryptoContext, group: String) async throws
    -> [MLSMember]
  {
    let id = ConversationId(bytes: Data(group.utf8))
    let clients = try await context.getClientIds(conversationId: id)
    let identities = try await context.getDeviceIdentities(conversationId: id, deviceIds: clients)
    guard (1...8).contains(clients.count), identities.count == clients.count else {
      throw SyncError.invalidCredentials
    }
    var result: [MLSMember] = []
    for identity in identities {
      guard let client = identity.clientId, identity.credentialType == .basic,
        !identity.thumbprint.isEmpty
      else { throw SyncError.invalidCredentials }
      let parsed = client.deserialize()
      guard parsed.domain == "gotsync.invalid", parsed.deviceId.toU64() == 1,
        let uuid = UUID(uuidString: parsed.userId.description)
      else { throw SyncError.invalidCredentials }
      result.append(
        MLSMember(
          clientID: client.copyBytes(), deviceID: ReplicaDeviceID(uuid: uuid),
          fingerprint: identity.thumbprint))
    }
    guard Set(result.map(\.clientID)).count == result.count,
      Set(result.map(\.fingerprint)).count == result.count
    else { throw SyncError.invalidCredentials }
    return result.sorted { $0.deviceID < $1.deviceID }
  }
  private func descriptor(publish: Bool, transportHash: Data? = nil) async throws -> MLSDescriptor {
    let client = client
    return try await db.transaction { context in
      let kp =
        publish
        ? try await context.generateKeyPackage(
          credentialRef: Self.credential(context), lifetime: 900) : nil
      let ids = try await context.getDeviceIdentities(
        conversationId: ConversationId(bytes: Data("gotsync-local-identity-v3".utf8)),
        deviceIds: [client])
      guard let fingerprint = ids.first?.thumbprint, !fingerprint.isEmpty else {
        throw SyncError.invalidCredentials
      }
      return MLSDescriptor(
        clientID: client.copyBytes(), fingerprint: fingerprint,
        keyPackage: try kp?.serialize() ?? Data(), transportHash: transportHash)
    }
  }

  func createInvitation() async throws -> MLSPairing {
    await acquire()
    defer { release() }
    try await resolvePending()
    var state = try await read()
    if state.removed {
      state = MLSData()
      try await write(state)
    }
    guard state.members.count < 8 else { throw SyncError.groupAtCapacity }
    guard !state.needsSnapshot else { throw SyncError.invalidPairMessage }
    if state.group == nil {
      let group = UUID().uuidString
      let token = try Data.secureRandom(count: 32)
      _ = try await relay.request(
        MLSRelayRequest(
          operation: "createGroup", route: group, token: token,
          member: client.copyBytes().base64EncodedString()))
      state.group = group
      state.token = token
      let initial = state
      try await db.transaction { context in
        let groupID = ConversationId(bytes: Data(group.utf8))
        try await context.createConversation(
          conversationId: groupID, credentialRef: Self.credential(context), externalSender: nil)
        var next = initial
        next.members = try await Self.roster(context, group: group)
        try await context.setData(data: CanonicalJSON.encoder.encode(next))
      }
      state = try await read()
    }
    let pairing = MLSPairing(
      route: UUID().uuidString, token: try .secureRandom(count: 32), role: .host,
      group: state.group!, local: try await descriptor(publish: false),
      expires: now().addingTimeInterval(900))
    state.pairing = pairing
    try await write(state)
    _ = try await relay.request(
      MLSRelayRequest(
        operation: "createPair", route: pairing.route, token: pairing.token,
        descriptor: pairing.local))
    state.pairing?.directoryPublished = true
    try await write(state)
    return state.pairing!
  }

  func join(_ invitation: MLSQR) async throws -> MLSPairing {
    await acquire()
    defer { release() }
    var state = try await read()
    guard state.group == nil, invitation.role == .host,
      invitation.expires.addingTimeInterval(300) > now()
    else { throw SyncError.invalidPairMessage }
    let token = try Data.secureRandom(count: 32)
    let local = try await descriptor(publish: true, transportHash: token.sha256)
    let pairing = MLSPairing(
      route: invitation.route, token: invitation.token, role: .joiner, group: invitation.group,
      local: local, remote: invitation.descriptor, expires: invitation.expires, localToken: token)
    state.pairing = pairing
    try await write(state)
    _ = try await relay.request(
      MLSRelayRequest(
        operation: "join", route: pairing.route, token: pairing.token, descriptor: local))
    state.pairing?.directoryPublished = true
    try await write(state)
    return state.pairing!
  }

  func verifyResponse(_ response: MLSQR) async throws {
    await acquire()
    defer { release() }
    var state = try await read()
    guard var pairing = state.pairing, pairing.role == .host, response.role == .joiner,
      response.route == pairing.route, response.group == pairing.group,
      response.token == pairing.token,
      response.expires == pairing.expires, response.expires.addingTimeInterval(300) > now()
    else { throw SyncError.invalidPairMessage }
    pairing.remote = response.descriptor
    pairing.verified = true
    state.pairing = pairing
    try await write(state)
  }

  private func pairingReply(_ request: MLSRelayRequest) async throws -> MLSRelayReply {
    do { return try await relay.request(request) } catch SyncError.invitationExpired {
      return MLSRelayReply(expired: true)
    }
  }

  func pollPairing() async throws {
    await acquire()
    defer { release() }
    try await resolvePending()
    var state = try await read()
    guard let pairing = state.pairing else { return }
    let admitted =
      pairing.remote.map { remote in
        state.members.contains {
          $0.clientID == remote.clientID && $0.fingerprint == remote.fingerprint
        }
      } ?? false
    if pairing.expires <= now() && pairing.role == .host && !admitted {
      if !pairing.local.keyPackage.isEmpty {
        try await db.transaction {
          try await $0.removeKeyPackagesFor(credentialRef: Self.credential($0))
        }
      }
      state.pairing = nil
      try await write(state)
      return
    }
    if pairing.role == .host {
      if !pairing.directoryPublished {
        _ = try await relay.request(
          MLSRelayRequest(
            operation: "createPair", route: pairing.route, token: pairing.token,
            descriptor: pairing.local))
        state.pairing?.directoryPublished = true
        try await write(state)
      }
      guard pairing.verified, !state.capacityBlocked, let remote = pairing.remote else { return }
      let directory = try await pairingReply(
        MLSRelayRequest(
          operation: "pair", route: pairing.route, token: pairing.token, descriptor: remote))
      if directory.expired == true && !admitted {
        state.pairing = nil
        try await write(state)
        return
      }
      guard admitted || directory.ready == true else { return }
      if let old = state.members.first(where: {
        $0.clientID == remote.clientID && $0.fingerprint != remote.fingerprint
      }) {
        try await stageCommit(add: nil, remove: old.clientID)
        try await resolvePending()
        return
      }
      if !state.members.contains(where: {
        $0.clientID == remote.clientID && $0.fingerprint == remote.fingerprint
      }) {
        try await stageCommit(add: pairing, remove: nil)
        try await resolvePending()
        state = try await read()
        guard state.members.contains(where: { $0.clientID == remote.clientID }) else { return }
      }
      if state.outbox == nil {
        let confirm = MLSApplication(
          version: 3, kind: "pairConfirm", pairing: pairing.route,
          keyPackageHash: remote.keyPackage.sha256)
        try await seal(confirm, sequence: state.uploaded)
      }
    } else if state.group == nil {
      let reply = try await pairingReply(
        MLSRelayRequest(operation: "welcome", route: pairing.route, token: pairing.token))
      guard let welcome = reply.welcome else {
        if reply.expired == true {
          try await db.transaction {
            try await $0.removeKeyPackagesFor(credentialRef: Self.credential($0))
          }
          state.pairing = nil
          try await write(state)
        } else if !pairing.directoryPublished {
          _ = try await relay.request(
            MLSRelayRequest(
              operation: "join", route: pairing.route, token: pairing.token,
              descriptor: pairing.local))
          state.pairing?.directoryPublished = true
          try await write(state)
        }
        return
      }
      guard welcome.group == pairing.group else { throw SyncError.safetyCodeMismatch }
      let initial = state
      try await db.transaction { context in
        let group = try await context.processWelcomeMessage(
          welcomeMessage: Welcome(bytes: welcome.payload))
        guard group.copyBytes() == Data(pairing.group.utf8),
          try await context.conversationEpoch(conversationId: group) == welcome.epoch
        else { throw SyncError.invalidPairMessage }
        var next = initial
        next.members = try await Self.roster(context, group: pairing.group)
        guard
          next.members.contains(where: {
            $0.fingerprint == pairing.remote?.fingerprint && $0.clientID == pairing.remote?.clientID
          }),
          next.members.contains(where: {
            $0.fingerprint == pairing.local.fingerprint && $0.clientID == pairing.local.clientID
          })
        else { throw SyncError.safetyCodeMismatch }
        next.group = pairing.group
        next.token = pairing.localToken
        next.cursor = welcome.cursor
        next.provisional = true
        next.awaitingInitialSnapshot = true
        next.initialMergePending = true
        try await context.setData(data: CanonicalJSON.encoder.encode(next))
      }
    }
  }

  private func stageCommit(add: MLSPairing?, remove: Data?) async throws {
    var state = try await read()
    guard state.candidate == nil, state.outbox == nil, let group = state.group, !state.provisional,
      !state.removed, !state.initialMergePending, !state.awaitingInitialSnapshot
    else { throw SyncError.invalidCredentials }
    let name = UUID().uuidString + ".db"
    let path = directory.appendingPathComponent(name)
    do {
      try salt.prepare(path)
      for suffix in ["", "-wal"] {
        let source = URL(fileURLWithPath: db.path.path + suffix)
        if FileManager.default.fileExists(atPath: source.path) {
          let target = URL(fileURLWithPath: path.path + suffix)
          try FileManager.default.copyItem(at: source, to: target)
          try synchronizeFile(target)
        }
      }
      try synchronizeDirectory(directory)
      let candidate = try await MLSDatabase.open(
        path, key: key, client: client, salt: salt, existing: true)
      let before = state
      let localDevice = deviceID
      try await candidate.transaction { context in
        let id = ConversationId(bytes: Data(group.utf8))
        let beforeEpoch = try await context.conversationEpoch(conversationId: id)
        if let add, let remote = add.remote {
          guard
            !before.members.contains(where: {
              $0.clientID == remote.clientID || $0.fingerprint == remote.fingerprint
            }), before.members.count < 8
          else { throw SyncError.invalidCredentials }
          try await context.addClientsToConversation(
            conversationId: id, keyPackages: [KeyPackage(bytes: remote.keyPackage)])
        } else if let remove {
          let ids = try await context.getClientIds(conversationId: id)
          guard let member = ids.first(where: { $0.copyBytes() == remove }) else {
            throw SyncError.invalidCredentials
          }
          try await context.removeClientsFromConversation(conversationId: id, clients: [member])
        }
        guard let bundle = await candidate.capture.take() else {
          throw SyncError.invalidCredentials
        }
        var next = before
        if remove == before.members.first(where: { $0.deviceID == localDevice })?.clientID {
          next.removed = true
        } else {
          next.members = try await Self.roster(context, group: group)
        }
        var event = MLSEvent(
          kind: "commit", epoch: beforeEpoch, payload: bundle.commit, previous: before.cursor)
        if let add, let remote = add.remote, let welcome = bundle.welcome {
          guard
            next.members.contains(where: {
              $0.fingerprint == remote.fingerprint && $0.clientID == remote.clientID
            })
          else { throw SyncError.safetyCodeMismatch }
          event.pair = MLSPairReference(
            route: add.route, token: add.token, keyPackage: remote.keyPackage,
            member: remote.clientID.base64EncodedString(),
            transportHash: remote.transportHash ?? Data(), welcome: try welcome.serialize())
        }
        if let remove { event.remove = [remove.base64EncodedString()] }
        next.outbox = MLSOutbox(event: event, plaintext: nil, sequence: before.uploaded)
        if let add {
          next.needsSnapshot = true
          next.snapshotOffset = 0
          next.snapshotPairing = add.route
        }
        try await context.setData(data: CanonicalJSON.encoder.encode(next))
      }
      try synchronizeDirectory(directory)
      state.candidate = name
      try await write(state)
    } catch {
      try? removeDatabase(name)
      throw error
    }
  }

  private func resolvePending(receipt: MLSRelayReply? = nil) async throws {
    var state = try await read()
    if let name = state.candidate {
      guard name.hasSuffix(".db"), UUID(uuidString: String(name.dropLast(3))) != nil else {
        throw SyncError.invalidCredentials
      }
      let candidate = try await MLSDatabase.open(
        directory.appendingPathComponent(name), key: key, client: client, salt: salt, existing: true
      )
      var next = try await candidate.transaction(durable: false) {
        try Self.decode(await $0.getData())
      }
      guard let outbox = next.outbox else { throw SyncError.invalidCredentials }
      let result: MLSRelayReply
      if let receipt {
        result = receipt
      } else {
        result = try await send(outbox.event, state: state)
      }
      if result.capacity == true { throw SyncError.archiveTooLarge }
      guard let accepted = result.accepted else { throw SyncError.invalidSyncMessage }
      if accepted {
        guard result.cursor == state.cursor + 1 else { throw SyncError.invalidSyncMessage }
        next.cursor = result.cursor!
        next.candidate = nil
        next.inbox = state.inbox
        next.initialMergePending = state.initialMergePending
        try await candidate.transaction { [next] in
          try await $0.setData(data: CanonicalJSON.encoder.encode(next))
        }
        try durableWrite(Data(name.utf8), to: directory.appendingPathComponent("current"))
        let old = filename
        db = candidate
        filename = name
        next.outbox = nil
        try await write(next)
        try removeDatabase(old)
      } else {
        state.candidate = nil
        try await write(state)
        try removeDatabase(name)
      }
      return
    }
    if let outbox = state.outbox {
      let result: MLSRelayReply
      if let receipt {
        result = receipt
      } else {
        result = try await send(outbox.event, state: state)
      }
      if result.capacity == true { throw SyncError.archiveTooLarge }
      guard let accepted = result.accepted else { throw SyncError.invalidSyncMessage }
      if accepted {
        guard let cursor = result.cursor else { throw SyncError.invalidSyncMessage }
        try Self.accept(outbox, cursor: cursor, state: &state)
      }
      state.outbox = nil
      try await write(state)
    }
  }

  private static func accept(_ outbox: MLSOutbox, cursor: UInt64, state: inout MLSData) throws {
    guard cursor == state.cursor + 1 || (outbox.event.kind == "commit" && cursor == state.cursor)
    else { throw SyncError.invalidSyncMessage }
    state.cursor = cursor
    state.uploaded = max(state.uploaded, outbox.sequence)
    if let plain = outbox.plaintext {
      let message = try CanonicalJSON.decoder.decode(MLSApplication.self, from: plain)
      if let offset = outbox.snapshotOffset {
        state.snapshotOffset = offset
        if message.final == true {
          state.needsSnapshot = false
          state.snapshotOffset = 0
          state.snapshotPairing = nil
        }
      }
      if message.kind == "pairConfirm" { state.pairing = nil }
      if message.kind == "leave" { state.leaveDelivered = true }
    }
    state.outbox = nil
  }

  private func send(_ event: MLSEvent, state: MLSData) async throws -> MLSRelayReply {
    guard let group = state.group, let token = state.token else {
      throw SyncError.invalidCredentials
    }
    return try await relay.request(
      MLSRelayRequest(
        operation: event.kind, route: group, token: token,
        member: client.copyBytes().base64EncodedString(), id: event.id, event: event))
  }
  func seal(_ message: MLSApplication, sequence: UInt64, snapshotOffset: Int? = nil) async throws {
    try await db.transaction { context in
      var state = try Self.decode(await context.getData())
      guard state.outbox == nil, let group = state.group, !state.provisional, !state.removed else {
        throw SyncError.invalidCredentials
      }
      let id = ConversationId(bytes: Data(group.utf8))
      let plain = try CanonicalJSON.encoder.encode(message)
      let event = MLSEvent(
        kind: "application", epoch: try await context.conversationEpoch(conversationId: id),
        payload: try await context.encryptMessage(conversationId: id, message: plain),
        previous: state.cursor)
      state.outbox = MLSOutbox(
        event: event, plaintext: plain, sequence: sequence, snapshotOffset: snapshotOffset)
      try await context.setData(data: CanonicalJSON.encoder.encode(state))
    }
  }

  func synchronize(localOperations: [TaskOperation]) async throws -> MLSData {
    await acquire()
    defer { release() }
    do { try await resolvePending() } catch {}
    var state = try await read()
    guard let group = state.group, let token = state.token else { return state }
    if state.removed {
      _ = try? await relay.request(
        MLSRelayRequest(
          operation: "fetch", route: group, token: token,
          member: client.copyBytes().base64EncodedString(), cursor: state.cursor))
      return state
    }
    let reply = try await relay.request(
      MLSRelayRequest(
        operation: "fetch", route: group, token: token,
        member: client.copyBytes().base64EncodedString(), cursor: state.cursor))
    if let canAppend = reply.canAppend, state.capacityBlocked == canAppend {
      state.capacityBlocked = !canAppend
      try await write(state)
    }
    for event in reply.events ?? [] {
      if try await read().removed { break }
      if let candidateName = try await read().candidate {
        let candidate = try await MLSDatabase.open(
          directory.appendingPathComponent(candidateName), key: key, client: client, salt: salt,
          existing: true)
        let candidateState = try await candidate.transaction(durable: false) {
          try Self.decode(await $0.getData())
        }
        if let outbox = candidateState.outbox, outbox.event.payload == event.payload,
          outbox.event.kind == event.kind, outbox.event.epoch == event.epoch,
          outbox.event.previous == event.previous
        {
          try await resolvePending(receipt: MLSRelayReply(accepted: true, cursor: event.cursor))
          continue
        }
      }
      try await consume(event)
    }
    state = try await read()
    if state.removed {
      _ = try? await relay.request(
        MLSRelayRequest(
          operation: "fetch", route: group, token: token,
          member: client.copyBytes().base64EncodedString(), cursor: state.cursor))
      return state
    }
    if !state.removed && !state.provisional && !state.awaitingInitialSnapshot
      && !state.initialMergePending && !state.capacityBlocked && state.inbox.isEmpty
      && state.outbox == nil && state.candidate == nil
    {
      if state.needsSnapshot && state.pairing == nil {
        let batch = Array(localOperations.dropFirst(state.snapshotOffset).prefix(128))
        let offset = state.snapshotOffset + batch.count
        try await seal(
          MLSApplication(
            version: 3, kind: "checkpoint", pairing: state.snapshotPairing, operations: batch,
            final: offset >= localOperations.count), sequence: state.uploaded,
          snapshotOffset: offset)
        try await resolvePending()
        return try await read()
      }
      if let target = state.removals.first {
        if state.members.contains(where: { $0.clientID == target }) {
          try await stageCommit(add: nil, remove: target)
          try await resolvePending()
        }
        var next = try await read()
        if !next.members.contains(where: { $0.clientID == target }) {
          next.removals.removeAll { $0 == target }
        }
        try await write(next)
        return next
      }
      if state.leaveRequested {
        if !state.leaveDelivered {
          try await seal(MLSApplication(version: 3, kind: "leave"), sequence: state.uploaded)
          try await resolvePending()
        }
        return try await read()
      }
      let own = localOperations.filter {
        $0.originDeviceID == deviceID && $0.originSequence > state.uploaded
      }.prefix(128)
      if !own.isEmpty {
        try await seal(
          MLSApplication(version: 3, kind: "operations", operations: Array(own)),
          sequence: own.last!.originSequence)
        try await resolvePending()
      }
    }
    return try await read()
  }

  private func consume(_ event: MLSEvent) async throws {
    let localClient = client.copyBytes()
    try await db.transaction { context in
      var state = try Self.decode(await context.getData())
      guard let group = state.group, let cursor = event.cursor, cursor == state.cursor + 1,
        !state.removed
      else { throw SyncError.invalidSyncMessage }
      let id = ConversationId(bytes: Data(group.utf8))
      let epoch = try await context.conversationEpoch(conversationId: id)
      guard event.epoch == epoch else { throw SyncError.invalidSyncMessage }
      try MLSHeader.validate(event.payload, group: Data(group.utf8), epoch: epoch, kind: event.kind)
      if let outbox = state.outbox, outbox.event.kind == "application",
        outbox.event.payload == event.payload,
        outbox.event.epoch == event.epoch, outbox.event.previous == event.previous
      {
        try Self.accept(outbox, cursor: cursor, state: &state)
        try await context.setData(data: CanonicalJSON.encoder.encode(state))
        return
      }
      let result = try await context.decryptMessage(conversationId: id, payload: event.payload)
      switch result {
      case .commit(let active, let buffered, let identity):
        guard event.kind == "commit", buffered?.isEmpty != false,
          state.members.contains(where: {
            $0.fingerprint == identity.thumbprint && $0.clientID == identity.clientId?.copyBytes()
          })
        else { throw SyncError.invalidSyncMessage }
        state.removed = !active
        if active { state.members = try await Self.roster(context, group: group) }
      case .text(let plaintext, let sender, let identity):
        guard event.kind == "application",
          let member = state.members.first(where: {
            $0.fingerprint == identity.thumbprint && $0.clientID == sender.copyBytes()
          })
        else { throw SyncError.invalidSyncMessage }
        let message = try CanonicalJSON.decoder.decode(MLSApplication.self, from: plaintext)
        guard message.version == 3 else { throw SyncError.invalidSyncMessage }
        if state.provisional && message.kind != "pairConfirm" {
          state.cursor = cursor
          try await context.setData(data: CanonicalJSON.encoder.encode(state))
          return
        }
        if state.provisional {
          guard message.kind == "pairConfirm", let pairing = state.pairing,
            identity.thumbprint == pairing.remote?.fingerprint,
            message.pairing == pairing.route,
            message.keyPackageHash == pairing.local.keyPackage.sha256
          else { throw SyncError.safetyCodeMismatch }
          state.provisional = false
        } else if message.kind == "operations" {
          guard message.operations.count <= 128,
            message.operations.allSatisfy({ $0.originDeviceID == member.deviceID })
          else { throw SyncError.invalidSyncMessage }
          if sender.copyBytes() != localClient { state.inbox.append(message.operations) }
        } else if message.kind == "checkpoint" {
          guard message.operations.count <= 128 else { throw SyncError.invalidSyncMessage }
          if state.awaitingInitialSnapshot, let pairing = state.pairing,
            message.pairing == pairing.route, identity.thumbprint == pairing.remote?.fingerprint
          {
            state.inbox.append(message.operations)
            if message.final == true {
              state.awaitingInitialSnapshot = false
              state.pairing = nil
            }
          }
        } else if message.kind == "leave" {
          if sender.copyBytes() != localClient && !state.removals.contains(sender.copyBytes()) {
            state.removals.append(sender.copyBytes())
          }
        } else if message.kind != "pairConfirm" {
          throw SyncError.invalidSyncMessage
        }
      case .proposal: throw SyncError.invalidSyncMessage
      @unknown default: throw SyncError.invalidSyncMessage
      }
      guard state.inbox.count <= 128 else { throw SyncError.archiveTooLarge }
      state.cursor = cursor
      try await context.setData(data: CanonicalJSON.encoder.encode(state))
    }
  }

  func acknowledgeInbox(through count: Int, initialMergeComplete: Bool = false) async throws {
    await acquire()
    defer { release() }
    var state = try await read()
    guard count >= 0, count <= state.inbox.count else { throw SyncError.invalidSyncMessage }
    guard count > 0 || initialMergeComplete else { return }
    state.inbox.removeFirst(count)
    if initialMergeComplete { state.initialMergePending = false }
    try await write(state)
  }
  private func removeDatabase(_ name: String) throws {
    try salt.remove(directory.appendingPathComponent(name))
    for suffix in ["", "-wal", "-shm"] {
      let url = directory.appendingPathComponent(name + suffix)
      if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
    }
  }
  func cancelPairing() async throws {
    await acquire()
    defer { release() }
    var state = try await read()
    guard state.candidate == nil else { throw SyncError.invalidCredentials }
    if state.provisional, let group = state.group {
      try await db.transaction {
        try await $0.wipeConversation(conversationId: ConversationId(bytes: Data(group.utf8)))
      }
      state = MLSData()
      try await write(state)
      return
    }
    if let pairing = state.pairing, !pairing.local.keyPackage.isEmpty {
      try await db.transaction { context in
        try await context.removeKeyPackagesFor(credentialRef: Self.credential(context))
      }
    }
    state.pairing = nil
    try await write(state)
  }
  func forgetTransport() async {
    await acquire()
    defer { release() }
    guard let state = try? await read(), let group = state.group, let token = state.token else {
      return
    }
    _ = try? await relay.request(
      MLSRelayRequest(
        operation: "forget", route: group, token: token,
        member: client.copyBytes().base64EncodedString()))
  }
  func requestLeave() async throws {
    await acquire()
    defer { release() }
    try await resolvePending()
    var state = try await read()
    guard state.group != nil, !state.provisional, !state.removed else {
      throw SyncError.invalidCredentials
    }
    if state.members.count == 1, let group = state.group {
      try await db.transaction {
        try await $0.wipeConversation(conversationId: ConversationId(bytes: Data(group.utf8)))
      }
      state.removed = true
      state.leaveRequested = true
      try await write(state)
      return
    }
    try await seal(MLSApplication(version: 3, kind: "leave"), sequence: state.uploaded)
    state = try await read()
    state.leaveRequested = true
    try await write(state)
    try await resolvePending()
  }
  func remove(_ clientID: Data) async throws {
    await acquire()
    defer { release() }
    guard clientID != client.copyBytes() else { throw SyncError.invalidCredentials }
    try await resolvePending()
    var state = try await read()
    if !state.removals.contains(clientID) {
      state.removals.append(clientID)
      try await write(state)
    }
    try await stageCommit(add: nil, remove: clientID)
    try await resolvePending()
  }
}
