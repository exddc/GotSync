import CryptoKit
import Foundation
import GotSyncMLS
@_spi(HostJournalPreview) @testable import GotSync

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
    private var droppedWriterAppend: (writer: Data, accepted: Int, unavailable: Bool)?
    private var appendsUnavailable = false
    private var unavailableAfterDrop = false
    private var holdsDroppedResponse = false
    private var offlineWriters: Set<Data> = []
    private var droppedResponse: CheckedContinuation<Void, Never>?
    private(set) var rejectedAppends = 0
    private var failWelcomeAcknowledgement = false
    private var failingAcknowledgers: Set<Data> = []
    private var fetchBudgets: [Data: Int] = [:]
    private var unacknowledgedLimit: Int?
    private(set) var interruptedFetches = 0
    private var expiredGroups: Set<Data> = []
    private(set) var lastPublishedReference: Data?
    private(set) var acknowledgementCount = 0

    private var heldApplicationWriters: Set<Data>?
    private var writerLimit: (count: Int, journaled: Bool)?
    private var rejections: [Data: UInt64] = [:]
    private var deferNextAdd = false
    private var deferredAdd: (delivery: MLSDelivery, authorization: Data)?
    private(set) var rateLimitedAdds = 0
    private var rateLimitedFetches = 0
    private var rateLimitedWriter: Data?
    private var dropAddResponse = false
    private var removalHook: (@Sendable () async throws -> Void)?
    private var conditionalAppend = true
    private var deferNextRemoval = false
    private var deferredRemoval: (delivery: MLSDelivery, authorization: Data)?
    private var dropRemovalResponse = false
    private(set) var conditionalRequests = 0
    private var fetchesLimitedAfterDrop: (count: Int, authorization: Data?) = (0, nil)

    /// Accepts the next append without answering. With `thenUnavailable`,
    /// every later append fails until `setAppendsUnavailable(false)`. With
    /// `held`, the failure reaches the client only after
    /// `releaseDroppedResponse()`.
    func dropNextAppendResponse(thenUnavailable: Bool = false, held: Bool = false) {
        dropAppendResponse = true
        unavailableAfterDrop = thenUnavailable
        holdsDroppedResponse = held
    }

    func releaseDroppedResponse() {
        holdsDroppedResponse = false
        droppedResponse?.resume()
        droppedResponse = nil
    }
    /// Rejects application messages from every writer except `authorizations`
    /// until called with `nil`.
    func holdApplications(except authorizations: [Data]?) {
        heldApplicationWriters = authorizations.map { Set($0.map(Self.digest)) }
    }

    /// Accepts the next Add without answering. From then on, the next
    /// `fetches` fetches of `authorization` are rate limited, so that writer
    /// cannot read the log to learn the Add landed.
    func dropNextAddResponse(thenRateLimitFetches fetches: Int = 0, of authorization: Data? = nil) {
        dropAddResponse = true
        fetchesLimitedAfterDrop = (fetches, authorization)
    }

    /// Answers the next Adds and fetches, of `authorization` only if given,
    /// with the relay gateway's HTTP 429 before the delivery store sees them,
    /// so a retried entry is not deduplicated.
    func rateLimitNext(adds: Int = 0, fetches: Int = 0, of authorization: Data? = nil) {
        rateLimitedAdds = adds
        rateLimitedFetches = fetches
        rateLimitedWriter = authorization.map(Self.digest)
    }

    private func isRateLimited(_ authorization: Data) -> Bool {
        rateLimitedWriter.map { $0 == Self.digest(authorization) } ?? true
    }

    /// Refuses an Add once the group has `count` active writers, as a relay
    /// with a smaller writer directory does.
    /// With `journaled`, as current relays do, an Add beyond `count` writers
    /// is refused as `keyPackageUnavailable` and every later copy with it.
    /// Without it, as earlier relays do, the Add receives HTTP 429.
    func limitWriters(to count: Int?, journaled: Bool = true) {
        writerLimit = count.map { ($0, journaled) }
    }

    /// Removes every published KeyPackage, as the relay does 15 minutes after
    /// publication.
    func expireKeyPackages() { packages = [:] }

    /// Holds the next Add before the delivery store and reports a lost
    /// connection; `releaseDeferredAdd()` delivers the held request later.
    func deferNextAddBeforeStore() { deferNextAdd = true }

    var holdsDeferredAdd: Bool { deferredAdd != nil }

    func releaseDeferredAdd() throws {
        guard let held = deferredAdd else { return }
        deferredAdd = nil
        _ = try appendNow(held.delivery, authorization: held.authorization)
    }

    func activeWriterCount(group: Data) -> Int {
        groups[group]?.writers.values.filter { $0.removal == nil }.count ?? 0
    }

    /// Drops the response to `authorization`'s next new application entry
    /// after `accepted` more.
    func dropAppendResponse(of authorization: Data, afterAccepting accepted: Int, thenUnavailable: Bool = true) {
        droppedWriterAppend = (Self.digest(authorization), accepted, thenUnavailable)
    }
    var isWriterAppendDropPending: Bool { droppedWriterAppend != nil }

    func setAppendsUnavailable(_ unavailable: Bool) { appendsUnavailable = unavailable }
    /// Fails every request from the writer `authorization` as if it had no
    /// network.
    func setOffline(_ authorization: Data, _ offline: Bool) {
        if offline {
            offlineWriters.insert(Self.digest(authorization))
        } else {
            offlineWriters.remove(Self.digest(authorization))
        }
    }
    func expireHistory(group: Data) { expiredGroups.insert(group) }

    func removalCursor(of authorization: Data, group: Data) -> UInt64? {
        groups[group]?.writers[Self.digest(authorization)]?.removal ?? nil
    }

    func failNextWelcomeAcknowledgement() { failWelcomeAcknowledgement = true }

    func failAcknowledgements(by authorization: Data, _ fail: Bool) {
        if fail { failingAcknowledgers.insert(Self.digest(authorization)) } else { failingAcknowledgers.remove(Self.digest(authorization)) }
    }

    /// Refuses appends while a group holds `count` entries that some active
    /// writer has not acknowledged, as the relay does before it can prune.
    func limitUnacknowledgedEntries(to count: Int?) { unacknowledgedLimit = count }

    /// Serves `count` more fetches to this writer, then fails its fetches
    /// until called again with `nil`.
    func limitFetches(by authorization: Data, to count: Int?) {
        fetchBudgets[Self.digest(authorization)] = count
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
        if offlineWriters.contains(writer) { throw URLError(.notConnectedToInternet) }
        if let existing = groups[group] {
            guard existing.writers[writer]?.removal == nil, existing.writers[writer] != nil else { throw MLSRelayError.epochConflict }
            return
        }
        groups[group] = Group(writers: [writer: (0, nil)])
    }

    /// Runs `action` when the next commit removing a writer reaches the
    /// relay, before the relay looks at it, so other members can append
    /// first.
    func beforeNextRemoval(_ action: @escaping @Sendable () async throws -> Void) { removalHook = action }

    /// Without it, the relay behaves like one that predates conditional
    /// appends: it reports no support and answers them as invalid.
    func setConditionalAppendSupported(_ supported: Bool) { conditionalAppend = supported }

    /// Holds the next conditional Remove before the delivery store and
    /// reports a lost connection; `releaseDeferredRemoval()` delivers it.
    func deferNextRemovalBeforeStore() { deferNextRemoval = true }

    @discardableResult
    func releaseDeferredRemoval() throws -> MLSAppendResult? {
        guard let held = deferredRemoval else { return nil }
        deferredRemoval = nil
        return try appendIfHeadNow(held.delivery, authorization: held.authorization)
    }

    /// Accepts the next conditional Remove without answering.
    func dropNextRemovalResponse() { dropRemovalResponse = true }

    func supportsConditionalAppend(group: Data, authorization: Data) throws -> Bool {
        _ = try authorize(group: group, authorization: authorization)
        return conditionalAppend
    }

    func appendIfHead(_ delivery: MLSDelivery, authorization: Data) async throws -> MLSAppendResult {
        conditionalRequests += 1
        if delivery.removeWriter != nil, let hook = removalHook {
            removalHook = nil
            try await hook()
        }
        if deferNextRemoval {
            deferNextRemoval = false
            deferredRemoval = (delivery, authorization)
            throw URLError(.networkConnectionLost)
        }
        let result = try appendIfHeadNow(delivery, authorization: authorization)
        if dropRemovalResponse, case .accepted = result {
            dropRemovalResponse = false
            throw URLError(.networkConnectionLost)
        }
        return result
    }

    /// The store's order: authorization, an accepted duplicate, the head
    /// precondition, then the ordinary append checks.
    private func appendIfHeadNow(_ delivery: MLSDelivery, authorization: Data) throws -> MLSAppendResult {
        guard conditionalAppend else { throw MLSRelayError.rejected(status: 400, code: "invalidRequest") }
        guard let expected = delivery.expectedHead, delivery.kind == .commit, delivery.removeWriter != nil else {
            throw MLSRelayError.rejected(status: 400, code: "invalidRequest")
        }
        if appendsUnavailable || offlineWriters.contains(Self.digest(authorization)) {
            throw URLError(.notConnectedToInternet)
        }
        guard groups[delivery.group]?.writers[Self.digest(authorization)].map({ $0.removal == nil }) == true else {
            throw MLSRelayError.unauthorized
        }
        let stored = delivery.withoutExpectedHead
        if let duplicate = entries.first(where: { $0.delivery.group == delivery.group && $0.delivery.payload == delivery.payload }) {
            guard duplicate.delivery == stored else { throw MLSRelayError.epochConflict }
            return .accepted(cursor: duplicate.cursor)
        }
        let head = head(of: delivery.group)
        guard expected <= head else { throw MLSRelayError.rejected(status: 400, code: "invalidRequest") }
        guard expected == head else { return .headAdvanced(head: head) }
        return try appendNow(stored, authorization: authorization)
    }

    func head(of group: Data) -> UInt64 {
        entries.last { $0.delivery.group == group }?.cursor ?? 0
    }

    func append(_ delivery: MLSDelivery, authorization: Data) async throws -> MLSAppendResult {
        guard delivery.expectedHead == nil else { throw MLSRelayError.invalidRequest }
        if delivery.removeWriter != nil, let hook = removalHook {
            removalHook = nil
            try await hook()
        }
        let dropping = dropAppendResponse
        do {
            return try appendNow(delivery, authorization: authorization)
        } catch {
            if dropping, !dropAppendResponse, holdsDroppedResponse {
                await withCheckedContinuation { droppedResponse = $0 }
            }
            throw error
        }
    }

    private func appendNow(_ delivery: MLSDelivery, authorization: Data) throws -> MLSAppendResult {
        if deferNextAdd, delivery.welcome != nil {
            deferNextAdd = false
            deferredAdd = (delivery, authorization)
            throw URLError(.networkConnectionLost)
        }
        if rateLimitedAdds > 0, delivery.welcome != nil, isRateLimited(authorization) {
            rateLimitedAdds -= 1
            throw MLSRelayError.rateLimited
        }
        if appendsUnavailable || offlineWriters.contains(Self.digest(authorization)) {
            rejectedAppends += 1
            throw URLError(.notConnectedToInternet)
        }
        if expiredGroups.contains(delivery.group) { throw MLSRelayError.historyExpired }
        if let allowed = heldApplicationWriters, delivery.kind == .application, !allowed.contains(Self.digest(authorization)) {
            throw URLError(.notConnectedToInternet)
        }
        guard groups[delivery.group]?.writers[Self.digest(authorization)].map({ $0.removal == nil }) == true else {
            throw MLSRelayError.unauthorized
        }
        if let duplicate = entries.first(where: { $0.delivery.group == delivery.group && $0.delivery.payload == delivery.payload }) {
            return try respond(.accepted(cursor: duplicate.cursor))
        }
        let digest = Self.digest(delivery.group + delivery.payload)
        if let epoch = rejections[digest] { return .keyPackageUnavailable(epoch: epoch) }
        guard delivery.epoch == groups[delivery.group]?.epoch else { throw MLSRelayError.epochConflict }
        if let unacknowledgedLimit, let group = groups[delivery.group] {
            let floor = group.writers.values.filter { $0.removal == nil }.map(\.ack).min() ?? 0
            let unacknowledged = entries.filter { $0.delivery.group == delivery.group && $0.cursor > floor }
            if unacknowledged.count >= unacknowledgedLimit { throw MLSRelayError.capacityReached }
        }
        if let reference = delivery.keyPackageReference {
            guard let package = packages[reference], package.writer == delivery.addWriter else {
                rejections[digest] = delivery.epoch
                return .keyPackageUnavailable(epoch: delivery.epoch)
            }
            if let writerLimit, activeWriterCount(group: delivery.group) >= writerLimit.count {
                guard writerLimit.journaled else { throw MLSRelayError.capacityReached }
                rejections[digest] = delivery.epoch
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
        if let drop = droppedWriterAppend, drop.writer == sender, delivery.kind == .application {
            guard drop.accepted > 0 else {
                droppedWriterAppend = nil
                appendsUnavailable = drop.unavailable
                throw URLError(.networkConnectionLost)
            }
            droppedWriterAppend = (drop.writer, drop.accepted - 1, drop.unavailable)
        }
        if dropAddResponse, delivery.welcome != nil {
            dropAddResponse = false
            if fetchesLimitedAfterDrop.count > 0 {
                rateLimitNext(fetches: fetchesLimitedAfterDrop.count, of: fetchesLimitedAfterDrop.authorization)
            }
            throw URLError(.networkConnectionLost)
        }
        return try respond(.accepted(cursor: cursor))
    }

    func fetch(group: Data, after cursor: UInt64, limit: Int, authorization: Data) throws -> [MLSRelayEntry] {
        if rateLimitedFetches > 0, isRateLimited(authorization) {
            rateLimitedFetches -= 1
            throw MLSRelayError.rateLimited
        }
        if offlineWriters.contains(Self.digest(authorization)) { throw URLError(.notConnectedToInternet) }
        if let budget = fetchBudgets[Self.digest(authorization)] {
            guard budget > 0 else {
                interruptedFetches += 1
                throw URLError(.networkConnectionLost)
            }
            fetchBudgets[Self.digest(authorization)] = budget - 1
        }
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
            appendsUnavailable = unavailableAfterDrop
            throw URLError(.networkConnectionLost)
        }
        return result
    }

    private static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
}

