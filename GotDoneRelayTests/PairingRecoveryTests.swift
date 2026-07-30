import Foundation
import XCTest
@testable import GotDoneRelay

final class PairingRecoveryTests: XCTestCase {
    @MainActor
    func testHostRetriesAmbiguousMarkerPutBeforeActivation() async throws {
        let pairRoot = Data(repeating: 0x11, count: 32)
        let pairID = Data(repeating: 0x12, count: 16)
        let hostID = try ReplicaDeviceID(
            bytes: Data(repeating: 0x13, count: 16)
        )
        let joinerID = try ReplicaDeviceID(
            bytes: Data(repeating: 0x14, count: 16)
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
        try replica.createTask(title: "Host survives")
        let pending = PendingPair(
            version: SyncProtocol.version,
            pairRoot: pairRoot,
            pairID: pairID,
            role: .host,
            localDeviceID: hostID.bytes,
            remoteDeviceID: joinerID.bytes,
            archiveHash: try replica.exportProvisioningArchive().sha256,
            expiresAt: .distantPast,
            finalizationState: .commitMarkerMayHaveBeenStored
        )
        try credentialStore.savePending(pending)
        let record = try commitRecord(for: pending)
        let markerMailbox = try PairingCommitMailbox(
            pairRoot: pairRoot,
            record: record,
            senderRole: .host
        )
        let receiptMailbox = try PairingCommitMailbox(
            pairRoot: pairRoot,
            record: record,
            senderRole: .joiner
        )
        let transport = PairingRecoveryMailboxTransport(
            ambiguousFirstPutRoutes: [markerMailbox.route],
            blockedRetryRoutes: [markerMailbox.route]
        )
        await transport.seed(
            route: receiptMailbox.route,
            envelope: try receiptMailbox.seal()
        )

        let model = SyncAppModel(
            keychain: keychain,
            baseDirectory: baseDirectory,
            mailboxTransport: transport,
            pairingRetryDelayNanoseconds: 10_000_000
        )
        let retryBlocked = await eventually {
            await transport.isRetryBlocked(route: markerMailbox.route)
        }

        XCTAssertTrue(retryBlocked)
        XCTAssertFalse(model.isPaired)
        XCTAssertNil(try credentialStore.active())
        XCTAssertNotNil(try credentialStore.pending())
        let storedMarkersBeforeRetry = await transport.uniqueStoredCount(
            route: markerMailbox.route
        )
        XCTAssertEqual(
            storedMarkersBeforeRetry,
            1
        )
        await transport.releaseRetry(route: markerMailbox.route)

        let finalized = await eventually {
            model.isPaired
                && !model.isPairingFinalizationLocked
                && (try? credentialStore.pending()) == nil
        }

        XCTAssertTrue(finalized)
        let markerPutCount = await transport.putCount(
            route: markerMailbox.route
        )
        let markerStoredCount = await transport.uniqueStoredCount(
            route: markerMailbox.route
        )
        XCTAssertGreaterThanOrEqual(
            markerPutCount,
            2
        )
        XCTAssertEqual(
            markerStoredCount,
            1
        )
        XCTAssertEqual(model.tasks.map(\.titleValue), ["Host survives"])
        XCTAssertEqual(
            try credentialStore.active(),
            try credentials(for: pending)
        )
        await model.stopRuntimeForTesting()
    }

    @MainActor
    func testHostRestartFromProvisionCompletesDurablePairing() async throws {
        let pairRoot = Data(repeating: 0x91, count: 32)
        let pairID = Data(repeating: 0x92, count: 16)
        let hostID = try ReplicaDeviceID(
            bytes: Data(repeating: 0x93, count: 16)
        )
        let joinerID = try ReplicaDeviceID(
            bytes: Data(repeating: 0x94, count: 16)
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
        try replica.createTask(title: "Host survives")
        for index in 0..<180 {
            try replica.createTask(
                title: "Host \(index) " + String(repeating: "x", count: 180)
            )
        }
        let archive = try replica.exportProvisioningArchive()
        let pending = PendingPair(
            version: SyncProtocol.version,
            pairRoot: pairRoot,
            pairID: pairID,
            role: .host,
            localDeviceID: hostID.bytes,
            remoteDeviceID: nil,
            archiveHash: archive.sha256,
            expiresAt: .distantPast,
            finalizationState: .provisionMayHaveBeenStored
        )
        try credentialStore.savePending(pending)
        let provisionMailbox = try PairingProvisionMailbox(
            pairRoot: pairRoot,
            pairID: pairID
        )
        let expectedProvision = try provisionMailbox.seal(
            archive: archive,
            hostDeviceID: hostID.bytes
        )
        XCTAssertGreaterThan(expectedProvision.count, 1)
        let readyMailbox = try PairingReadyMailbox(
            pairRoot: pairRoot,
            pairID: pairID,
            hostDeviceID: hostID.bytes,
            archiveHash: archive.sha256
        )
        let record = try PairingCommitRecord(
            pairID: pairID,
            hostDeviceID: hostID.bytes,
            joinerDeviceID: joinerID.bytes,
            archiveHash: archive.sha256
        )
        let markerMailbox = try PairingCommitMailbox(
            pairRoot: pairRoot,
            record: record,
            senderRole: .host
        )
        let receiptMailbox = try PairingCommitMailbox(
            pairRoot: pairRoot,
            record: record,
            senderRole: .joiner
        )
        let transport = PairingRecoveryMailboxTransport()
        await transport.seed(
            route: readyMailbox.route,
            envelope: try readyMailbox.seal(
                joinerDeviceID: joinerID.bytes
            )
        )
        await transport.seed(
            route: receiptMailbox.route,
            envelope: try receiptMailbox.seal()
        )

        let model = SyncAppModel(
            keychain: keychain,
            baseDirectory: baseDirectory,
            mailboxTransport: transport,
            pairingRetryDelayNanoseconds: 10_000_000
        )
        let finalized = await eventually {
            model.isPaired
                && !model.isPairingFinalizationLocked
                && (try? credentialStore.pending()) == nil
        }

        XCTAssertTrue(finalized)
        XCTAssertEqual(model.tasks.count, 181)
        XCTAssertTrue(model.tasks.contains { $0.titleValue == "Host survives" })
        let provisionStoredCount = await transport.uniqueStoredCount(
            route: provisionMailbox.route
        )
        let provisionStoredIDs = await transport.storedMessageIDs(
            route: provisionMailbox.route
        )
        let provisionPutCount = await transport.putCount(
            route: provisionMailbox.route
        )
        let readyFetchCount = await transport.fetchCount(
            route: readyMailbox.route
        )
        let markerStoredCount = await transport.uniqueStoredCount(
            route: markerMailbox.route
        )
        let receiptFetchCount = await transport.fetchCount(
            route: receiptMailbox.route
        )
        XCTAssertEqual(
            provisionStoredCount,
            expectedProvision.count
        )
        XCTAssertEqual(
            provisionStoredIDs,
            Set(expectedProvision.map(\.messageID))
        )
        XCTAssertEqual(
            provisionPutCount,
            (expectedProvision.count + 3) / 4
        )
        XCTAssertGreaterThanOrEqual(
            readyFetchCount,
            1
        )
        XCTAssertEqual(
            markerStoredCount,
            1
        )
        XCTAssertGreaterThanOrEqual(
            receiptFetchCount,
            1
        )
        XCTAssertEqual(
            try credentialStore.active(),
            PairCredentials(
                pairRoot: pairRoot,
                pairID: pairID,
                role: .host,
                localDeviceID: hostID.bytes,
                remoteDeviceID: joinerID.bytes
            )
        )
        await model.stopRuntimeForTesting()
    }

    @MainActor
    func testJoinerRestartFromWaitingConsumesProvisionAndActivates() async throws {
        let pairRoot = Data(repeating: 0xA1, count: 32)
        let pairID = Data(repeating: 0xA2, count: 16)
        let hostID = try ReplicaDeviceID(
            bytes: Data(repeating: 0xA3, count: 16)
        )
        let joinerID = try ReplicaDeviceID(
            bytes: Data(repeating: 0xA4, count: 16)
        )
        var hostReplica = try TaskReplica(deviceID: hostID)
        try hostReplica.createTask(title: "Imported after restart")
        for index in 0..<180 {
            try hostReplica.createTask(
                title: "Imported \(index) "
                    + String(repeating: "y", count: 175)
            )
        }
        let archive = try hostReplica.exportProvisioningArchive()
        let keychain = KeychainStore(
            service: "com.gotdone.relay.tests.\(UUID().uuidString)"
        )
        let credentialStore = CredentialStore(keychain: keychain)
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stagingURL = baseDirectory.appendingPathComponent(
            SyncAppModel.pairingStagingFilename
        )
        defer {
            try? credentialStore.clearPair()
            try? keychain.delete(account: InstallIdentity.account)
            try? FileManager.default.removeItem(at: baseDirectory)
        }
        try keychain.write(joinerID.bytes, account: InstallIdentity.account)
        let pending = PendingPair(
            version: SyncProtocol.version,
            pairRoot: pairRoot,
            pairID: pairID,
            role: .joiner,
            localDeviceID: joinerID.bytes,
            remoteDeviceID: nil,
            archiveHash: Data(),
            expiresAt: .distantPast,
            finalizationState: .waitingForProvision
        )
        try credentialStore.savePending(pending)
        let provisionMailbox = try PairingProvisionMailbox(
            pairRoot: pairRoot,
            pairID: pairID
        )
        let provision = try provisionMailbox.seal(
            archive: archive,
            hostDeviceID: hostID.bytes
        )
        XCTAssertGreaterThan(provision.count, 1)
        let readyMailbox = try PairingReadyMailbox(
            pairRoot: pairRoot,
            pairID: pairID,
            hostDeviceID: hostID.bytes,
            archiveHash: archive.sha256
        )
        let record = try PairingCommitRecord(
            pairID: pairID,
            hostDeviceID: hostID.bytes,
            joinerDeviceID: joinerID.bytes,
            archiveHash: archive.sha256
        )
        let markerMailbox = try PairingCommitMailbox(
            pairRoot: pairRoot,
            record: record,
            senderRole: .host
        )
        let receiptMailbox = try PairingCommitMailbox(
            pairRoot: pairRoot,
            record: record,
            senderRole: .joiner
        )
        let transport = PairingRecoveryMailboxTransport()
        for envelope in provision {
            await transport.seed(
                route: provisionMailbox.route,
                envelope: envelope
            )
        }
        await transport.seed(
            route: markerMailbox.route,
            envelope: try markerMailbox.seal()
        )

        let model = SyncAppModel(
            keychain: keychain,
            baseDirectory: baseDirectory,
            mailboxTransport: transport,
            pairingRetryDelayNanoseconds: 10_000_000
        )
        let finalized = await eventually {
            model.isPaired
                && !model.isPairingFinalizationLocked
                && (try? credentialStore.pending()) == nil
        }

        XCTAssertTrue(finalized)
        XCTAssertEqual(model.tasks.count, 181)
        XCTAssertTrue(
            model.tasks.contains {
                $0.titleValue == "Imported after restart"
            }
        )
        let provisionStoredIDs = await transport.storedMessageIDs(
            route: provisionMailbox.route
        )
        let provisionFetchCount = await transport.fetchCount(
            route: provisionMailbox.route
        )
        let readyStoredCount = await transport.uniqueStoredCount(
            route: readyMailbox.route
        )
        let receiptStoredCount = await transport.uniqueStoredCount(
            route: receiptMailbox.route
        )
        XCTAssertEqual(
            provisionStoredIDs,
            Set(provision.map(\.messageID))
        )
        XCTAssertGreaterThanOrEqual(
            provisionFetchCount,
            1
        )
        XCTAssertEqual(
            readyStoredCount,
            1
        )
        XCTAssertEqual(
            receiptStoredCount,
            1
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stagingURL.path)
        )
        XCTAssertEqual(
            try credentialStore.active(),
            PairCredentials(
                pairRoot: pairRoot,
                pairID: pairID,
                role: .joiner,
                localDeviceID: joinerID.bytes,
                remoteDeviceID: hostID.bytes,
                pairingArchiveHash: archive.sha256
            )
        )
        await model.stopRuntimeForTesting()
    }

    @MainActor
    func testJoinerCancellationPersistsAbortAndHostRollsBack() async throws {
        let pairRoot = Data(repeating: 0xB1, count: 32)
        let pairID = Data(repeating: 0xB2, count: 16)
        let hostID = try ReplicaDeviceID(
            bytes: Data(repeating: 0xB3, count: 16)
        )
        let joinerID = try ReplicaDeviceID(
            bytes: Data(repeating: 0xB4, count: 16)
        )
        let hostKeychain = KeychainStore(
            service: "com.gotdone.relay.tests.\(UUID().uuidString)"
        )
        let hostCredentialStore = CredentialStore(keychain: hostKeychain)
        let hostBaseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let hostPersistenceURL = hostBaseDirectory.appendingPathComponent(
            "replica-v1.json"
        )
        let joinerKeychain = KeychainStore(
            service: "com.gotdone.relay.tests.\(UUID().uuidString)"
        )
        let joinerCredentialStore = CredentialStore(keychain: joinerKeychain)
        let joinerBaseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? hostCredentialStore.clearPair()
            try? hostKeychain.delete(account: InstallIdentity.account)
            try? FileManager.default.removeItem(at: hostBaseDirectory)
            try? joinerCredentialStore.clearPair()
            try? joinerKeychain.delete(account: InstallIdentity.account)
            try? FileManager.default.removeItem(at: joinerBaseDirectory)
        }
        try hostKeychain.write(
            hostID.bytes,
            account: InstallIdentity.account
        )
        try joinerKeychain.write(
            joinerID.bytes,
            account: InstallIdentity.account
        )
        var hostReplica = try TaskReplica(
            deviceID: hostID,
            persistenceURL: hostPersistenceURL
        )
        try hostReplica.createTask(title: "Keep host tasks")
        let archive = try hostReplica.exportProvisioningArchive()
        let joinerPending = PendingPair(
            version: SyncProtocol.version,
            pairRoot: pairRoot,
            pairID: pairID,
            role: .joiner,
            localDeviceID: joinerID.bytes,
            remoteDeviceID: nil,
            archiveHash: Data(),
            expiresAt: .distantPast,
            finalizationState: .waitingForProvision
        )
        try joinerCredentialStore.savePending(joinerPending)
        let transport = PairingRecoveryMailboxTransport()
        let joinerModel = SyncAppModel(
            keychain: joinerKeychain,
            baseDirectory: joinerBaseDirectory,
            mailboxTransport: transport,
            pairingRetryDelayNanoseconds: 10_000_000
        )

        XCTAssertTrue(joinerModel.canCancelPairing)
        joinerModel.cancelPairing()
        let joinerCancelled = await eventually {
            !joinerModel.isPairingFinalizationLocked
                && (try? joinerCredentialStore.pending()) == nil
        }
        let abortMailbox = try PairingAbortMailbox(
            pairRoot: pairRoot,
            pairID: pairID,
            senderRole: .joiner
        )
        let abortEnvelopes = await transport.storedEnvelopes(
            route: abortMailbox.route
        )

        XCTAssertTrue(joinerCancelled)
        XCTAssertFalse(joinerModel.isPaired)
        XCTAssertNil(try joinerCredentialStore.active())
        XCTAssertEqual(abortEnvelopes.count, 1)
        XCTAssertEqual(
            try abortMailbox.open(try XCTUnwrap(abortEnvelopes.first))
                .senderDeviceID,
            joinerID.bytes
        )
        await joinerModel.stopRuntimeForTesting()

        let hostPending = PendingPair(
            version: SyncProtocol.version,
            pairRoot: pairRoot,
            pairID: pairID,
            role: .host,
            localDeviceID: hostID.bytes,
            remoteDeviceID: nil,
            archiveHash: archive.sha256,
            expiresAt: .distantPast,
            finalizationState: .provisionMayHaveBeenStored
        )
        try hostCredentialStore.savePending(hostPending)
        let hostModel = SyncAppModel(
            keychain: hostKeychain,
            baseDirectory: hostBaseDirectory,
            mailboxTransport: transport,
            pairingRetryDelayNanoseconds: 10_000_000
        )
        let hostRolledBack = await eventually {
            !hostModel.isPairingFinalizationLocked
                && (try? hostCredentialStore.pending()) == nil
        }
        let provisionMailbox = try PairingProvisionMailbox(
            pairRoot: pairRoot,
            pairID: pairID
        )
        let provisionPutCount = await transport.putCount(
            route: provisionMailbox.route
        )

        XCTAssertTrue(hostRolledBack)
        XCTAssertFalse(hostModel.isPaired)
        XCTAssertNil(try hostCredentialStore.active())
        XCTAssertEqual(hostModel.tasks.map(\.titleValue), ["Keep host tasks"])
        XCTAssertEqual(
            provisionPutCount,
            0
        )
        await hostModel.stopRuntimeForTesting()
    }

