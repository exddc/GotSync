import Foundation
import WireCoreCryptoUniffi
import XCTest

@testable import GotSync

final class WireMLSTests: XCTestCase {
  func testRealRelayPairAndMessage() async throws {
    guard let endpoint = ProcessInfo.processInfo.environment["GOTSYNC_WIRE_RELAY"] else {
      throw XCTSkip("Requires real relay")
    }
    let relay = MLSRelay(url: URL(string: endpoint)!, policy: .localDevelopment)
    let aID = ReplicaDeviceID(uuid: UUID())
    let bID = ReplicaDeviceID(uuid: UUID())
    let a = try await WireMLS.open(
      directory: temporary(), secretStore: MemorySecretStore(), deviceID: aID, relay: relay)
    let b = try await WireMLS.open(
      directory: temporary(), secretStore: MemorySecretStore(), deviceID: bID, relay: relay)
    let invite = try await a.createInvitation()
    let response = try await b.join(MLSQR(invite))
    try await a.verifyResponse(MLSQR(response))
    try await a.pollPairing()
    try await b.pollPairing()
    _ = try await a.synchronize(localOperations: [])
    let joined = try await b.synchronize(localOperations: [])
    XCTAssertFalse(joined.provisional)
    XCTAssertEqual(joined.members.count, 2)
    var replica = try TaskReplica(deviceID: aID)
    try replica.createTask(title: "Wire encrypted task")
    for _ in 0..<3 { _ = try await a.synchronize(localOperations: replica.retainedOperations) }
    let received = try await b.synchronize(localOperations: [])
    XCTAssertTrue(received.inbox.flatMap { $0 }.contains { $0.taskID == replica.tasks[0].id })
  }
  private func temporary() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }
}

private actor LostResponseRelay: MLSDelivery {
  let relay: MLSRelay
  var drop: String?
  init(_ relay: MLSRelay) { self.relay = relay }
  func arm(_ operation: String) { drop = operation }
  func request(_ request: MLSRelayRequest) async throws -> MLSRelayReply {
    let result = try await relay.request(request)
    if request.operation == drop && result.accepted == true {
      drop = nil
      throw URLError(.networkConnectionLost)
    }
    return result
  }
}

extension WireMLSTests {
  private func ack(_ client: WireMLS) async throws {
    let state = try await client.snapshot()
    try await client.acknowledgeInbox(
      through: state.inbox.count, initialMergeComplete: !state.awaitingInitialSnapshot)
  }
  private func delivery() throws -> MLSRelay {
    guard let endpoint = ProcessInfo.processInfo.environment["GOTSYNC_WIRE_RELAY"] else {
      throw XCTSkip("Requires real relay")
    }
    return MLSRelay(url: URL(string: endpoint)!, policy: .localDevelopment)
  }
  private func fresh(_ relay: any MLSDelivery) async throws -> WireMLS {
    try await WireMLS.open(
      directory: temporary(), secretStore: MemorySecretStore(),
      deviceID: ReplicaDeviceID(uuid: UUID()), relay: relay)
  }
  private func pair(_ a: WireMLS, _ b: WireMLS) async throws {
    let invitation = try await a.createInvitation()
    let response = try await b.join(MLSQR(invitation))
    try await a.verifyResponse(MLSQR(response))
    for _ in 0..<5 {
      try await a.pollPairing()
      try await b.pollPairing()
      _ = try await a.synchronize(localOperations: [])
      _ = try await b.synchronize(localOperations: [])
      try await ack(a)
      try await ack(b)
    }
    let state = try await b.snapshot()
    XCTAssertFalse(state.provisional)
    XCTAssertNil(state.pairing)
  }

  func testAcceptedCommitLostResponseReopensExactDurableCandidate() async throws {
    let relay = try delivery()
    let fault = LostResponseRelay(relay)
    let directory = temporary()
    let store = MemorySecretStore()
    let id = ReplicaDeviceID(uuid: UUID())
    let a = try await WireMLS.open(
      directory: directory, secretStore: store, deviceID: id, relay: fault)
    let b = try await fresh(relay)
    let invitation = try await a.createInvitation()
    let response = try await b.join(MLSQR(invitation))
    try await a.verifyResponse(MLSQR(response))
    await fault.arm("commit")
    do {
      try await a.pollPairing()
      XCTFail("Expected lost response")
    } catch is URLError {}
    let pending = try await a.snapshot()
    XCTAssertNotNil(pending.candidate)
    let reopened = try await WireMLS.open(
      directory: directory, secretStore: store, deviceID: id, relay: relay)
    try await reopened.pollPairing()
    try await b.pollPairing()
    _ = try await reopened.synchronize(localOperations: [])
    let joined = try await b.synchronize(localOperations: [])
    XCTAssertFalse(joined.provisional)
    let restored = try await reopened.snapshot()
    XCTAssertNil(restored.candidate)
  }