extension TaskReplica {
    init(deviceID: ReplicaDeviceID, persistenceURL: URL? = nil) throws {
        try self.init(deviceID: deviceID, persistenceURL: persistenceURL, newOrigin: nil)
    }
}

/// Builds a valid replica archive directly, so tests can reach replica limits
/// without applying thousands of operations one at a time.
enum ReplicaFixture {
    static func taskID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012X", index))!
    }

    static func archive(
        deviceID: ReplicaDeviceID,
        taskCount: Int,
        toggleCount: Int = 0,
        foreignOrigins: [ReplicaDeviceID] = []
    ) throws -> Data {
        precondition(taskCount > 0)
        var lamport: UInt64 = 0
        var operations: [TaskOperation] = []
        var records: [ReplicatedTask] = []
        for index in 1...taskCount {
            lamport += 1
            let operation = TaskOperation(
                originDeviceID: deviceID,
                originSequence: lamport,
                lamport: lamport,
                taskID: taskID(index),
                mutation: .create(title: "Task \(index)", completed: false)
            )
            operations.append(operation)
            records.append(ReplicatedTask(
                id: operation.taskID,
                title: LWWRegister(value: "Task \(index)", stamp: operation.stamp),
                completed: LWWRegister(value: false, stamp: operation.stamp),
                deletion: nil
            ))
        }
        let toggled = records[0].id
        var completed = records[0].completed!
        var vector = [deviceID: UInt64(taskCount)]
        for _ in 0..<toggleCount {
            lamport += 1
            let operation = TaskOperation(
                originDeviceID: deviceID,
                originSequence: lamport,
                lamport: lamport,
                taskID: toggled,
                mutation: .setCompleted(!completed.value)
            )
            operations.append(operation)
            completed = LWWRegister(value: !completed.value, stamp: operation.stamp)
            vector[deviceID] = lamport
        }
        for origin in foreignOrigins {
            lamport += 1
            let operation = TaskOperation(
                originDeviceID: origin,
                originSequence: 1,
                lamport: lamport,
                taskID: toggled,
                mutation: .setCompleted(!completed.value)
            )
            operations.append(operation)
            completed = LWWRegister(value: !completed.value, stamp: operation.stamp)
            vector[origin] = 1
        }
        records[0].completed = completed
        return try ReplicaArchive(
            formatVersion: ReplicaLimits.archiveFormatVersion,
            deviceID: deviceID,
            originDeviceID: deviceID,
            nextLocalOriginSequence: vector[deviceID]! + 1,
            lamport: lamport,
            versionVector: ReplicaVersionVector(vector),
            taskRecords: records,
            operations: operations
        ).canonicalData()
    }
}
