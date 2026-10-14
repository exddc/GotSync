import CryptoKit
import XCTest
@testable import GotSync

final class SecurityTests: XCTestCase {
    private enum EraseBoundary: CaseIterable {
        case beforeActiveCredentialDeletion
        case beforePendingCredentialDeletion
        case beforeReplicaDeletion
        case beforeReplicaRecreation
        case beforeMarkerDeletion
    }

    func testMnemonicRoundTripAndChecksum() throws {
        let secret = Data(0..<16)
        let invitation = try Invitation(secret: secret)

        XCTAssertEqual(invitation.phrase.split(separator: " ").count, 17)
        XCTAssertEqual(try Invitation.from(phrase: invitation.phrase), invitation)
        XCTAssertEqual(try Invitation.from(url: invitation.url(scheme: "gotsync-tests"), scheme: "gotsync-tests"), invitation)

        var words = invitation.phrase.split(separator: " ").map(String.init)
        words[16] = MnemonicCodec.words[(MnemonicCodec.words.firstIndex(of: words[16])! + 1) % 256]
        XCTAssertThrowsError(try Invitation.from(phrase: words.joined(separator: " "))) {
            XCTAssertEqual($0 as? MnemonicError, .invalidChecksum)
        }

        XCTAssertThrowsError(
            try Invitation.from(
                url: URL(string: "gotsync-tests://pair?v=1&v=1&secret=\(secret.base64URLString)")!, scheme: "gotsync-tests"
            )
        ) {
            XCTAssertEqual($0 as? MnemonicError, .invalidInviteURL)
        }
    }

