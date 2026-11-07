import CryptoKit
import Foundation
import GotSyncMLS
import SQLite3
import XCTest
@testable import GotSync

/// Ten devices, each with its own identity, storage, and secret store, share
/// one group on the real relay that `scripts/test-integration.sh` starts.
/// Every device connects from 127.0.0.1, so the relay sees one source, as it
/// would for devices behind one NAT.
@MainActor
final class TenDeviceAcceptanceTests: XCTestCase {
    private var root: URL!
    private var relayURL: URL!
    private var mailboxURL: URL!
    private var metricsURL: URL!
    private var database: URL!
    private var stores: [String: MemorySecretStore] = [:]
    private var engines: [String: SyncEngine] = [:]
    private let profile = try! SyncGroupProfile(
        application: "org.gotsync.acceptance", schema: .taskReplica, memberLimit: SyncGroupProfile.supportedMemberCeiling
    )

    override func setUp() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GOTSYNC_INTEGRATION"] == "1" else {
            if environment["GOTSYNC_REQUIRE_INTEGRATION"] == "1" {
                XCTFail("The required relay integration environment is missing.")
            }
            throw XCTSkip("Run scripts/test-integration.sh to start the real relay.")
        }
        relayURL = try XCTUnwrap(URL(string: environment["GOTSYNC_RELAY_URL"] ?? ""))
        mailboxURL = try XCTUnwrap(URL(string: environment["GOTSYNC_MAILBOX_URL"] ?? ""))
        metricsURL = try XCTUnwrap(URL(string: environment["GOTSYNC_METRICS_URL"] ?? ""))
        database = URL(fileURLWithPath: try XCTUnwrap(environment["GOTSYNC_RELAY_DATABASE"]))
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() async throws {
        for engine in engines.values { await engine.stop() }
        engines = [:]
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testTenDevicesShareOneGroupOnOneSourceAddress() async throws {
        let before = try await counters()
        var linked = [start("device-0")]
        XCTAssertTrue(linked[0].addTask(title: "Device 0"))
        for index in 1..<profile.memberLimit {
            let joiner = start("device-\(index)")
            XCTAssertTrue(joiner.addTask(title: "Device \(index)"))
            try await pair(linked[(index - 1) / 2], joiner, usePhrase: index.isMultiple(of: 2))
            linked.append(joiner)
        }
        let titles = Set((0..<profile.memberLimit).map { "Device \($0)" })
        try await converge("ten devices", linked, titles: titles)
        let group = try await groupID(linked[0])
        try await assertRelayWritersMatchRoster(group: group, engines: linked, count: 10)
        for engine in linked {
            XCTAssertEqual(engine.memberLimit, 10)
            let stored = try await XCTUnwrapAsync(engine.mlsSessionForTesting).groupProfile()
            XCTAssertEqual(stored, profile.descriptor)
        }

        try await assertEleventhRefused(by: linked[3], group: group, engines: linked)

        await linked[3].stop()
        await linked[7].stop()
        XCTAssertTrue(linked[5].addTask(title: "While two were stopped"))
        linked[3] = start("device-3")
        linked[7] = start("device-7")
        XCTAssertTrue(linked[3].isPaired && linked[7].isPaired)
        XCTAssertTrue(linked[7].addTask(title: "After restart"))
        var expected = titles.union(["While two were stopped", "After restart"])
        try await converge("restarted devices", linked, titles: expected)

        let removed = linked.remove(at: 5)
        let removedAuthorization = try await authorization(removed)
        let removedFingerprint = try await fingerprint(removed)
        XCTAssertTrue(linked[0].removeDevice(fingerprint: removedFingerprint))
        try await wait("removal") {
            !removed.isPaired && linked.allSatisfy { $0.linkedMemberCount == 9 }
        }
        XCTAssertEqual(removed.linkEndedReason, .removedFromGroup)
        try await assertRelayWritersMatchRoster(group: group, engines: linked, count: 9)
        do {
            _ = try await transport().fetch(group: group, after: 0, limit: 8, authorization: removedAuthorization)
            XCTFail("The relay served a removed device")
        } catch MLSRelayError.unauthorized {}

        let replacement = start("device-10")
        XCTAssertTrue(replacement.addTask(title: "Replacement"))
        try await pair(linked[2], replacement, usePhrase: true)
        linked.append(replacement)
        expected.insert("Replacement")
        try await converge("replacement", linked, titles: expected)
        try await assertRelayWritersMatchRoster(group: group, engines: linked, count: 10)

        let leaving = linked.remove(at: 8)
        let leavingFingerprint = try await fingerprint(leaving)
        XCTAssertTrue(linked[0].removeDevice(fingerprint: leavingFingerprint))
        try await wait("second removal") { !leaving.isPaired && linked.allSatisfy { $0.linkedMemberCount == 9 } }
        let racers = [start("device-11"), start("device-12")]
        try await approveConcurrently(inviters: [linked[1], linked[6]], joiners: racers)
        let admitted = racers.filter(\.isPaired)
        XCTAssertEqual(admitted.count, 1, "exactly one of two concurrent joiners fits the tenth slot")
        linked += admitted
        try await wait("tenth slot taken") { linked.allSatisfy { $0.linkedMemberCount == 10 } }
        for refused in racers where !refused.isPaired {
            let leftover = try await refused.mlsSessionForTesting?.group()
            XCTAssertNil(leftover, "the refused joiner kept MLS group state")
        }
        let refusals = [linked[1], linked[6]].compactMap(\.lastPairingFailure)
        XCTAssertEqual(refusals, [.groupAtCapacity])
        try await converge("after concurrent invitations", linked, titles: expected)
        try await assertRelayWritersMatchRoster(group: group, engines: linked, count: 10)

        let idleStart = try await counters()
        let idleWindow: Double = 20
        try await Task.sleep(for: .seconds(idleWindow))
        let idleEnd = try await counters()
        let idleRate = Double(idleEnd["delivery_requests", default: 0] - idleStart["delivery_requests", default: 0]) / idleWindow
        print("ten-device idle delivery requests per second from one source: \(idleRate)")
        XCTAssertLessThan(idleRate, 40, "idle traffic must stay below the default per-source rate")

        let after = try await counters()
        for counter in ["rate_limit_rejections", "source_concurrency_rejections", "admission_rejections", "internal_errors"] {
            XCTAssertEqual(after[counter, default: 0] - before[counter, default: 0], 0, counter)
        }
        print("ten-device delivery requests during the whole run: \(after["delivery_requests", default: 0] - before["delivery_requests", default: 0])")
    }

    private func start(_ name: String) -> SyncEngine {
        let store = stores[name] ?? MemorySecretStore()
        stores[name] = store
        let configuration = try! SyncConfiguration(
            relayURL: relayURL,
            mailboxURL: mailboxURL,
            storageDirectory: root.appendingPathComponent(name),
            invitationURLScheme: "gotsync-tests",
            endpointPolicy: .localDevelopment,
            groupProfile: profile
        )
        let engine = SyncEngine(configuration: configuration, secretStore: store, pairingRetryDelayNanoseconds: 100_000_000)
        engines[name] = engine
        return engine
    }

    private func transport() -> HTTPMLSRelayTransport {
        HTTPMLSRelayTransport(baseURL: mailboxURL, policy: .localDevelopment)
    }

    private func invite(_ inviter: SyncEngine) async throws -> URL {
        try await wait("inviter has reservations") { !inviter.awaitsReservationsForTesting }
        inviter.createPrivateSync()
        try await wait("invitation") { inviter.invitationURL != nil }
        return try XCTUnwrap(inviter.invitationURL)
    }

    private func pair(_ inviter: SyncEngine, _ joiner: SyncEngine, usePhrase: Bool) async throws {
        let url = try await invite(inviter)
        if usePhrase {
            joiner.joinPrivateSync(phrase: try XCTUnwrap(inviter.invitationPhrase))
        } else {
            joiner.joinPrivateSync(url: url)
        }
        try await wait("safety code") { inviter.isHostApprovalPending && joiner.safetyCode != nil }
        XCTAssertEqual(inviter.safetyCode, joiner.safetyCode)
        inviter.approveSafetyCode()
        try await wait("paired") { inviter.isPaired && joiner.isPaired && !inviter.canCancelPairing }
    }

    private func approveConcurrently(inviters: [SyncEngine], joiners: [SyncEngine]) async throws {
        for (inviter, joiner) in zip(inviters, joiners) {
            joiner.joinPrivateSync(url: try await invite(inviter))
        }
        try await wait("both safety codes") {
            inviters.allSatisfy(\.isHostApprovalPending) && joiners.allSatisfy { $0.safetyCode != nil }
        }
        for inviter in inviters { inviter.approveSafetyCode() }
        try await wait("both decisions final") {
            inviters.allSatisfy { !$0.canCancelPairing } && joiners.allSatisfy { $0.isPaired || $0.phase == .failed }
        }
    }

    private func converge(_ stage: String, _ engines: [SyncEngine], titles: Set<String>) async throws {
        try await wait(stage) {
            engines.allSatisfy {
                Set($0.tasks.compactMap(\.titleValue)) == titles && $0.pendingMailboxOperationCount == 0
                    && $0.linkedMemberCount == engines.count && $0.phase == .synced
            }
        }
        let snapshots = Set(engines.map { $0.tasks.map { "\($0.id)|\($0.titleValue ?? "")|\(String(describing: $0.isCompleted))" }.sorted() })
        XCTAssertEqual(snapshots.count, 1, "\(stage): devices hold different task state")
    }

    /// Tries to add an eleventh device three ways: through the engine, by
    /// committing an Add directly, and by asking the relay for an eleventh
    /// writer. Nothing may change the roster or the relay's writers.
    private func assertEleventhRefused(by inviter: SyncEngine, group: Data, engines: [SyncEngine]) async throws {
        XCTAssertTrue(inviter.isGroupAtCapacity)
        inviter.inviteToGroup()
        XCTAssertEqual(inviter.errorMessage, SyncError.groupAtCapacity.errorDescription)
        XCTAssertNil(inviter.invitationURL)

        let outsider = try MLSSession(
            directory: root.appendingPathComponent("outsider-mls"),
            deviceID: Data.secureRandom(count: 16),
            secretStore: MemorySecretStore(),
            transport: transport()
        )
        let token = try Data.secureRandom(count: 32)
        let session = try XCTUnwrap(inviter.mlsSessionForTesting)
        let published = try await outsider.publishKeyPackage(pairingToken: token, profile: profile.descriptor)
        let keyPackage = try await XCTUnwrapAsync(await session.fetchKeyPackage(reference: published.reference, pairingToken: token))
        do {
            _ = try await session.add(keyPackage: keyPackage, verifiedFingerprint: published.fingerprint, reference: published.reference)
            XCTFail("The MLS library prepared an eleventh Add")
        } catch {}
        let pending = try await session.pendingDelivery()
        XCTAssertNil(pending)

        let second = try await outsider.publishKeyPackage(pairingToken: token, profile: profile.descriptor)
        let outsiderWriter = Data(SHA256.hash(data: try await outsider.client.transportAuthorization()))
        let forged = MLSDelivery(
            group: group, epoch: try await session.epoch(), kind: .commit, payload: try Data.secureRandom(count: 64),
            welcome: try Data.secureRandom(count: 64), keyPackageReference: second.reference, addWriter: outsiderWriter
        )
        let inviterAuthorization = try await authorization(inviter)
        let refused = try await transport().append(forged, authorization: inviterAuthorization)
        XCTAssertEqual(refused, .keyPackageUnavailable(epoch: forged.epoch), "the relay admitted an eleventh writer")
        let repeated = try await transport().append(forged, authorization: inviterAuthorization)
        XCTAssertEqual(repeated, refused, "the refusal is not journaled")
        XCTAssertTrue(try relayStillHoldsPackage(second.reference))
        try await assertRelayWritersMatchRoster(group: group, engines: engines, count: 10)
    }

    private func assertRelayWritersMatchRoster(
        group: Data, engines: [SyncEngine], count: Int, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let roster = try await XCTUnwrapAsync(engines[0].mlsSessionForTesting).members()
        XCTAssertEqual(roster.count, count, file: file, line: line)
        for engine in engines {
            let members = try await XCTUnwrapAsync(engine.mlsSessionForTesting).members()
            XCTAssertEqual(Set(members.map(\.fingerprint)), Set(roster.map(\.fingerprint)), file: file, line: line)
        }
        XCTAssertEqual(try relayWriters(group: group), Set(roster.map(\.writerHash)), file: file, line: line)
    }

    private func query(_ sql: String, _ value: Data, row: (OpaquePointer) -> Void) throws {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(connection)
            throw AcceptanceError.relayDatabase
        }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 5000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw AcceptanceError.relayDatabase
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), transient) }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: row(statement)
            case SQLITE_DONE: return
            default: throw AcceptanceError.relayDatabase
            }
        }
    }

    private func relayWriters(group: Data) throws -> Set<Data> {
        var writers: Set<Data> = []
        try query("SELECT digest FROM mls_writers WHERE route=? AND removal IS NULL", group) { statement in
            if let bytes = sqlite3_column_blob(statement, 0) {
                writers.insert(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
            }
        }
        return writers
    }

    private func relayStillHoldsPackage(_ reference: Data) throws -> Bool {
        var held = false
        try query("SELECT payload IS NOT NULL FROM mls_packages WHERE reference=?", reference) { statement in
            held = sqlite3_column_int(statement, 0) == 1
        }
        return held
    }

    private func counters() async throws -> [String: Int] {
        let (data, _) = try await URLSession.shared.data(from: metricsURL)
        let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(snapshot?["counters"] as? [String: Int])
    }

    private func groupID(_ engine: SyncEngine) async throws -> Data {
        try await XCTUnwrapAsync(await engine.mlsSessionForTesting?.group())
    }

    private func fingerprint(_ engine: SyncEngine) async throws -> Data {
        try await XCTUnwrapAsync(await engine.mlsSessionForTesting?.fingerprint())
    }

    private func authorization(_ engine: SyncEngine) async throws -> Data {
        try await XCTUnwrapAsync(engine.mlsSessionForTesting).client.transportAuthorization()
    }

    private func wait(_ stage: String, file: StaticString = #filePath, line: UInt = #line, until predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                let details = engines.sorted { $0.key < $1.key }.map {
                    "\($0.key) \($0.value.phase) members=\($0.value.linkedMemberCount) tasks=\($0.value.tasks.count): \($0.value.errorMessage ?? $0.value.mailboxErrorMessage ?? "no error")"
                }.joined(separator: "; ")
                XCTFail("Timed out at \(stage): \(details)", file: file, line: line)
                throw AcceptanceError.timeout
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

private enum AcceptanceError: Error {
    case timeout
    case relayDatabase
}

private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