    @MainActor
    func testHostCanCancelProvisionAndRepublishAbortAfterRestart()
        async throws
    {
        let pairRoot = Data(repeating: 0xC1, count: 32)
        let pairID = Data(repeating: 0xC2, count: 16)
        let hostID = try ReplicaDeviceID(
            bytes: Data(repeating: 0xC3, count: 16)
        )
        let joinerID = try ReplicaDeviceID(
            bytes: Data(repeating: 0xC4, count: 16)
        )
        let hostKeychain = KeychainStore(
            service: "com.gotdone.relay.tests.\(UUID().uuidString)"
        )
        let hostStore = CredentialStore(keychain: hostKeychain)
        let hostBaseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let joinerKeychain = KeychainStore(
            service: "com.gotdone.relay.tests.\(UUID().uuidString)"
        )
        let joinerStore = CredentialStore(keychain: joinerKeychain)
        let joinerBaseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? hostStore.clearPair()
            try? hostKeychain.delete(account: InstallIdentity.account)
            try? FileManager.default.removeItem(at: hostBaseDirectory)
            try? joinerStore.clearPair()
            try? joinerKeychain.delete(account: InstallIdentity.account)
            try? FileManager.default.removeItem(at: joinerBaseDirectory)
        }
        try hostKeychain.write(
            hostID.bytes,
            account: InstallIdentity.account
        )
        try joinerKeychain.write(
            joinerID.bytes,
            account: InstallIdentity.account
        )
        var hostReplica = try TaskReplica(
            deviceID: hostID,
            persistenceURL: hostBaseDirectory.appendingPathComponent(
                "replica-v1.json"
            )
        )
        try hostReplica.createTask(title: "Host stays local")
        let pending = PendingPair(
            version: SyncProtocol.version,
            pairRoot: pairRoot,
            pairID: pairID,
            role: .host,
            localDeviceID: hostID.bytes,
            remoteDeviceID: nil,
            archiveHash: try hostReplica.exportProvisioningArchive().sha256,
            expiresAt: .distantPast,
            finalizationState: .provisionMayHaveBeenStored
        )
        try hostStore.savePending(pending)
        let abortMailbox = try PairingAbortMailbox(
            pairRoot: pairRoot,
            pairID: pairID,
            senderRole: .host
        )
        let transport = PairingRecoveryMailboxTransport(
            ambiguousFirstPutRoutes: [abortMailbox.route]
        )
        let firstHost = SyncAppModel(
            keychain: hostKeychain,
            baseDirectory: hostBaseDirectory,
            mailboxTransport: transport,
            pairingRetryDelayNanoseconds: 10_000_000_000
        )