  func testOfflineRestartThreeClientsAndRemoval() async throws {
    let relay = try delivery()
    let a = try await fresh(relay)
    let b = try await fresh(relay)
    try await pair(a, b)
    let store = MemorySecretStore()
    let directory = temporary()
    let cID = ReplicaDeviceID(uuid: UUID())
    let c = try await WireMLS.open(
      directory: directory, secretStore: store, deviceID: cID, relay: relay)
    try await pair(a, c)
    for _ in 0..<3 {
      _ = try await b.synchronize(localOperations: [])
      try await ack(b)
    }
    var replica = try TaskReplica(deviceID: await a.deviceID)
    try replica.createTask(title: "While C is offline")
    for _ in 0..<4 {
      _ = try await a.synchronize(localOperations: replica.retainedOperations)
      try await ack(a)
    }
    let restarted = try await WireMLS.open(
      directory: directory, secretStore: store, deviceID: cID, relay: relay)
    let caughtUp = try await restarted.synchronize(localOperations: [])
    XCTAssertTrue(caughtUp.inbox.flatMap { $0 }.contains { $0.taskID == replica.tasks[0].id })
    try await a.remove(c.client.copyBytes())
    let removed = try await restarted.synchronize(localOperations: [])
    XCTAssertTrue(removed.removed)
    try replica.createTask(title: "After removal")
    for _ in 0..<4 {
      _ = try await a.synchronize(localOperations: replica.retainedOperations)
      try await ack(a)
    }
    let after = try await restarted.synchronize(localOperations: [])
    XCTAssertTrue(after.removed)
    XCTAssertFalse(after.inbox.flatMap { $0 }.contains { $0.taskID == replica.tasks[0].id })
  }

  func testMutualQRSubstitutionFailsBeforeAdmission() async throws {
    let relay = try delivery()
    let a = try await fresh(relay)
    let b = try await fresh(relay)
    let attacker = try await fresh(relay)
    let invite = try await a.createInvitation()
    let response = try await b.join(MLSQR(invite))
    let alienInvite = try await attacker.createInvitation()
    let alienResponse = try await fresh(relay).join(MLSQR(alienInvite))
    do {
      try await a.verifyResponse(MLSQR(alienResponse))
      XCTFail("Accepted another pairing response")
    } catch {}
    try await a.pollPairing()
    let beforeAdmission = try await a.snapshot()
    XCTAssertEqual(beforeAdmission.members.count, 1)
    try await a.verifyResponse(MLSQR(response))
    try await a.pollPairing()
    try await b.pollPairing()
    _ = try await a.synchronize(localOperations: [])
    let state = try await b.synchronize(localOperations: [])
    XCTAssertFalse(state.provisional)
  }
}

extension WireMLSTests {
  func testConcurrentCommitsConvergeAtOneEpoch() async throws {
    let relay = try delivery()
    let a = try await fresh(relay)
    let b = try await fresh(relay)
    let c = try await fresh(relay)
    try await pair(a, b)
    try await pair(a, c)
    for _ in 0..<3 {
      _ = try await b.synchronize(localOperations: [])
      try await ack(b)
    }
    let target = await c.client.copyBytes()
    async let first: Void = a.remove(target)
    async let second: Void = b.remove(target)
    _ = try await (first, second)
    for _ in 0..<4 {
      _ = try await a.synchronize(localOperations: [])
      _ = try await b.synchronize(localOperations: [])
      try await ack(a)
      try await ack(b)
    }
    let left = try await a.snapshot()
    let right = try await b.snapshot()
    XCTAssertEqual(left.members, right.members)
    XCTAssertEqual(left.members.count, 2)
    let removed = try await c.synchronize(localOperations: [])
    XCTAssertTrue(removed.removed)
  }

  @MainActor
  func testSyncEngineUsesMLSAndKeepsBothLists() async throws {
    let relay = try delivery()
    let endpoint = relay.url.deletingLastPathComponent().deletingLastPathComponent()
    let mailbox = endpoint.appendingPathComponent("v1/mailbox")
    let configurationA = try SyncConfiguration(
      relayURL: URL(string: "ws://127.0.0.1:8765/v1")!, mailboxURL: mailbox,
      storageDirectory: temporary(), invitationURLScheme: "gotsync-tests",
      endpointPolicy: .localDevelopment)
    let configurationB = try SyncConfiguration(
      relayURL: configurationA.endpoints.relayURL, mailboxURL: mailbox,
      storageDirectory: temporary(), invitationURLScheme: "gotsync-tests",
      endpointPolicy: .localDevelopment)
    let a = SyncEngine(configuration: configurationA, secretStore: MemorySecretStore())
    let b = SyncEngine(configuration: configurationB, secretStore: MemorySecretStore())
    XCTAssertTrue(a.addTask(title: "Host task"))
    XCTAssertTrue(b.addTask(title: "Joiner task"))
    a.createPrivateSync()
    try await eventually { a.invitationURL != nil }
    b.joinPrivateSync(url: a.invitationURL!)
    try await eventually { b.invitationURL != nil }
    a.joinPrivateSync(url: b.invitationURL!)
    do { try await eventually { b.hasPairingReplicaConflict } } catch {
      print("ENGINE A", a.phase, a.errorMessage as Any, a.mailboxErrorMessage as Any, a.tasks.count)
      print("ENGINE B", b.phase, b.errorMessage as Any, b.mailboxErrorMessage as Any, b.tasks.count)
      await a.stop()
      await b.stop()
      throw error
    }
    b.resolvePairingReplicaConflictKeepingBoth()
    try await eventually { a.tasks.count == 2 && b.tasks.count == 2 && b.isPaired }
    XCTAssertEqual(Set(a.tasks.compactMap(\.titleValue)), ["Host task", "Joiner task"])
    XCTAssertTrue(b.addTask(title: "Live MLS edit"))
    try await eventually { a.tasks.count == 3 }
    await a.stop()
    await b.stop()
  }

