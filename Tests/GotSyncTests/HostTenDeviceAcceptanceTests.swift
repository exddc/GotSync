import Foundation
import GotSyncMLS
import XCTest
@testable import GotSync

/// Ten host-journal devices share one group on the real relay that
/// `scripts/test-integration.sh` starts, each with its own identity,
/// storage, secret store and host journal.
@MainActor
final class HostTenDeviceAcceptanceTests: XCTestCase {
    private var root: URL!
    private var relayURL: URL!
    private var mailboxURL: URL!
    private var metricsURL: URL!
    private var stores: [String: MemorySecretStore] = [:]
    private var engines: [String: SyncEngine] = [:]
    private var provenances: [String: HostJournalProvenance] = [:]
    private var captured: [String: UInt64] = [:]
    private var applied: [String: [String]] = [:]
    private var appliedThrough: [String: UInt64] = [:]
    private let profile = try! SyncGroupProfile(
        application: "org.gotsync.host-acceptance", schema: .hostJournal(payload: "example.records", version: 1),
        memberLimit: SyncGroupProfile.supportedMemberCeiling
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
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() async throws {
        for engine in engines.values { await engine.stop() }
        engines = [:]
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testTenHostsShareOneJournalGroup() async throws {
        let before = try await counters()
        var names = ["host-0"]
        var linked = [start("host-0")]
        for index in 1..<profile.memberLimit {
            let name = "host-\(index)"
            let joiner = start(name)
            let inviter = linked[(index - 1) / 2]
            try await pair(inviter, joiner, usePhrase: index.isMultiple(of: 2))
            try await prepare(inviter, names[(index - 1) / 2])
            try await prepare(joiner, name)
            names.append(name)
            linked.append(joiner)
        }
        try await converge("ten hosts", names)
        for engine in linked {
            XCTAssertEqual(engine.memberLimit, 10)
            XCTAssertNil(engine.hostRepair)
        }

        await linked[3].stop()
        await linked[7].stop()
        try await submit(linked[5], names[5], ["while two were stopped"])
        linked[3] = start(names[3])
        linked[7] = start(names[7])
        XCTAssertTrue(linked[3].isPaired && linked[7].isPaired)
        try await resume(linked[3], names[3])
        try await resume(linked[7], names[7])
        try await submit(linked[7], names[7], ["after restart"])
        try await converge("restarted hosts", names)

        let removed = linked.remove(at: 5)
        let removedName = names.remove(at: 5)
        let removedJournal = try XCTUnwrap(removed.hostJournal).view.journalID
        let removedFingerprint = try await XCTUnwrapAsync(await removed.mlsSessionForTesting?.fingerprint())
        XCTAssertTrue(linked[0].removeDevice(fingerprint: removedFingerprint))
        try await wait("removal") {
            !removed.isPaired && removed.hostLifecycle == .active && linked.allSatisfy { $0.linkedMemberCount == 9 }
        }
        XCTAssertEqual(removed.linkEndedReason, .removedFromGroup)
        let retired = try HostJournalStore.open(HostJournalStore.fileURL(in: root.appendingPathComponent(removedName), journalID: removedJournal))
        XCTAssertEqual(retired.view.retirement, .removed)

        let replacement = start("host-10")
        try await pair(linked[2], replacement, usePhrase: true)
        try await prepare(replacement, "host-10")
        linked.append(replacement)
        names.append("host-10")
        try await converge("replacement", names)

        let idleStart = try await counters()
        let idleWindow: Double = 20
        try await Task.sleep(for: .seconds(idleWindow))
        let idleEnd = try await counters()
        let idleRate = Double(idleEnd["delivery_requests", default: 0] - idleStart["delivery_requests", default: 0]) / idleWindow
        print("ten-host idle delivery requests per second from one source: \(idleRate)")
        XCTAssertLessThan(idleRate, 40, "idle traffic must stay below the default per-source rate")
        try await wait("idle hosts quiescent together") { linked.allSatisfy { $0.hostView?.isQuiescent == true } }

        let after = try await counters()
        for counter in ["rate_limit_rejections", "source_concurrency_rejections", "admission_rejections", "internal_errors"] {
            XCTAssertEqual(after[counter, default: 0] - before[counter, default: 0], 0, counter)
        }
        print("ten-host delivery requests during the whole run: \(after["delivery_requests", default: 0] - before["delivery_requests", default: 0])")
    }

    // MARK: - Harness

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

    /// Enrolls once, submits one record named after the device and declares
    /// readiness, so the device may invite and provide history.
    private func prepare(_ engine: SyncEngine, _ name: String) async throws {
        guard provenances[name] == nil else { return }
        let journal = try XCTUnwrap(engine.hostJournal)
        provenances[name] = try await journal.resume(try await journal.enroll())
        try await submit(engine, name, [name])
        try await journal.declareReady(capturedThrough: captured[name, default: 0])
    }

    private func resume(_ engine: SyncEngine, _ name: String) async throws {
        try await wait("\(name) opened") { engine.hostLifecycle != .opening }
        let stored = try XCTUnwrap(provenances[name])
        provenances[name] = try await XCTUnwrap(engine.hostJournal).resume(HostJournalProvenance(
            journalID: stored.journalID, enrollmentID: stored.enrollmentID,
            appliedThrough: appliedThrough[name, default: 0], capturedThrough: captured[name, default: 0]
        ))
    }

    private func submit(_ engine: SyncEngine, _ name: String, _ payloads: [String]) async throws {
        captured[name, default: 0] += UInt64(payloads.count)
        _ = try await XCTUnwrap(engine.hostJournal).submit(
            payloads.map { HostJournalMutation(id: HostJournalStore.randomBytes(16), payload: Data($0.utf8)) },
            capturedThrough: captured[name, default: 0]
        )
    }

    /// Applies what has arrived, as a host would, and reports whether the
    /// device holds every other device's records with complete history.
    private func settled(_ name: String, expecting count: Int) async -> Bool {
        guard let engine = engines[name], let journal = engine.hostJournal else { return false }
        while let batch = try? await journal.incoming(after: journal.view.appliedThrough, limit: 64), let last = batch.last {
            applied[name, default: []] += batch.map { String(decoding: $0.payload, as: UTF8.self) }
            guard (try? await journal.markApplied(through: last.position)) != nil else { return false }
            appliedThrough[name] = last.position
        }
        let view = journal.view
        return view.historyApplied && Int(view.recordCount) == count
            && engine.hostView?.isQuiescent == true && engine.phase == .synced
    }

    private func converge(_ stage: String, _ names: [String]) async throws {
        let expected = captured.values.reduce(0) { $0 + Int($1) }
        try await wait(stage) {
            for name in names {
                guard await self.settled(name, expecting: expected), self.engines[name]?.linkedMemberCount == names.count else { return false }
            }
            return true
        }
        let heads = Set(names.compactMap { self.engines[$0]?.hostJournal?.receivedVector })
        XCTAssertEqual(heads.count, 1, "\(stage): devices hold different journals")
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

    private func counters() async throws -> [String: Int] {
        let (data, _) = try await URLSession.shared.data(from: metricsURL)
        let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(snapshot?["counters"] as? [String: Int])
    }

    private func wait(_ stage: String, file: StaticString = #filePath, line: UInt = #line, until predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        while await !predicate() {
            guard ContinuousClock.now < deadline else {
                let details = engines.sorted { $0.key < $1.key }.map {
                    let view = $0.value.hostJournal?.view
                    return "\($0.key) \($0.value.phase) members=\($0.value.linkedMemberCount) records=\(view?.recordCount ?? 0) complete=\(view?.historyComplete ?? false) quiescent=\($0.value.hostView?.isQuiescent ?? false): \($0.value.errorMessage ?? $0.value.mailboxErrorMessage ?? "no error")"
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
}

private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