        XCTAssertTrue(firstHost.canCancelPairing)
        firstHost.cancelPairing()
        let ambiguousPutPersisted = await eventually {
            let puts = await transport.putCount(route: abortMailbox.route)
            let actions = try? hostStore.terminalPairingActions()
            let pendingState =
                (try? hostStore.pending())?.finalizationState
            return puts >= 1
                && actions?.contains { $0.kind == .abort } == true
                && pendingState == .abortMayHaveBeenStored
        }

        XCTAssertTrue(ambiguousPutPersisted)
        XCTAssertFalse(firstHost.isPaired)
        XCTAssertTrue(firstHost.isPairingFinalizationLocked)
        await firstHost.stopRuntimeForTesting()
        await transport.purge(route: abortMailbox.route)

        let restartedHost = SyncAppModel(
            keychain: hostKeychain,
            baseDirectory: hostBaseDirectory,
            mailboxTransport: transport,
            pairingRetryDelayNanoseconds: 10_000_000
        )
        let hostCancelled = await eventually {
            !restartedHost.isPairingFinalizationLocked
                && (try? hostStore.pending()) == nil
        }

        XCTAssertTrue(hostCancelled)
        XCTAssertFalse(restartedHost.isPaired)
        XCTAssertEqual(
            restartedHost.tasks.map(\.titleValue),
            ["Host stays local"]
        )
        let joinerPending = PendingPair(
            version: SyncProtocol.version,
            pairRoot: pairRoot,
            pairID: pairID,
            role: .joiner,
            localDeviceID: joinerID.bytes,
            remoteDeviceID: nil,
            archiveHash: Data(),
            expiresAt: .distantPast,
            finalizationState: .waitingForProvision
        )
        try joinerStore.savePending(joinerPending)
        let joinerModel = SyncAppModel(
            keychain: joinerKeychain,
            baseDirectory: joinerBaseDirectory,
            mailboxTransport: transport,
            pairingRetryDelayNanoseconds: 10_000_000
        )
        let joinerCancelled = await eventually {
            !joinerModel.isPairingFinalizationLocked
                && (try? joinerStore.pending()) == nil
        }

        XCTAssertTrue(joinerCancelled)
        XCTAssertFalse(joinerModel.isPaired)
        let abortAcknowledged = await eventually {
            await transport.acknowledgeCount(route: abortMailbox.route) > 0
        }
        XCTAssertTrue(abortAcknowledged)
        await joinerModel.stopRuntimeForTesting()
        await restartedHost.stopRuntimeForTesting()