  @MainActor
  private func eventually(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(12)
    while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
    if !condition() {
      XCTFail("Timed out waiting for sync state")
      throw URLError(.timedOut)
    }
  }
}

private actor CorruptingRelay: MLSDelivery {
  let relay: MLSRelay
  var corrupt = false
  init(_ relay: MLSRelay) { self.relay = relay }
  func enable() { corrupt = true }
  func request(_ request: MLSRelayRequest) async throws -> MLSRelayReply {
    var reply = try await relay.request(request)
    if corrupt, request.operation == "fetch", let event = reply.events?.first {
      var payload = event.payload
      payload[payload.count - 1] ^= 1
      reply.events = [
        MLSEvent(
          kind: event.kind, epoch: event.epoch, payload: payload, previous: event.previous,
          pair: event.pair, cursor: event.cursor, remove: event.remove)
      ]
    }
    return reply
  }
}

extension WireMLSTests {
  func testTamperRollsBackMLSStateInboxAndCursor() async throws {
    let relay = try delivery()
    let fault = CorruptingRelay(relay)
    let a = try await fresh(relay)
    let b = try await fresh(fault)
    try await pair(a, b)
    var replica = try TaskReplica(deviceID: await a.deviceID)
    try replica.createTask(title: "Authenticated")
    for _ in 0..<3 { _ = try await a.synchronize(localOperations: replica.retainedOperations) }
    let before = try await b.snapshot()
    await fault.enable()
    do {
      _ = try await b.synchronize(localOperations: [])
      XCTFail("Tamper accepted")
    } catch {}
    let after = try await b.snapshot()
    XCTAssertEqual(before.cursor, after.cursor)
    XCTAssertEqual(before.inbox.count, after.inbox.count)
  }

  func testMLSHeaderRejectsReplayFutureEpochRelabelAndTruncation() throws {
    let group = Data("g".utf8)
    var header = Data([0, 1, 0, 2, 1, 103])
    header.appendUInt64(7)
    header.append(1)
    XCTAssertNoThrow(try MLSHeader.validate(header, group: group, epoch: 7, kind: "application"))
    XCTAssertThrowsError(
      try MLSHeader.validate(header, group: group, epoch: 8, kind: "application"))
    XCTAssertThrowsError(
      try MLSHeader.validate(header, group: group, epoch: 6, kind: "application"))
    XCTAssertThrowsError(try MLSHeader.validate(header, group: group, epoch: 7, kind: "commit"))
    XCTAssertThrowsError(
      try MLSHeader.validate(header, group: Data("other".utf8), epoch: 7, kind: "application"))
    for size in 0..<header.count {
      XCTAssertThrowsError(
        try MLSHeader.validate(header.prefix(size), group: group, epoch: 7, kind: "application"))
    }
  }
}

private final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var date = Date()
  func now() -> Date { lock.withLock { date } }
  func advance() { lock.withLock { date.addTimeInterval(901) } }
}

extension WireMLSTests {
  func testHostCancelAndExpiryKeepExistingGroupUsable() async throws {
    let relay = try delivery()
    let clock = TestClock()
    let a = try await WireMLS.open(
      directory: temporary(), secretStore: MemorySecretStore(),
      deviceID: ReplicaDeviceID(uuid: UUID()), relay: relay, now: { clock.now() })
    let b = try await fresh(relay)
    try await pair(a, b)
    _ = try await a.createInvitation()
    try await a.cancelPairing()
    let canceled = try await a.snapshot()
    XCTAssertNil(canceled.pairing)
    XCTAssertEqual(canceled.members.count, 2)
    _ = try await a.createInvitation()
    clock.advance()
    try await a.pollPairing()
    let expired = try await a.snapshot()
    XCTAssertNil(expired.pairing)
    var replica = try TaskReplica(deviceID: await a.deviceID)
    try replica.createTask(title: "After expired invitation")
    _ = try await a.synchronize(localOperations: replica.retainedOperations)
    let received = try await b.synchronize(localOperations: [])
    XCTAssertFalse(received.inbox.isEmpty)
  }