    func testPairingHandshakeAndDirectionalFrames() throws {
        let invitation = try Invitation(secret: Data(0..<16))
        let context = HandshakeContext.pairing(
            relayOrigin: "ws://127.0.0.1:8765",
            route: invitation.pairRoute
        )
        let initiatorKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: Data(1...32)
        )
        let responderKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: Data((1...32).reversed())
        )
        let initiator = try InitiatorHandshake(
            context: context,
            psk: invitation.pairPSK,
            privateKey: initiatorKey,
            connectionID: Data(repeating: 0x11, count: 16),
            nonceA: Data(repeating: 0x22, count: 16)
        )
        let response = try ResponderHandshake.respond(
            to: initiator.hello,
            context: context,
            psk: invitation.pairPSK,
            privateKey: responderKey,
            nonceB: Data(repeating: 0x33, count: 16)
        )
        let initiatorResult = try initiator.receive(response.response)
        let responderMaterial = try response.state.receive(initiatorResult.confirm)

        XCTAssertEqual(
            initiatorResult.material.transcriptHash,
            responderMaterial.transcriptHash
        )
        XCTAssertEqual(initiatorResult.material.pairRoot, responderMaterial.pairRoot)
        XCTAssertEqual(initiatorResult.material.pairID, responderMaterial.pairID)
        XCTAssertEqual(initiatorResult.material.safetyCode, responderMaterial.safetyCode)

        var hostSession = try initiatorResult.material.makeSecureSession(role: .host)
        var joinerSession = try responderMaterial.makeSecureSession(role: .joiner)
        let provision = Data("provision".utf8)
        let provisionFrame = try hostSession.seal(provision)
        XCTAssertEqual(try joinerSession.open(provisionFrame), provision)

        let receipt = Data("receipt".utf8)
        let receiptFrame = try joinerSession.seal(receipt)
        XCTAssertEqual(try hostSession.open(receiptFrame), receipt)
    }

    func testHandshakeRejectsTamperedConfirmation() throws {
        let invitation = try Invitation(secret: Data(repeating: 0x44, count: 16))
        let context = HandshakeContext.pairing(
            relayOrigin: "ws://127.0.0.1:8765",
            route: invitation.pairRoute
        )
        let initiator = try InitiatorHandshake(context: context, psk: invitation.pairPSK)
        var response = try ResponderHandshake.respond(
            to: initiator.hello,
            context: context,
            psk: invitation.pairPSK
        ).response
        response[response.count - 1] ^= 1

        XCTAssertThrowsError(try initiator.receive(response)) {
            XCTAssertEqual($0 as? SyncCryptoError, .invalidConfirmation)
        }
    }

    func testPairingHandshakeRejectsPeersWithoutDurableCompletion() throws {
        let invitation = try Invitation(
            secret: Data(repeating: 0x45, count: 16)
        )
        let modern = HandshakeContext.pairing(
            relayOrigin: "ws://127.0.0.1:8765",
            route: invitation.pairRoute
        )
        let legacy = HandshakeContext.pairing(
            relayOrigin: "ws://127.0.0.1:8765",
            route: invitation.pairRoute,
            pairingProtocolVersion: nil
        )

        let modernInitiator = try InitiatorHandshake(
            context: modern,
            psk: invitation.pairPSK
        )
        let legacyResponse = try ResponderHandshake.respond(
            to: modernInitiator.hello,
            context: legacy,
            psk: invitation.pairPSK
        )
        XCTAssertThrowsError(
            try modernInitiator.receive(legacyResponse.response)
        ) {
            XCTAssertEqual(
                $0 as? SyncCryptoError,
                .invalidConfirmation
            )
        }

        let legacyInitiator = try InitiatorHandshake(
            context: legacy,
            psk: invitation.pairPSK
        )
        let modernResponse = try ResponderHandshake.respond(
            to: legacyInitiator.hello,
            context: modern,
            psk: invitation.pairPSK
        )
        XCTAssertThrowsError(
            try legacyInitiator.receive(modernResponse.response)
        ) {
            XCTAssertEqual(
                $0 as? SyncCryptoError,
                .invalidConfirmation
            )
        }
    }

    func testFrameRejectsReplayAndTampering() throws {
        let key = Data(repeating: 0x55, count: 32)
        let prefix = Data(repeating: 0x66, count: 4)
        let transcript = Data(repeating: 0x77, count: 32)
        var sender = try FrameCipher(
            key: key,
            noncePrefix: prefix,
            transcriptHash: transcript,
            mode: .sync,
            direction: DeviceRole.host.wireByte
        )
        var receiver = try FrameCipher(
            key: key,
            noncePrefix: prefix,
            transcriptHash: transcript,
            mode: .sync,
            direction: DeviceRole.host.wireByte
        )
        let frame = try sender.seal(Data("hello".utf8))
        XCTAssertEqual(
            frame.hexString,
            "0100000000000000004ac77b4a4f6cc6626af0cb56075d1d76e5e24a1f1c"
        )
        XCTAssertEqual(try receiver.open(frame), Data("hello".utf8))

        XCTAssertThrowsError(try receiver.open(frame)) {
            XCTAssertEqual(
                $0 as? SyncCryptoError,
                .invalidFrameSequence(expected: 1, actual: 0)
            )
        }

        var nextFrame = try sender.seal(Data("again".utf8))
        nextFrame[nextFrame.count - 1] ^= 1
        XCTAssertThrowsError(try receiver.open(nextFrame))
    }

    func testPairingCommitMailboxRoundTrip() throws {
        let pairRoot = Data(0..<32)
        let record = try pairingCommitRecord()
        let sender = try PairingCommitMailbox(
            pairRoot: pairRoot,
            record: record,
            senderRole: .host
        )
        let receiver = try PairingCommitMailbox(
            pairRoot: pairRoot,
            record: record,
            senderRole: .host
        )

        XCTAssertEqual(try receiver.open(sender.seal()), record)
        XCTAssertEqual(
            sender.route,
            (PairingCommitMailbox.routeLabel + sender.authorization).sha256
        )
    }

    func testPairingControlVersionTwoVector() throws {
        let mailbox = try PairingReadyMailbox(
            pairRoot: Data(0..<32),
            pairID: Data(32..<48),
            hostDeviceID: Data(48..<64),
            archiveHash: Data("archive".utf8).sha256
        )
        let envelope = try mailbox.seal(
            joinerDeviceID: Data(64..<80)
        )

        XCTAssertEqual(
            mailbox.route.hexString,
            "40d096012b53dfab67c1a65f661dfcf8d90830144804d9b3d39deb462e0d85ec"
        )
        XCTAssertEqual(
            mailbox.authorization.hexString,
            "61629459738c9a16851a452f81116f48801a3802ca0f2fa1fa8b685c39b67733"
        )
        XCTAssertEqual(
            envelope.messageID.hexString,
            "e723003c883768a081147aaeb4287d29ff60121f5dced9c82c4a8a80d59949c3"
        )
        XCTAssertEqual(
            envelope.ciphertext.hexString,
            "d83bc4b191f9d81f366dedd4f739cb7a93e5ad85a007bbd19c98e4813d627a63dcc0bb770976d5ab1d3596b694d337af543934d005dc15a8800c41b4bddbdf06c5019bbdc3a859c81f1f9f8b150b7473e20778a25c2b837b389921fd42f1aa5c326dff82f3abc9bb227f1c593bddb3102e1d7fb4863759f5bec8f612a31f0b9fc73a3e7f2c87dd9081d140c513588801278436797397e33356210ca27cc351d2fe47bd91664e8b9ae1bc16ccebfb59116c00da75a49bafbff5a3ad882a2abd7209ac3a9105b8acb47f0ac4d0f0e2cd7a183012ec"
        )
    }

    func testPairingCommitMailboxUsesDeterministicDedupeID() throws {
        let mailbox = try PairingCommitMailbox(
            pairRoot: Data(repeating: 0x31, count: 32),
            record: pairingCommitRecord(),
            senderRole: .host
        )

        let first = try mailbox.seal()
        let retry = try mailbox.seal()

        XCTAssertEqual(first.messageID, retry.messageID)
        XCTAssertEqual(first, retry)
    }

    func testPairingCommitMailboxIsolatesDirectionsAndOperationKeys() throws {
        let pairRoot = Data(repeating: 0x41, count: 32)
        let record = try pairingCommitRecord()
        let host = try PairingCommitMailbox(
            pairRoot: pairRoot,
            record: record,
            senderRole: .host
        )
        let joiner = try PairingCommitMailbox(
            pairRoot: pairRoot,
            record: record,
            senderRole: .joiner
        )
        let operationMailbox = try MailboxKeyMaterial(
            pairRoot: pairRoot,
            pairID: record.pairID,
            senderRole: .host
        )
        let envelope = try host.seal()

        XCTAssertNotEqual(host.route, joiner.route)
        XCTAssertNotEqual(host.authorization, joiner.authorization)
        XCTAssertNotEqual(try host.seal(), try joiner.seal())
        XCTAssertNotEqual(host.route, operationMailbox.route)
        XCTAssertNotEqual(host.authorization, operationMailbox.authorization)
        XCTAssertThrowsError(try joiner.open(envelope))
        XCTAssertThrowsError(try operationMailbox.open(envelope))
    }

    func testPairingCommitMailboxRejectsTamperingAndWrongPairingTuple() throws {
        let pairRoot = Data(repeating: 0x51, count: 32)
        let record = try pairingCommitRecord()
        let mailbox = try PairingCommitMailbox(
            pairRoot: pairRoot,
            record: record,
            senderRole: .host
        )
        let envelope = try mailbox.seal()

        var tamperedCiphertext = envelope.ciphertext
        tamperedCiphertext[tamperedCiphertext.startIndex] ^= 1
        XCTAssertThrowsError(
            try mailbox.open(
                StoredMailboxEnvelope(
                    messageID: envelope.messageID,
                    ciphertext: tamperedCiphertext
                )
            )
        )

        var tamperedID = envelope.messageID
        tamperedID[tamperedID.startIndex] ^= 1
        XCTAssertThrowsError(
            try mailbox.open(
                StoredMailboxEnvelope(
                    messageID: tamperedID,
                    ciphertext: envelope.ciphertext
                )
            )
        )

        let wrongRoot = try PairingCommitMailbox(
            pairRoot: Data(repeating: 0x52, count: 32),
            record: record,
            senderRole: .host
        )
        XCTAssertThrowsError(try wrongRoot.open(envelope))

        let wrongPair = try PairingCommitMailbox(
            pairRoot: pairRoot,
            record: PairingCommitRecord(
                pairID: Data(repeating: 0x62, count: 16),
                hostDeviceID: record.hostDeviceID,
                joinerDeviceID: record.joinerDeviceID,
                archiveHash: record.archiveHash
            ),
            senderRole: .host
        )
        XCTAssertThrowsError(try wrongPair.open(envelope))

        let wrongHost = try PairingCommitMailbox(
            pairRoot: pairRoot,
            record: PairingCommitRecord(
                pairID: record.pairID,
                hostDeviceID: Data(repeating: 0x63, count: 16),
                joinerDeviceID: record.joinerDeviceID,
                archiveHash: record.archiveHash
            ),
            senderRole: .host
        )
        XCTAssertThrowsError(try wrongHost.open(envelope))

        let wrongJoiner = try PairingCommitMailbox(
            pairRoot: pairRoot,
            record: PairingCommitRecord(
                pairID: record.pairID,
                hostDeviceID: record.hostDeviceID,
                joinerDeviceID: Data(repeating: 0x64, count: 16),
                archiveHash: record.archiveHash
            ),
            senderRole: .host
        )
        XCTAssertThrowsError(try wrongJoiner.open(envelope))

        let wrongArchive = try PairingCommitMailbox(
            pairRoot: pairRoot,
            record: PairingCommitRecord(
                pairID: record.pairID,
                hostDeviceID: record.hostDeviceID,
                joinerDeviceID: record.joinerDeviceID,
                archiveHash: Data(repeating: 0x65, count: 32)
            ),
            senderRole: .host
        )
        XCTAssertThrowsError(try wrongArchive.open(envelope))
    }

    func testPairingCommitRejectsInvalidFieldLengthsAndVersion() throws {
        let record = try pairingCommitRecord()

        for length in [0, 15, 17] {
            XCTAssertThrowsError(
                try PairingCommitRecord(
                    pairID: Data(repeating: 0x71, count: length),
                    hostDeviceID: record.hostDeviceID,
                    joinerDeviceID: record.joinerDeviceID,
                    archiveHash: record.archiveHash
                )
            ) {
                XCTAssertEqual(
                    $0 as? MailboxCryptoError,
                    .invalidEnvelope
                )
            }
        }
        for length in [0, 15, 17] {
            XCTAssertThrowsError(
                try PairingCommitRecord(
                    pairID: record.pairID,
                    hostDeviceID: Data(repeating: 0x72, count: length),
                    joinerDeviceID: record.joinerDeviceID,
                    archiveHash: record.archiveHash
                )
            )
            XCTAssertThrowsError(
                try PairingCommitRecord(
                    pairID: record.pairID,
                    hostDeviceID: record.hostDeviceID,
                    joinerDeviceID: Data(repeating: 0x73, count: length),
                    archiveHash: record.archiveHash
                )
            )
        }
        for length in [0, 31, 33] {
            XCTAssertThrowsError(
                try PairingCommitRecord(
                    pairID: record.pairID,
                    hostDeviceID: record.hostDeviceID,
                    joinerDeviceID: record.joinerDeviceID,
                    archiveHash: Data(repeating: 0x74, count: length)
                )
            )
        }
        XCTAssertThrowsError(
            try PairingCommitRecord(
                version: SyncProtocol.pairingVersion &+ 1,
                pairID: record.pairID,
                hostDeviceID: record.hostDeviceID,
                joinerDeviceID: record.joinerDeviceID,
                archiveHash: record.archiveHash
            )
        )
        XCTAssertThrowsError(
            try PairingCommitRecord(
                pairID: record.pairID,
                hostDeviceID: record.hostDeviceID,
                joinerDeviceID: record.hostDeviceID,
                archiveHash: record.archiveHash
            )
        )
        for length in [0, 31, 33] {
            XCTAssertThrowsError(
                try PairingCommitMailbox(
                    pairRoot: Data(repeating: 0x75, count: length),
                    record: record,
                    senderRole: .host
                )
            ) {
                XCTAssertEqual(
                    $0 as? MailboxCryptoError,
                    .invalidCredentials
                )
            }
        }
    }

    func testKeychainThisDeviceOnlyRoundTrip() throws {
        let store = MemorySecretStore(service: "com.gotdone.relay.tests.\(UUID().uuidString)")
        let account = "secret"
        let value = Data("private".utf8)

        try store.write(value, account: account)
        XCTAssertEqual(try store.read(account: account), value)
        try store.delete(account: account)
        XCTAssertNil(try store.read(account: account))
    }

    @MainActor
    func testReplicaStorageFailureCannotRestorePairOrAcceptEdits() throws {
        let service = "com.gotdone.relay.tests.\(UUID().uuidString)"
        let keychain = MemorySecretStore(service: service)
        let credentialStore = CredentialStore(keychain: keychain)
        let identity = try InstallIdentity.loadOrCreate(store: keychain)
        try credentialStore.saveActive(
            PairCredentials(
                pairRoot: Data(repeating: 0x11, count: 32),
                pairID: Data(repeating: 0x22, count: 16),
                role: .host,
                localDeviceID: identity.deviceID,
                remoteDeviceID: Data(repeating: 0x33, count: 16)
            )
        )
        defer {
            try? credentialStore.clearPair()
            try? keychain.delete(account: InstallIdentity.account)
        }

        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }

        let model = SyncEngine(
            keychain: keychain,
            baseDirectory: blocker
        )
        XCTAssertEqual(model.phase, .failed)
        XCTAssertFalse(model.isPaired)

        model.addTask(title: "Must not become volatile")
        model.createPrivateSync()

        XCTAssertTrue(model.tasks.isEmpty)
        XCTAssertNil(model.invitationPhrase)
        XCTAssertEqual(model.phase, .failed)
    }

    @MainActor
    func testRejectedTaskTitlePreservesRecoverableEditState() throws {
        let service = "com.gotdone.relay.tests.\(UUID().uuidString)"
        let keychain = MemorySecretStore(service: service)
        let credentialStore = CredentialStore(keychain: keychain)
        let identity = try InstallIdentity.loadOrCreate(store: keychain)
        try credentialStore.saveActive(
            PairCredentials(
                pairRoot: Data(repeating: 0x21, count: 32),
                pairID: Data(repeating: 0x22, count: 16),
                role: .host,
                localDeviceID: identity.deviceID,
                remoteDeviceID: ReplicaDeviceID(uuid: UUID()).bytes
            )
        )
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? credentialStore.clearPair()
            try? keychain.delete(account: InstallIdentity.account)
            try? FileManager.default.removeItem(at: baseDirectory)
        }
        let model = SyncEngine(
            keychain: keychain,
            baseDirectory: baseDirectory
        )

        XCTAssertFalse(
            model.addTask(
                title: String(
                    repeating: "a",
                    count: ReplicaLimits.maxTitleUnicodeScalars + 1
                )
            )
        )
        XCTAssertTrue(model.tasks.isEmpty)
        XCTAssertNotNil(model.localEditErrorMessage)
        XCTAssertNotEqual(model.phase, .failed)

        XCTAssertTrue(model.addTask(title: "Accepted"))
        XCTAssertEqual(model.tasks.count, 1)
        XCTAssertNil(model.localEditErrorMessage)
        model.applicationDidEnterBackground()
    }

    @MainActor
    func testRuntimeStorageFailureRemainsFatalAcrossLifecycle() async throws {
        let service = "com.gotdone.relay.tests.\(UUID().uuidString)"
        let keychain = MemorySecretStore(service: service)
        let credentialStore = CredentialStore(keychain: keychain)
        let identity = try InstallIdentity.loadOrCreate(store: keychain)
        try credentialStore.saveActive(
            PairCredentials(
                pairRoot: Data(repeating: 0x31, count: 32),
                pairID: Data(repeating: 0x32, count: 16),
                role: .host,
                localDeviceID: identity.deviceID,
                remoteDeviceID: ReplicaDeviceID(uuid: UUID()).bytes
            )
        )
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? credentialStore.clearPair()
            try? keychain.delete(account: InstallIdentity.account)
            try? FileManager.default.removeItem(at: baseDirectory)
        }
        let model = SyncEngine(
            keychain: keychain,
            baseDirectory: baseDirectory
        )
        let persistenceURL = baseDirectory.appendingPathComponent("replica-v1.json")
        try FileManager.default.removeItem(at: persistenceURL)
        try FileManager.default.createDirectory(
            at: persistenceURL,
            withIntermediateDirectories: false
        )

        XCTAssertFalse(model.addTask(title: "Cannot persist"))
        XCTAssertEqual(model.phase, .failed)
        XCTAssertTrue(model.tasks.isEmpty)

        model.applicationDidBecomeActive()
        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertEqual(model.phase, .failed)
        XCTAssertFalse(model.addTask(title: "Still disabled"))
        XCTAssertTrue(model.tasks.isEmpty)
        model.applicationDidEnterBackground()
    }

    @MainActor
    func testCancelPairingRollsBackStagedJoinerReplica() throws {
        let service = "com.gotdone.relay.tests.\(UUID().uuidString)"
        let keychain = MemorySecretStore(service: service)
        let credentialStore = CredentialStore(keychain: keychain)
        let identity = try InstallIdentity.loadOrCreate(store: keychain)
        defer {
            try? credentialStore.clearPair()
            try? keychain.delete(account: InstallIdentity.account)
        }

        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let model = SyncEngine(
            keychain: keychain,
            baseDirectory: baseDirectory
        )
        let localDeviceID = try ReplicaDeviceID(bytes: identity.deviceID)
        var host = try TaskReplica(deviceID: ReplicaDeviceID(uuid: UUID()))
        try host.createTask(title: "Staged")
        let archive = try host.exportProvisioningArchive()
        let persistenceURL = baseDirectory.appendingPathComponent("replica-v1.json")
        let stagingURL = baseDirectory.appendingPathComponent(
            SyncEngine.pairingStagingFilename
        )
        _ = try TaskReplica.provision(
            deviceID: localDeviceID,
            from: archive,
            persistenceURL: stagingURL
        )
        try credentialStore.savePending(
            PendingPair(
                version: SyncProtocol.version,
                pairRoot: Data(repeating: 0x44, count: 32),
                pairID: Data(repeating: 0x55, count: 16),
                role: .joiner,
                localDeviceID: identity.deviceID,
                remoteDeviceID: host.deviceID.bytes,
                archiveHash: archive.sha256,
                expiresAt: Date().addingTimeInterval(120)
            )
        )

        model.cancelPairing()

        XCTAssertNil(try credentialStore.pending())
        XCTAssertTrue(
            try TaskReplica(
                deviceID: localDeviceID,
                persistenceURL: persistenceURL
            ).isEmpty
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))
        XCTAssertTrue(model.tasks.isEmpty)
    }

    @MainActor
    func testNonemptyJoinStartsWithoutChangingArchive() async throws {
        let service = "com.gotdone.relay.tests.\(UUID().uuidString)"
        let keychain = MemorySecretStore(service: service)
        let credentialStore = CredentialStore(keychain: keychain)
        _ = try InstallIdentity.loadOrCreate(store: keychain)
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? credentialStore.clearPair()
            try? keychain.delete(account: InstallIdentity.account)
            try? FileManager.default.removeItem(at: baseDirectory)
        }
        let model = SyncEngine(
            keychain: keychain,
            baseDirectory: baseDirectory
        )
        XCTAssertTrue(model.addTask(title: "Keep me"))
        let persistenceURL = baseDirectory.appendingPathComponent(
            "replica-v1.json"
        )
        let before = try Data(contentsOf: persistenceURL)
        let invitation = try Invitation(secret: Data(repeating: 0x87, count: 16))

        XCTAssertTrue(model.hasLocalReplicaHistory)
        XCTAssertTrue(model.canEditLocalTasks)
        XCTAssertTrue(model.canJoinExistingSync)

        model.joinPrivateSync(phrase: invitation.phrase)

        XCTAssertEqual(model.phase, .waitingForPeer)
        XCTAssertEqual(model.tasks.first?.titleValue, "Keep me")
        XCTAssertEqual(try Data(contentsOf: persistenceURL), before)
        XCTAssertNil(try credentialStore.pending())
        await model.stop()
    }

    @MainActor
    func testUnpairedStorageFailureDisablesLocalEditing() throws {
        let service = "com.gotdone.relay.tests.\(UUID().uuidString)"
        let keychain = MemorySecretStore(service: service)
        let credentialStore = CredentialStore(keychain: keychain)
        _ = try InstallIdentity.loadOrCreate(store: keychain)
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? credentialStore.clearPair()
            try? keychain.delete(account: InstallIdentity.account)
            try? FileManager.default.removeItem(at: baseDirectory)
        }
        let model = SyncEngine(
            keychain: keychain,
            baseDirectory: baseDirectory
        )
        XCTAssertTrue(model.addTask(title: "Existing"))
        let persistenceURL = baseDirectory.appendingPathComponent(
            "replica-v1.json"
        )
        try FileManager.default.removeItem(at: persistenceURL)
        try FileManager.default.createDirectory(
            at: persistenceURL,
            withIntermediateDirectories: false
        )

        XCTAssertFalse(model.addTask(title: "Cannot persist"))

        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.tasks.map(\.titleValue), ["Existing"])
        XCTAssertTrue(model.hasLocalReplicaHistory)
        XCTAssertFalse(model.canEditLocalTasks)
        XCTAssertNotNil(model.errorMessage)
    }

    @MainActor
    func testPendingJoinRecoveryPreservesExistingArchive() throws {
        let service = "com.gotdone.relay.tests.\(UUID().uuidString)"
        let keychain = MemorySecretStore(service: service)
        let credentialStore = CredentialStore(keychain: keychain)
        let identity = try InstallIdentity.loadOrCreate(store: keychain)
        let localDeviceID = try ReplicaDeviceID(bytes: identity.deviceID)
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? credentialStore.clearPair()
            try? keychain.delete(account: InstallIdentity.account)
            try? FileManager.default.removeItem(at: baseDirectory)
        }
        let persistenceURL = baseDirectory.appendingPathComponent(
            "replica-v1.json"
        )
        var replica = try TaskReplica(
            deviceID: localDeviceID,
            persistenceURL: persistenceURL
        )
        try replica.createTask(title: "Survives recovery")
        let before = try Data(contentsOf: persistenceURL)
        let stagingURL = baseDirectory.appendingPathComponent(
            SyncEngine.pairingStagingFilename
        )
        try Data("staged".utf8).write(to: stagingURL)
        try credentialStore.savePending(
            PendingPair(
                version: SyncProtocol.version,
                pairRoot: Data(repeating: 0x91, count: 32),
                pairID: Data(repeating: 0x92, count: 16),
                role: .joiner,
                localDeviceID: identity.deviceID,
                remoteDeviceID: ReplicaDeviceID(uuid: UUID()).bytes,
                archiveHash: Data(repeating: 0x93, count: 32),
                expiresAt: Date().addingTimeInterval(120)
            )
        )

        let recovered = SyncEngine(
            keychain: keychain,
            baseDirectory: baseDirectory
        )

        XCTAssertEqual(
            recovered.tasks.first?.titleValue,
            "Survives recovery"
        )
        XCTAssertEqual(try Data(contentsOf: persistenceURL), before)
        XCTAssertNil(try credentialStore.pending())
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))
    }

    @MainActor
    func testInterruptedEraseCompletesAcrossEveryBoundary() throws {
        for boundary in EraseBoundary.allCases {
            let service = "com.gotdone.relay.tests.\(UUID().uuidString)"
            let keychain = MemorySecretStore(service: service)
            let credentialStore = CredentialStore(keychain: keychain)
            let identity = try InstallIdentity.loadOrCreate(store: keychain)
            let localDeviceID = try ReplicaDeviceID(bytes: identity.deviceID)
            let remoteDeviceID = ReplicaDeviceID(uuid: UUID())
            let baseDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: baseDirectory,
                withIntermediateDirectories: true
            )
            let persistenceURL = baseDirectory.appendingPathComponent("replica-v1.json")
            let markerURL = baseDirectory.appendingPathComponent(
                SyncEngine.eraseMarkerFilename
            )

            var staleReplica = try TaskReplica(
                deviceID: localDeviceID,
                persistenceURL: persistenceURL
            )
            try staleReplica.createTask(title: "Must stay erased")
            let credentials = PairCredentials(
                pairRoot: Data(repeating: 0x61, count: 32),
                pairID: Data(repeating: 0x62, count: 16),
                role: .host,
                localDeviceID: identity.deviceID,
                remoteDeviceID: remoteDeviceID.bytes
            )
            let pending = PendingPair(
                version: SyncProtocol.version,
                pairRoot: credentials.pairRoot,
                pairID: credentials.pairID,
                role: .host,
                localDeviceID: identity.deviceID,
                remoteDeviceID: remoteDeviceID.bytes,
                archiveHash: try staleReplica.exportProvisioningArchive().sha256,
                expiresAt: Date().addingTimeInterval(120)
            )

            if boundary == .beforeActiveCredentialDeletion {
                try credentialStore.saveActive(credentials)
            }
            if boundary == .beforeActiveCredentialDeletion
                || boundary == .beforePendingCredentialDeletion
            {
                try credentialStore.savePending(pending)
            }
            if boundary == .beforeReplicaRecreation
                || boundary == .beforeMarkerDeletion
            {
                try FileManager.default.removeItem(at: persistenceURL)
            }
            if boundary == .beforeMarkerDeletion {
                _ = try TaskReplica(
                    deviceID: localDeviceID,
                    persistenceURL: persistenceURL
                )
            }
            try Data([SyncProtocol.version]).write(to: markerURL, options: .atomic)

            let recovered = SyncEngine(
                keychain: keychain,
                baseDirectory: baseDirectory
            )

            XCTAssertEqual(recovered.phase, .unpaired, "\(boundary)")
            XCTAssertFalse(recovered.isPaired, "\(boundary)")
            XCTAssertTrue(recovered.tasks.isEmpty, "\(boundary)")
            XCTAssertNil(try credentialStore.active(), "\(boundary)")
            XCTAssertNil(try credentialStore.pending(), "\(boundary)")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: markerURL.path),
                "\(boundary)"
            )
            XCTAssertTrue(
                try TaskReplica(
                    deviceID: localDeviceID,
                    persistenceURL: persistenceURL
                ).isEmpty,
                "\(boundary)"
            )

            try? credentialStore.clearPair()
            try? keychain.delete(account: InstallIdentity.account)
            try? FileManager.default.removeItem(at: baseDirectory)
        }
    }

    @MainActor
    func testEraseRemovesCredentialsReplicaAndRecoveryMarker() throws {
        let service = "com.gotdone.relay.tests.\(UUID().uuidString)"
        let keychain = MemorySecretStore(service: service)
        let credentialStore = CredentialStore(keychain: keychain)
        let identity = try InstallIdentity.loadOrCreate(store: keychain)
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? credentialStore.clearPair()
            try? keychain.delete(account: InstallIdentity.account)
            try? FileManager.default.removeItem(at: baseDirectory)
        }

        let model = SyncEngine(
            keychain: keychain,
            baseDirectory: baseDirectory
        )
        model.addTask(title: "Erase me")
        try credentialStore.saveActive(
            PairCredentials(
                pairRoot: Data(repeating: 0x71, count: 32),
                pairID: Data(repeating: 0x72, count: 16),
                role: .host,
                localDeviceID: identity.deviceID,
                remoteDeviceID: ReplicaDeviceID(uuid: UUID()).bytes
            )
        )
        let artifactSuffix = Data(repeating: 0x73, count: 16)
            .base64URLString
        let artifactURLs = [
            SyncEngine.pairingStagingFilename,
            SyncEngine.pairingMergedFilename,
            SyncEngine.pairingConflictBackupFilename,
        ].map {
            baseDirectory.appendingPathComponent(
                "\($0).\(artifactSuffix)"
            )
        }
        for url in artifactURLs {
            try Data("protected task data".utf8).write(to: url)
        }
        let unrelatedURL = baseDirectory.appendingPathComponent(
            "replica-v1.pairing.json.notes"
        )
        try Data("unrelated".utf8).write(to: unrelatedURL)

        model.eraseLocalData()

        let markerURL = baseDirectory.appendingPathComponent(
            SyncEngine.eraseMarkerFilename
        )
        let persistenceURL = baseDirectory.appendingPathComponent("replica-v1.json")
        XCTAssertEqual(model.phase, .unpaired)
        XCTAssertTrue(model.tasks.isEmpty)
        XCTAssertNil(try credentialStore.active())
        XCTAssertNil(try credentialStore.pending())
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertTrue(
            artifactURLs.allSatisfy {
                !FileManager.default.fileExists(atPath: $0.path)
            }
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: unrelatedURL.path)
        )
        XCTAssertTrue(
            try TaskReplica(
                deviceID: ReplicaDeviceID(bytes: identity.deviceID),
                persistenceURL: persistenceURL
            ).isEmpty
        )
    }

    private func pairingCommitRecord() throws -> PairingCommitRecord {
        try PairingCommitRecord(
            pairID: Data(repeating: 0x11, count: 16),
            hostDeviceID: Data(repeating: 0x21, count: 16),
            joinerDeviceID: Data(repeating: 0x31, count: 16),
            archiveHash: Data(repeating: 0x41, count: 32)
        )
    }
}
