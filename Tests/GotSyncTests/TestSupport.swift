import CryptoKit
import Foundation
import GotSyncMLS
@testable import GotSync

final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var accessibilities: [String: SecretAccessibility] = [:]
    init(service: String = UUID().uuidString) {}
    func read(account: String) throws -> Data? { lock.withLock { values[account] } }
    func write(_ data: Data, account: String) throws {
        try write(data, account: account, accessibility: .whenUnlockedThisDeviceOnly)
    }
    func write(_ data: Data, account: String, accessibility: SecretAccessibility) throws {
        lock.withLock {
            values[account] = data
            accessibilities[account] = accessibility
        }
    }
    func delete(account: String) throws {
        lock.withLock {
            values.removeValue(forKey: account)
            accessibilities.removeValue(forKey: account)
        }
    }
    func accessibility(account: String) -> SecretAccessibility? { lock.withLock { accessibilities[account] } }
}

enum TestEndpoints {
    static let relayURL = URL(string: "ws://127.0.0.1:8765/v2/pairing")!
    static let mailboxURL = URL(string: "http://127.0.0.1:8767/v2/mls")!
}

@MainActor
extension SyncEngine {
    convenience init(
        keychain: any SecretStore = MemorySecretStore(),
        baseDirectory: URL? = nil,
        relayURL: URL = TestEndpoints.relayURL,
        mailboxURL: URL = TestEndpoints.mailboxURL,
        backgroundMailboxScheduler: (any BackgroundMailboxScheduling)? = nil,
        pairingRetryDelayNanoseconds: UInt64 = 1_000_000_000,
        mlsTransport: (any MLSRelayTransport)? = nil,
        rendezvous: (any PairingRendezvous)? = nil,
        syncIntervalNanoseconds: UInt64 = 2_000_000_000
    ) {
        let directory = baseDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = try! SyncConfiguration(relayURL: relayURL, mailboxURL: mailboxURL, storageDirectory: directory, invitationURLScheme: "gotsync-tests", endpointPolicy: .localDevelopment)
        self.init(
            configuration: configuration,
            secretStore: keychain,
            backgroundMailboxScheduler: backgroundMailboxScheduler,
            pairingRetryDelayNanoseconds: pairingRetryDelayNanoseconds,
            mlsTransport: mlsTransport,
            rendezvous: rendezvous,
            syncIntervalNanoseconds: syncIntervalNanoseconds
        )
    }
}

@MainActor
final class RecordingBackgroundMailboxScheduler: BackgroundMailboxScheduling {
    private(set) var scheduleCalls: [Int] = []
    private(set) var cancelCount = 0
    private(set) var isRegistered = false
    var handler: (@MainActor () async -> Void)?
    func register(handler: @escaping @MainActor () async -> Void) { self.handler = handler; isRegistered = true }
    func scheduleFlushIfNeeded(pendingOperationCount: Int) { scheduleCalls.append(pendingOperationCount); if pendingOperationCount <= 0 { cancelCount += 1 } }
    func cancelFlush() { cancelCount += 1 }
    func fireHandlerForTesting() async { await handler?() }
}

final class FakePairingConnection: PairingConnection, @unchecked Sendable {
    let route: Data
    private let rendezvous: FakePairingRendezvous
    private let lock = NSLock()
    private var buffer: [RelayEvent] = []
    private var waiter: CheckedContinuation<RelayEvent, Error>?
    private var closed = false

    init(route: Data, rendezvous: FakePairingRendezvous) {
        self.route = route
        self.rendezvous = rendezvous
    }