        let finalHost = SyncAppModel(
            keychain: hostKeychain,
            baseDirectory: hostBaseDirectory,
            mailboxTransport: transport,
            pairingRetryDelayNanoseconds: 10_000_000
        )
        let abortRetired = await eventually {
            (try? hostStore.terminalPairingActions().isEmpty) == true
        }
        XCTAssertTrue(abortRetired)
        await finalHost.stopRuntimeForTesting()
    }

    @MainActor
    func testJoinerRestartWithStagedArchiveFinishesFromMarker() async throws {
        let fixture = try makeJoinerFixture(seed: 0x21)
        defer { fixture.cleanup() }
        _ = try TaskReplica.provision(
            deviceID: fixture.joinerID,
            from: fixture.archive,
            persistenceURL: fixture.stagingURL
        )
        try fixture.credentialStore.savePending(fixture.pending)
        let record = try commitRecord(for: fixture.pending)
        let markerMailbox = try PairingCommitMailbox(
            pairRoot: fixture.pending.pairRoot,
            record: record,
            senderRole: .host
        )
        let receiptMailbox = try PairingCommitMailbox(
            pairRoot: fixture.pending.pairRoot,
            record: record,
            senderRole: .joiner
        )
        let transport = PairingRecoveryMailboxTransport()
        await transport.seed(
            route: markerMailbox.route,
            envelope: try markerMailbox.seal()
        )

        let model = SyncAppModel(
            keychain: fixture.keychain,
            baseDirectory: fixture.baseDirectory,
            mailboxTransport: transport,
            pairingRetryDelayNanoseconds: 10_000_000
        )
        let finalized = await eventually {
            model.isPaired
                && !model.isPairingFinalizationLocked
                && (try? fixture.credentialStore.pending()) == nil
        }

        XCTAssertTrue(finalized)
        let receiptStoredCount = await transport.uniqueStoredCount(
            route: receiptMailbox.route
        )
        XCTAssertEqual(model.tasks.map(\.titleValue), ["Imported"])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.stagingURL.path)
        )
        XCTAssertEqual(
            receiptStoredCount,
            1
        )
        XCTAssertEqual(
            try fixture.credentialStore.active(),
            try credentials(for: fixture.pending)
        )
        await model.stopRuntimeForTesting()
    }

    @MainActor
    func testAbortAcknowledgementResumesAfterReceiverRestart() async throws {
        let localID = try ReplicaDeviceID(
            bytes: Data(repeating: 0xB5, count: 16)
        )
        let remoteID = try ReplicaDeviceID(
            bytes: Data(repeating: 0xB6, count: 16)
        )
        let pairRoot = Data(repeating: 0xB7, count: 32)
        let pairID = Data(repeating: 0xB8, count: 16)
        let keychain = KeychainStore(
            service: "com.gotdone.relay.tests.\(UUID().uuidString)"
        )
        let store = CredentialStore(keychain: keychain)
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? store.clearPair()
            try? keychain.delete(account: InstallIdentity.account)
            try? FileManager.default.removeItem(at: baseDirectory)
        }
        try keychain.write(
            localID.bytes,
            account: InstallIdentity.account
        )
        let pending = PendingPair(
            version: SyncProtocol.version,
            pairRoot: pairRoot,
            pairID: pairID,
            role: .host,
            localDeviceID: localID.bytes,
            remoteDeviceID: remoteID.bytes,
            archiveHash: Data(repeating: 0xB9, count: 32),
            expiresAt: Date().addingTimeInterval(120),
            finalizationState:
                .abortAcknowledgementMayHaveBeenStored,
            pairingArtifactID: pairID,
            abortAcknowledgementCursor: 1
        )
        try store.savePending(pending)
        let mailbox = try PairingAbortMailbox(
            pairRoot: pairRoot,
            pairID: pairID,
            senderRole: .joiner
        )
        let transport = PairingRecoveryMailboxTransport()
        await transport.seed(
            route: mailbox.route,
            envelope: try mailbox.seal(senderDeviceID: remoteID.bytes)
        )

        let model = SyncAppModel(
            keychain: keychain,
            baseDirectory: baseDirectory,
            mailboxTransport: transport,
            pairingRetryDelayNanoseconds: 10_000_000
        )
        let completed = await eventually {
            let pendingCleared = (try? store.pending()) == nil
            let acknowledgementCount =
                await transport.acknowledgeCount(route: mailbox.route)
            return pendingCleared && acknowledgementCount == 1
        }

        XCTAssertTrue(completed)
        XCTAssertEqual(model.phase, .unpaired)
        XCTAssertFalse(model.isPairingFinalizationLocked)
        await model.stopRuntimeForTesting()
    }

    @MainActor
    func testJoinerRestartAfterInstallBeforeActiveSaveIsIdempotent() async throws {
        let fixture = try makeJoinerFixture(seed: 0x31)
        defer { fixture.cleanup() }
        _ = try TaskReplica.provision(
            deviceID: fixture.joinerID,
            from: fixture.archive,
            persistenceURL: fixture.persistenceURL
        )
        try fixture.credentialStore.savePending(fixture.pending)
        let record = try commitRecord(for: fixture.pending)
        let markerMailbox = try PairingCommitMailbox(
            pairRoot: fixture.pending.pairRoot,
            record: record,
            senderRole: .host
        )
        let transport = PairingRecoveryMailboxTransport()
        await transport.seed(
            route: markerMailbox.route,
            envelope: try markerMailbox.seal()
        )

        let model = SyncAppModel(
            keychain: fixture.keychain,
            baseDirectory: fixture.baseDirectory,
            mailboxTransport: transport,
            pairingRetryDelayNanoseconds: 10_000_000
        )
        let finalized = await eventually {
            model.isPaired
                && !model.isPairingFinalizationLocked
                && (try? fixture.credentialStore.pending()) == nil
        }

        XCTAssertTrue(finalized)
        XCTAssertEqual(model.tasks.map(\.titleValue), ["Imported"])
        XCTAssertEqual(
            try fixture.credentialStore.active(),
            try credentials(for: fixture.pending)
        )
        await model.stopRuntimeForTesting()
    }

    @MainActor
    func testJoinerKeepsPendingAndStagingUntilReceiptRetryConfirms() async throws {
        let fixture = try makeJoinerFixture(seed: 0x41)
        defer { fixture.cleanup() }
        _ = try TaskReplica.provision(
            deviceID: fixture.joinerID,
            from: fixture.archive,
            persistenceURL: fixture.stagingURL
        )
        try fixture.credentialStore.savePending(fixture.pending)
        let record = try commitRecord(for: fixture.pending)
        let markerMailbox = try PairingCommitMailbox(
            pairRoot: fixture.pending.pairRoot,
            record: record,
            senderRole: .host
        )
        let receiptMailbox = try PairingCommitMailbox(
            pairRoot: fixture.pending.pairRoot,
            record: record,
            senderRole: .joiner
        )
        let transport = PairingRecoveryMailboxTransport(
            ambiguousFirstPutRoutes: [receiptMailbox.route],
            blockedRetryRoutes: [receiptMailbox.route]
        )
        await transport.seed(
            route: markerMailbox.route,
            envelope: try markerMailbox.seal()
        )

        let model = SyncAppModel(
            keychain: fixture.keychain,
            baseDirectory: fixture.baseDirectory,
            mailboxTransport: transport,
            pairingRetryDelayNanoseconds: 10_000_000
        )
        let retryBlocked = await eventually {
            await transport.isRetryBlocked(route: receiptMailbox.route)
        }

        XCTAssertTrue(retryBlocked)
        XCTAssertTrue(model.isPaired)
        XCTAssertTrue(model.isPairingFinalizationLocked)
        XCTAssertNotNil(try fixture.credentialStore.pending())
        XCTAssertNotNil(try fixture.credentialStore.active())
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.stagingURL.path)
        )
        let storedReceiptsBeforeRetry = await transport.uniqueStoredCount(
            route: receiptMailbox.route
        )
        XCTAssertEqual(
            storedReceiptsBeforeRetry,
            1
        )
        await transport.releaseRetry(route: receiptMailbox.route)

        let finalized = await eventually {
            model.isPaired
                && !model.isPairingFinalizationLocked
                && (try? fixture.credentialStore.pending()) == nil
        }

        XCTAssertTrue(finalized)
        let receiptPutCount = await transport.putCount(
            route: receiptMailbox.route
        )
        let receiptStoredCount = await transport.uniqueStoredCount(
            route: receiptMailbox.route
        )
        XCTAssertGreaterThanOrEqual(
            receiptPutCount,
            2
        )
        XCTAssertEqual(
            receiptStoredCount,
            1
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.stagingURL.path)
        )
        XCTAssertEqual(model.tasks.map(\.titleValue), ["Imported"])
        await model.stopRuntimeForTesting()
    }

    @MainActor
    func testReceiptRepublishesAfterPurgeAndRestartUntilPeerCompletes()
        async throws
    {
        let fixture = try makeJoinerFixture(seed: 0x45)
        defer { fixture.cleanup() }
        _ = try TaskReplica.provision(
            deviceID: fixture.joinerID,
            from: fixture.archive,
            persistenceURL: fixture.stagingURL
        )
        try fixture.credentialStore.savePending(fixture.pending)
        let record = try commitRecord(for: fixture.pending)
        let markerMailbox = try PairingCommitMailbox(
            pairRoot: fixture.pending.pairRoot,
            record: record,
            senderRole: .host
        )
        let receiptMailbox = try PairingCommitMailbox(
            pairRoot: fixture.pending.pairRoot,
            record: record,
            senderRole: .joiner
        )
        let transport = PairingRecoveryMailboxTransport()
        await transport.seed(
            route: markerMailbox.route,
            envelope: try markerMailbox.seal()
        )

        let firstJoiner = SyncAppModel(
            keychain: fixture.keychain,
            baseDirectory: fixture.baseDirectory,
            mailboxTransport: transport,
            pairingRetryDelayNanoseconds: 10_000_000
        )
        let firstFinalized = await eventually {
            firstJoiner.isPaired
                && !firstJoiner.isPairingFinalizationLocked
                && (try? fixture.credentialStore.pending()) == nil
                && (try? fixture.credentialStore.terminalPairingActions()
                    .contains { $0.kind == .receipt }) == true
        }

        XCTAssertTrue(firstFinalized)
        await firstJoiner.stopRuntimeForTesting()
        await transport.purge(route: receiptMailbox.route)
        let storedAfterPurge = await transport.storedEnvelopes(
            route: receiptMailbox.route
        )
        XCTAssertTrue(storedAfterPurge.isEmpty)

        let restartedJoiner = SyncAppModel(
            keychain: fixture.keychain,
            baseDirectory: fixture.baseDirectory,
            mailboxTransport: transport,
            pairingRetryDelayNanoseconds: 10_000_000
        )
        let republished = await eventually {
            let putCount = await transport.putCount(
                route: receiptMailbox.route
            )
            let stored = await transport.storedEnvelopes(
                route: receiptMailbox.route
            )
            return putCount >= 2 && !stored.isEmpty
        }
        XCTAssertTrue(republished)

        let hostKeychain = KeychainStore(
            service: "com.gotdone.relay.tests.\(UUID().uuidString)"
        )
        let hostStore = CredentialStore(keychain: hostKeychain)
        let hostBaseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? hostStore.clearPair()
            try? hostKeychain.delete(account: InstallIdentity.account)
            try? FileManager.default.removeItem(at: hostBaseDirectory)
        }
        try hostKeychain.write(
            fixture.hostID.bytes,
            account: InstallIdentity.account
        )
        _ = try TaskReplica(
            deviceID: fixture.hostID,
            persistenceURL: hostBaseDirectory.appendingPathComponent(
                "replica-v1.json"
            )
        )
        let hostPending = PendingPair(
            version: SyncProtocol.version,
            pairRoot: fixture.pending.pairRoot,
            pairID: fixture.pending.pairID,
            role: .host,
            localDeviceID: fixture.hostID.bytes,
            remoteDeviceID: fixture.joinerID.bytes,
            archiveHash: fixture.pending.archiveHash,
            expiresAt: .distantPast,
            finalizationState: .commitMarkerMayHaveBeenStored
        )
        try hostStore.savePending(hostPending)
        let hostModel = SyncAppModel(
            keychain: hostKeychain,
            baseDirectory: hostBaseDirectory,
            mailboxTransport: transport,
            pairingRetryDelayNanoseconds: 10_000_000
        )
        let hostCompleted = await eventually {
            hostModel.isPaired
                && !hostModel.isPairingFinalizationLocked
                && (try? hostStore.pending()) == nil
        }

        XCTAssertTrue(hostCompleted)
        let receiptAcknowledged = await eventually {
            await transport.acknowledgeCount(route: receiptMailbox.route) > 0
        }
        XCTAssertTrue(receiptAcknowledged)
        await restartedJoiner.stopRuntimeForTesting()

        let finalJoiner = SyncAppModel(
            keychain: fixture.keychain,
            baseDirectory: fixture.baseDirectory,
            mailboxTransport: transport,
            pairingRetryDelayNanoseconds: 10_000_000
        )
        let receiptRetired = await eventually {
            (try? fixture.credentialStore.terminalPairingActions().isEmpty)
                == true
        }
        XCTAssertTrue(receiptRetired)
        XCTAssertTrue(
            try fixture.credentialStore.terminalPairingActions().isEmpty
        )
        await hostModel.stopRuntimeForTesting()
        await finalJoiner.stopRuntimeForTesting()
    }

    @MainActor
    func testTamperedCommitDoesNotMutateJoinerRecoveryState() async throws {
        let fixture = try makeJoinerFixture(seed: 0x4A)
        defer { fixture.cleanup() }
        _ = try TaskReplica(
            deviceID: fixture.joinerID,
            persistenceURL: fixture.persistenceURL
        )
        _ = try TaskReplica.provision(
            deviceID: fixture.joinerID,
            from: fixture.archive,
            persistenceURL: fixture.stagingURL
        )
        let mainBefore = try Data(contentsOf: fixture.persistenceURL)
        let stagingBefore = try Data(contentsOf: fixture.stagingURL)
        try fixture.credentialStore.savePending(fixture.pending)
        let record = try commitRecord(for: fixture.pending)
        let markerMailbox = try PairingCommitMailbox(
            pairRoot: fixture.pending.pairRoot,
            record: record,
            senderRole: .host
        )
        let marker = try markerMailbox.seal()
        var tamperedCiphertext = marker.ciphertext
        tamperedCiphertext[tamperedCiphertext.startIndex] ^= 0x01
        let tamperedMarker = try StoredMailboxEnvelope(
            messageID: marker.messageID,
            ciphertext: tamperedCiphertext
        )
        let transport = PairingRecoveryMailboxTransport()
        await transport.seed(
            route: markerMailbox.route,
            envelope: tamperedMarker
        )

        let model = SyncAppModel(
            keychain: fixture.keychain,
            baseDirectory: fixture.baseDirectory,
            mailboxTransport: transport,
            pairingRetryDelayNanoseconds: 10_000_000
        )
        let fetched = await eventually {
            await transport.fetchCount(route: markerMailbox.route) > 0
        }
        let acknowledgeCount = await transport.acknowledgeCount(
            route: markerMailbox.route
        )

        XCTAssertTrue(fetched)
        XCTAssertFalse(model.isPaired)
        XCTAssertTrue(model.isPairingFinalizationLocked)
        XCTAssertNil(try fixture.credentialStore.active())
        XCTAssertEqual(
            try fixture.credentialStore.pending(),
            fixture.pending
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.persistenceURL),
            mainBefore
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.stagingURL),
            stagingBefore
        )
        XCTAssertEqual(acknowledgeCount, 0)
        await model.stopRuntimeForTesting()
    }

    @MainActor
    func testActiveHostPendingRepublishesUntilReceiptArrives() async throws {
        let pairRoot = Data(repeating: 0x51, count: 32)
        let pairID = Data(repeating: 0x52, count: 16)
        let hostID = try ReplicaDeviceID(
            bytes: Data(repeating: 0x53, count: 16)
        )
        let joinerID = try ReplicaDeviceID(
            bytes: Data(repeating: 0x54, count: 16)
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
        var replica = try TaskReplica(
            deviceID: hostID,
            persistenceURL: baseDirectory.appendingPathComponent(
                "replica-v1.json"
            )
        )
        try replica.createTask(title: "Active host")
        let pending = PendingPair(
            version: SyncProtocol.version,
            pairRoot: pairRoot,
            pairID: pairID,
            role: .host,
            localDeviceID: hostID.bytes,
            remoteDeviceID: joinerID.bytes,
            archiveHash: try replica.exportProvisioningArchive().sha256,
            expiresAt: .distantPast,
            finalizationState: .commitMarkerMayHaveBeenStored
        )
        try credentialStore.savePending(pending)
        try credentialStore.saveActive(credentials(for: pending))
        let record = try commitRecord(for: pending)
        let markerMailbox = try PairingCommitMailbox(
            pairRoot: pairRoot,
            record: record,
            senderRole: .host
        )
        let receiptMailbox = try PairingCommitMailbox(
            pairRoot: pairRoot,
            record: record,
            senderRole: .joiner
        )
        let transport = PairingRecoveryMailboxTransport()
        await transport.seed(
            route: receiptMailbox.route,
            envelope: try receiptMailbox.seal()
        )

        let model = SyncAppModel(
            keychain: keychain,
            baseDirectory: baseDirectory,
            mailboxTransport: transport,
            pairingRetryDelayNanoseconds: 10_000_000
        )
        let finalized = await eventually {
            !model.isPairingFinalizationLocked
                && (try? credentialStore.pending()) == nil
        }

        XCTAssertTrue(finalized)
        let markerPutCount = await transport.putCount(
            route: markerMailbox.route
        )
        XCTAssertGreaterThanOrEqual(
            markerPutCount,
            1
        )
        XCTAssertEqual(model.tasks.map(\.titleValue), ["Active host"])
        await model.stopRuntimeForTesting()
    }

    @MainActor
    func testJoinerConflictCanKeepBothTaskListsAndFinishPairing() async throws {
        let fixture = try makeJoinerFixture(
            seed: 0x61,
            finalizationState: .provisionStagedAwaitingMergeApproval
        )
        defer { fixture.cleanup() }
        var localReplica = try TaskReplica.provision(
            deviceID: fixture.joinerID,
            from: fixture.archive,
            persistenceURL: fixture.persistenceURL
        )
        try localReplica.createTask(title: "Keep local")
        _ = try TaskReplica.provision(
            deviceID: fixture.joinerID,
            from: fixture.archive,
            persistenceURL: fixture.stagingURL
        )
        try fixture.credentialStore.savePending(fixture.pending)
        let record = try commitRecord(for: fixture.pending)
        let markerMailbox = try PairingCommitMailbox(
            pairRoot: fixture.pending.pairRoot,
            record: record,
            senderRole: .host
        )
        let transport = PairingRecoveryMailboxTransport()
        await transport.seed(
            route: markerMailbox.route,
            envelope: try markerMailbox.seal()
        )

        let model = SyncAppModel(
            keychain: fixture.keychain,
            baseDirectory: fixture.baseDirectory,
            mailboxTransport: transport,
            pairingRetryDelayNanoseconds: 10_000_000
        )
        // Additive-only merge (local-only tasks, no conflicts) auto-continues.
        let recovered = await eventually {
            model.isPaired
                && !model.isPairingFinalizationLocked
                && (try? fixture.credentialStore.pending()) == nil
        }

        XCTAssertTrue(recovered)
        XCTAssertFalse(model.hasPairingReplicaConflict)
        XCTAssertNil(model.keepBothPreview)
        XCTAssertEqual(
            Set(model.tasks.compactMap(\.titleValue)),
            ["Imported", "Keep local"]
        )
        XCTAssertEqual(model.tasks.count, 2)
        XCTAssertNotNil(try fixture.credentialStore.active())
        XCTAssertTrue(model.addTask(title: "Still editable"))
        XCTAssertEqual(
            Set(model.tasks.compactMap(\.titleValue)),
            ["Imported", "Keep local", "Still editable"]
        )
        await model.stopRuntimeForTesting()
    }

    @MainActor
    func testPreReadyPendingJoinRollsBackStaging() throws {
        let fixture = try makeJoinerFixture(
            seed: 0x71,
            finalizationState: nil
        )
        defer { fixture.cleanup() }
        _ = try TaskReplica.provision(
            deviceID: fixture.joinerID,
            from: fixture.archive,
            persistenceURL: fixture.stagingURL
        )
        try fixture.credentialStore.savePending(fixture.pending)

        let model = SyncAppModel(
            keychain: fixture.keychain,
            baseDirectory: fixture.baseDirectory,
            mailboxTransport: PairingRecoveryMailboxTransport()
        )

        XCTAssertFalse(model.isPaired)
        XCTAssertFalse(model.isPairingFinalizationLocked)
        XCTAssertTrue(model.tasks.isEmpty)
        XCTAssertNil(try fixture.credentialStore.pending())
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.stagingURL.path)
        )
    }

    func testLegacyPendingPairDecodesWithoutFinalizationState() throws {
        let keychain = KeychainStore(
            service: "com.gotdone.relay.tests.\(UUID().uuidString)"
        )
        let credentialStore = CredentialStore(keychain: keychain)
        defer { try? credentialStore.clearPair() }
        let legacy = LegacyPendingPair(
            version: SyncProtocol.version,
            pairRoot: Data(repeating: 0x81, count: 32),
            pairID: Data(repeating: 0x82, count: 16),
            role: .host,
            localDeviceID: Data(repeating: 0x83, count: 16),
            remoteDeviceID: nil,
            archiveHash: Data(repeating: 0x84, count: 32),
            expiresAt: Date()
        )
        try keychain.write(
            CanonicalJSON.encoder.encode(legacy),
            account: "pending-pair-v1"
        )

        XCTAssertNil(try credentialStore.pending()?.finalizationState)
    }

    func testLegacyFinalizingPendingPairDecodesForSafeRollback() throws {
        let keychain = KeychainStore(
            service: "com.gotdone.relay.tests.\(UUID().uuidString)"
        )
        let credentialStore = CredentialStore(keychain: keychain)
        defer { try? credentialStore.clearPair() }
        let legacy = LegacyPendingPair(
            version: SyncProtocol.version,
            pairRoot: Data(repeating: 0x91, count: 32),
            pairID: Data(repeating: 0x92, count: 16),
            role: .joiner,
            localDeviceID: Data(repeating: 0x93, count: 16),
            remoteDeviceID: Data(repeating: 0x94, count: 16),
            archiveHash: Data(repeating: 0x95, count: 32),
            expiresAt: Date(),
            finalizationState: "readyMayHaveBeenSent"
        )
        try keychain.write(
            CanonicalJSON.encoder.encode(legacy),
            account: "pending-pair-v1"
        )

        let pending = try XCTUnwrap(credentialStore.pending())
        XCTAssertNil(pending.pairingVersion)
        XCTAssertEqual(
            pending.finalizationState,
            .readyMayHaveBeenStored
        )
    }

    @MainActor
    func testLegacyActiveAndPendingForEitherRoleRequiresRelink()
        throws
    {
        for (index, role) in [DeviceRole.host, .joiner].enumerated() {
            let seed = UInt8(0xA0 + index * 8)
            let localID = try ReplicaDeviceID(
                bytes: Data(repeating: seed, count: 16)
            )
            let remoteID = try ReplicaDeviceID(
                bytes: Data(repeating: seed &+ 1, count: 16)
            )
            let keychain = KeychainStore(
                service: "com.gotdone.relay.tests.\(UUID().uuidString)"
            )
            let store = CredentialStore(keychain: keychain)
            let baseDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    UUID().uuidString,
                    isDirectory: true
                )
            defer {
                try? store.clearPair()
                try? keychain.delete(account: InstallIdentity.account)
                try? FileManager.default.removeItem(at: baseDirectory)
            }
            try keychain.write(
                localID.bytes,
                account: InstallIdentity.account
            )
            var replica = try TaskReplica(
                deviceID: localID,
                persistenceURL: baseDirectory.appendingPathComponent(
                    "replica-v1.json"
                )
            )
            try replica.createTask(title: "Preserved \(role)")
            let pairRoot = Data(repeating: seed &+ 2, count: 32)
            let pairID = Data(repeating: seed &+ 3, count: 16)
            try store.saveActive(
                PairCredentials(
                    pairRoot: pairRoot,
                    pairID: pairID,
                    role: role,
                    localDeviceID: localID.bytes,
                    remoteDeviceID: remoteID.bytes
                )
            )
            try store.savePending(
                PendingPair(
                    version: SyncProtocol.version,
                    pairRoot: pairRoot,
                    pairID: pairID,
                    role: role,
                    localDeviceID: localID.bytes,
                    pairingVersion: nil,
                    remoteDeviceID: remoteID.bytes,
                    archiveHash: Data(repeating: seed &+ 4, count: 32),
                    expiresAt: .distantPast,
                    finalizationState: role == .host
                        ? .commitMarkerMayHaveBeenStored
                        : .readyMayHaveBeenStored
                )
            )

            let model = SyncAppModel(
                keychain: keychain,
                baseDirectory: baseDirectory,
                mailboxTransport: PairingRecoveryMailboxTransport()
            )

            XCTAssertFalse(model.isPaired)
            XCTAssertEqual(model.phase, .failed)
            XCTAssertTrue(model.canEditLocalTasks)
            XCTAssertTrue(
                model.errorMessage?.contains("older pairing") == true
            )
            XCTAssertNil(try store.active())
            XCTAssertNil(try store.pending())
            XCTAssertEqual(
                model.tasks.map(\.titleValue),
                ["Preserved \(role)"]
            )
            XCTAssertTrue(model.addTask(title: "Still editable"))
        }
    }

    @MainActor
    func testImmutableOrphanDoesNotDisableActivePairEditingOrRelink()
        async throws
    {
        let localID = try ReplicaDeviceID(
            bytes: Data(repeating: 0xD1, count: 16)
        )
        let remoteID = try ReplicaDeviceID(
            bytes: Data(repeating: 0xD2, count: 16)
        )
        let keychain = KeychainStore(
            service: "com.gotdone.relay.tests.\(UUID().uuidString)"
        )
        let store = CredentialStore(keychain: keychain)
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stagingURL = baseDirectory.appendingPathComponent(
            SyncAppModel.pairingStagingFilename
        )
        defer {
            if FileManager.default.fileExists(atPath: stagingURL.path) {
                try? FileManager.default.setAttributes(
                    [.immutable: false],
                    ofItemAtPath: stagingURL.path
                )
            }
            try? store.clearPair()
            try? keychain.delete(account: InstallIdentity.account)
            try? FileManager.default.removeItem(at: baseDirectory)
        }
        try keychain.write(
            localID.bytes,
            account: InstallIdentity.account
        )
        var replica = try TaskReplica(
            deviceID: localID,
            persistenceURL: baseDirectory.appendingPathComponent(
                "replica-v1.json"
            )
        )
        try replica.createTask(title: "Active task")
        try store.saveActive(
            PairCredentials(
                pairRoot: Data(repeating: 0xD3, count: 32),
                pairID: Data(repeating: 0xD4, count: 16),
                role: .host,
                localDeviceID: localID.bytes,
                remoteDeviceID: remoteID.bytes
            )
        )
        try Data("orphan".utf8).write(to: stagingURL)
        try FileManager.default.setAttributes(
            [.immutable: true],
            ofItemAtPath: stagingURL.path
        )

        let model = SyncAppModel(
            keychain: keychain,
            baseDirectory: baseDirectory,
            mailboxTransport: PairingRecoveryMailboxTransport()
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: stagingURL.path)
        )
        XCTAssertTrue(model.isPaired)
        XCTAssertTrue(model.canEditLocalTasks)
        XCTAssertTrue(model.addTask(title: "Still editable"))
        XCTAssertEqual(model.tasks.count, 2)
        model.unlinkAndKeepTasks()
        let invitation = try Invitation.generate()
        model.joinPrivateSync(phrase: invitation.phrase)
        XCTAssertEqual(model.phase, .waitingForPeer)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: stagingURL.path)
        )
        model.cancelPairing()
        await model.stopRuntimeForTesting()
    }

    @MainActor
    func testDamagedTerminalJournalDoesNotUnlinkHealthyActivePair()
        async throws
    {
        let localID = try ReplicaDeviceID(
            bytes: Data(repeating: 0xE1, count: 16)
        )
        let remoteID = try ReplicaDeviceID(
            bytes: Data(repeating: 0xE2, count: 16)
        )
        let keychain = KeychainStore(
            service: "com.gotdone.relay.tests.\(UUID().uuidString)"
        )
        let store = CredentialStore(keychain: keychain)
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? store.clearPair()
            try? keychain.delete(account: InstallIdentity.account)
            try? FileManager.default.removeItem(at: baseDirectory)
        }
        try keychain.write(
            localID.bytes,
            account: InstallIdentity.account
        )
        var replica = try TaskReplica(
            deviceID: localID,
            persistenceURL: baseDirectory.appendingPathComponent(
                "replica-v1.json"
            )
        )
        try replica.createTask(title: "Healthy active task")
        let active = PairCredentials(
            pairRoot: Data(repeating: 0xE3, count: 32),
            pairID: Data(repeating: 0xE4, count: 16),
            role: .joiner,
            localDeviceID: localID.bytes,
            remoteDeviceID: remoteID.bytes,
            pairingArchiveHash: Data(repeating: 0xE5, count: 32)
        )
        try store.saveActive(active)
        let damagedJournal = Data("not a journal".utf8)
        try keychain.write(
            damagedJournal,
            account: CredentialStore.terminalPairingActionsAccount
        )

        let model = SyncAppModel(
            keychain: keychain,
            baseDirectory: baseDirectory,
            mailboxTransport: PairingRecoveryMailboxTransport()
        )

        XCTAssertTrue(model.isPaired)
        XCTAssertEqual(try store.active(), active)
        let reconstructed = try store.terminalPairingActions()
        XCTAssertEqual(reconstructed.count, 1)
        XCTAssertEqual(reconstructed.first?.kind, .receipt)
        XCTAssertEqual(reconstructed.first?.pairID, active.pairID)
        XCTAssertEqual(
            try keychain.read(
                account:
                    CredentialStore.damagedTerminalPairingActionsAccount
            ),
            damagedJournal
        )
        XCTAssertFalse(model.mailboxRequiresRepair)
        XCTAssertTrue(model.canEditLocalTasks)
        XCTAssertTrue(model.addTask(title: "Still editable"))
        await model.stopRuntimeForTesting()
    }

    @MainActor
    func testUnrecoverableTerminalJournalIsPreservedForRepair()
        async throws
    {
        let localID = try ReplicaDeviceID(
            bytes: Data(repeating: 0xF1, count: 16)
        )
        let remoteID = try ReplicaDeviceID(
            bytes: Data(repeating: 0xF2, count: 16)
        )
        let keychain = KeychainStore(
            service: "com.gotdone.relay.tests.\(UUID().uuidString)"
        )
        let store = CredentialStore(keychain: keychain)
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? store.clearPair()
            try? keychain.delete(account: InstallIdentity.account)
            try? FileManager.default.removeItem(at: baseDirectory)
        }
        try keychain.write(
            localID.bytes,
            account: InstallIdentity.account
        )
        var replica = try TaskReplica(
            deviceID: localID,
            persistenceURL: baseDirectory.appendingPathComponent(
                "replica-v1.json"
            )
        )
        try replica.createTask(title: "Keep through repair")
        try store.saveActive(
            PairCredentials(
                pairRoot: Data(repeating: 0xF3, count: 32),
                pairID: Data(repeating: 0xF4, count: 16),
                role: .host,
                localDeviceID: localID.bytes,
                remoteDeviceID: remoteID.bytes
            )
        )
        let damagedJournal = Data("preserve this evidence".utf8)
        try keychain.write(
            damagedJournal,
            account: CredentialStore.terminalPairingActionsAccount
        )

        let model = SyncAppModel(
            keychain: keychain,
            baseDirectory: baseDirectory,
            mailboxTransport: PairingRecoveryMailboxTransport()
        )

        XCTAssertTrue(model.isPaired)
        XCTAssertTrue(model.mailboxRequiresRepair)
        XCTAssertEqual(
            try keychain.read(
                account: CredentialStore.terminalPairingActionsAccount
            ),
            damagedJournal
        )
        let mailboxCompleted = await eventually {
            model.mailboxState == .available
        }
        XCTAssertTrue(mailboxCompleted)
        XCTAssertTrue(model.mailboxRequiresRepair)
        XCTAssertTrue(model.pairingRecoveryResetRequired)
        model.unlinkAndKeepTasks()
        XCTAssertFalse(model.pairingRecoveryResetRequired)
        XCTAssertNil(
            try keychain.read(
                account: CredentialStore.terminalPairingActionsAccount
            )
        )
        XCTAssertEqual(
            model.tasks.compactMap(\.titleValue),
            ["Keep through repair"]
        )
        model.createPrivateSync()
        XCTAssertEqual(model.phase, .waitingForPeer)
        await model.stopRuntimeForTesting()
    }

    @MainActor
    private func eventually(
        timeout: TimeInterval = 4,
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    @MainActor
    private func makeJoinerFixture(
        seed: UInt8,
        finalizationState: PairingFinalizationState? = .readyMayHaveBeenStored
    ) throws -> JoinerFixture {
        let hostID = try ReplicaDeviceID(
            bytes: Data(repeating: seed &+ 2, count: 16)
        )
        let joinerID = try ReplicaDeviceID(
            bytes: Data(repeating: seed &+ 3, count: 16)
        )
        var hostReplica = try TaskReplica(deviceID: hostID)
        try hostReplica.createTask(title: "Imported")
        let archive = try hostReplica.exportProvisioningArchive()
        let keychain = KeychainStore(
            service: "com.gotdone.relay.tests.\(UUID().uuidString)"
        )
        try keychain.write(
            joinerID.bytes,
            account: InstallIdentity.account
        )
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return JoinerFixture(
            keychain: keychain,
            credentialStore: CredentialStore(keychain: keychain),
            baseDirectory: baseDirectory,
            persistenceURL: baseDirectory.appendingPathComponent(
                "replica-v1.json"
            ),
            stagingURL: baseDirectory.appendingPathComponent(
                SyncAppModel.pairingStagingFilename
            ),
            hostID: hostID,
            joinerID: joinerID,
            archive: archive,
            pending: PendingPair(
                version: SyncProtocol.version,
                pairRoot: Data(repeating: seed, count: 32),
                pairID: Data(repeating: seed &+ 1, count: 16),
                role: .joiner,
                localDeviceID: joinerID.bytes,
                remoteDeviceID: hostID.bytes,
                archiveHash: archive.sha256,
                expiresAt: .distantPast,
                finalizationState: finalizationState
            )
        )
    }

    private func commitRecord(
        for pending: PendingPair
    ) throws -> PairingCommitRecord {
        let remoteDeviceID = try XCTUnwrap(pending.remoteDeviceID)
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

    private func credentials(
        for pending: PendingPair
    ) throws -> PairCredentials {
        PairCredentials(
            pairRoot: pending.pairRoot,
            pairID: pending.pairID,
            role: pending.role,
            localDeviceID: pending.localDeviceID,
            remoteDeviceID: try XCTUnwrap(pending.remoteDeviceID),
            pairingArchiveHash: pending.role == .joiner
                ? pending.archiveHash
                : nil
        )
    }
}

private struct JoinerFixture {
    let keychain: KeychainStore
    let credentialStore: CredentialStore
    let baseDirectory: URL
    let persistenceURL: URL
    let stagingURL: URL
    let hostID: ReplicaDeviceID
    let joinerID: ReplicaDeviceID
    let archive: Data
    let pending: PendingPair

    func cleanup() {
        try? credentialStore.clearPair()
        try? keychain.delete(account: InstallIdentity.account)
        try? FileManager.default.removeItem(at: baseDirectory)
    }
}

private struct LegacyPendingPair: Codable {
    let version: UInt8
    let pairRoot: Data
    let pairID: Data
    let role: DeviceRole
    let localDeviceID: Data
    let remoteDeviceID: Data?
    let archiveHash: Data
    let expiresAt: Date
    var finalizationState: String? = nil
}

private actor PairingRecoveryMailboxTransport: MailboxTransport {
    private var messages: [Data: [FetchedMailboxEnvelope]] = [:]
    private var cursors: [Data: [Data: UInt64]] = [:]
    private var acknowledgedMessageIDs: [Data: Set<Data>] = [:]
    private var nextCursor: UInt64 = 1
    private var putCounts: [Data: Int] = [:]
    private var fetchCounts: [Data: Int] = [:]
    private var acknowledgeCounts: [Data: Int] = [:]
    private var uniqueStoredCounts: [Data: Int] = [:]
    private let ambiguousFirstPutRoutes: Set<Data>
    private let blockedRetryRoutes: Set<Data>
    private var failedAmbiguously: Set<Data> = []
    private var blockedRetryContinuations:
        [Data: CheckedContinuation<Void, Never>] = [:]
    private var retryBlockedRoutes: Set<Data> = []
    private var releasedRetryRoutes: Set<Data> = []

    init(
        ambiguousFirstPutRoutes: Set<Data> = [],
        blockedRetryRoutes: Set<Data> = []
    ) {
        self.ambiguousFirstPutRoutes = ambiguousFirstPutRoutes
        self.blockedRetryRoutes = blockedRetryRoutes
    }

    func seed(route: Data, envelope: StoredMailboxEnvelope) {
        _ = store(route: route, envelope: envelope)
    }

    func purge(route: Data) {
        messages.removeValue(forKey: route)
        cursors.removeValue(forKey: route)
        acknowledgedMessageIDs.removeValue(forKey: route)
    }

    func put(
        route: Data,
        authorization: Data,
        messages: [StoredMailboxEnvelope]
    ) async throws -> [MailboxStoredReceipt] {
        putCounts[route, default: 0] += 1
        let failsAmbiguously = ambiguousFirstPutRoutes.contains(route)
            && failedAmbiguously.insert(route).inserted
        if failsAmbiguously {
            _ = messages.map {
                store(route: route, envelope: $0)
            }
            throw URLError(.networkConnectionLost)
        }
        if blockedRetryRoutes.contains(route),
           failedAmbiguously.contains(route),
           !releasedRetryRoutes.contains(route)
        {
            retryBlockedRoutes.insert(route)
            await withCheckedContinuation { continuation in
                blockedRetryContinuations[route] = continuation
            }
        }
        return messages.map {
            store(route: route, envelope: $0)
        }
    }

    func fetch(
        route: Data,
        authorization: Data,
        after cursor: UInt64,
        limit: Int
    ) async throws -> MailboxFetchPage {
        fetchCounts[route, default: 0] += 1
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
        acknowledgeCounts[route, default: 0] += 1
        let acknowledged = messages[route, default: []]
            .filter { $0.cursor <= cursor }
            .map(\.envelope.messageID)
        acknowledgedMessageIDs[route, default: []]
            .formUnion(acknowledged)
        messages[route] = messages[route, default: []].filter {
            $0.cursor > cursor
        }
    }

    func forget(route: Data, authorization: Data) async throws {
        messages.removeValue(forKey: route)
    }

    func putCount(route: Data) -> Int {
        putCounts[route, default: 0]
    }

    func fetchCount(route: Data) -> Int {
        fetchCounts[route, default: 0]
    }

    func acknowledgeCount(route: Data) -> Int {
        acknowledgeCounts[route, default: 0]
    }

    func uniqueStoredCount(route: Data) -> Int {
        uniqueStoredCounts[route, default: 0]
    }

    func storedMessageIDs(route: Data) -> Set<Data> {
        Set(cursors[route, default: [:]].keys)
    }

    func storedEnvelopes(route: Data) -> [StoredMailboxEnvelope] {
        messages[route, default: []].map(\.envelope)
    }

    func isRetryBlocked(route: Data) -> Bool {
        retryBlockedRoutes.contains(route)
            && blockedRetryContinuations[route] != nil
    }

    func releaseRetry(route: Data) {
        releasedRetryRoutes.insert(route)
        retryBlockedRoutes.remove(route)
        blockedRetryContinuations.removeValue(forKey: route)?.resume()
    }

    private func store(
        route: Data,
        envelope: StoredMailboxEnvelope
    ) -> MailboxStoredReceipt {
        if let cursor = cursors[route]?[envelope.messageID] {
            return MailboxStoredReceipt(
                messageID: envelope.messageID,
                cursor: cursor,
                acknowledged: acknowledgedMessageIDs[
                    route,
                    default: []
                ].contains(envelope.messageID)
            )
        }
        let cursor = nextCursor
        nextCursor += 1
        cursors[route, default: [:]][envelope.messageID] = cursor
        messages[route, default: []].append(
            FetchedMailboxEnvelope(
                cursor: cursor,
                envelope: envelope
            )
        )
        uniqueStoredCounts[route, default: 0] += 1
        return MailboxStoredReceipt(
            messageID: envelope.messageID,
            cursor: cursor
        )
    }
}