  func testOtherMemberTrafficBeforeInviterConfirmDoesNotBreakJoin() async throws {
    let relay = try delivery()
    let a = try await fresh(relay)
    let b = try await fresh(relay)
    let c = try await fresh(relay)
    try await pair(a, b)
    let invite = try await a.createInvitation()
    let response = try await c.join(MLSQR(invite))
    try await a.verifyResponse(MLSQR(response))
    try await a.pollPairing()
    try await c.pollPairing()
    _ = try await b.synchronize(localOperations: [])
    try await ack(b)
    var replica = try TaskReplica(deviceID: await b.deviceID)
    try replica.createTask(title: "Member traffic before confirm")
    _ = try await b.synchronize(localOperations: replica.retainedOperations)
    let provisional = try await c.synchronize(localOperations: [])
    XCTAssertTrue(provisional.provisional)
    _ = try await a.synchronize(localOperations: [])
    try await ack(a)
    for _ in 0..<5 {
      try await a.pollPairing()
      _ = try await a.synchronize(localOperations: [])
      _ = try await c.synchronize(localOperations: [])
      try await ack(a)
      try await ack(c)
    }
    let joined = try await c.snapshot()
    XCTAssertFalse(joined.provisional)
    XCTAssertFalse(joined.awaitingInitialSnapshot)
  }

  func testAcknowledgementRetainsNewerInboxEntries() async throws {
    let relay = try delivery()
    let a = try await fresh(relay)
    let b = try await fresh(relay)
    try await pair(a, b)
    var replica = try TaskReplica(deviceID: await a.deviceID)
    try replica.createTask(title: "First")
    _ = try await a.synchronize(localOperations: replica.retainedOperations)
    let first = try await b.synchronize(localOperations: [])
    try replica.createTask(title: "Second")
    _ = try await a.synchronize(localOperations: replica.retainedOperations)
    let both = try await b.synchronize(localOperations: [])
    XCTAssertGreaterThan(both.inbox.count, first.inbox.count)
    try await b.acknowledgeInbox(through: first.inbox.count)
    let remaining = try await b.snapshot()
    XCTAssertEqual(remaining.inbox.count, both.inbox.count - first.inbox.count)
  }

  func testAuthenticatedLeaveIsCommittedByRemainingMember() async throws {
    let relay = try delivery()
    let a = try await fresh(relay)
    let b = try await fresh(relay)
    try await pair(a, b)
    try await b.requestLeave()
    for _ in 0..<5 {
      _ = try await a.synchronize(localOperations: [])
      try await ack(a)
    }
    let removed = try await b.synchronize(localOperations: [])
    XCTAssertTrue(removed.removed)
    XCTAssertTrue(removed.leaveRequested)
    let remaining = try await a.snapshot()
    XCTAssertEqual(remaining.members.count, 1)
  }

  func testForeignOriginAndUnsolicitedCheckpointCannotImpersonateSender() async throws {
    let relay = try delivery()
    let a = try await fresh(relay)
    let b = try await fresh(relay)
    try await pair(a, b)
    var replica = try TaskReplica(deviceID: await b.deviceID)
    try replica.createTask(title: "Forged origin")
    try await a.seal(
      MLSApplication(
        version: 3, kind: "checkpoint", operations: replica.retainedOperations, final: true),
      sequence: 0)
    _ = try await a.synchronize(localOperations: [])
    let ignored = try await b.synchronize(localOperations: [])
    XCTAssertTrue(ignored.inbox.isEmpty)
    try await a.seal(
      MLSApplication(version: 3, kind: "operations", operations: replica.retainedOperations),
      sequence: 0)
    _ = try await a.synchronize(localOperations: [])
    do {
      _ = try await b.synchronize(localOperations: [])
      XCTFail("Forged direct origin accepted")
    } catch {}
  }
}

