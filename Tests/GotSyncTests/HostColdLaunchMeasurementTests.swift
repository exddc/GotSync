import Foundation
import XCTest
@_spi(HostJournalPreview) @testable import GotSync

/// One process-cold launch of a full journal: archive discovery, validation
/// on a detached task's own connection, and the main-actor install. Run once
/// per process with `GOTSYNC_COLD_LAUNCH_DIR` naming a fixture directory under
/// the temporary directory; the first run only builds the fixture.
@MainActor
final class HostColdLaunchMeasurementTests: XCTestCase {
    func testColdLaunchOfAFullJournalWithFourArchives() async throws {
        guard let name = ProcessInfo.processInfo.environment["GOTSYNC_COLD_LAUNCH_DIR"] else {
            throw XCTSkip("Set GOTSYNC_COLD_LAUNCH_DIR to measure a cold launch.")
        }
        let directory = Self.fixture(name)
        let marker = directory.appendingPathComponent("journal-id")
        guard let journalID = try? Data(contentsOf: marker) else {
            try buildFixture(in: directory, marker: marker)
            print("COLD_LAUNCH fixture built")
            return
        }
        let url = HostJournalStore.fileURL(in: directory, journalID: journalID)
        let launch = ContinuousClock.now
        let listings = try HostJournalFiles.discover(in: directory)
        let discovered = ContinuousClock.now
        let cancellation = HostJournalCancellation()
        let prepared = try await Task.detached(priority: .userInitiated) {
            try HostJournalPreparation.prepare(url, cancellation: cancellation)
        }.value
        let installing = ContinuousClock.now
        let store = try XCTUnwrap(try HostJournalStore.install(prepared))
        let ready = ContinuousClock.now
        XCTAssertEqual(listings.count, 5)
        XCTAssertEqual(store.view.recordCount, 120_000)
        print(String(
            format: "COLD_LAUNCH ready=%.2fms discover=%.2fms prepare=%.2fms install=%.2fms",
            Self.milliseconds(ready - launch), Self.milliseconds(discovered - launch),
            Self.milliseconds(installing - discovered), Self.milliseconds(ready - installing)
        ))
    }

    private func buildFixture(in directory: URL, marker: URL) throws {
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for _ in 0..<4 {
            try HostJournalStore.create(in: directory, group: JournalFixture.group).retire(.unlink, heldInbox: [])
        }
        let store = try HostJournalStore.create(in: directory, group: JournalFixture.group)
        let origin = JournalFixture.origin(7)
        var prior = JournalEnvelope.zeroDigest
        for (cursor, start) in stride(from: 1, through: 120_000, by: 256).enumerated() {
            let run = try JournalFixture.chain(origin, count: min(256, 120_001 - start), from: UInt64(start), prior: prior, payload: { _ in Data(count: 40) })
            _ = try store.intake([JournalFixture.arrival(run, cursor: UInt64(cursor + 1))])
            prior = run.last!.digest
        }
        XCTAssertEqual(store.view.recordCount, 120_000)
        try store.view.journalID.write(to: marker)
    }

    /// One process-cold engine launch: `SyncEngine` init, which discovers and
    /// classifies the journals synchronously, then validation away from the
    /// main actor and install, until the engine is active. Reconcile and every
    /// network request start only afterwards and are not measured. Run once per
    /// process with `GOTSYNC_ENGINE_COLD_LAUNCH_DIR`; the first run only builds
    /// the paired fixture.
    func testEngineColdLaunchWithAFullJournalAndFourArchives() async throws {
        guard let name = ProcessInfo.processInfo.environment["GOTSYNC_ENGINE_COLD_LAUNCH_DIR"] else {
            throw XCTSkip("Set GOTSYNC_ENGINE_COLD_LAUNCH_DIR to measure an engine cold launch.")
        }
        let root = Self.fixture(name)
        let marker = root.appendingPathComponent("built")
        guard FileManager.default.fileExists(atPath: marker.path) else {
            try await buildEngineFixture(in: root)
            try Data().write(to: marker)
            print("ENGINE_COLD_LAUNCH fixture built")
            return
        }
        var scopes: [(String, ContinuousClock.Instant)] = []
        SyncEngine.initScopeHookForTesting = { scopes.append(($0, .now)) }
        defer { SyncEngine.initScopeHookForTesting = nil }
        let launch = ContinuousClock.now
        let engine = Self.engine(root.appendingPathComponent("b"), relay: FakeMLSRelay(), rendezvous: FakePairingRendezvous())
        let initialized = ContinuousClock.now
        SyncEngine.initScopeHookForTesting = nil
        var previous = launch
        let breakdown = scopes.map { name, instant -> String in
            defer { previous = instant }
            return String(format: "%@=%.2f", name, Self.milliseconds(instant - previous))
        }.joined(separator: " ")
        print("ENGINE_INIT_SCOPES \(breakdown)")
        var prepared: ContinuousClock.Instant?
        engine.preparedJournalHookForTesting = { _ in prepared = .now }
        XCTAssertEqual(engine.hostLifecycle, .opening)
        while engine.hostLifecycle == .opening {
            try await Task.sleep(for: .milliseconds(1))
        }
        let ready = ContinuousClock.now
        XCTAssertEqual(engine.hostLifecycle, .active)
        XCTAssertNil(engine.hostRepair)
        XCTAssertEqual(engine.hostView?.journal?.recordCount, 120_000)
        await engine.stop()
        print(String(
            format: "ENGINE_COLD_LAUNCH ready=%.2fms init=%.2fms preparedAfter=%.2fms",
            Self.milliseconds(ready - launch), Self.milliseconds(initialized - launch),
            Self.milliseconds((prepared ?? ready) - launch)
        ))
    }

