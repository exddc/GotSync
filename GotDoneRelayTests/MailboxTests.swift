import Foundation
import XCTest
@testable import GotDoneRelay

final class MailboxTests: XCTestCase {
    func testPairingProvisionMailboxChunksReassemblesAndRetriesExactly()
        throws
    {
        let pairRoot = Data(0..<32)
        let pairID = Data(repeating: 0x11, count: 16)
        let hostDeviceID = Data(repeating: 0x21, count: 16)
        let archive = Data(
            repeating: 0x31,
            count: ProtocolLimits.mailboxEnvelopeBytes + 8_192
        )
        let mailbox = try PairingProvisionMailbox(
            pairRoot: pairRoot,
            pairID: pairID
        )

        let first = try mailbox.seal(
            archive: archive,
            hostDeviceID: hostDeviceID
        )
        let retry = try mailbox.seal(
            archive: archive,
            hostDeviceID: hostDeviceID
        )

        XCTAssertGreaterThan(first.count, 1)
        XCTAssertEqual(first, retry)
        XCTAssertTrue(
            first.allSatisfy {
                $0.ciphertext.count <= ProtocolLimits.mailboxEnvelopeBytes
            }
        )
        XCTAssertEqual(
            mailbox.route,
            (PairingProvisionMailbox.routeLabel + mailbox.authorization).sha256
        )
        let payload = try mailbox.open(Array(first.reversed()) + [first[0]])
        XCTAssertEqual(payload.archive, archive)
        XCTAssertEqual(payload.archiveHash, archive.sha256)
        XCTAssertEqual(payload.hostDeviceID, hostDeviceID)
    }

    func testPairingProvisionMailboxRejectsTamperingMissingChunksAndDirection()
        throws
    {
        let pairRoot = Data(repeating: 0x41, count: 32)
        let pairID = Data(repeating: 0x42, count: 16)
        let archive = Data(
            repeating: 0x43,
            count: ProtocolLimits.mailboxEnvelopeBytes + 1
        )
        let mailbox = try PairingProvisionMailbox(
            pairRoot: pairRoot,
            pairID: pairID
        )
        let envelopes = try mailbox.seal(
            archive: archive,
            hostDeviceID: Data(repeating: 0x44, count: 16)
        )

        var changedCiphertext = envelopes[0].ciphertext
        changedCiphertext[changedCiphertext.startIndex] ^= 1
        var tampered = envelopes
        tampered[0] = try StoredMailboxEnvelope(
            messageID: envelopes[0].messageID,
            ciphertext: changedCiphertext
        )
        XCTAssertThrowsError(try mailbox.open(tampered))
        XCTAssertThrowsError(try mailbox.open(Array(envelopes.dropLast())))
        XCTAssertThrowsError(
            try PairingProvisionMailbox(
                pairRoot: pairRoot,
                pairID: pairID,
                senderRole: .joiner
            )
        )
        let wrongRoot = try PairingProvisionMailbox(
            pairRoot: Data(repeating: 0x45, count: 32),
            pairID: pairID
        )
        XCTAssertThrowsError(try wrongRoot.open(envelopes))
    }

    func testPairingReadyMailboxRoundTripIsDeterministicAndBoundToTuple()
        throws
    {
        let pairRoot = Data(repeating: 0x51, count: 32)
        let pairID = Data(repeating: 0x52, count: 16)
        let hostDeviceID = Data(repeating: 0x53, count: 16)
        let joinerDeviceID = Data(repeating: 0x54, count: 16)
        let archiveHash = Data(repeating: 0x55, count: 32)
        let mailbox = try PairingReadyMailbox(
            pairRoot: pairRoot,
            pairID: pairID,
            hostDeviceID: hostDeviceID,
            archiveHash: archiveHash
        )

        let first = try mailbox.seal(joinerDeviceID: joinerDeviceID)
        let retry = try mailbox.seal(joinerDeviceID: joinerDeviceID)
        let record = try mailbox.open(first)

        XCTAssertEqual(first, retry)
        XCTAssertEqual(record.version, SyncProtocol.pairingVersion)
        XCTAssertEqual(record.pairID, pairID)
        XCTAssertEqual(record.hostDeviceID, hostDeviceID)
        XCTAssertEqual(record.joinerDeviceID, joinerDeviceID)
        XCTAssertEqual(record.archiveHash, archiveHash)
        XCTAssertEqual(
            mailbox.route,
            (PairingReadyMailbox.routeLabel + mailbox.authorization).sha256
        )

        let wrongTuple = try PairingReadyMailbox(
            pairRoot: pairRoot,
            pairID: pairID,
            hostDeviceID: hostDeviceID,
            archiveHash: Data(repeating: 0x56, count: 32)
        )
        XCTAssertThrowsError(try wrongTuple.open(first))

        var changedID = first.messageID
        changedID[changedID.startIndex] ^= 1
        XCTAssertThrowsError(
            try mailbox.open(
                StoredMailboxEnvelope(
                    messageID: changedID,
                    ciphertext: first.ciphertext
                )
            )
        )
    }

    func testPairingAbortMailboxRoundTripIsDeterministicAndDirectional()
        throws
    {
        let pairRoot = Data(repeating: 0x61, count: 32)
        let pairID = Data(repeating: 0x62, count: 16)
        let senderDeviceID = Data(repeating: 0x63, count: 16)
        let host = try PairingAbortMailbox(
            pairRoot: pairRoot,
            pairID: pairID,
            senderRole: .host
        )
        let joiner = try PairingAbortMailbox(
            pairRoot: pairRoot,
            pairID: pairID,
            senderRole: .joiner
        )

        let first = try host.seal(senderDeviceID: senderDeviceID)
        let retry = try host.seal(senderDeviceID: senderDeviceID)
        let record = try host.open(first)

        XCTAssertEqual(first, retry)
        XCTAssertEqual(record.version, SyncProtocol.pairingVersion)
        XCTAssertEqual(record.pairID, pairID)
        XCTAssertEqual(record.senderDeviceID, senderDeviceID)
        XCTAssertEqual(record.senderRole, .host)
        XCTAssertNotEqual(host.route, joiner.route)
        XCTAssertThrowsError(try joiner.open(first))

        var changedCiphertext = first.ciphertext
        changedCiphertext[changedCiphertext.startIndex] ^= 1
        XCTAssertThrowsError(
            try host.open(
                StoredMailboxEnvelope(
                    messageID: first.messageID,
                    ciphertext: changedCiphertext
                )
            )
        )
    }