    func deliver(_ event: RelayEvent) {
        lock.lock()
        guard !closed else { return lock.unlock() }
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: event)
        } else {
            buffer.append(event)
            lock.unlock()
        }
    }

    func close() {
        lock.lock()
        closed = true
        let waiter = waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(throwing: RelaySocketError.notConnected)
    }

    func receive() async throws -> RelayEvent {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !buffer.isEmpty {
                let event = buffer.removeFirst()
                lock.unlock()
                continuation.resume(returning: event)
            } else if closed {
                lock.unlock()
                continuation.resume(throwing: RelaySocketError.notConnected)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func send(_ data: Data) async throws {
        try await rendezvous.forward(data, from: self)
    }

    func cancel() async {
        await rendezvous.leave(self)
    }
}

/// In-memory stand-in for the relay's two-socket pairing rooms. The
/// interceptor sees every forwarded frame and returns the frames to deliver.
actor FakePairingRendezvous: PairingRendezvous {
    typealias Interceptor = @Sendable (Data) -> [Data]

    private var rooms: [Data: [FakePairingConnection]] = [:]
    private var interceptor: Interceptor?

    func setInterceptor(_ interceptor: Interceptor?) { self.interceptor = interceptor }

    func connect(route: Data) async throws -> any PairingConnection {
        var members = rooms[route, default: []]
        guard members.count < 2 else { throw RelaySocketError.notConnected }
        let connection = FakePairingConnection(route: route, rendezvous: self)
        members.append(connection)
        rooms[route] = members
        if members.count == 2 {
            for member in members { member.deliver(.peerReady) }
        }
        return connection
    }

    func forward(_ data: Data, from sender: FakePairingConnection) throws {
        guard rooms[sender.route]?.contains(where: { $0 === sender }) == true else { throw RelaySocketError.notConnected }
        let frames = interceptor?(data) ?? [data]
        for peer in rooms[sender.route] ?? [] where peer !== sender {
            for frame in frames { peer.deliver(.binary(frame)) }
        }
    }

    func leave(_ connection: FakePairingConnection) {
        connection.close()
        guard var members = rooms[connection.route], members.contains(where: { $0 === connection }) else { return }
        members.removeAll { $0 === connection }
        rooms[connection.route] = members.isEmpty ? nil : members
        for peer in members { peer.deliver(.peerLeft) }
    }
}

actor FakeMLSRelay: MLSRelayTransport {
    private struct Group {
        var epoch: UInt64 = 0
        var writers: [Data: (ack: UInt64, removal: UInt64?)] = [:]
    }

    private var packages: [Data: (payload: Data?, writer: Data, pairing: Data)] = [:]
    private var published: [Data: Data] = [:]
    private var nextFetchSubstitute: Data?
    private var groups: [Data: Group] = [:]
    private var entries: [MLSRelayEntry] = []
    private var dropAppendResponse = false
    private var appendsUnavailable = false
    private(set) var rejectedAppends = 0
    private var failWelcomeAcknowledgement = false
    private var failingAcknowledgers: Set<Data> = []
    private var expiredGroups: Set<Data> = []
    private(set) var lastPublishedReference: Data?
    private(set) var acknowledgementCount = 0

    func dropNextAppendResponse() { dropAppendResponse = true }
    func setAppendsUnavailable(_ unavailable: Bool) { appendsUnavailable = unavailable }
    func expireHistory(group: Data) { expiredGroups.insert(group) }

    func removalCursor(of authorization: Data, group: Data) -> UInt64? {
        groups[group]?.writers[Self.digest(authorization)]?.removal ?? nil
    }

    func failNextWelcomeAcknowledgement() { failWelcomeAcknowledgement = true }

    func failAcknowledgements(by authorization: Data, _ fail: Bool) {
        if fail { failingAcknowledgers.insert(Self.digest(authorization)) } else { failingAcknowledgers.remove(Self.digest(authorization)) }
    }

    func acknowledged(by authorization: Data) -> UInt64? {
        groups.values.compactMap { $0.writers[Self.digest(authorization)]?.ack }.first
    }

    func publishedKeyPackage(reference: Data) -> Data? {
        published[reference]
    }

    func substituteNextKeyPackageFetch(with keyPackage: Data) {
        nextFetchSubstitute = keyPackage
    }

    func log(group: Data) -> [MLSRelayEntry] {
        entries.filter { $0.delivery.group == group }
    }

    func inject(_ delivery: MLSDelivery) {
        let cursor = UInt64(entries.count + 1)
        entries.append(MLSRelayEntry(cursor: cursor, delivery: delivery))
        groups[delivery.group, default: Group()].epoch += delivery.kind == .commit ? 1 : 0
        if let added = delivery.addWriter { groups[delivery.group]?.writers[added] = (cursor - 1, nil) }
    }

    func publishKeyPackage(_ keyPackage: Data, authorization: Data, pairingHash: Data) -> Data {
        let reference = Data(SHA256.hash(data: keyPackage))
        packages[reference] = (keyPackage, Self.digest(authorization), pairingHash)
        lastPublishedReference = reference
        published[reference] = keyPackage
        return reference
    }

    func fetchKeyPackage(reference: Data, pairingToken: Data) throws -> Data? {
        guard let package = packages[reference] else { return nil }
        guard package.pairing == Self.digest(pairingToken) else { throw MLSRelayError.unauthorized }
        packages[reference]?.payload = nil
        defer { nextFetchSubstitute = nil }
        return nextFetchSubstitute ?? package.payload
    }

    func createGroup(_ group: Data, authorization: Data) throws {
        let writer = Self.digest(authorization)
        if let existing = groups[group] {
            guard existing.writers[writer]?.removal == nil, existing.writers[writer] != nil else { throw MLSRelayError.epochConflict }
            return
        }
        groups[group] = Group(writers: [writer: (0, nil)])
    }

    func append(_ delivery: MLSDelivery, authorization: Data) throws -> MLSAppendResult {
        if appendsUnavailable {
            rejectedAppends += 1
            throw URLError(.notConnectedToInternet)
        }
        if expiredGroups.contains(delivery.group) { throw MLSRelayError.historyExpired }
        guard groups[delivery.group]?.writers[Self.digest(authorization)].map({ $0.removal == nil }) == true else {
            throw MLSRelayError.unauthorized
        }
        if let duplicate = entries.first(where: { $0.delivery.group == delivery.group && $0.delivery.payload == delivery.payload }) {
            return try respond(.accepted(cursor: duplicate.cursor))
        }
        guard delivery.epoch == groups[delivery.group]?.epoch else { throw MLSRelayError.epochConflict }
        if let reference = delivery.keyPackageReference {
            guard let package = packages[reference], package.writer == delivery.addWriter else {
                return .keyPackageUnavailable(epoch: delivery.epoch)
            }
            packages[reference] = nil
        }
        let cursor = UInt64(entries.count + 1)
        entries.append(MLSRelayEntry(cursor: cursor, delivery: delivery))
        groups[delivery.group]?.epoch += delivery.kind == .commit ? 1 : 0
        if let added = delivery.addWriter { groups[delivery.group]?.writers[added] = (cursor - 1, nil) }
        let sender = Self.digest(authorization)
        for removed in [delivery.removeWriter, delivery.kind == .proposal ? sender : nil].compactMap({ $0 })
        where groups[delivery.group]?.writers[removed]?.removal == nil {
            groups[delivery.group]?.writers[removed]?.removal = cursor
        }
        return try respond(.accepted(cursor: cursor))
    }

    func fetch(group: Data, after cursor: UInt64, limit: Int, authorization: Data) throws -> [MLSRelayEntry] {
        let writer = try authorize(group: group, authorization: authorization)
        return Array(entries.filter {
            $0.delivery.group == group && $0.cursor > cursor && $0.cursor <= (writer.removal ?? .max)
        }.prefix(limit))
    }

    func acknowledge(group: Data, through cursor: UInt64, authorization: Data) throws {
        acknowledgementCount += 1
        if failingAcknowledgers.contains(Self.digest(authorization)) { throw URLError(.networkConnectionLost) }
        _ = try authorize(group: group, authorization: authorization)
        let digest = Self.digest(authorization)
        if failWelcomeAcknowledgement, entries.first(where: { $0.cursor == cursor })?.delivery.addWriter == digest {
            failWelcomeAcknowledgement = false
            throw URLError(.networkConnectionLost)
        }
        let previous = groups[group]?.writers[digest]?.ack ?? 0
        groups[group]?.writers[digest]?.ack = max(previous, cursor)
    }

    private func authorize(group: Data, authorization: Data) throws -> (ack: UInt64, removal: UInt64?) {
        if expiredGroups.contains(group) { throw MLSRelayError.historyExpired }
        guard let writer = groups[group]?.writers[Self.digest(authorization)] else { throw MLSRelayError.unauthorized }
        if let removal = writer.removal, writer.ack >= removal { throw MLSRelayError.unauthorized }
        return writer
    }

    private func respond(_ result: MLSAppendResult) throws -> MLSAppendResult {
        if dropAppendResponse {
            dropAppendResponse = false
            throw URLError(.networkConnectionLost)
        }
        return result
    }

    private static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
}
