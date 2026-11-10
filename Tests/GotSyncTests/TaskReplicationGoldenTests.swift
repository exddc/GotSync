import CryptoKit
import Foundation
import XCTest
@_spi(HostJournalPreview) @testable import GotSync

@MainActor
final class TaskReplicationGoldenTests: XCTestCase {
    private var root: URL!
    private var relay: FakeMLSRelay!
    private var rendezvous: FakePairingRendezvous!
    private var stores: [String: MemorySecretStore] = [:]
    private var engines: [SyncEngine] = []

    private static let hostOrigin = try! ReplicaDeviceID(bytes: Data(repeating: 0x11, count: 16))
    private static let foreignOrigin = try! ReplicaDeviceID(bytes: Data(repeating: 0x22, count: 16))
    private static let gapOrigin = try! ReplicaDeviceID(bytes: Data(repeating: 0x33, count: 16))
    private static let member = Data(repeating: 0xA1, count: 32)
    private static let owner = Data(repeating: 0xB2, count: 32)

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        relay = FakeMLSRelay()
        rendezvous = FakePairingRendezvous()
        stores = [:]
        engines = []
    }

    override func tearDown() async throws {
        for engine in engines { await engine.stop() }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Wire messages

    func testVersion2MessageBytesMatchRecordedFixtures() throws {
        let task = ReplicaFixture.taskID(7)
        let operations = [
            TaskOperation(originDeviceID: Self.hostOrigin, originSequence: 1, lamport: 1, taskID: task,
                          mutation: .create(title: "Größe / \"quoted\"", completed: false)),
            TaskOperation(originDeviceID: Self.hostOrigin, originSequence: 2, lamport: 4, taskID: task,
                          mutation: .setTitle("Renamed")),
            TaskOperation(originDeviceID: Self.foreignOrigin, originSequence: 1, lamport: 5, taskID: task,
                          mutation: .setCompleted(true)),
            TaskOperation(originDeviceID: Self.foreignOrigin, originSequence: 2, lamport: 6, taskID: task,
                          mutation: .delete),
        ]
        let vector = try ReplicaVersionVector([Self.hostOrigin: 2, Self.foreignOrigin: 9])
        let claims = [
            OriginReservation(member: Self.member, owner: Self.owner, origins: [Self.hostOrigin, Self.gapOrigin],
                              epoch: 3, cursor: 41),
            OriginReservation(member: Self.owner, owner: Self.member, origins: [], epoch: 4, cursor: 42,
                              released: true, admitted: true),
        ]
        let messages: [(String, ReplicationMessage)] = [
            ("operations", .operations(operations)),
            ("hello-provider", .hello(vector: vector, provider: Self.owner)),
            ("hello", .hello(vector: ReplicaVersionVector(), provider: nil)),
            ("reservation", .reservation(member: Self.member, origins: [Self.gapOrigin, Self.hostOrigin], epoch: 7)),
            ("release", .release(member: Self.member, reservation: 99)),
            ("reservations-overflowed", .reservations(claims, overflowed: true, for: Self.member)),
            ("reservations", .reservations([], overflowed: false, for: Self.member)),
        ]
        let recorded = Dictionary(uniqueKeysWithValues: messages.map { ($0.0, Self.digest(try! $0.1.encoded())) })
        XCTAssertEqual(recorded, Self.recordedMessageDigests)
        XCTAssertEqual(String(decoding: try messages[0].1.encoded(), as: UTF8.self), Self.recordedOperationsMessage)
    }

    // MARK: - Persisted files

    func testPersistedTaskFilesMatchRecordedFixtures() throws {
        let directory = root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let device = try ReplicaDeviceID(bytes: Data(repeating: 0x44, count: 16))
        let replicaURL = directory.appendingPathComponent("replica-v1.json")
        var replica = try TaskReplica(deviceID: device, persistenceURL: replicaURL, newOrigin: Self.hostOrigin)
        try replica.createTask(id: ReplicaFixture.taskID(1), title: "Local")
        try replica.createTask(id: ReplicaFixture.taskID(2), title: "Second", completed: true)
        try replica.setCompleted(taskID: ReplicaFixture.taskID(1), completed: true)
        try replica.applyRemote([
            TaskOperation(originDeviceID: Self.foreignOrigin, originSequence: 1, lamport: 9, taskID: ReplicaFixture.taskID(3),
                          mutation: .create(title: "Remote", completed: false)),
            TaskOperation(originDeviceID: Self.foreignOrigin, originSequence: 2, lamport: 10, taskID: ReplicaFixture.taskID(2),
                          mutation: .delete),
        ])
        XCTAssertEqual(String(decoding: try Data(contentsOf: replicaURL), as: UTF8.self), Self.recordedReplica)

        let deferredURL = directory.appendingPathComponent(DeferredOperationStore.filename)
        try DeferredOperationStore.save(replica.retainedOperations.filter { $0.originDeviceID == Self.foreignOrigin }, to: deferredURL)
        XCTAssertEqual(String(decoding: try Data(contentsOf: deferredURL), as: UTF8.self), Self.recordedDeferred)

        var obligation = ReplyObligation()
        obligation.merge(try ReplicaVersionVector([Self.hostOrigin: 1, Self.foreignOrigin: 2]), provider: false)
        obligation.merge(try ReplicaVersionVector([Self.hostOrigin: 3]), provider: true)
        obligation.addRecipient(Self.member)
        let obligationURL = directory.appendingPathComponent(ReplyObligation.filename)
        try ReplyObligation.save(obligation, to: obligationURL)
        XCTAssertEqual(String(decoding: try Data(contentsOf: obligationURL), as: UTF8.self), Self.recordedObligation)

        var checkpoint = ReplicationCheckpoint(
            group: Data(repeating: 0x55, count: 32),
            members: [.init(deviceID: device.bytes, fingerprint: Self.owner)],
            joinPending: true,
            provider: Self.owner
        )
        checkpoint.setUploadedThrough(3, origin: Self.hostOrigin)
        checkpoint.pendingRemovals = [Self.member]
        checkpoint.provisionalMembers = [.init(fingerprint: Self.member, deadline: Date(timeIntervalSince1970: 1_800_000_000))]
        checkpoint.originReservations = [
            OriginReservation(member: Self.member, owner: Self.owner, origins: [Self.gapOrigin], epoch: 2, cursor: 17),
        ]
        checkpoint.reservationsVisible = false
        checkpoint.reservationsProvider = Self.owner
        checkpoint.reservationsOverflowed = true
        checkpoint.reservationAttempts = [.init(member: Self.member, origins: [Self.gapOrigin], epoch: 2, after: 16)]
        checkpoint.membersWithUnknownHistory = [Self.member]
        let checkpointURL = directory.appendingPathComponent(ReplicationCheckpoint.filename)
        try checkpoint.save(to: checkpointURL)
        XCTAssertEqual(String(decoding: try Data(contentsOf: checkpointURL), as: UTF8.self), Self.recordedCheckpoint)
    }

    // MARK: - Engine transcript

    /// A provider and own-origin reply, a gap hello and an upload, read as
    /// plaintext from the stopped peer's MLS inbox.
    func testEngineRepliesHelloAndUploadMatchRecordedTranscript() async throws {
        let host = try await seededHost("transcript-host", taskCount: 300)
        let peer = engine("transcript-peer")
        try await pair(host, peer)
        try await wait("peer converged") {
            peer.tasks.count == 300 && peer.phase == .synced && !peer.awaitsReservationsForTesting
                && host.phase == .synced && host.pendingMailboxOperationCount == 0
        }
        let hostFingerprint = try await fingerprint(host)
        let peerFingerprint = try await fingerprint(peer)
        await peer.stop()
        engines.removeAll { $0 === peer }
        let session = try XCTUnwrap(peer.mlsSessionForTesting)
        _ = try await session.synchronize()
        if let last = try await session.inbox().last {
            try await session.acknowledgeInbox(through: last.cursor)
        }

        var transcript: [ReplicationMessage] = []
        var plaintexts: [Data] = []
        func collect(_ count: Int, _ stage: String) async throws {
            try await wait(stage) {
                _ = try await session.synchronize()
                return try await session.inbox().count >= count
            }
            let inbox = try await session.inbox()
            XCTAssertEqual(inbox.count, count, stage)
            XCTAssertTrue(inbox.allSatisfy { $0.sender == hostFingerprint }, stage)
            plaintexts = inbox.map(\.plaintext)
            transcript = try plaintexts.map(ReplicationMessage.decode)
        }

        try await send(.hello(vector: try ReplicaVersionVector([Self.hostOrigin: 1]), provider: hostFingerprint), from: session)
        try await collect(3, "provider reply")
        try await send(.hello(vector: try ReplicaVersionVector([Self.hostOrigin: 299, Self.foreignOrigin: 1]), provider: nil),
                       from: session)
        try await collect(4, "own reply")
        let gapTask = ReplicaFixture.taskID(900)
        let gapCreate = TaskOperation(originDeviceID: Self.gapOrigin, originSequence: 1, lamport: 5_001, taskID: gapTask,
                                      mutation: .create(title: "Gap", completed: false))
        let gapRename = TaskOperation(originDeviceID: Self.gapOrigin, originSequence: 2, lamport: 5_002, taskID: gapTask,
                                      mutation: .setTitle("Gap closed"))
        try await send(.operations([gapRename]), from: session)
        try await collect(5, "gap hello")
        try await send(.operations([gapCreate, gapRename]), from: session)
        try await wait("gap closed") { host.tasks.contains { $0.titleValue == "Gap closed" } }
        XCTAssertTrue(host.addTask(title: "Uploaded"))
        let uploaded = try XCTUnwrap(host.tasks.first { $0.titleValue == "Uploaded" }).id
        try await collect(6, "upload")

        XCTAssertEqual(transcript.map(Self.summary), [
            "operations 256", "operations 44", "reservations 0", "operations 1", "hello 2", "operations 1",
        ])
        let replacements = [
            (hostFingerprint.base64EncodedString(), "<HOST>"),
            (peerFingerprint.base64EncodedString(), "<PEER>"),
            (uploaded.uuidString, "<UPLOADED>"),
        ]
        let normalized = plaintexts.map { Self.normalize(String(decoding: $0, as: UTF8.self), replacements) }
        XCTAssertEqual(Self.digest(Data(normalized.joined(separator: "\n").utf8)), Self.recordedTranscriptDigest)
        XCTAssertEqual(normalized[2], Self.recordedReservationsSnapshot)
        XCTAssertEqual(normalized[4], Self.recordedGapHello)

        await host.stop()
        let hostDevice = host.localDeviceID.base64EncodedString()
        let group = try await XCTUnwrapAsync(await host.mlsSessionForTesting?.group())
        let fileReplacements = replacements + [
            (hostDevice, "<HOSTDEVICE>"),
            (try ReplicaDeviceID(bytes: host.localDeviceID).description, "<HOSTDEVICE>"),
            (peer.localDeviceID.base64EncodedString(), "<PEERDEVICE>"),
            (group.base64EncodedString(), "<GROUP>"),
        ]
        let directory = root.appendingPathComponent("transcript-host")
        let replica = Self.normalize(
            String(decoding: try Data(contentsOf: directory.appendingPathComponent("replica-v1.json")), as: UTF8.self),
            fileReplacements
        )
        XCTAssertEqual(Self.digest(Data(replica.utf8)), Self.recordedHostReplicaDigest)
        let checkpoint = Self.normalize(
            String(decoding: try Data(contentsOf: directory.appendingPathComponent(ReplicationCheckpoint.filename)), as: UTF8.self),
            fileReplacements
        )
        XCTAssertEqual(checkpoint, Self.recordedHostCheckpoint)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(ReplyObligation.filename).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(DeferredOperationStore.filename).path))
    }

    // MARK: - Drain ordering

    /// Operations are applied before the drain reads the roster, and the
    /// checkpoint is copied only after those reads.
    func testDrainAppliesBeforeMemberReadsAndKeepsCheckpointChangesMadeDuringThem() async throws {
        let host = engine("drain-host")
        let peer = engine("drain-peer")
        try await pair(host, peer)
        try await wait("linked") { host.phase == .synced && peer.phase == .synced && !peer.awaitsReservationsForTesting }
        await host.stop()
        await peer.stop()
        let peerSession = try XCTUnwrap(peer.mlsSessionForTesting)
        let hostSession = try XCTUnwrap(host.mlsSessionForTesting)
        let task = ReplicaFixture.taskID(901)
        try await send(.operations([TaskOperation(originDeviceID: Self.gapOrigin, originSequence: 1, lamport: 7_001, taskID: task,
                                                  mutation: .create(title: "During drain", completed: false))]),
                       from: peerSession)
        try await send(.release(member: Self.member, reservation: 1), from: peerSession)
        try await wait("host fetched both") {
            _ = try await hostSession.synchronize()
            return try await hostSession.inbox().count == 2
        }
        let added = Data(repeating: 0xC3, count: 32)
        var observed = false
        host.drainMemberReadHookForTesting = {
            observed = true
            XCTAssertNotNil(host.replicaForTesting.task(id: task), "operations were not applied before the roster read")
            let held = try await hostSession.inbox().count
            XCTAssertEqual(held, 2, "the inbox was acknowledged before the roster read")
            try host.markProvisionalForTesting(added, deadline: Date().addingTimeInterval(600))
        }
        try await host.drainInboxForTesting()
        host.drainMemberReadHookForTesting = nil
        XCTAssertTrue(observed)
        XCTAssertTrue(host.provisionalMembersForTesting.contains(added), "a drain overwrote a checkpoint saved during its reads")
        let remaining = try await hostSession.inbox().count
        XCTAssertEqual(remaining, 0)
        XCTAssertEqual(host.tasks.first { $0.id == task }?.titleValue, "During drain")
    }

    // MARK: - Helpers

    private func engine(_ name: String) -> SyncEngine {
        let store = stores[name] ?? MemorySecretStore()
        stores[name] = store
        let engine = SyncEngine(
            configuration: try! SyncConfiguration(
                relayURL: TestEndpoints.relayURL,
                mailboxURL: TestEndpoints.mailboxURL,
                storageDirectory: root.appendingPathComponent(name),
                invitationURLScheme: "gotsync-tests",
                endpointPolicy: .localDevelopment,
                groupProfile: .legacyTaskDemo
            ),
            secretStore: store,
            backgroundMailboxScheduler: nil,
            pairingRetryDelayNanoseconds: 20_000_000,
            mlsTransport: relay,
            rendezvous: rendezvous,
            syncIntervalNanoseconds: 50_000_000
        )
        engines.append(engine)
        return engine
    }

    private func seededHost(_ name: String, taskCount: Int) async throws -> SyncEngine {
        let initial = engine(name)
        let device = try ReplicaDeviceID(bytes: initial.localDeviceID)
        await initial.stop()
        engines.removeAll { $0 === initial }
        var operations: [TaskOperation] = []
        var records: [ReplicatedTask] = []
        for index in 1...taskCount {
            let operation = TaskOperation(
                originDeviceID: Self.hostOrigin, originSequence: UInt64(index), lamport: UInt64(index),
                taskID: ReplicaFixture.taskID(index), mutation: .create(title: "Task \(index)", completed: false)
            )
            operations.append(operation)
            records.append(ReplicatedTask(
                id: operation.taskID,
                title: LWWRegister(value: "Task \(index)", stamp: operation.stamp),
                completed: LWWRegister(value: false, stamp: operation.stamp),
                deletion: nil
            ))
        }
        let toggle = TaskOperation(
            originDeviceID: Self.foreignOrigin, originSequence: 1, lamport: UInt64(taskCount + 1),
            taskID: records[0].id, mutation: .setCompleted(true)
        )
        operations.append(toggle)
        records[0].completed = LWWRegister(value: true, stamp: toggle.stamp)
        try ProtectedStorage.write(
            try ReplicaArchive(
                formatVersion: ReplicaLimits.archiveFormatVersion,
                deviceID: device,
                originDeviceID: Self.hostOrigin,
                nextLocalOriginSequence: UInt64(taskCount + 1),
                lamport: UInt64(taskCount + 1),
                versionVector: ReplicaVersionVector([Self.hostOrigin: UInt64(taskCount), Self.foreignOrigin: 1]),
                taskRecords: records,
                operations: operations
            ).canonicalData(),
            to: root.appendingPathComponent("\(name)/replica-v1.json")
        )
        return engine(name)
    }

    private func wait(
        _ stage: String,
        timeout: Duration = .seconds(20),
        file: StaticString = #filePath,
        line: UInt = #line,
        until predicate: () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while try await !predicate() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out at \(stage)", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func pair(_ host: SyncEngine, _ joiner: SyncEngine) async throws {
        try await wait("host ready to invite") { !host.canCancelPairing }
        host.createPrivateSync()
        try await wait("invitation") { host.invitationURL != nil }
        joiner.joinPrivateSync(url: try XCTUnwrap(host.invitationURL))
        try await wait("safety code") { host.isHostApprovalPending && joiner.safetyCode != nil }
        host.approveSafetyCode()
        try await wait("paired") { host.isPaired && joiner.isPaired && !host.canCancelPairing }
    }

    private func fingerprint(_ engine: SyncEngine) async throws -> Data {
        try await XCTUnwrapAsync(await engine.mlsSessionForTesting?.fingerprint())
    }

    private func send(_ message: ReplicationMessage, from session: MLSSession) async throws {
        guard case .accepted = try await session.send(message.encoded()) else {
            throw CancellationError()
        }
    }

    private static func summary(_ message: ReplicationMessage) -> String {
        switch message.kind {
        case .operations: "operations \(message.operations?.count ?? 0)"
        case .hello: "hello \(message.vector?.origins.count ?? 0)"
        case .reservations: "reservations \(message.reservations?.count ?? 0)"
        case .reservation, .release: message.kind.rawValue
        }
    }

    private static func normalize(_ text: String, _ replacements: [(String, String)]) -> String {
        var result = text
        for (value, placeholder) in replacements {
            result = result.replacingOccurrences(of: value, with: placeholder)
        }
        return result.replacingOccurrences(of: #""cursor":\d+"#, with: #""cursor":0"#, options: .regularExpression)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Fixtures

    private static let recordedMessageDigests = [
        "hello": "229adeeb1b0d80c8ed7b667ab00baa34d237d8d2b17d8ea8b3c2ea465b93970f",
        "hello-provider": "ea2ccc27939e254e3ad64359840bad3176e67c7758da2b22d805b5accb8ec28d",
        "operations": "6c7b175c3ff476f7461efcbecbecadb4b470579e85471f65396dee09f5b1c9b8",
        "release": "eeb6f381f15c99efa6127774a77cd26916c991b06f3aa113a3b2eb1372749ed3",
        "reservation": "1429cb75b4b59341bab175189cbffed8982ebc605fc9ab45903de905f66ba1fb",
        "reservations": "fd2bcfb428d4f3f899d2fdb11e55eb16585190b32052be11057ec9da0466099a",
        "reservations-overflowed": "223988f6371d2e482675ee727847f38c41ffb626676176cef0993c83befd6e64",
    ]
    private static let recordedOperationsMessage = #"{"kind":"operations","operations":[{"lamport":1,"mutation":{"completed":false,"title":"Größe / \"quoted\"","type":"create"},"originDeviceID":"EREREREREREREREREREREQ","originSequence":1,"taskID":"00000000-0000-4000-8000-000000000007"},{"lamport":4,"mutation":{"title":"Renamed","type":"setTitle"},"originDeviceID":"EREREREREREREREREREREQ","originSequence":2,"taskID":"00000000-0000-4000-8000-000000000007"},{"lamport":5,"mutation":{"completed":true,"type":"setCompleted"},"originDeviceID":"IiIiIiIiIiIiIiIiIiIiIg","originSequence":1,"taskID":"00000000-0000-4000-8000-000000000007"},{"lamport":6,"mutation":{"type":"delete"},"originDeviceID":"IiIiIiIiIiIiIiIiIiIiIg","originSequence":2,"taskID":"00000000-0000-4000-8000-000000000007"}],"version":2}"#
    private static let recordedReplica = #"{"deviceID":"RERERERERERERERERERERA","formatVersion":2,"lamport":10,"nextLocalOriginSequence":4,"operations":[{"lamport":1,"mutation":{"completed":false,"title":"Local","type":"create"},"originDeviceID":"EREREREREREREREREREREQ","originSequence":1,"taskID":"00000000-0000-4000-8000-000000000001"},{"lamport":2,"mutation":{"completed":true,"title":"Second","type":"create"},"originDeviceID":"EREREREREREREREREREREQ","originSequence":2,"taskID":"00000000-0000-4000-8000-000000000002"},{"lamport":3,"mutation":{"completed":true,"type":"setCompleted"},"originDeviceID":"EREREREREREREREREREREQ","originSequence":3,"taskID":"00000000-0000-4000-8000-000000000001"},{"lamport":9,"mutation":{"completed":false,"title":"Remote","type":"create"},"originDeviceID":"IiIiIiIiIiIiIiIiIiIiIg","originSequence":1,"taskID":"00000000-0000-4000-8000-000000000003"},{"lamport":10,"mutation":{"type":"delete"},"originDeviceID":"IiIiIiIiIiIiIiIiIiIiIg","originSequence":2,"taskID":"00000000-0000-4000-8000-000000000002"}],"originDeviceID":"EREREREREREREREREREREQ","taskRecords":[{"completed":{"stamp":{"lamport":3,"originDeviceID":"EREREREREREREREREREREQ"},"value":true},"id":"00000000-0000-4000-8000-000000000001","title":{"stamp":{"lamport":1,"originDeviceID":"EREREREREREREREREREREQ"},"value":"Local"}},{"completed":{"stamp":{"lamport":2,"originDeviceID":"EREREREREREREREREREREQ"},"value":true},"deletion":{"lamport":10,"originDeviceID":"IiIiIiIiIiIiIiIiIiIiIg"},"id":"00000000-0000-4000-8000-000000000002","title":{"stamp":{"lamport":2,"originDeviceID":"EREREREREREREREREREREQ"},"value":"Second"}},{"completed":{"stamp":{"lamport":9,"originDeviceID":"IiIiIiIiIiIiIiIiIiIiIg"},"value":false},"id":"00000000-0000-4000-8000-000000000003","title":{"stamp":{"lamport":9,"originDeviceID":"IiIiIiIiIiIiIiIiIiIiIg"},"value":"Remote"}}],"versionVector":[{"originDeviceID":"EREREREREREREREREREREQ","sequence":3},{"originDeviceID":"IiIiIiIiIiIiIiIiIiIiIg","sequence":2}]}"#
    private static let recordedDeferred = #"{"operations":[{"lamport":9,"mutation":{"completed":false,"title":"Remote","type":"create"},"originDeviceID":"IiIiIiIiIiIiIiIiIiIiIg","originSequence":1,"taskID":"00000000-0000-4000-8000-000000000003"},{"lamport":10,"mutation":{"type":"delete"},"originDeviceID":"IiIiIiIiIiIiIiIiIiIiIg","originSequence":2,"taskID":"00000000-0000-4000-8000-000000000002"}],"version":1}"#
    private static let recordedObligation = #"{"own":[{"originDeviceID":"EREREREREREREREREREREQ","sequence":1},{"originDeviceID":"IiIiIiIiIiIiIiIiIiIiIg","sequence":2}],"provided":[{"originDeviceID":"EREREREREREREREREREREQ","sequence":3}],"recipients":["oaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaE="],"version":1}"#
    private static let recordedCheckpoint = #"{"group":"VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVU=","joinPending":true,"members":[{"deviceID":"RERERERERERERERERERERA==","fingerprint":"srKysrKysrKysrKysrKysrKysrKysrKysrKysrKysrI="}],"membersWithUnknownHistory":["oaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaE="],"originReservations":[{"admitted":false,"cursor":17,"epoch":2,"member":"oaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaE=","origins":["MzMzMzMzMzMzMzMzMzMzMw"],"owner":"srKysrKysrKysrKysrKysrKysrKysrKysrKysrKysrI=","released":false}],"pendingRemovals":["oaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaE="],"provider":"srKysrKysrKysrKysrKysrKysrKysrKysrKysrKysrI=","provisionalMembers":[{"deadline":821692800,"fingerprint":"oaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaE="}],"reservationAttempts":[{"after":16,"epoch":2,"member":"oaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaE=","origins":["MzMzMzMzMzMzMzMzMzMzMw"]}],"reservationsOverflowed":true,"reservationsProvider":"srKysrKysrKysrKysrKysrKysrKysrKysrKysrKysrI=","reservationsVisible":false,"uploadOrigin":"EREREREREREREREREREREQ","uploadedThrough":3,"version":2}"#
    private static let recordedTranscriptDigest = #"8b49b2ff4f1829e5a50cf093c160afa1f1d4fb872a97c699c5c783114f7e300e"#
    private static let recordedReservationsSnapshot = #"{"kind":"reservations","member":"<PEER>","reservations":[],"version":2}"#
    private static let recordedGapHello = #"{"kind":"hello","vector":[{"originDeviceID":"EREREREREREREREREREREQ","sequence":300},{"originDeviceID":"IiIiIiIiIiIiIiIiIiIiIg","sequence":1}],"version":2}"#
    private static let recordedHostReplicaDigest = #"40ef1221727c0a69f59feb6f71e8915ab67ca54cb2a7357b74cf43d34042b47f"#
    private static let recordedHostCheckpoint = #"{"group":"<GROUP>","joinPending":false,"members":[{"deviceID":"<HOSTDEVICE>","fingerprint":"<HOST>"},{"deviceID":"<PEERDEVICE>","fingerprint":"<PEER>"}],"originReservations":[],"pendingRemovals":[],"provisionalMembers":[],"uploadOrigin":"EREREREREREREREREREREQ","uploadedThrough":301,"version":2}"#
}

private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