    func testPairingControlV2UsesSharedLabelAndStageSeparatedRoutes()
        throws
    {
        let pairRoot = Data(repeating: 0x71, count: 32)
        let pairID = Data(repeating: 0x72, count: 16)
        let hostDeviceID = Data(repeating: 0x73, count: 16)
        let joinerDeviceID = Data(repeating: 0x74, count: 16)
        let archiveHash = Data(repeating: 0x75, count: 32)
        let provision = try PairingProvisionMailbox(
            pairRoot: pairRoot,
            pairID: pairID
        )
        let ready = try PairingReadyMailbox(
            pairRoot: pairRoot,
            pairID: pairID,
            hostDeviceID: hostDeviceID,
            archiveHash: archiveHash
        )
        let commit = try PairingCommitMailbox(
            pairRoot: pairRoot,
            record: PairingCommitRecord(
                pairID: pairID,
                hostDeviceID: hostDeviceID,
                joinerDeviceID: joinerDeviceID,
                archiveHash: archiveHash
            ),
            senderRole: .host
        )
        let abort = try PairingAbortMailbox(
            pairRoot: pairRoot,
            pairID: pairID,
            senderRole: .host
        )

        XCTAssertEqual(
            PairingProvisionMailbox.routeLabel,
            Data("com.gotdone.sync/pairing-control-route/v2".utf8)
        )
        XCTAssertEqual(
            PairingProvisionMailbox.routeLabel,
            PairingReadyMailbox.routeLabel
        )
        XCTAssertEqual(
            PairingProvisionMailbox.routeLabel,
            PairingCommitMailbox.routeLabel
        )
        XCTAssertEqual(
            PairingProvisionMailbox.routeLabel,
            PairingAbortMailbox.routeLabel
        )
        XCTAssertEqual(
            Set([
                provision.route,
                ready.route,
                commit.route,
                abort.route,
            ]).count,
            4
        )
    }

    func testStoredEnvelopeIsDeterministicAndDirectional() throws {
        let pairRoot = Data(0..<32)
        let pairID = Data(160..<176)
        let hostID = try ReplicaDeviceID(
            bytes: Data(repeating: 0x11, count: 16)
        )
        let joinerID = try ReplicaDeviceID(
            bytes: Data(repeating: 0x22, count: 16)
        )
        let operation = TaskOperation(
            originDeviceID: hostID,
            originSequence: 1,
            lamport: 1,
            taskID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            mutation: .create(title: "Offline", completed: false)
        )
        let host = try PairMailbox(
            credentials: credentials(
                pairRoot: pairRoot,
                pairID: pairID,
                role: .host,
                local: hostID,
                remote: joinerID
            )
        )
        let joiner = try PairMailbox(
            credentials: credentials(
                pairRoot: pairRoot,
                pairID: pairID,
                role: .joiner,
                local: joinerID,
                remote: hostID
            )
        )

        let first = try host.seal(operation)
        let retry = try host.seal(operation)

        XCTAssertEqual(first, retry)
        XCTAssertEqual(try joiner.open(first), operation)
        XCTAssertNotEqual(host.outbound.route, host.inbound.route)
        XCTAssertEqual(host.outbound.route, joiner.inbound.route)
        XCTAssertEqual(host.inbound.route, joiner.outbound.route)
        XCTAssertEqual(
            host.outbound.route,
            (MailboxKeyMaterial.routeLabel + host.outbound.authorization).sha256
        )
        XCTAssertThrowsError(try host.open(first))
    }

    func testStoredEnvelopeVersionOneVector() throws {
        let pairRoot = Data(0..<32)
        let pairID = Data(160..<176)
        let hostID = try ReplicaDeviceID(
            bytes: Data(repeating: 0x11, count: 16)
        )
        let joinerID = try ReplicaDeviceID(
            bytes: Data(repeating: 0x22, count: 16)
        )
        let operation = TaskOperation(
            originDeviceID: hostID,
            originSequence: 1,
            lamport: 1,
            taskID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            mutation: .create(title: "Offline", completed: false)
        )
        let host = try PairMailbox(
            credentials: credentials(
                pairRoot: pairRoot,
                pairID: pairID,
                role: .host,
                local: hostID,
                remote: joinerID
            )
        )
        let envelope = try host.seal(operation)

        XCTAssertEqual(
            host.outbound.route.hexString,
            "094c4fdd7654e4e688b4176223ec7a7edabc8b92167f78268d77b57eb4e1559e"
        )
        XCTAssertEqual(
            envelope.messageID.hexString,
            "cf5241d20e44a6afc74b4798a779646b1cf71e230d7b0204ac6cded1fe117757"
        )
        XCTAssertEqual(
            envelope.ciphertext.hexString,
            "8a45040a6c56da75cd2973c8df12a09cfc65b627c722befa87f90d6a3eb5d0c85b301fd72995abd8d36f3fe093ebb2462729fc6aada6610baf66def0cdc2753518feaba626e6fdf4a9e6e706729557b23f522d3915c0e659fc3c2ad487a8a21f76cc632d6b8125873459a375db856fc377bf55c392cf875cbfd249dcf84c237150191e5d51e5819e2c35accb5d9ce84c0aa65f51d40f43217952a50310ecdd4ea900af28085f3c7aab7c1f30a0934d02cc97099e911506422fbf4fe6c9ddb15747a56837dd4cb9f1417fea"
        )
    }

    func testStoredEnvelopeRejectsTamperingAndWrongPair() throws {
        let pairRoot = Data(repeating: 0x31, count: 32)
        let pairID = Data(repeating: 0x41, count: 16)
        let hostID = try ReplicaDeviceID(
            bytes: Data(repeating: 0x51, count: 16)
        )
        let joinerID = try ReplicaDeviceID(
            bytes: Data(repeating: 0x61, count: 16)
        )
        let operation = TaskOperation(
            originDeviceID: hostID,
            originSequence: 1,
            lamport: 1,
            taskID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            mutation: .create(title: "Private", completed: false)
        )
        let host = try PairMailbox(
            credentials: credentials(
                pairRoot: pairRoot,
                pairID: pairID,
                role: .host,
                local: hostID,
                remote: joinerID
            )
        )
        let joiner = try PairMailbox(
            credentials: credentials(
                pairRoot: pairRoot,
                pairID: pairID,
                role: .joiner,
                local: joinerID,
                remote: hostID
            )
        )
        let envelope = try host.seal(operation)

        var changedID = envelope.messageID
        changedID[changedID.startIndex] ^= 0x01
        let idTampered = try StoredMailboxEnvelope(
            messageID: changedID,
            ciphertext: envelope.ciphertext
        )
        XCTAssertThrowsError(try joiner.open(idTampered))

        var changedCiphertext = envelope.ciphertext
        changedCiphertext[changedCiphertext.startIndex] ^= 0x01
        let ciphertextTampered = try StoredMailboxEnvelope(
            messageID: envelope.messageID,
            ciphertext: changedCiphertext
        )
        XCTAssertThrowsError(try joiner.open(ciphertextTampered))

        let wrongPair = try PairMailbox(
            credentials: credentials(
                pairRoot: pairRoot,
                pairID: Data(repeating: 0x42, count: 16),
                role: .joiner,
                local: joinerID,
                remote: hostID
            )
        )
        XCTAssertThrowsError(try wrongPair.open(envelope))
    }