#if os(macOS)
  private struct FileSecretStore: SecretStore {
    let directory: URL
    func read(account: String) throws -> Data? {
      let url = directory.appendingPathComponent(account)
      return FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
    }
    func write(_ data: Data, account: String) throws {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(to: directory.appendingPathComponent(account), options: .atomic)
    }
    func delete(account: String) throws {
      try FileManager.default.removeItem(at: directory.appendingPathComponent(account))
    }
  }

  private actor KillAfterAcceptance: MLSDelivery {
    let relay: MLSRelay
    init(_ relay: MLSRelay) { self.relay = relay }
    func request(_ request: MLSRelayRequest) async throws -> MLSRelayReply {
      let result = try await relay.request(request)
      if request.operation == "commit" && result.accepted == true { kill(getpid(), SIGKILL) }
      return result
    }
  }

  extension WireMLSTests {
    func testCrashChild() async throws {
      let env = ProcessInfo.processInfo.environment
      guard let path = env["GOTSYNC_WIRE_CRASH_DIRECTORY"], let uuid = env["GOTSYNC_WIRE_CRASH_ID"]
      else { throw XCTSkip("Subprocess fixture only") }
      let root = URL(fileURLWithPath: path)
      let a = try await WireMLS.open(
        directory: root.appendingPathComponent("mls"),
        secretStore: FileSecretStore(directory: root.appendingPathComponent("secrets")),
        deviceID: ReplicaDeviceID(uuid: UUID(uuidString: uuid)!),
        relay: KillAfterAcceptance(try delivery()))
      try await a.pollPairing()
      XCTFail("Crash fixture did not terminate")
    }

    func testAbruptProcessDeathAfterRelayAcceptanceRecoversExactCommit() async throws {
      let relay = try delivery()
      let root = temporary()
      let uuid = UUID()
      let store = FileSecretStore(directory: root.appendingPathComponent("secrets"))
      let a = try await WireMLS.open(
        directory: root.appendingPathComponent("mls"), secretStore: store,
        deviceID: ReplicaDeviceID(uuid: uuid), relay: relay)
      let b = try await fresh(relay)
      let invitation = try await a.createInvitation()
      let response = try await b.join(MLSQR(invitation))
      try await a.verifyResponse(MLSQR(response))
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
      process.arguments = [
        "xctest", "-XCTest", "GotSyncTests.WireMLSTests/testCrashChild",
        Bundle(for: WireMLSTests.self).bundleURL.path,
      ]
      var environment = ProcessInfo.processInfo.environment
      environment["GOTSYNC_WIRE_CRASH_DIRECTORY"] = root.path
      environment["GOTSYNC_WIRE_CRASH_ID"] = uuid.uuidString
      process.environment = environment
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      let deadline = Date().addingTimeInterval(20)
      while process.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
      if process.isRunning {
        process.terminate()
        XCTFail("Crash fixture timed out")
      }
      XCTAssertEqual(process.terminationReason, .uncaughtSignal)
      XCTAssertEqual(process.terminationStatus, SIGKILL)
      let recovered = try await WireMLS.open(
        directory: root.appendingPathComponent("mls"), secretStore: store,
        deviceID: ReplicaDeviceID(uuid: uuid), relay: relay)
      for _ in 0..<4 {
        try await recovered.pollPairing()
        try await b.pollPairing()
        _ = try await recovered.synchronize(localOperations: [])
        _ = try await b.synchronize(localOperations: [])
        try await ack(b)
      }
      let joined = try await b.snapshot()
      let restored = try await recovered.snapshot()
      XCTAssertFalse(joined.provisional)
      XCTAssertNil(restored.candidate)
      XCTAssertEqual(restored.members.count, 2)
    }
  }
#endif

private actor RawMLSCommand: CoreCryptoCommand {
  let block: @Sendable (CoreCryptoContext) async throws -> Void
  var failed = false
  init(_ block: @escaping @Sendable (CoreCryptoContext) async throws -> Void) { self.block = block }
  func execute(context: CoreCryptoContext) async throws {
    do { try await block(context) } catch {
      failed = true
      throw error
    }
  }
}

private actor TestCommitTransport: MlsTransport {
  var bundle: CommitBundle?
  func sendCommitBundle(commitBundle: CommitBundle) async throws { bundle = commitBundle }
  func prepareForTransport(historySecret: HistorySecret) async -> MlsTransportData { Data() }
}

extension WireMLSTests {
  func testRawSDKCannotDecryptAfterRemoval() async throws {
    let relay = try delivery()
    let tap = RecordingRelay(try delivery())
    let root = temporary()
    let store = MemorySecretStore()
    let a = try await fresh(tap)
    let id = ReplicaDeviceID(uuid: UUID())
    let b = try await WireMLS.open(directory: root, secretStore: store, deviceID: id, relay: relay)
    try await pair(a, b)
    let saved = temporary()
    try FileManager.default.copyItem(at: root, to: saved)
    try await a.remove(b.client.copyBytes())
    let removed = try await b.synchronize(localOperations: [])
    XCTAssertTrue(removed.removed)
    var replica = try TaskReplica(deviceID: await a.deviceID)
    try replica.createTask(title: "Cryptographically excluded")
    _ = try await a.synchronize(localOperations: replica.retainedOperations)
    for _ in 0..<3 { _ = try await a.synchronize(localOperations: replica.retainedOperations) }
    let state = try await a.snapshot()
    let captured = await tap.lastApplication()
    let payload = try XCTUnwrap(captured)
    let filename = String(
      decoding: try Data(contentsOf: saved.appendingPathComponent("current")), as: UTF8.self)
    let key = try XCTUnwrap(store.read(account: "wire-mls-v3-database-key"))
    let savedDatabase = saved.appendingPathComponent(filename)
    try WireDatabaseSalt(secrets: store).prepare(savedDatabase)
    let database = try await openDatabase(
      location: savedDatabase.path, key: DatabaseKey(bytes: key))
    let crypto = try coreCryptoNew(database: database)
    let client = await b.client
    let transport = TestCommitTransport()
    let initialize = RawMLSCommand { context in
      try await context.mlsInit(clientId: client, transport: transport)
      let members = try await context.getClientIds(
        conversationId: ConversationId(bytes: Data(state.group!.utf8)))
      XCTAssertEqual(members.count, 2)
    }
    try await crypto.transactionFfi(command: initialize)
    let command = RawMLSCommand { context in
      _ = try await context.decryptMessage(
        conversationId: ConversationId(bytes: Data(state.group!.utf8)), payload: payload)
    }
    do {
      try await crypto.transactionFfi(command: command)
      XCTFail("Removed SDK store decrypted a new message")
    } catch {}
    let failed = await command.failed
    XCTAssertTrue(failed)
  }
}