    /// An absolute path is used as given, so simulator runs share one fixture.
    private static func fixture(_ name: String) -> URL {
        name.hasPrefix("/") ? URL(fileURLWithPath: name, isDirectory: true)
            : FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
    }

    private static let profile = try! SyncGroupProfile(
        application: "org.gotsync.host", schema: .hostJournal(payload: "example.records", version: 1), memberLimit: 10
    )

    private static func engine(_ directory: URL, relay: FakeMLSRelay, rendezvous: FakePairingRendezvous) -> SyncEngine {
        SyncEngine(
            configuration: try! SyncConfiguration(
                relayURL: TestEndpoints.relayURL, mailboxURL: TestEndpoints.mailboxURL, storageDirectory: directory,
                invitationURLScheme: "gotsync-tests", endpointPolicy: .localDevelopment, groupProfile: profile
            ),
            secretStore: FileSecretStore(url: directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + ".secrets")),
            backgroundMailboxScheduler: nil,
            pairingRetryDelayNanoseconds: 20_000_000,
            mlsTransport: relay,
            rendezvous: rendezvous,
            syncIntervalNanoseconds: 50_000_000
        )
    }

    private func buildEngineFixture(in root: URL) async throws {
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let relay = FakeMLSRelay()
        let rendezvous = FakePairingRendezvous()
        let a = Self.engine(root.appendingPathComponent("a"), relay: relay, rendezvous: rendezvous)
        let b = Self.engine(root.appendingPathComponent("b"), relay: relay, rendezvous: rendezvous)
        func wait(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while !condition() {
                guard ContinuousClock.now < deadline else { throw CancellationError() }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try await wait { !a.canCancelPairing }
        a.createPrivateSync()
        try await wait { a.invitationURL != nil }
        b.joinPrivateSync(url: try XCTUnwrap(a.invitationURL))
        try await wait { a.isHostApprovalPending && b.safetyCode != nil }
        a.approveSafetyCode()
        try await wait { a.isPaired && b.isPaired && !a.canCancelPairing && b.hostJournal != nil }
        await a.stop()
        await b.stop()
        let journalID = try XCTUnwrap(b.hostView?.journal?.journalID)
        let journal = try HostJournalStore.open(HostJournalStore.fileURL(in: root.appendingPathComponent("b"), journalID: journalID))
        let origin = JournalFixture.origin(7)
        var prior = JournalEnvelope.zeroDigest
        for (cursor, start) in stride(from: 1, through: 120_000, by: 256).enumerated() {
            let run = try JournalFixture.chain(origin, count: min(256, 120_001 - start), from: UInt64(start), prior: prior, payload: { _ in Data(count: 40) })
            _ = try journal.intake([JournalFixture.arrival(run, cursor: UInt64(cursor + 1))])
            prior = run.last!.digest
        }
        XCTAssertEqual(journal.view.recordCount, 120_000)
        for _ in 0..<4 {
            try HostJournalStore.create(in: root.appendingPathComponent("b"), group: JournalFixture.group).retire(.unlink, heldInbox: [])
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1e3 + Double(duration.components.attoseconds) / 1e15
    }
}

/// A secret store kept in one file, so a later process opens the same keys.
final class FileSecretStore: SecretStore, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    init(url: URL) {
        self.url = url
    }

    private func load() -> [String: Data] {
        (try? JSONDecoder().decode([String: Data].self, from: Data(contentsOf: url))) ?? [:]
    }

    func read(account: String) throws -> Data? { lock.withLock { load()[account] } }

    func write(_ data: Data, account: String) throws {
        try write(data, account: account, accessibility: .whenUnlockedThisDeviceOnly)
    }

    func write(_ data: Data, account: String, accessibility: SecretAccessibility) throws {
        try lock.withLock {
            var values = load()
            values[account] = data
            try JSONEncoder().encode(values).write(to: url, options: .atomic)
        }
    }

    func delete(account: String) throws {
        try lock.withLock {
            var values = load()
            values.removeValue(forKey: account)
            try JSONEncoder().encode(values).write(to: url, options: .atomic)
        }
    }
}