    func testHTTPMailboxRejectsStreamedOversizeResponse() async throws {
        MailboxURLProtocol.setResponseBody(
            Data(
                repeating: 0x7b,
                count: ProtocolLimits.mailboxRequestBytes + 1
            )
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MailboxURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
        }
        let transport = HTTPMailboxTransport(
            baseURL: SyncProtocol.defaultMailboxURL,
            session: session
        )

        do {
            _ = try await transport.fetch(
                route: Data(repeating: 0x01, count: 32),
                authorization: Data(repeating: 0x02, count: 32),
                after: 0,
                limit: 1
            )
            XCTFail("Expected the response-size limit.")
        } catch {
            XCTAssertEqual(
                error as? MailboxTransportError,
                .responseTooLarge
            )
        }
    }

    @MainActor
    func testOfflineMailboxSyncsBothDirectionsAfterSenderBackgrounds() async throws {
        let transport = MemoryMailboxTransport()
        let pairRoot = Data(repeating: 0x81, count: 32)
        let pairID = Data(repeating: 0x82, count: 16)
        let hostID = try ReplicaDeviceID(
            bytes: Data(repeating: 0x83, count: 16)
        )
        let joinerID = try ReplicaDeviceID(
            bytes: Data(repeating: 0x84, count: 16)
        )
        let hostKeychain = KeychainStore(
            service: "com.gotdone.relay.tests.\(UUID().uuidString)"
        )
        let joinerKeychain = KeychainStore(
            service: "com.gotdone.relay.tests.\(UUID().uuidString)"
        )
        let hostDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let joinerDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let hostStore = CredentialStore(keychain: hostKeychain)
        let joinerStore = CredentialStore(keychain: joinerKeychain)
        defer {
            try? hostStore.clearPair()
            try? joinerStore.clearPair()
            try? hostKeychain.delete(account: InstallIdentity.account)
            try? joinerKeychain.delete(account: InstallIdentity.account)
            try? FileManager.default.removeItem(at: hostDirectory)
            try? FileManager.default.removeItem(at: joinerDirectory)
        }

        try hostKeychain.write(hostID.bytes, account: InstallIdentity.account)
        try joinerKeychain.write(joinerID.bytes, account: InstallIdentity.account)
        try hostStore.saveActive(
            credentials(
                pairRoot: pairRoot,
                pairID: pairID,
                role: .host,
                local: hostID,
                remote: joinerID
            )
        )
        try joinerStore.saveActive(
            credentials(
                pairRoot: pairRoot,
                pairID: pairID,
                role: .joiner,
                local: joinerID,
                remote: hostID
            )
        )

        let host = SyncAppModel(
            keychain: hostKeychain,
            baseDirectory: hostDirectory,
            mailboxTransport: transport
        )
        XCTAssertTrue(host.addTask(title: "Created while joiner is closed"))
        let hostUploaded = await eventually {
            host.pendingMailboxOperationCount == 0
                && host.mailboxState == .available
        }
        XCTAssertTrue(hostUploaded)
        host.applicationDidEnterBackground()

        let joiner = SyncAppModel(
            keychain: joinerKeychain,
            baseDirectory: joinerDirectory,
            mailboxTransport: transport
        )
        let joinerReceived = await eventually {
            joiner.tasks.first?.titleValue
                == "Created while joiner is closed"
        }
        XCTAssertTrue(joinerReceived)
        let firstLiveMessageCount = await transport.liveMessageCount()
        XCTAssertEqual(firstLiveMessageCount, 0)

        XCTAssertTrue(joiner.addTask(title: "Created while host is closed"))
        let joinerUploaded = await eventually {
            joiner.pendingMailboxOperationCount == 0
        }
        XCTAssertTrue(joinerUploaded)
        joiner.applicationDidEnterBackground()
        host.applicationDidBecomeActive()

        let hostReceived = await eventually {
            Set(host.tasks.compactMap(\.titleValue)) == Set([
                "Created while joiner is closed",
                "Created while host is closed",
            ])
        }
        XCTAssertTrue(hostReceived)
        let secondLiveMessageCount = await transport.liveMessageCount()
        XCTAssertEqual(secondLiveMessageCount, 0)
        host.applicationDidEnterBackground()
    }

    @MainActor
    func testEraseWaitsForCanceledFetchBeforeForgettingRoutes() async throws {
        let pairRoot = Data(repeating: 0x91, count: 32)
        let pairID = Data(repeating: 0x92, count: 16)
        let hostID = try ReplicaDeviceID(
            bytes: Data(repeating: 0x93, count: 16)
        )
        let joinerID = try ReplicaDeviceID(
            bytes: Data(repeating: 0x94, count: 16)
        )
        let hostCredentials = credentials(
            pairRoot: pairRoot,
            pairID: pairID,
            role: .host,
            local: hostID,
            remote: joinerID
        )
        let joinerMailbox = try PairMailbox(
            credentials: credentials(
                pairRoot: pairRoot,
                pairID: pairID,
                role: .joiner,
                local: joinerID,
                remote: hostID
            )
        )
        let remoteOperation = TaskOperation(
            originDeviceID: joinerID,
            originSequence: 1,
            lamport: 1,
            taskID: UUID(uuidString: "99999999-aaaa-bbbb-cccc-dddddddddddd")!,
            mutation: .create(title: "Must remain erased", completed: false)
        )
        let transport = BlockingFetchMailboxTransport(
            page: MailboxFetchPage(
                messages: [
                    FetchedMailboxEnvelope(
                        cursor: 1,
                        envelope: try joinerMailbox.seal(remoteOperation)
                    ),
                ],
                nextCursor: 1,
                hasMore: false
            )
        )
        let keychain = KeychainStore(
            service: "com.gotdone.relay.tests.\(UUID().uuidString)"
        )
        let credentialStore = CredentialStore(keychain: keychain)
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? credentialStore.clearPair()
            try? keychain.delete(account: InstallIdentity.account)
            try? FileManager.default.removeItem(at: baseDirectory)
        }
        try keychain.write(hostID.bytes, account: InstallIdentity.account)
        try credentialStore.saveActive(hostCredentials)
        let model = SyncAppModel(
            keychain: keychain,
            baseDirectory: baseDirectory,
            mailboxTransport: transport
        )