private actor FixtureBytes {
  var value: Data?
  func set(_ value: Data) { self.value = value }
}

private actor ForgedWelcomeRelay: MLSDelivery {
  let relay: MLSRelay
  var welcome: MLSWelcome?
  var event: MLSEvent?
  init(_ relay: MLSRelay) { self.relay = relay }
  func install(welcome: MLSWelcome, event: MLSEvent) {
    self.welcome = welcome
    self.event = event
  }
  func request(_ request: MLSRelayRequest) async throws -> MLSRelayReply {
    if request.operation == "welcome", let welcome { return MLSRelayReply(welcome: welcome) }
    if request.operation == "fetch", let event { return MLSRelayReply(events: [event]) }
    return try await relay.request(request)
  }
}

extension WireMLSTests {
  func testForgedWelcomeContainingInviterLeafStillRequiresActualInviterSignature() async throws {
    let relay = try delivery()
    let evil = ForgedWelcomeRelay(relay)
    let root = temporary()
    let store = MemorySecretStore()
    let aID = ReplicaDeviceID(uuid: UUID())
    let a = try await WireMLS.open(directory: root, secretStore: store, deviceID: aID, relay: relay)
    let b = try await fresh(evil)
    let invitation = try await a.createInvitation()
    let response = try await b.join(MLSQR(invitation))
    let filename = String(
      decoding: try Data(contentsOf: root.appendingPathComponent("current")), as: UTF8.self)
    let key = try XCTUnwrap(store.read(account: "wire-mls-v3-database-key"))
    let hostDB = try await openDatabase(
      location: root.appendingPathComponent(filename).path, key: DatabaseKey(bytes: key))
    let host = try coreCryptoNew(database: hostDB)
    let hostKP = FixtureBytes()
    let aClient = await a.client
    let hostTransport = TestCommitTransport()
    let generate = RawMLSCommand { context in
      try await context.mlsInit(clientId: aClient, transport: hostTransport)
      let credential = try await context.conversationCredential(
        conversationId: ConversationId(bytes: Data("gotsync-local-identity-v3".utf8)))
      let kp = try await context.generateKeyPackage(credentialRef: credential, lifetime: 900)
      await hostKP.set(try kp.serialize())
    }
    try await host.transactionFfi(command: generate)
    let capturedKP = await hostKP.value
    let publicHostKP = try XCTUnwrap(capturedKP)
    let rogueRoot = temporary()
    try FileManager.default.createDirectory(at: rogueRoot, withIntermediateDirectories: true)
    let rogueDB = try await openDatabase(
      location: rogueRoot.appendingPathComponent("rogue.db").path,
      key: DatabaseKey(bytes: Data.secureRandom(count: 32)))
    let rogue = try coreCryptoNew(database: rogueDB)
    let transport = TestCommitTransport()
    let rogueID = ClientId(
      userId: try Uuid(uuid: UUID().uuidString), deviceId: DeviceId(id: 1),
      domain: "gotsync.invalid")
    let group = ConversationId(bytes: Data(invitation.group.utf8))
    let forge = RawMLSCommand { context in
      try await context.mlsInit(clientId: rogueID, transport: transport)
      let credential = try await context.addCredential(
        credential: Credential.basic(
          cipherSuite: .mls128Dhkemx25519Aes128gcmSha256Ed25519, clientId: rogueID))
      try await context.createConversation(
        conversationId: group, credentialRef: credential, externalSender: nil)
      try await context.addClientsToConversation(
        conversationId: group,
        keyPackages: [
          KeyPackage(bytes: publicHostKP), KeyPackage(bytes: response.local.keyPackage),
        ])
    }
    try await rogue.transactionFfi(command: forge)
    let capturedBundle = await transport.bundle
    let bundle = try XCTUnwrap(capturedBundle)
    let welcome = try XCTUnwrap(bundle.welcome).serialize()
    let cipher = FixtureBytes()
    let confirm = try CanonicalJSON.encoder.encode(
      MLSApplication(
        version: 3, kind: "pairConfirm", pairing: invitation.route,
        keyPackageHash: response.local.keyPackage.sha256))
    let encrypt = RawMLSCommand { context in
      await cipher.set(try await context.encryptMessage(conversationId: group, message: confirm))
    }
    try await rogue.transactionFfi(command: encrypt)
    let capturedCipher = await cipher.value
    let payload = try XCTUnwrap(capturedCipher)
    await evil.install(
      welcome: MLSWelcome(payload: welcome, group: invitation.group, cursor: 0, epoch: 1),
      event: MLSEvent(kind: "application", epoch: 1, payload: payload, previous: 0, cursor: 1))
    try await b.pollPairing()
    let staged = try await b.snapshot()
    XCTAssertTrue(staged.provisional)
    XCTAssertTrue(staged.members.contains { $0.fingerprint == invitation.local.fingerprint })
    do {
      _ = try await b.synchronize(localOperations: [])
      XCTFail("Rogue Welcome signer impersonated the inviter")
    } catch { XCTAssertEqual(error as? SyncError, .safetyCodeMismatch) }
    let rejected = try await b.snapshot()
    XCTAssertTrue(rejected.provisional)
    XCTAssertEqual(rejected.cursor, 0)
    XCTAssertTrue(rejected.inbox.isEmpty)
  }
}

