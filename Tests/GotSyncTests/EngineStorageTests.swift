import XCTest
@testable import GotSync

final class EngineStorageTests: XCTestCase {
    private enum EraseBoundary: CaseIterable {
        case beforeLegacyCredentialDeletion
        case beforeReplicaDeletion
        case beforeReplicaRecreation
        case beforeMarkerDeletion
    }

    func testMnemonicRoundTripAndChecksum() throws {
        let secret = Data(0..<16)
        let invitation = try Invitation(
            secret: secret,
            groupID: Data(repeating: 0x01, count: 32),
            inviterFingerprint: Data(repeating: 0x02, count: 32)
        )

        XCTAssertEqual(invitation.phrase.split(separator: " ").count, 17)
        XCTAssertEqual(try Invitation.from(phrase: invitation.phrase), try Invitation(secret: secret))
        XCTAssertEqual(try Invitation.from(url: invitation.url(scheme: "gotsync-tests"), scheme: "gotsync-tests"), invitation)
        XCTAssertThrowsError(try Invitation(secret: secret).url(scheme: "gotsync-tests"))
        XCTAssertThrowsError(
            try Invitation.from(url: URL(string: "gotsync-tests://pair?v=1&secret=\(secret.base64URLString)")!, scheme: "gotsync-tests")
        ) {
            XCTAssertEqual($0 as? MnemonicError, .unsupportedVersion)
        }

        var words = invitation.phrase.split(separator: " ").map(String.init)
        words[16] = MnemonicCodec.words[(MnemonicCodec.words.firstIndex(of: words[16])! + 1) % 256]
        XCTAssertThrowsError(try Invitation.from(phrase: words.joined(separator: " "))) {
            XCTAssertEqual($0 as? MnemonicError, .invalidChecksum)
        }

        XCTAssertThrowsError(
            try Invitation.from(
                url: URL(string: "gotsync-tests://pair?v=2&v=2&secret=\(secret.base64URLString)")!, scheme: "gotsync-tests"
            )
        ) {
            XCTAssertEqual($0 as? MnemonicError, .invalidInviteURL)
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
        _ = try InstallIdentity.loadOrCreate(store: keychain)
        defer {
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
        _ = try InstallIdentity.loadOrCreate(store: keychain)
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
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
        _ = try InstallIdentity.loadOrCreate(store: keychain)
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
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
    func testNonemptyJoinStartsWithoutChangingArchive() async throws {
        let service = "com.gotdone.relay.tests.\(UUID().uuidString)"
        let keychain = MemorySecretStore(service: service)
        _ = try InstallIdentity.loadOrCreate(store: keychain)
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
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
        await model.stop()
    }

    @MainActor
    func testUnpairedStorageFailureDisablesLocalEditing() throws {
        let service = "com.gotdone.relay.tests.\(UUID().uuidString)"
        let keychain = MemorySecretStore(service: service)
        _ = try InstallIdentity.loadOrCreate(store: keychain)
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
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
    func testLegacyPendingJoinIsDiscardedAndArchivePreserved() throws {
        let service = "com.gotdone.relay.tests.\(UUID().uuidString)"
        let keychain = MemorySecretStore(service: service)
        let identity = try InstallIdentity.loadOrCreate(store: keychain)
        let localDeviceID = try ReplicaDeviceID(bytes: identity.deviceID)
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )
        defer {
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
        try keychain.write(Data("pending".utf8), account: "pending-pair-v1")

        let recovered = SyncEngine(
            keychain: keychain,
            baseDirectory: baseDirectory
        )

        XCTAssertEqual(
            recovered.tasks.first?.titleValue,
            "Survives recovery"
        )
        XCTAssertEqual(try Data(contentsOf: persistenceURL), before)
        XCTAssertNil(try keychain.read(account: "pending-pair-v1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))
    }

    @MainActor
    func testInterruptedEraseCompletesAcrossEveryBoundary() throws {
        for boundary in EraseBoundary.allCases {
            let service = "com.gotdone.relay.tests.\(UUID().uuidString)"
            let keychain = MemorySecretStore(service: service)
            let identity = try InstallIdentity.loadOrCreate(store: keychain)
            let localDeviceID = try ReplicaDeviceID(bytes: identity.deviceID)
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

            if boundary == .beforeLegacyCredentialDeletion {
                for account in LegacyLinkCredentials.accounts {
                    try keychain.write(Data("version 1".utf8), account: account)
                }
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
            XCTAssertFalse(try LegacyLinkCredentials.exist(in: keychain), "\(boundary)")
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

            try? keychain.delete(account: InstallIdentity.account)
            try? FileManager.default.removeItem(at: baseDirectory)
        }
    }

    @MainActor
    func testEraseRemovesCredentialsReplicaAndRecoveryMarker() throws {
        let service = "com.gotdone.relay.tests.\(UUID().uuidString)"
        let keychain = MemorySecretStore(service: service)
        let identity = try InstallIdentity.loadOrCreate(store: keychain)
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? keychain.delete(account: InstallIdentity.account)
            try? FileManager.default.removeItem(at: baseDirectory)
        }

        let model = SyncEngine(
            keychain: keychain,
            baseDirectory: baseDirectory
        )
        model.addTask(title: "Erase me")
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

    @MainActor
    func testDeferredOperationsAreLoadedAtLaunchAndErased() throws {
        let keychain = MemorySecretStore(service: "com.gotdone.relay.tests.\(UUID().uuidString)")
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let deferredURL = baseDirectory.appendingPathComponent(DeferredOperationStore.filename)
        let operations = (1...3).map {
            TaskOperation(
                originDeviceID: ReplicaDeviceID(uuid: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!),
                originSequence: UInt64($0),
                lamport: UInt64($0),
                taskID: UUID(),
                mutation: .create(title: "Deferred \($0)", completed: false)
            )
        }

        try DeferredOperationStore.save(operations, to: deferredURL)
        XCTAssertEqual(try DeferredOperationStore.load(from: deferredURL), operations)

        let model = SyncEngine(keychain: keychain, baseDirectory: baseDirectory)
        XCTAssertEqual(model.unappliedRemoteOperationCount, 3)
        XCTAssertEqual(model.state.unappliedRemoteOperationCount, 3)
        model.eraseLocalData()
        XCTAssertEqual(model.unappliedRemoteOperationCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: deferredURL.path))

        let unreadable = Data("not deferred operations".utf8)
        try unreadable.write(to: deferredURL)
        for _ in 0..<2 {
            let relaunched = SyncEngine(keychain: keychain, baseDirectory: baseDirectory)
            XCTAssertEqual(relaunched.phase, .failed)
            XCTAssertEqual(relaunched.errorMessage, SyncError.localStorageUnavailable.errorDescription)
            XCTAssertFalse(relaunched.isPaired)
            relaunched.createPrivateSync()
            XCTAssertNil(relaunched.invitationURL)
            XCTAssertEqual(relaunched.phase, .failed)
            XCTAssertEqual(try Data(contentsOf: deferredURL), unreadable)
        }
        let repaired = SyncEngine(keychain: keychain, baseDirectory: baseDirectory)
        repaired.eraseLocalData()
        XCTAssertEqual(repaired.phase, .unpaired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: deferredURL.path))
    }

    @MainActor
    func testReplyObligationKeepsLowestRequestAndFailsClosedWhenUnreadable() throws {
        let a = ReplicaDeviceID(uuid: UUID())
        let b = ReplicaDeviceID(uuid: UUID())
        var obligation = ReplyObligation()
        obligation.merge(try ReplicaVersionVector([a: 5, b: 2]), provider: true)
        obligation.merge(try ReplicaVersionVector([a: 3]), provider: true)
        XCTAssertEqual(obligation.provided, try ReplicaVersionVector([a: 3]))
        XCTAssertNil(obligation.own)
        obligation.advance(past: (4...6).map {
            TaskOperation(originDeviceID: a, originSequence: $0, lamport: $0, taskID: UUID(), mutation: .setCompleted(true))
        })
        XCTAssertEqual(obligation.provided, try ReplicaVersionVector([a: 6]))

        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let url = baseDirectory.appendingPathComponent(ReplyObligation.filename)
        try ReplyObligation.save(obligation, to: url)
        XCTAssertEqual(try ReplyObligation.load(from: url), obligation)
        try ReplyObligation.save(nil, to: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        let unreadable = Data("not a reply obligation".utf8)
        try unreadable.write(to: url)
        let keychain = MemorySecretStore(service: "com.gotdone.relay.tests.\(UUID().uuidString)")
        let engine = SyncEngine(keychain: keychain, baseDirectory: baseDirectory)
        XCTAssertEqual(engine.phase, .failed)
        XCTAssertEqual(engine.errorMessage, SyncError.localStorageUnavailable.errorDescription)
        XCTAssertEqual(try Data(contentsOf: url), unreadable)
        engine.eraseLocalData()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testReplyObligationStaysWithinOriginLimitAcrossRestart() throws {
        let requested = (0..<ReplicaLimits.maxOrigins).map { _ in ReplicaDeviceID(uuid: UUID()) }
        let held = (0..<ReplicaLimits.maxOrigins).map { _ in ReplicaDeviceID(uuid: UUID()) }
        let request = try ReplicaVersionVector(Dictionary(uniqueKeysWithValues: requested.map { ($0, 1) }))
        var obligation = ReplyObligation()
        obligation.merge(request, provider: true)
        obligation.merge(request, provider: false)
        obligation.advance(past: held.map {
            TaskOperation(originDeviceID: $0, originSequence: 1, lamport: 1, taskID: UUID(), mutation: .setCompleted(true))
        })
        obligation.retain(origins: held)
        let own = try XCTUnwrap(obligation.own)
        let provided = try XCTUnwrap(obligation.provided)
        XCTAssertEqual(Set(own.origins), Set(held))
        XCTAssertEqual(Set(provided.origins), Set(held))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try ReplyObligation.save(obligation, to: url)
        XCTAssertEqual(try ReplyObligation.load(from: url), obligation)
    }
}