        let fetchDeadline = Date().addingTimeInterval(5)
        var fetchStarted = false
        while Date() < fetchDeadline {
            if await transport.fetchHasStarted() {
                fetchStarted = true
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(fetchStarted)

        model.eraseLocalProofOfConcept()
        let forgottenBeforeFetchFinished =
            await transport.forgottenRouteCount()
        XCTAssertEqual(forgottenBeforeFetchFinished, 0)
        await transport.releaseFetch()

        let forgetDeadline = Date().addingTimeInterval(5)
        var routesForgotten = false
        while Date() < forgetDeadline {
            if await transport.forgottenRouteCount() == 2 {
                routesForgotten = true
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(routesForgotten)
        XCTAssertEqual(model.phase, .unpaired)
        XCTAssertTrue(model.tasks.isEmpty)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(model.tasks.isEmpty)
    }

    @MainActor
    func testUnlinkPreservesLocalTasksAndRejectsCanceledFetch() async throws {
        let pairRoot = Data(repeating: 0x95, count: 32)
        let pairID = Data(repeating: 0x96, count: 16)
        let hostID = try ReplicaDeviceID(
            bytes: Data(repeating: 0x97, count: 16)
        )
        let joinerID = try ReplicaDeviceID(
            bytes: Data(repeating: 0x98, count: 16)
        )
        let hostCredentials = credentials(
            pairRoot: pairRoot,
            pairID: pairID,
            role: .host,
            local: hostID,
            remote: joinerID
        )
        let joinerMailbox = try PairMailbox(
            credentials: credentials(
                pairRoot: pairRoot,
                pairID: pairID,
                role: .joiner,
                local: joinerID,
                remote: hostID
            )
        )
        let remoteOperation = TaskOperation(
            originDeviceID: joinerID,
            originSequence: 1,
            lamport: 2,
            taskID: UUID(
                uuidString: "99999999-bbbb-cccc-dddd-eeeeeeeeeeee"
            )!,
            mutation: .create(
                title: "Must not cross unlink",
                completed: false
            )
        )
        let transport = BlockingFetchMailboxTransport(
            page: MailboxFetchPage(
                messages: [
                    FetchedMailboxEnvelope(
                        cursor: 1,
                        envelope: try joinerMailbox.seal(remoteOperation)
                    ),
                ],
                nextCursor: 1,
                hasMore: false
            )
        )
        let keychain = KeychainStore(
            service: "com.gotdone.relay.tests.\(UUID().uuidString)"
        )
        let credentialStore = CredentialStore(keychain: keychain)
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let persistenceURL = baseDirectory
            .appendingPathComponent("replica-v1.json")
        defer {
            try? credentialStore.clearPair()
            try? keychain.delete(account: InstallIdentity.account)
            try? FileManager.default.removeItem(at: baseDirectory)
        }
        try keychain.write(hostID.bytes, account: InstallIdentity.account)
        var replica = try TaskReplica(
            deviceID: hostID,
            persistenceURL: persistenceURL
        )
        try replica.createTask(title: "Keep locally")
        let archiveBeforeUnlink = try Data(contentsOf: persistenceURL)
        try credentialStore.saveActive(hostCredentials)
        try credentialStore.saveMailboxCheckpoint(
            MailboxCheckpoint(
                pairID: pairID,
                uploadedLocalSequence: 1
            )
        )
        let model = SyncAppModel(
            keychain: keychain,
            baseDirectory: baseDirectory,
            mailboxTransport: transport
        )

        let fetchDeadline = Date().addingTimeInterval(5)
        while Date() < fetchDeadline,
              !(await transport.fetchHasStarted())
        {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let fetchDidStart = await transport.fetchHasStarted()
        XCTAssertTrue(fetchDidStart)

        model.unlinkAndKeepTasks()

        XCTAssertEqual(model.phase, .unpaired)
        XCTAssertFalse(model.isPaired)
        XCTAssertEqual(model.tasks.map(\.titleValue), ["Keep locally"])
        XCTAssertNil(try credentialStore.active())
        XCTAssertNil(try credentialStore.pending())
        XCTAssertNil(try credentialStore.mailboxCheckpoint())
        XCTAssertEqual(
            try InstallIdentity.loadOrCreate(store: keychain).deviceID,
            hostID.bytes
        )

        await transport.releaseFetch()
        let forgetDeadline = Date().addingTimeInterval(5)
        while Date() < forgetDeadline,
              await transport.forgottenRouteCount() != 2
        {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let forgottenRouteCount = await transport.forgottenRouteCount()
        XCTAssertEqual(forgottenRouteCount, 2)
        XCTAssertEqual(try Data(contentsOf: persistenceURL), archiveBeforeUnlink)

        let restarted = SyncAppModel(
            keychain: keychain,
            baseDirectory: baseDirectory,
            mailboxTransport: transport
        )
        XCTAssertFalse(restarted.isPaired)
        XCTAssertEqual(restarted.tasks.map(\.titleValue), ["Keep locally"])
    }

    @MainActor
    func testAmbiguousPutRetriesIdenticalEnvelopeAfterModelRestart() async throws {
        let pairRoot = Data(repeating: 0xa1, count: 32)
        let pairID = Data(repeating: 0xa2, count: 16)
        let hostID = try ReplicaDeviceID(
            bytes: Data(repeating: 0xa3, count: 16)
        )
        let joinerID = try ReplicaDeviceID(
            bytes: Data(repeating: 0xa4, count: 16)
        )
        let keychain = KeychainStore(
            service: "com.gotdone.relay.tests.\(UUID().uuidString)"
        )
        let credentialStore = CredentialStore(keychain: keychain)
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let transport = CrashBoundaryMailboxTransport(
            failsFirstPutAfterStore: true
        )
        defer {
            try? credentialStore.clearPair()
            try? keychain.delete(account: InstallIdentity.account)
            try? FileManager.default.removeItem(at: baseDirectory)
        }
        try keychain.write(hostID.bytes, account: InstallIdentity.account)
        try credentialStore.saveActive(
            credentials(
                pairRoot: pairRoot,
                pairID: pairID,
                role: .host,
                local: hostID,
                remote: joinerID
            )
        )

        let firstModel = SyncAppModel(
            keychain: keychain,
            baseDirectory: baseDirectory,
            mailboxTransport: transport
        )
        XCTAssertTrue(firstModel.addTask(title: "Retry exactly"))
        let failureObserved = await eventually {
            firstModel.mailboxState == .unavailable
                && firstModel.pendingMailboxOperationCount == 1
        }
        XCTAssertTrue(failureObserved)
        await firstModel.stopRuntimeForTesting()

        let restartedModel = SyncAppModel(
            keychain: keychain,
            baseDirectory: baseDirectory,
            mailboxTransport: transport
        )
        let retryCompleted = await eventually {
            restartedModel.pendingMailboxOperationCount == 0
                && restartedModel.mailboxState == .available
        }
        XCTAssertTrue(retryCompleted)
        let putAttempts = await transport.putAttempts()
        XCTAssertGreaterThanOrEqual(putAttempts.count, 2)
        XCTAssertEqual(putAttempts[0], putAttempts[1])
        XCTAssertEqual(
            try credentialStore.mailboxCheckpoint()?.uploadedLocalSequence,
            1
        )
        await restartedModel.stopRuntimeForTesting()
    }

    @MainActor
    func testAckFailureRedeliversWithoutDuplicatingReplica() async throws {
        let pairRoot = Data(repeating: 0xb1, count: 32)
        let pairID = Data(repeating: 0xb2, count: 16)
        let hostID = try ReplicaDeviceID(
            bytes: Data(repeating: 0xb3, count: 16)
        )
        let joinerID = try ReplicaDeviceID(
            bytes: Data(repeating: 0xb4, count: 16)
        )
        let hostCredentials = credentials(
            pairRoot: pairRoot,
            pairID: pairID,
            role: .host,
            local: hostID,
            remote: joinerID
        )
        let joinerMailbox = try PairMailbox(
            credentials: credentials(
                pairRoot: pairRoot,
                pairID: pairID,
                role: .joiner,
                local: joinerID,
                remote: hostID
            )
        )
        let operation = TaskOperation(
            originDeviceID: joinerID,
            originSequence: 1,
            lamport: 1,
            taskID: UUID(uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff")!,
            mutation: .create(title: "Apply once", completed: false)
        )
        let keychain = KeychainStore(
            service: "com.gotdone.relay.tests.\(UUID().uuidString)"
        )
        let credentialStore = CredentialStore(keychain: keychain)
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let transport = CrashBoundaryMailboxTransport(
            failsFirstAcknowledgement: true
        )
        defer {
            try? credentialStore.clearPair()
            try? keychain.delete(account: InstallIdentity.account)
            try? FileManager.default.removeItem(at: baseDirectory)
        }
        try keychain.write(hostID.bytes, account: InstallIdentity.account)
        try credentialStore.saveActive(hostCredentials)
        try await transport.seed(
            route: joinerMailbox.outbound.route,
            envelope: joinerMailbox.seal(operation)
        )

        let firstModel = SyncAppModel(
            keychain: keychain,
            baseDirectory: baseDirectory,
            mailboxTransport: transport
        )
        let failedAckObserved = await eventually {
            firstModel.tasks.first?.titleValue == "Apply once"
                && firstModel.mailboxState == .unavailable
        }
        XCTAssertTrue(failedAckObserved)
        await firstModel.stopRuntimeForTesting()

        let restartedModel = SyncAppModel(
            keychain: keychain,
            baseDirectory: baseDirectory,
            mailboxTransport: transport
        )
        let redeliveryAcknowledged = await eventually {
            restartedModel.tasks.first?.titleValue == "Apply once"
                && restartedModel.mailboxState == .available
        }
        XCTAssertTrue(redeliveryAcknowledged)
        let remainingMessages = await transport.liveMessageCount()
        XCTAssertEqual(remainingMessages, 0)
        let persisted = try TaskReplica(
            deviceID: hostID,
            persistenceURL: baseDirectory
                .appendingPathComponent("replica-v1.json")
        )
        XCTAssertEqual(persisted.retainedOperations, [operation])
        XCTAssertEqual(persisted.tasks.count, 1)
        await restartedModel.stopRuntimeForTesting()
    }

    @MainActor
    func testPutFailureDoesNotBlockInboundApplyAndAck() async throws {
        let pairRoot = Data(repeating: 0xc1, count: 32)
        let pairID = Data(repeating: 0xc2, count: 16)
        let hostID = try ReplicaDeviceID(
            bytes: Data(repeating: 0xc3, count: 16)
        )
        let joinerID = try ReplicaDeviceID(
            bytes: Data(repeating: 0xc4, count: 16)
        )
        let hostCredentials = credentials(
            pairRoot: pairRoot,
            pairID: pairID,
            role: .host,
            local: hostID,
            remote: joinerID
        )
        let joinerMailbox = try PairMailbox(
            credentials: credentials(
                pairRoot: pairRoot,
                pairID: pairID,
                role: .joiner,
                local: joinerID,
                remote: hostID
            )
        )
        let remoteOperation = TaskOperation(
            originDeviceID: joinerID,
            originSequence: 1,
            lamport: 2,
            taskID: UUID(uuidString: "cccccccc-dddd-eeee-ffff-000000000001")!,
            mutation: .create(title: "Inbound still arrives", completed: false)
        )
        let keychain = KeychainStore(
            service: "com.gotdone.relay.tests.\(UUID().uuidString)"
        )
        let credentialStore = CredentialStore(keychain: keychain)
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let persistenceURL = baseDirectory.appendingPathComponent(
            "replica-v1.json"
        )
        let transport = PartialFailureMailboxTransport(failPut: true)
        defer {
            try? credentialStore.clearPair()
            try? keychain.delete(account: InstallIdentity.account)
            try? FileManager.default.removeItem(at: baseDirectory)
        }
        try keychain.write(hostID.bytes, account: InstallIdentity.account)
        try credentialStore.saveActive(hostCredentials)
        var localReplica = try TaskReplica(
            deviceID: hostID,
            persistenceURL: persistenceURL
        )
        try localReplica.createTask(title: "Pending outbound")
        await transport.seed(
            route: joinerMailbox.outbound.route,
            envelope: try joinerMailbox.seal(remoteOperation)
        )

        let model = SyncAppModel(
            keychain: keychain,
            baseDirectory: baseDirectory,
            mailboxTransport: transport
        )
        let inboundApplied = await eventually {
            Set(model.tasks.compactMap(\.titleValue)) == Set([
                "Pending outbound",
                "Inbound still arrives",
            ])
                && model.mailboxState == .unavailable
        }

        XCTAssertTrue(inboundApplied)
        let acknowledgementCount = await transport.acknowledgementCount()
        XCTAssertEqual(acknowledgementCount, 1)
        XCTAssertEqual(model.pendingMailboxOperationCount, 1)
        await model.stopRuntimeForTesting()
    }

    @MainActor
    func testMailboxCapacityFailureHasActionableNotice() async throws {
        let pairRoot = Data(repeating: 0xc5, count: 32)
        let pairID = Data(repeating: 0xc6, count: 16)
        let hostID = try ReplicaDeviceID(
            bytes: Data(repeating: 0xc7, count: 16)
        )
        let joinerID = try ReplicaDeviceID(
            bytes: Data(repeating: 0xc8, count: 16)
        )
        let keychain = KeychainStore(
            service: "com.gotdone.relay.tests.\(UUID().uuidString)"
        )
        let credentialStore = CredentialStore(keychain: keychain)
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let transport = PartialFailureMailboxTransport(
            failPutAsCapacity: true
        )
        defer {
            try? credentialStore.clearPair()
            try? keychain.delete(account: InstallIdentity.account)
            try? FileManager.default.removeItem(at: baseDirectory)
        }
        try keychain.write(hostID.bytes, account: InstallIdentity.account)
        try credentialStore.saveActive(
            credentials(
                pairRoot: pairRoot,
                pairID: pairID,
                role: .host,
                local: hostID,
                remote: joinerID
            )
        )

        let model = SyncAppModel(
            keychain: keychain,
            baseDirectory: baseDirectory,
            mailboxTransport: transport
        )
        XCTAssertTrue(model.addTask(title: "Stored locally"))
        let capacityObserved = await eventually {
            model.mailboxCapacityReached
                && model.mailboxState == .unavailable
        }

        XCTAssertTrue(capacityObserved)
        XCTAssertEqual(
            model.syncNotice?.title,
            "Private mailbox is full"
        )
        XCTAssertTrue(
            model.syncNotice?.detail.contains("saved on this iPhone") == true
        )
        XCTAssertFalse(
            model.syncNotice?.detail.lowercased().contains("keep got done open")
                == true
        )
        XCTAssertFalse(model.syncNotice?.detail.contains("unlink") == true)
        XCTAssertEqual(model.pendingMailboxOperationCount, 1)
        await model.stopRuntimeForTesting()
    }

    @MainActor
    func testFetchFailureDoesNotBlockOutboundCheckpoint() async throws {
        let pairRoot = Data(repeating: 0xd1, count: 32)
        let pairID = Data(repeating: 0xd2, count: 16)
        let hostID = try ReplicaDeviceID(
            bytes: Data(repeating: 0xd3, count: 16)
        )
        let joinerID = try ReplicaDeviceID(
            bytes: Data(repeating: 0xd4, count: 16)
        )
        let keychain = KeychainStore(
            service: "com.gotdone.relay.tests.\(UUID().uuidString)"
        )
        let credentialStore = CredentialStore(keychain: keychain)
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let persistenceURL = baseDirectory.appendingPathComponent(
            "replica-v1.json"
        )
        let transport = PartialFailureMailboxTransport(failFetch: true)
        defer {
            try? credentialStore.clearPair()
            try? keychain.delete(account: InstallIdentity.account)
            try? FileManager.default.removeItem(at: baseDirectory)
        }
        try keychain.write(hostID.bytes, account: InstallIdentity.account)
        try credentialStore.saveActive(
            credentials(
                pairRoot: pairRoot,
                pairID: pairID,
                role: .host,
                local: hostID,
                remote: joinerID
            )
        )
        var localReplica = try TaskReplica(
            deviceID: hostID,
            persistenceURL: persistenceURL
        )
        try localReplica.createTask(title: "Outbound still stores")

        let model = SyncAppModel(
            keychain: keychain,
            baseDirectory: baseDirectory,
            mailboxTransport: transport
        )
        let outboundStored = await eventually {
            model.pendingMailboxOperationCount == 0
                && model.mailboxState == .unavailable
        }

        XCTAssertTrue(outboundStored)
        let putCount = await transport.putCount()
        XCTAssertEqual(putCount, 1)
        XCTAssertEqual(
            try credentialStore.mailboxCheckpoint()?.uploadedLocalSequence,
            1
        )
        await model.stopRuntimeForTesting()
    }

    @MainActor
    func testSlowOutboundPutDoesNotStopInboundPolling() async throws {
        let pairRoot = Data(repeating: 0xe1, count: 32)
        let pairID = Data(repeating: 0xe2, count: 16)
        let hostID = try ReplicaDeviceID(
            bytes: Data(repeating: 0xe3, count: 16)
        )
        let joinerID = try ReplicaDeviceID(
            bytes: Data(repeating: 0xe4, count: 16)
        )
        let keychain = KeychainStore(
            service: "com.gotdone.relay.tests.\(UUID().uuidString)"
        )
        let credentialStore = CredentialStore(keychain: keychain)
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let persistenceURL = baseDirectory
            .appendingPathComponent("replica-v1.json")
        let transport = BlockingPutMailboxTransport()
        defer {
            try? credentialStore.clearPair()
            try? keychain.delete(account: InstallIdentity.account)
            try? FileManager.default.removeItem(at: baseDirectory)
        }
        try keychain.write(hostID.bytes, account: InstallIdentity.account)
        var replica = try TaskReplica(
            deviceID: hostID,
            persistenceURL: persistenceURL
        )
        try replica.createTask(title: "Outbound backlog")
        try credentialStore.saveActive(
            credentials(
                pairRoot: pairRoot,
                pairID: pairID,
                role: .host,
                local: hostID,
                remote: joinerID
            )
        )

        let model = SyncAppModel(
            keychain: keychain,
            baseDirectory: baseDirectory,
            mailboxTransport: transport
        )
        let firstFetchDeadline = Date().addingTimeInterval(2)
        var putStarted = false
        var fetchCount = 0
        while Date() < firstFetchDeadline {
            putStarted = await transport.putHasStarted()
            fetchCount = await transport.fetchCount()
            if putStarted && fetchCount >= 1 {
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        let repeatedFetchDeadline = Date().addingTimeInterval(3)
        while Date() < repeatedFetchDeadline {
            fetchCount = await transport.fetchCount()
            if fetchCount >= 2 {
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        await transport.releasePut()

        XCTAssertTrue(putStarted)
        XCTAssertGreaterThanOrEqual(fetchCount, 2)
        await model.stopRuntimeForTesting()
    }

    private func credentials(
        pairRoot: Data,
        pairID: Data,
        role: DeviceRole,
        local: ReplicaDeviceID,
        remote: ReplicaDeviceID
    ) -> PairCredentials {
        PairCredentials(
            pairRoot: pairRoot,
            pairID: pairID,
            role: role,
            localDeviceID: local.bytes,
            remoteDeviceID: remote.bytes
        )
    }

    @MainActor
    private func eventually(
        timeout: TimeInterval = 5,
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

}

private actor MemoryMailboxTransport: MailboxTransport {
    private struct Record {
        let cursor: UInt64
        let messageID: Data
        let ciphertextHash: Data
        var envelope: StoredMailboxEnvelope?
    }

    private var records: [Data: [Record]] = [:]
    private var nextCursor: UInt64 = 1

    func put(
        route: Data,
        authorization: Data,
        messages: [StoredMailboxEnvelope]
    ) async throws -> [MailboxStoredReceipt] {
        try authorize(route: route, authorization: authorization)
        var routeRecords = records[route, default: []]
        var receipts: [MailboxStoredReceipt] = []
        for message in messages {
            let hash = message.ciphertext.sha256
            if let existing = routeRecords.first(where: {
                $0.messageID == message.messageID
            }) {
                guard existing.ciphertextHash == hash else {
                    throw MailboxTransportError.rejected(
                        status: 409,
                        code: "messageConflict"
                    )
                }
                receipts.append(
                    MailboxStoredReceipt(
                        messageID: message.messageID,
                        cursor: existing.cursor,
                        acknowledged: existing.envelope == nil
                    )
                )
                continue
            }
            let cursor = nextCursor
            nextCursor += 1
            routeRecords.append(
                Record(
                    cursor: cursor,
                    messageID: message.messageID,
                    ciphertextHash: hash,
                    envelope: message
                )
            )
            receipts.append(
                MailboxStoredReceipt(
                    messageID: message.messageID,
                    cursor: cursor
                )
            )
        }
        records[route] = routeRecords
        return receipts
    }

    func fetch(
        route: Data,
        authorization: Data,
        after cursor: UInt64,
        limit: Int
    ) async throws -> MailboxFetchPage {
        try authorize(route: route, authorization: authorization)
        let available = records[route, default: []]
            .filter { $0.cursor > cursor && $0.envelope != nil }
            .sorted { $0.cursor < $1.cursor }
        let selected = Array(available.prefix(limit))
        let messages = selected.compactMap { record in
            record.envelope.map {
                FetchedMailboxEnvelope(cursor: record.cursor, envelope: $0)
            }
        }
        return MailboxFetchPage(
            messages: messages,
            nextCursor: messages.last?.cursor ?? cursor,
            hasMore: available.count > selected.count
        )
    }

    func acknowledge(
        route: Data,
        authorization: Data,
        through cursor: UInt64
    ) async throws {
        try authorize(route: route, authorization: authorization)
        var routeRecords = records[route, default: []]
        for index in routeRecords.indices
        where routeRecords[index].cursor <= cursor {
            routeRecords[index].envelope = nil
        }
        records[route] = routeRecords
    }

    func forget(route: Data, authorization: Data) async throws {
        try authorize(route: route, authorization: authorization)
        records.removeValue(forKey: route)
    }

    func liveMessageCount() -> Int {
        records.values.reduce(0) { count, records in
            count + records.filter { $0.envelope != nil }.count
        }
    }

    private func authorize(route: Data, authorization: Data) throws {
        guard
            route
                == (MailboxKeyMaterial.routeLabel + authorization).sha256
        else {
            throw MailboxTransportError.rejected(
                status: 401,
                code: "unauthorized"
            )
        }
    }
}

private actor BlockingFetchMailboxTransport: MailboxTransport {
    private let page: MailboxFetchPage
    private var fetchContinuation:
        CheckedContinuation<MailboxFetchPage, Never>?
    private var fetchStarted = false
    private var forgottenRoutes = Set<Data>()

    init(page: MailboxFetchPage) {
        self.page = page
    }

    func put(
        route: Data,
        authorization: Data,
        messages: [StoredMailboxEnvelope]
    ) async throws -> [MailboxStoredReceipt] {
        []
    }

    func fetch(
        route: Data,
        authorization: Data,
        after cursor: UInt64,
        limit: Int
    ) async throws -> MailboxFetchPage {
        fetchStarted = true
        return await withCheckedContinuation { continuation in
            fetchContinuation = continuation
        }
    }

    func acknowledge(
        route: Data,
        authorization: Data,
        through cursor: UInt64
    ) async throws {}

    func forget(route: Data, authorization: Data) async throws {
        forgottenRoutes.insert(route)
    }

    func fetchHasStarted() -> Bool {
        fetchStarted
    }

    func releaseFetch() {
        fetchContinuation?.resume(returning: page)
        fetchContinuation = nil
    }

    func forgottenRouteCount() -> Int {
        forgottenRoutes.count
    }
}

private actor BlockingPutMailboxTransport: MailboxTransport {
    private var putContinuation: CheckedContinuation<Void, Never>?
    private var putStarted = false
    private var storedFetchCount = 0

    func put(
        route: Data,
        authorization: Data,
        messages: [StoredMailboxEnvelope]
    ) async throws -> [MailboxStoredReceipt] {
        putStarted = true
        await withCheckedContinuation { continuation in
            putContinuation = continuation
        }
        return messages.enumerated().map { index, message in
            MailboxStoredReceipt(
                messageID: message.messageID,
                cursor: UInt64(index + 1)
            )
        }
    }

    func fetch(
        route: Data,
        authorization: Data,
        after cursor: UInt64,
        limit: Int
    ) async throws -> MailboxFetchPage {
        storedFetchCount += 1
        return MailboxFetchPage(
            messages: [],
            nextCursor: cursor,
            hasMore: false
        )
    }

    func acknowledge(
        route: Data,
        authorization: Data,
        through cursor: UInt64
    ) async throws {}

    func forget(route: Data, authorization: Data) async throws {}

    func putHasStarted() -> Bool {
        putStarted
    }

    func fetchCount() -> Int {
        storedFetchCount
    }

    func releasePut() {
        putContinuation?.resume()
        putContinuation = nil
    }
}

private final class MailboxURLProtocol: URLProtocol, @unchecked Sendable {
    private static let responseLock = NSLock()
    nonisolated(unsafe) private static var responseBody = Data()

    static func setResponseBody(_ data: Data) {
        responseLock.lock()
        responseBody = data
        responseLock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.responseLock.lock()
        let body = Self.responseBody
        Self.responseLock.unlock()
        guard
            let url = request.url,
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )
        else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        let chunkSize = 16 * 1_024
        for start in stride(from: 0, to: body.count, by: chunkSize) {
            let end = min(start + chunkSize, body.count)
            client?.urlProtocol(
                self,
                didLoad: body.subdata(in: start..<end)
            )
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor CrashBoundaryMailboxTransport: MailboxTransport {
    private struct Record {
        let cursor: UInt64
        let envelope: StoredMailboxEnvelope
        var isLive: Bool
    }

    private var records: [Data: [Record]] = [:]
    private var capturedPutAttempts: [[StoredMailboxEnvelope]] = []
    private var nextCursor: UInt64 = 1
    private var shouldFailPut: Bool
    private var shouldFailAcknowledgement: Bool

    init(
        failsFirstPutAfterStore: Bool = false,
        failsFirstAcknowledgement: Bool = false
    ) {
        shouldFailPut = failsFirstPutAfterStore
        shouldFailAcknowledgement = failsFirstAcknowledgement
    }

    func seed(route: Data, envelope: StoredMailboxEnvelope) {
        records[route, default: []].append(
            Record(cursor: nextCursor, envelope: envelope, isLive: true)
        )
        nextCursor += 1
    }

    func put(
        route: Data,
        authorization: Data,
        messages: [StoredMailboxEnvelope]
    ) async throws -> [MailboxStoredReceipt] {
        capturedPutAttempts.append(messages)
        var routeRecords = records[route, default: []]
        var receipts: [MailboxStoredReceipt] = []
        for message in messages {
            if let existing = routeRecords.first(where: {
                $0.envelope.messageID == message.messageID
            }) {
                guard existing.envelope == message else {
                    throw MailboxTransportError.rejected(
                        status: 409,
                        code: "messageConflict"
                    )
                }
                receipts.append(
                    MailboxStoredReceipt(
                        messageID: message.messageID,
                        cursor: existing.cursor
                    )
                )
                continue
            }
            let cursor = nextCursor
            nextCursor += 1
            routeRecords.append(
                Record(
                    cursor: cursor,
                    envelope: message,
                    isLive: true
                )
            )
            receipts.append(
                MailboxStoredReceipt(
                    messageID: message.messageID,
                    cursor: cursor
                )
            )
        }
        records[route] = routeRecords
        if shouldFailPut {
            shouldFailPut = false
            throw URLError(.timedOut)
        }
        return receipts
    }

    func fetch(
        route: Data,
        authorization: Data,
        after cursor: UInt64,
        limit: Int
    ) async throws -> MailboxFetchPage {
        let available = records[route, default: []]
            .filter { $0.isLive && $0.cursor > cursor }
            .sorted { $0.cursor < $1.cursor }
        let selected = Array(available.prefix(limit))
        return MailboxFetchPage(
            messages: selected.map {
                FetchedMailboxEnvelope(
                    cursor: $0.cursor,
                    envelope: $0.envelope
                )
            },
            nextCursor: selected.last?.cursor ?? cursor,
            hasMore: available.count > selected.count
        )
    }

    func acknowledge(
        route: Data,
        authorization: Data,
        through cursor: UInt64
    ) async throws {
        if shouldFailAcknowledgement {
            shouldFailAcknowledgement = false
            throw URLError(.networkConnectionLost)
        }
        var routeRecords = records[route, default: []]
        for index in routeRecords.indices
        where routeRecords[index].cursor <= cursor {
            routeRecords[index].isLive = false
        }
        records[route] = routeRecords
    }

    func forget(route: Data, authorization: Data) async throws {
        records.removeValue(forKey: route)
    }

    func putAttempts() -> [[StoredMailboxEnvelope]] {
        capturedPutAttempts
    }

    func liveMessageCount() -> Int {
        records.values.reduce(0) { count, records in
            count + records.filter(\.isLive).count
        }
    }
}

private actor PartialFailureMailboxTransport: MailboxTransport {
    private let failPut: Bool
    private let failFetch: Bool
    private let failPutAsCapacity: Bool
    private var messages: [Data: [FetchedMailboxEnvelope]] = [:]
    private var storedPutCount = 0
    private var storedAcknowledgementCount = 0
    private var nextCursor: UInt64 = 1

    init(
        failPut: Bool = false,
        failFetch: Bool = false,
        failPutAsCapacity: Bool = false
    ) {
        self.failPut = failPut
        self.failFetch = failFetch
        self.failPutAsCapacity = failPutAsCapacity
    }

    func seed(route: Data, envelope: StoredMailboxEnvelope) {
        messages[route, default: []].append(
            FetchedMailboxEnvelope(
                cursor: nextCursor,
                envelope: envelope
            )
        )
        nextCursor += 1
    }

    func put(
        route: Data,
        authorization: Data,
        messages: [StoredMailboxEnvelope]
    ) async throws -> [MailboxStoredReceipt] {
        if failPutAsCapacity {
            throw MailboxTransportError.rejected(
                status: 429,
                code: "mailboxCapacity"
            )
        }
        if failPut {
            throw MailboxTransportError.rejected(
                status: 503,
                code: "temporarilyUnavailable"
            )
        }
        storedPutCount += 1
        return messages.map {
            let receipt = MailboxStoredReceipt(
                messageID: $0.messageID,
                cursor: nextCursor
            )
            nextCursor += 1
            return receipt
        }
    }

    func fetch(
        route: Data,
        authorization: Data,
        after cursor: UInt64,
        limit: Int
    ) async throws -> MailboxFetchPage {
        if failFetch {
            throw MailboxTransportError.rejected(
                status: 503,
                code: "temporarilyUnavailable"
            )
        }
        let available = messages[route, default: []]
            .filter { $0.cursor > cursor }
            .sorted { $0.cursor < $1.cursor }
        let selected = Array(available.prefix(limit))
        return MailboxFetchPage(
            messages: selected,
            nextCursor: selected.last?.cursor ?? cursor,
            hasMore: available.count > selected.count
        )
    }

    func acknowledge(
        route: Data,
        authorization: Data,
        through cursor: UInt64
    ) async throws {
        storedAcknowledgementCount += 1
        messages[route] = messages[route, default: []].filter {
            $0.cursor > cursor
        }
    }

    func forget(route: Data, authorization: Data) async throws {
        messages.removeValue(forKey: route)
    }

    func putCount() -> Int {
        storedPutCount
    }

    func acknowledgementCount() -> Int {
        storedAcknowledgementCount
    }
}