extension WireMLSTests {
  func testRelinkReplacesOldSigningKeyAndTransportCapability() async throws {
    let relay = try delivery()
    let a = try await fresh(relay)
    let id = ReplicaDeviceID(uuid: UUID())
    let b = try await WireMLS.open(
      directory: temporary(), secretStore: MemorySecretStore(), deviceID: id, relay: relay)
    try await pair(a, b)
    let old = try await b.snapshot()
    let replacement = try await WireMLS.open(
      directory: temporary(), secretStore: MemorySecretStore(), deviceID: id, relay: relay)
    try await pair(a, replacement)
    let state = try await replacement.snapshot()
    XCTAssertEqual(state.members.count, 2)
    XCTAssertNotEqual(
      state.members.first { $0.deviceID == id }?.fingerprint,
      old.members.first { $0.deviceID == id }?.fingerprint)
    do {
      _ = try await relay.request(
        MLSRelayRequest(
          operation: "fetch", route: old.group!, token: old.token!,
          member: b.client.copyBytes().base64EncodedString(), cursor: old.cursor))
      XCTFail("Old transport capability survived relink")
    } catch {}
  }
}

extension WireMLSTests {
  func testDatabaseDirectoryMoveKeepsIdentityAndPendingCommit() async throws {
    let relay = try delivery()
    let root = temporary()
    let moved = temporary()
    let store = MemorySecretStore()
    let id = ReplicaDeviceID(uuid: UUID())
    let fault = LostResponseRelay(relay)
    let a = try await WireMLS.open(directory: root, secretStore: store, deviceID: id, relay: fault)
    let b = try await fresh(relay)
    let invitation = try await a.createInvitation()
    let response = try await b.join(MLSQR(invitation))
    try await a.verifyResponse(MLSQR(response))
    await fault.arm("commit")
    do {
      try await a.pollPairing()
      XCTFail("Expected lost response")
    } catch is URLError {}
    try FileManager.default.copyItem(at: root, to: moved)
    let restored = try await WireMLS.open(
      directory: moved, secretStore: store, deviceID: id, relay: relay)
    try await restored.pollPairing()
    try await b.pollPairing()
    _ = try await restored.synchronize(localOperations: [])
    let joined = try await b.synchronize(localOperations: [])
    XCTAssertFalse(joined.provisional)
    let state = try await restored.snapshot()
    XCTAssertEqual(state.members.count, 2)
    XCTAssertNil(state.candidate)
    #if os(iOS)
      let old = String(
        decoding: try Data(contentsOf: root.appendingPathComponent("current")), as: UTF8.self)
      let account =
        "keystore_salt_" + Data(root.appendingPathComponent(old).path.utf8).sha256.hexString
      XCTAssertNil(try KeychainStore(service: "wire.com").read(account: account))
    #endif
  }

  @MainActor
  func testEmptyHostKeepsJoinerLocalTasksAcrossBackgroundResume() async throws {
    let relay = try delivery()
    let mailbox = relay.url.deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("v1/mailbox")
    let a = SyncEngine(
      configuration: try SyncConfiguration(
        relayURL: URL(string: "ws://127.0.0.1:8765/v1")!, mailboxURL: mailbox,
        storageDirectory: temporary(), invitationURLScheme: "gotsync-tests",
        endpointPolicy: .localDevelopment), secretStore: MemorySecretStore())
    let b = SyncEngine(
      configuration: try SyncConfiguration(
        relayURL: URL(string: "ws://127.0.0.1:8765/v1")!, mailboxURL: mailbox,
        storageDirectory: temporary(), invitationURLScheme: "gotsync-tests",
        endpointPolicy: .localDevelopment), secretStore: MemorySecretStore())
    XCTAssertTrue(b.addTask(title: "Local survives"))
    a.createPrivateSync()
    try await eventually { a.invitationURL != nil }
    b.joinPrivateSync(url: a.invitationURL!)
    try await eventually { b.invitationURL != nil }
    a.joinPrivateSync(url: b.invitationURL!)
    try await eventually { a.isPaired && b.isPaired && a.tasks.count == 1 }
    XCTAssertEqual(b.tasks.first?.titleValue, "Local survives")
    b.applicationDidEnterBackground()
    await b.waitForBackgroundWork()
    b.applicationDidBecomeActive()
    XCTAssertTrue(a.addTask(title: "After resume"))
    try await eventually { b.tasks.count == 2 }
    await a.stop()
    await b.stop()
  }
}

private actor RecordingRelay: MLSDelivery {
  let relay: MLSRelay
  var application: Data?
  init(_ relay: MLSRelay) { self.relay = relay }
  func lastApplication() -> Data? { application }
  func request(_ request: MLSRelayRequest) async throws -> MLSRelayReply {
    let reply = try await relay.request(request)
    if request.operation == "application", reply.accepted == true {
      application = request.event?.payload
    }
    return reply
  }
}

