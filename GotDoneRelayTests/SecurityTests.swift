import CryptoKit
import XCTest
@testable import GotDoneRelay

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
        XCTAssertEqual(try Invitation.from(url: invitation.url), invitation)

        var words = invitation.phrase.split(separator: " ").map(String.init)
        words[16] = MnemonicCodec.words[(MnemonicCodec.words.firstIndex(of: words[16])! + 1) % 256]
        XCTAssertThrowsError(try Invitation.from(phrase: words.joined(separator: " "))) {
            XCTAssertEqual($0 as? MnemonicError, .invalidChecksum)
        }

        XCTAssertThrowsError(
            try Invitation.from(
                url: URL(string: "gotdone://pair?v=1&v=1&secret=\(secret.base64URLString)")!
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

    func testKeychainThisDeviceOnlyRoundTrip() throws {
        let store = KeychainStore(service: "com.gotdone.relay.tests.\(UUID().uuidString)")
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
        let keychain = KeychainStore(service: service)
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

        let model = SyncAppModel(
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
        let keychain = KeychainStore(service: service)
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
        let model = SyncAppModel(
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
        let keychain = KeychainStore(service: service)
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
        let model = SyncAppModel(
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
        let keychain = KeychainStore(service: service)
        let credentialStore = CredentialStore(keychain: keychain)
        let identity = try InstallIdentity.loadOrCreate(store: keychain)
        defer {
            try? credentialStore.clearPair()
            try? keychain.delete(account: InstallIdentity.account)
        }

        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let model = SyncAppModel(
            keychain: keychain,
            baseDirectory: baseDirectory
        )
        let localDeviceID = try ReplicaDeviceID(bytes: identity.deviceID)
        var host = try TaskReplica(deviceID: ReplicaDeviceID(uuid: UUID()))
        try host.createTask(title: "Staged")
        let archive = try host.exportProvisioningArchive()
        let persistenceURL = baseDirectory.appendingPathComponent("replica-v1.json")
        _ = try TaskReplica.provision(
            deviceID: localDeviceID,
            from: archive,
            persistenceURL: persistenceURL
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
        XCTAssertTrue(model.tasks.isEmpty)
    }

    @MainActor
    func testInterruptedEraseCompletesAcrossEveryBoundary() throws {
        for boundary in EraseBoundary.allCases {
            let service = "com.gotdone.relay.tests.\(UUID().uuidString)"
            let keychain = KeychainStore(service: service)
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
                SyncAppModel.eraseMarkerFilename
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

            let recovered = SyncAppModel(
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
        let keychain = KeychainStore(service: service)
        let credentialStore = CredentialStore(keychain: keychain)
        let identity = try InstallIdentity.loadOrCreate(store: keychain)
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? credentialStore.clearPair()
            try? keychain.delete(account: InstallIdentity.account)
            try? FileManager.default.removeItem(at: baseDirectory)
        }

        let model = SyncAppModel(
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

        model.eraseLocalProofOfConcept()

        let markerURL = baseDirectory.appendingPathComponent(
            SyncAppModel.eraseMarkerFilename
        )
        let persistenceURL = baseDirectory.appendingPathComponent("replica-v1.json")
        XCTAssertEqual(model.phase, .unpaired)
        XCTAssertTrue(model.tasks.isEmpty)
        XCTAssertNil(try credentialStore.active())
        XCTAssertNil(try credentialStore.pending())
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertTrue(
            try TaskReplica(
                deviceID: ReplicaDeviceID(bytes: identity.deviceID),
                persistenceURL: persistenceURL
            ).isEmpty
        )
    }
}