extension WireMLSTests {
  func testIssuedWelcomeSurvivesJoinerClockExpiry() async throws {
    let relay = try delivery()
    let a = try await fresh(relay)
    let clock = TestClock()
    let b = try await WireMLS.open(
      directory: temporary(), secretStore: MemorySecretStore(),
      deviceID: ReplicaDeviceID(uuid: UUID()), relay: relay, now: { clock.now() })
    let invitation = try await a.createInvitation()
    let response = try await b.join(MLSQR(invitation))
    try await a.verifyResponse(MLSQR(response))
    try await a.pollPairing()
    clock.advance()
    try await b.pollPairing()
    _ = try await a.synchronize(localOperations: [])
    let joined = try await b.synchronize(localOperations: [])
    XCTAssertFalse(joined.provisional)
    XCTAssertEqual(joined.members.count, 2)
  }

  func testLeaveBetweenAdmissionAndConfirmPreservesInitialCheckpoint() async throws {
    let relay = try delivery()
    let a = try await fresh(relay)
    let b = try await fresh(relay)
    let c = try await fresh(relay)
    try await pair(a, b)
    let invitation = try await a.createInvitation()
    let response = try await c.join(MLSQR(invitation))
    try await a.verifyResponse(MLSQR(response))
    try await a.pollPairing()
    try await c.pollPairing()
    _ = try await b.synchronize(localOperations: [])
    try await ack(b)
    try await b.requestLeave()
    var replica = try TaskReplica(deviceID: await a.deviceID)
    try replica.createTask(title: "Initial checkpoint survives interference")
    for _ in 0..<12 {
      _ = try await a.synchronize(localOperations: replica.retainedOperations)
      try await a.pollPairing()
      try await c.pollPairing()
      _ = try await c.synchronize(localOperations: [])
      try await ack(a)
    }
    let joined = try await c.snapshot()
    XCTAssertFalse(joined.provisional)
    XCTAssertFalse(joined.awaitingInitialSnapshot)
    XCTAssertTrue(joined.inbox.flatMap { $0 }.contains { $0.taskID == replica.tasks[0].id })
  }
}

private actor DirectoryFaultRelay: MLSDelivery {
  let relay: MLSRelay
  var failed: Set<String> = []
  init(_ relay: MLSRelay) { self.relay = relay }
  func request(_ request: MLSRelayRequest) async throws -> MLSRelayReply {
    if ["createPair", "join"].contains(request.operation), failed.insert(request.operation).inserted
    {
      throw URLError(.networkConnectionLost)
    }
    return try await relay.request(request)
  }
}

extension WireMLSTests {
  func testPairDirectoryPublicationRetriesOnBothDevices() async throws {
    let relay = try delivery()
    let fault = DirectoryFaultRelay(relay)
    let a = try await fresh(fault)
    let b = try await fresh(fault)
    do {
      _ = try await a.createInvitation()
      XCTFail("Expected directory failure")
    } catch is URLError {}
    try await a.pollPairing()
    let state = try await a.snapshot()
    let invitation = try XCTUnwrap(state.pairing)
    do {
      _ = try await b.join(MLSQR(invitation))
      XCTFail("Expected directory failure")
    } catch is URLError {}
    let pending = try await b.snapshot()
    let response = try XCTUnwrap(pending.pairing)
    try await a.verifyResponse(MLSQR(response))
    for _ in 0..<8 {
      try await a.pollPairing()
      try await b.pollPairing()
      _ = try await a.synchronize(localOperations: [])
      _ = try await b.synchronize(localOperations: [])
      try await ack(a)
      try await ack(b)
    }
    let joined = try await b.snapshot()
    XCTAssertFalse(joined.provisional)
    XCTAssertNil(joined.pairing)
    XCTAssertEqual(joined.members.count, 2)
  }
}

extension WireMLSTests {
  func testPendingCommitPromotionKeepsInboxAcknowledgement() async throws {
    let relay = try delivery()
    let fault = LostResponseRelay(relay)
    let a = try await fresh(relay)
    let b = try await fresh(fault)
    let c = try await fresh(relay)
    try await pair(a, b)
    try await pair(a, c)
    _ = try await b.synchronize(localOperations: [])
    try await ack(b)
    var replica = try TaskReplica(deviceID: await a.deviceID)
    try replica.createTask(title: "Acknowledge while pending")
    _ = try await a.synchronize(localOperations: replica.retainedOperations)
    let received = try await b.synchronize(localOperations: [])
    XCTAssertFalse(received.inbox.isEmpty)
    await fault.arm("commit")
    do {
      try await b.remove(c.client.copyBytes())
      XCTFail("Expected lost response")
    } catch is URLError {}
    try await ack(b)
    let promoted = try await b.synchronize(localOperations: [])
    XCTAssertNil(promoted.candidate)
    XCTAssertTrue(promoted.inbox.isEmpty)
    XCTAssertFalse(promoted.initialMergePending)
  }
}
