import CryptoKit
import Foundation
import os

/// The service-owned binding of blob work to one group membership.
struct BlobBinding: Equatable, Sendable {
    let route: BlobRoute
    let session: Data
    let generation: UInt64
}

/// Durable outgoing sealing, upload and descriptor handoff; incoming fetch,
/// verification and publication handoff; and re-upload of objects other
/// members want.
///
/// Every durable transition, every exposure of a descriptor or file and every
/// registration runs as one synchronous segment of this actor that first
/// checks the captured binding generation and the row's session. Cloning,
/// sealing, network and validation run off the actor and only produce
/// candidates. Host source files are never written or deleted.
@_spi(BlobPreview) public actor BlobTransferService {
    static let ledgerBytes: Int64 = 64 * 1_024 * 1_024
    static let maxOutgoingRows = 16
    static let maxIncomingByteRows = 8
    static let maxQueuedDescriptors = 1_024
    static let maxAvailable = 4_000
    static let diskFloor: Int64 = 512 * 1_024 * 1_024
    static let maxIntegrityAttempts = 3
    static let availabilityInterval: TimeInterval = 6 * 3_600
    static let directoryName = "blob-v1"

    public static var maximumObjectPlaintextLength: UInt64 { BlobFormat.maxPlaintextLength }

    private struct Fence {
        var generation: UInt64 = 0
        /// The newest generation retired outside the actor, so a later bind
        /// never resumes the retired session.
        var retiredThrough: UInt64 = 0
    }

    private struct Active {
        let binding: BlobBinding
        let member: Data
        let access: @Sendable () async throws -> (group: Data, token: Data)
        let relay: BlobRelayClient
        let uploads = BlobSignal()
        let downloads = BlobSignal()
        let availability = BlobSignal()
        var scheduler: Task<Void, Never>?
    }

    private struct Sealing {
        let kind: BlobContentKind
        let route: Data
        let expected: Data
        let task: Task<BlobOutgoingStatus, Error>
    }

    let files: BlobFiles
    private let store: BlobStateStore
    private let relayURL: URL
    private let policy: EndpointSecurityPolicy
    /// URL protocols the relay sessions use instead of the network, for tests.
    private let relayProtocols: [AnyClass]?
    private nonisolated let fence = OSAllocatedUnfairLock(initialState: Fence())
    private nonisolated let observers = OSAllocatedUnfairLock(initialState: [UUID: AsyncStream<Void>.Continuation]())
    private var record: BlobBindingRecord?
    private var active: Active?
    private var committedBytes: Int64 = 0
    private var reservations: [UUID: Int64] = [:]
    private var fetchTickets: [Data: UUID] = [:]
    /// Incoming rows a download worker is processing. Their files and
    /// reservation are released when the worker returns, never earlier.
    private var activeFetches: Set<Data> = []
    private var sealing: [Data: Sealing] = [:]
    private var cancelledSeals: Set<Data> = []
    private var waitingCapacity: [Data: BlobContentKind] = [:]
    private var relayUnsupported = false
    private var hooks: BlobHostHooks?

    init(directory: URL, relayURL: URL, policy: EndpointSecurityPolicy, relayProtocols: [AnyClass]? = nil) throws {
        files = BlobFiles(root: directory)
        self.relayURL = relayURL
        self.policy = policy
        self.relayProtocols = relayProtocols
        do {
            store = try BlobStateStore(files: files)
            record = try store.binding()
        } catch {
            throw BlobError.storageUnavailable
        }
        let generation = record?.generation ?? 0
        fence.withLock { $0 = Fence(generation: generation, retiredThrough: 0) }
        committedBytes = try Self.recover(store: store, files: files, record: record)
    }

    /// Opens the service off the caller's executor.
    static func open(directory: URL, relayURL: URL, policy: EndpointSecurityPolicy) async throws -> BlobTransferService {
        try await Task.detached(priority: .utility) {
            try BlobTransferService(directory: directory, relayURL: relayURL, policy: policy)
        }.value
    }

    /// Deletes leftovers of interrupted work and returns the bytes held by committed rows.
    private static func recover(store: BlobStateStore, files: BlobFiles, record: BlobBindingRecord?) throws -> Int64 {
        let outgoing: [BlobOutgoingRow]
        var incoming: [BlobIncomingRow]
        do {
            outgoing = try store.allOutgoing()
            incoming = try store.allIncoming()
        } catch {
            throw BlobError.storageUnavailable
        }
        var keep: Set<URL> = []
        for row in outgoing where row.phase == .sealed {
            keep.insert(files.sealedFile(row.id, generation: row.sealGeneration).standardizedFileURL)
        }
        for index in incoming.indices {
            let row = incoming[index]
            switch row.phase {
            case .fetching:
                let ciphertext = files.ciphertext(row.id)
                if FileManager.default.fileExists(atPath: ciphertext.path) {
                    keep.insert(ciphertext.standardizedFileURL)
                } else if row.present != 0 {
                    incoming[index].present = 0
                    try? store.put(incoming[index])
                }
            case .verified:
                keep.insert(files.verifiedFile(row.id).standardizedFileURL)
            default:
                break
            }
        }
        var bytes: Int64 = 0
        let manager = FileManager.default
        for directory in [files.staging, files.sealed, files.incoming, files.verified, files.reupload] {
            for file in (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                if keep.contains(file.standardizedFileURL) {
                    bytes += BlobFiles.size(file)
                } else {
                    BlobFiles.remove(file)
                }
            }
        }
        return bytes
    }

    // MARK: - Engine lifecycle

    /// Binds blob work to `route` for the member `member`. The persisted
    /// session is kept while the same member stays in the same route and was
    /// never retired; otherwise a new session starts and earlier rows retire.
    /// The fence generation now. A bind that read it before a retirement is refused.
    nonisolated var bindingToken: UInt64 { fence.withLock { $0.generation } }

    @discardableResult
    func ensureBound(
        route: BlobRoute,
        member: Data,
        notRetiredSince token: UInt64,
        access: @escaping @Sendable () async throws -> (group: Data, token: Data)
    ) throws -> BlobBinding {
        let current = fence.withLock { $0 }
        guard current.retiredThrough <= token else { throw BlobError.staleBinding }
        if let active, active.binding.route == route, active.member == member, active.binding.generation == current.generation {
            return active.binding
        }
        stopActive()
        var next: BlobBindingRecord
        if let record, !record.retired, current.retiredThrough <= record.generation,
           record.route == route.bytes, record.member == member {
            next = record
        } else {
            next = BlobBindingRecord(route: route.bytes, member: member, session: try Data.secureRandom(count: 16),
                                     retired: false, generation: 0)
        }
        next.generation = max(current.generation, record?.generation ?? 0) + 1
        do {
            try store.save(next)
        } catch {
            throw BlobError.storageUnavailable
        }
        record = next
        let generation = next.generation
        fence.withLock { $0.generation = generation }
        let binding = BlobBinding(route: route, session: next.session, generation: next.generation)
        var started = Active(binding: binding, member: member, access: access,
                             relay: BlobRelayClient(baseURL: relayURL, policy: policy, protocolClasses: relayProtocols))
        started.scheduler = Task { [weak self] in await self?.runScheduler(generation: binding.generation) }
        active = started
        relayUnsupported = false
        retireRowsOutside(session: next.session)
        notify()
        return binding
    }

    /// Invalidates the binding at once, from any thread, before leave or
    /// erase touches MLS state. No commit of the old generation can follow.
    nonisolated func retireNow() {
        let retired = fence.withLock { state -> UInt64 in
            state.generation &+= 1
            state.retiredThrough = state.generation
            return state.generation
        }
        Task { await self.finishRetirement(through: retired) }
    }

    /// Ends the binding. Network tasks are cancelled without waiting; verified
    /// content stays offered to the host; unverified parts are deleted.
    func retire() {
        let retired = fence.withLock { state -> UInt64 in
            state.generation &+= 1
            state.retiredThrough = state.generation
            return state.generation
        }
        finishRetirement(through: retired)
    }

    private func finishRetirement(through generation: UInt64) {
        guard var record, record.generation < generation else {
            return
        }
        stopActive()
        record.retired = true
        record.generation = generation
        try? store.save(record)
        self.record = record
        retireRowsOutside(session: nil)
        notify()
    }

    private func stopActive() {
        guard let active else { return }
        active.scheduler?.cancel()
        active.relay.invalidate()
        self.active = nil
    }

    /// Marks unverified incoming rows of every other session retired and
    /// deletes their parts. Verified content is kept for the host.
    private func retireRowsOutside(session: Data?) {
        guard let rows = try? store.allIncoming() else { return }
        for var row in rows where row.session != session {
            switch row.phase {
            case .queued, .fetching, .unavailable:
                dropFetchFiles(row.id)
                row.phase = .retired
                row.present = 0
                try? store.put(row)
            case .rejected, .verified, .retired:
                break
            }
        }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        fence.withLock { $0.generation } == generation && active?.binding.generation == generation
    }

    private func currentSession(_ generation: UInt64) -> Data? {
        isCurrent(generation) ? active?.binding.session : nil
    }

    private func requireBinding(_ route: BlobRoute) throws -> Active {
        guard let active, isCurrent(active.binding.generation) else { throw BlobError.notBound }
        guard active.binding.route == route else { throw BlobError.routeMismatch }
        return active
    }

    // MARK: - Host API

    public func setHooks(_ hooks: BlobHostHooks) {
        self.hooks = hooks
        active?.availability.fire()
    }

    /// A signal after each committed change; statuses are read with
    /// `outgoing()`, `incoming()` and `summary()`.
    public nonisolated func updates() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        observers.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.observers.withLock { $0[id] = nil }
        }
        return stream
    }

    private func notify() {
        for continuation in observers.withLock({ Array($0.values) }) {
            continuation.yield()
        }
    }

    /// Seals a private clone of an image file under a fresh key and commits it.
    /// Returns the existing status for a repeated ID with the same route and
    /// hash. The host keeps `source`; the library never changes it.
    public func seal(
        _ id: BlobTransferID,
        route: BlobRoute,
        source: URL,
        expectedContentHash: Data
    ) async throws -> BlobOutgoingStatus {
        try await seal(id, kind: .image, route: route, source: source, expected: expectedContentHash)
    }

    /// Seals one application-data chunk of at most 10 MiB, such as one part of
    /// a host record too large for a journal payload. No image validation
    /// runs; the descriptor is a version 2 data descriptor.
    public func sealData(
        _ id: BlobTransferID,
        route: BlobRoute,
        source: URL,
        expectedContentHash: Data
    ) async throws -> BlobOutgoingStatus {
        try await seal(id, kind: .applicationData, route: route, source: source, expected: expectedContentHash)
    }

    private func seal(
        _ id: BlobTransferID, kind: BlobContentKind, route: BlobRoute, source: URL, expected expectedContentHash: Data
    ) async throws -> BlobOutgoingStatus {
        if let row = try readOutgoing(id.bytes) {
            guard row.kind == kind else { throw BlobError.contentKindMismatch }
            guard row.route == route.bytes, row.expected == expectedContentHash else { throw BlobError.transferMismatch }
            return outgoingStatus(row)
        }
        if let running = sealing[id.bytes] {
            guard running.kind == kind else { throw BlobError.contentKindMismatch }
            guard running.route == route.bytes, running.expected == expectedContentHash else { throw BlobError.transferMismatch }
            return try await running.task.value
        }
        guard expectedContentHash.count == BlobFormat.hashLength else { throw BlobError.invalidIdentifier }
        let active = try requireBinding(route)
        guard try countOutgoing() + sealing.count < Self.maxOutgoingRows else {
            waitingCapacity[id.bytes] = kind
            throw BlobError.capacity(.outgoingRows)
        }
        let length: UInt64
        do {
            length = try BlobImageValidator.fileSize(source)
        } catch {
            throw BlobError.sourceUnreadable
        }
        guard let layout = try? BlobPartLayout(plaintextLength: length) else { throw BlobError.exceedsSyncLimits }
        let ticket = try reserve(Int64(length + layout.ciphertextLength), for: id.bytes, kind: kind)
        cancelledSeals.remove(id.bytes)
        let generation = active.binding.generation
        let session = active.binding.session
        let files = files
        let task = Task<BlobOutgoingStatus, Error> {
            let candidate: BlobSealCandidate
            do {
                candidate = try await Self.produceSeal(
                    id: id.bytes, kind: kind, source: source, expected: expectedContentHash, route: route, files: files,
                    sealGeneration: 0
                )
            } catch {
                self.release(ticket)
                throw error
            }
            return try self.commitSealed(
                candidate, id: id.bytes, kind: kind, route: route, source: source, expected: expectedContentHash,
                generation: generation, session: session, ticket: ticket
            )
        }
        sealing[id.bytes] = Sealing(kind: kind, route: route.bytes, expected: expectedContentHash, task: task)
        defer { sealing[id.bytes] = nil }
        return try await task.value
    }

    public func outgoing() -> [BlobOutgoingStatus] {
        ((try? store.allOutgoing()) ?? []).map(outgoingStatus)
    }

    /// Deletes the offered row whose frozen descriptor has `descriptorDigest`.
    /// No row is success. Works for retired rows too.
    public func confirmHandoff(_ id: BlobTransferID, descriptorDigest: Data) throws {
        guard let row = try readOutgoing(id.bytes) else { return }
        guard let digest = row.digest, digest == descriptorDigest else { throw BlobError.staleConfirmation }
        try write { try store.deleteOutgoing(id.bytes) }
        notify()
    }

    /// Drops an outgoing transfer that was never offered. An offered one is
    /// handed off with `confirmHandoff` instead.
    public func cancelOutgoing(_ id: BlobTransferID) throws {
        if sealing[id.bytes] != nil {
            cancelledSeals.insert(id.bytes)
        }
        guard let row = try readOutgoing(id.bytes) else { return }
        guard row.descriptor == nil else { throw BlobError.alreadyOffered }
        try write { try store.deleteOutgoing(id.bytes) }
        removeCommitted(files.sealedFile(row.id, generation: row.sealGeneration))
        waitingCapacity.removeValue(forKey: id.bytes)
        notify()
    }

    /// Queues an image descriptor from an accepted host record for fetching.
    /// An application-data descriptor is refused with `contentKindMismatch`.
    public func requestIncoming(_ id: BlobTransferID, route: BlobRoute, descriptor: Data) throws {
        try requestIncoming(id, kind: .image, route: route, descriptor: descriptor)
    }

    /// Queues an application-data descriptor from an accepted host record. The
    /// verified chunk is admitted only by the host's `acceptsData` hook.
    public func requestIncomingData(_ id: BlobTransferID, route: BlobRoute, descriptor: Data) throws {
        try requestIncoming(id, kind: .applicationData, route: route, descriptor: descriptor)
    }

    private func requestIncoming(_ id: BlobTransferID, kind: BlobContentKind, route: BlobRoute, descriptor: Data) throws {
        if let row = try readIncoming(id.bytes) {
            guard row.kind == kind else { throw BlobError.contentKindMismatch }
            guard row.route == route.bytes, row.descriptor == descriptor else { throw BlobError.transferMismatch }
            return
        }
        let decoded = try BlobDescriptor.decodeForService(descriptor, kind: kind)
        let active = try requireBinding(route)
        let rows = try readAllIncoming()
        guard rows.filter({ !$0.phase.holdsBytes }).count < Self.maxQueuedDescriptors else {
            throw BlobError.capacity(.queuedDescriptors)
        }
        let row = BlobIncomingRow(
            id: id.bytes, route: route.bytes, session: active.binding.session, descriptor: descriptor,
            digest: BlobDescriptor.digest(of: descriptor), objectID: decoded.objectID, phase: .queued,
            present: 0, attempts: 0, rejection: nil, retryAt: 0
        )
        try write { try store.put(row) }
        active.downloads.fire()
        notify()
    }

    public func incoming() -> [BlobIncomingStatus] {
        ((try? store.allIncoming()) ?? []).map(incomingStatus)
    }

    /// Deletes the verified row and its file once the host has published the
    /// content with `descriptorDigest`. No row is success.
    public func confirmPublished(_ id: BlobTransferID, descriptorDigest: Data) throws {
        guard let row = try readIncoming(id.bytes) else { return }
        guard row.digest == descriptorDigest, row.phase == .verified else { throw BlobError.staleConfirmation }
        try write { try store.deleteIncoming(id.bytes) }
        removeCommitted(files.verifiedFile(id.bytes))
        notify()
    }

    /// Drops an incoming transfer the host no longer wants, such as a rejected
    /// variant. Verified content is confirmed with `confirmPublished` instead.
    public func cancelIncoming(_ id: BlobTransferID) throws {
        guard let row = try readIncoming(id.bytes) else { return }
        guard row.phase != .verified else { throw BlobError.alreadyOffered }
        try write { try store.deleteIncoming(id.bytes) }
        dropFetchFiles(id.bytes)
        notify()
    }

    /// Records that the host holds verified content for an image `descriptor`,
    /// so it can be re-uploaded when other members want it.
    public func registerAvailable(route: BlobRoute, descriptor: Data) throws {
        try register(route: route, descriptor: descriptor, kind: .image)
    }

    /// Records that the host holds the content of an application-data
    /// descriptor, for re-upload.
    public func registerAvailableData(route: BlobRoute, descriptor: Data) throws {
        try register(route: route, descriptor: descriptor, kind: .applicationData)
    }

    private func register(route: BlobRoute, descriptor: Data, kind: BlobContentKind) throws {
        let decoded = try BlobDescriptor.decodeForService(descriptor, kind: kind)
        let active = try requireBinding(route)
        if let existing = try readAvailable(route: route.bytes, objectID: decoded.objectID) {
            guard existing == descriptor else { throw BlobError.transferMismatch }
            return
        }
        guard try countAvailable() < Self.maxAvailable else { throw BlobError.capacity(.availableRegistry) }
        try write { try store.register(route: route.bytes, objectID: decoded.objectID, descriptor: descriptor) }
        active.availability.fire()
        notify()
    }

    public func unregisterAvailable(route: BlobRoute, objectID: Data) throws {
        try write { try store.unregister(route: route.bytes, objectID: objectID) }
        notify()
    }

    /// Tells the relay these objects are no longer needed. An availability
    /// hint only; it never affects local content.
    public func release(route: BlobRoute, objectIDs: [Data]) async throws {
        let active = try requireBinding(route)
        guard objectIDs.allSatisfy({ $0.count == BlobFormat.hashLength }) else { throw BlobError.invalidIdentifier }
        let access = try await active.access()
        guard access.group == route.bytes else { throw BlobError.staleBinding }
        for start in stride(from: 0, to: objectIDs.count, by: 16) {
            do {
                try await active.relay.release(route: route, objectIDs: Array(objectIDs[start..<min(start + 16, objectIDs.count)]),
                                               token: access.token)
            } catch BlobRelayError.unsupported {
                throw BlobError.relayUnsupported
            }
        }
    }

    public func summary() -> BlobSummary {
        makeSummary(kind: nil)
    }

    /// Filters transfer and registry counts; byte totals and resource flags
    /// still describe the shared service ledger and relay.
    public func summary(for kind: BlobContentKind) -> BlobSummary {
        makeSummary(kind: kind)
    }

    private func makeSummary(kind: BlobContentKind?) -> BlobSummary {
        var summary = BlobSummary()
        for status in outgoing() where kind == nil || status.kind == kind {
            switch status.state {
            case .uploading: summary.outgoingUploading += 1
            case .readyForHandoff: summary.outgoingOffered += 1
            case .repairRequired: summary.outgoingRepairRequired += 1
            case .failed: summary.outgoingFailed += 1
            case .retired: summary.outgoingRetired += 1
            }
        }
        for status in incoming() where kind == nil || status.kind == kind {
            switch status.state {
            case .queued: summary.incomingQueued += 1
            case .fetching: summary.incomingFetching += 1
            case .unavailable: summary.incomingUnavailable += 1
            case .rejected: summary.incomingRejected += 1
            case .awaitingPublish where status.isRetired: summary.incomingRetiredVerified += 1
            case .awaitingPublish: summary.incomingVerified += 1
            case .retired: break
            }
        }
        summary.outgoingWaitingCapacity = waitingCapacity.values.filter { kind == nil || $0 == kind }.count
        summary.availableObjects = (try? countAvailable(kind: kind)) ?? 0
        summary.libraryBytes = committedBytes + reservations.values.reduce(0, +)
        summary.relayUnsupported = relayUnsupported
        let outgoingRows = (try? countOutgoing()) ?? 0
        let byteRows = ((try? store.allIncoming()) ?? []).filter { $0.phase.holdsBytes }.count
        summary.hostBackpressure = !waitingCapacity.isEmpty
            || outgoingRows >= Self.maxOutgoingRows
            || byteRows >= Self.maxIncomingByteRows
            || summary.libraryBytes >= Self.ledgerBytes - Int64(BlobFormat.maxPlaintextLength + BlobFormat.maxCiphertextLength)
        return summary
    }

    // MARK: - Statuses

    private func isRetired(session: Data) -> Bool {
        guard let record, !record.retired else { return true }
        return record.session != session
    }

    private func outgoingStatus(_ row: BlobOutgoingRow) -> BlobOutgoingStatus {
        let state: BlobOutgoingStatus.State
        if isRetired(session: row.session), row.phase != .failed {
            state = .retired(descriptor: row.descriptor, digest: row.digest)
        } else {
            switch row.phase {
            case .sealed, .uploaded: state = .uploading
            case .offered: state = .readyForHandoff(descriptor: row.descriptor ?? Data(), digest: row.digest ?? Data())
            case .repairRequired: state = .repairRequired(descriptor: row.descriptor ?? Data(), digest: row.digest ?? Data())
            case .failed: state = .failed(BlobOutgoingFailure(row.failure))
            }
        }
        return BlobOutgoingStatus(
            id: try! BlobTransferID(bytes: row.id), route: try! BlobRoute(bytes: row.route), kind: row.kind,
            contentHash: row.expected, state: state
        )
    }

    private func incomingStatus(_ row: BlobIncomingRow) -> BlobIncomingStatus {
        let decoded = try? BlobDescriptor.stored(row.descriptor)
        let state: BlobIncomingStatus.State
        switch row.phase {
        case .queued: state = .queued
        case .fetching: state = .fetching
        case .unavailable: state = .unavailable
        case .rejected: state = .rejected(BlobRejection(row.rejection))
        case .verified:
            state = .awaitingPublish(file: files.verifiedFile(row.id), contentHash: decoded?.contentHash ?? Data(), digest: row.digest)
        case .retired: state = .retired
        }
        return BlobIncomingStatus(
            id: try! BlobTransferID(bytes: row.id), route: try! BlobRoute(bytes: row.route), kind: row.kind,
            objectID: row.objectID,
            digest: row.digest, isRetired: isRetired(session: row.session), state: state
        )
    }

    // MARK: - Ledger

    private func reserve(_ bytes: Int64, for id: Data, kind: BlobContentKind) throws -> UUID {
        let reserved = reservations.values.reduce(0, +)
        guard committedBytes + reserved + bytes <= Self.ledgerBytes else {
            waitingCapacity[id] = kind
            throw BlobError.capacity(.libraryBytes)
        }
        guard let free = BlobFiles.freeBytes(at: files.root), free - reserved - bytes >= Self.diskFloor else {
            waitingCapacity[id] = kind
            throw BlobError.capacity(.diskFloor)
        }
        waitingCapacity.removeValue(forKey: id)
        let ticket = UUID()
        reservations[ticket] = bytes
        return ticket
    }

    private func release(_ ticket: UUID) {
        reservations[ticket] = nil
    }

    /// Moves a file into the committed count; the caller then releases the
    /// reservation that covered it.
    private func adopt(_ url: URL) {
        committedBytes += BlobFiles.size(url)
    }

    private func removeCommitted(_ url: URL) {
        let size = BlobFiles.size(url)
        guard size > 0 || FileManager.default.fileExists(atPath: url.path) else { return }
        BlobFiles.remove(url)
        committedBytes = max(0, committedBytes - size)
    }

    private func releaseFetch(_ id: Data) {
        if let ticket = fetchTickets.removeValue(forKey: id) {
            release(ticket)
        }
    }

    // MARK: - Store access

    private func write(_ body: () throws -> Void) throws {
        do {
            try store.transaction(body)
        } catch let error as BlobError {
            throw error
        } catch {
            throw BlobError.storageUnavailable
        }
    }

    private func readOutgoing(_ id: Data) throws -> BlobOutgoingRow? {
        do { return try store.outgoing(id) } catch { throw BlobError.storageUnavailable }
    }

    private func readIncoming(_ id: Data) throws -> BlobIncomingRow? {
        do { return try store.incoming(id) } catch { throw BlobError.storageUnavailable }
    }

    private func readAllIncoming() throws -> [BlobIncomingRow] {
        do { return try store.allIncoming() } catch { throw BlobError.storageUnavailable }
    }

    private func readAvailable(route: Data, objectID: Data) throws -> Data? {
        do { return try store.available(route: route, objectID: objectID) } catch { throw BlobError.storageUnavailable }
    }

    private func countOutgoing() throws -> Int {
        do { return try store.outgoingCount() } catch { throw BlobError.storageUnavailable }
    }

    private func countAvailable(kind: BlobContentKind? = nil) throws -> Int {
        do { return try store.availableCount(kind: kind) } catch { throw BlobError.storageUnavailable }
    }

    // MARK: - Sealing

    /// Clone, hash, validate and seal, all off the actor. Returns a candidate
    /// the actor commits or discards.
    private static func produceSeal(
        id: Data, kind: BlobContentKind, source: URL, expected: Data, route: BlobRoute, files: BlobFiles, sealGeneration: Int
    ) async throws -> BlobSealCandidate {
        let clone = files.clone(id)
        let output = files.sealedFile(id, generation: sealGeneration)
        do {
            BlobFiles.remove(clone)
            do {
                try FileManager.default.copyItem(at: source, to: clone)
            } catch {
                throw BlobError.sourceUnreadable
            }
            guard try Self.contentHash(of: clone) == expected else { throw BlobError.sourceChanged }
            let image = kind == .image
                ? try await Self.validate(clone)
                : BlobImageInfo(mediaType: BlobDescriptor.dataMediaType, pixelWidth: 0, pixelHeight: 0)
            let sealed = try await BlobWorkGate.seal.run { () throws -> BlobSealedObject in
                let input = try FileHandle(forReadingFrom: clone)
                defer { try? input.close() }
                let handle = try BlobFiles.create(output)
                defer { try? handle.close() }
                return try BlobCipher.seal(source: input, route: route, output: handle)
            }
            guard sealed.contentHash == expected else { throw BlobError.sourceChanged }
            BlobFiles.synchronize(directory: files.sealed)
            return BlobSealCandidate(sealed: sealed, image: image, clone: clone, output: output)
        } catch {
            BlobFiles.remove(clone)
            BlobFiles.remove(output)
            if let error = error as? BlobError { throw error }
            if case BlobCodecError.sourceChanged = error { throw BlobError.sourceChanged }
            throw BlobError.sourceUnreadable
        }
    }

    private static func validate(_ url: URL) async throws -> BlobImageInfo {
        do {
            return try await BlobWorkGate.validation.run { try BlobImageValidator.validate(url) }
        } catch BlobImageValidator.Failure.exceedsLimits {
            throw BlobError.exceedsSyncLimits
        } catch {
            throw BlobError.imageRejected
        }
    }

    private static func contentHash(of url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: BlobFormat.plaintextPartLength), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }

    private func commitSealed(
        _ candidate: BlobSealCandidate, id: Data, kind: BlobContentKind, route: BlobRoute, source: URL, expected: Data,
        generation: UInt64, session: Data, ticket: UUID
    ) throws -> BlobOutgoingStatus {
        defer {
            release(ticket)
            BlobFiles.remove(candidate.clone)
        }
        guard currentSession(generation) == session, !cancelledSeals.contains(id), (try? store.outgoing(id)) == nil else {
            cancelledSeals.remove(id)
            BlobFiles.remove(candidate.output)
            throw BlobError.staleBinding
        }
        let row = BlobOutgoingRow(
            id: id, kind: kind, route: route.bytes, session: session, expected: expected, source: source.path,
            phase: .sealed, sealGeneration: 0, key: candidate.sealed.key.withUnsafeBytes { Data($0) },
            objectID: candidate.sealed.objectID, plaintextLength: candidate.sealed.manifest.layout.plaintextLength,
            partHashes: candidate.sealed.manifest.partHashes, mediaType: candidate.image.mediaType,
            pixelWidth: candidate.image.pixelWidth, pixelHeight: candidate.image.pixelHeight,
            descriptor: nil, digest: nil, failure: nil, attempts: 0, retryAt: 0
        )
        do {
            try write { try store.put(row) }
        } catch {
            BlobFiles.remove(candidate.output)
            throw error
        }
        adopt(candidate.output)
        active?.uploads.fire()
        notify()
        return outgoingStatus(row)
    }

    /// Before an offer only: a fresh clone that must still have the row's
    /// content hash, sealed under a new key into a new seal generation.
    private func reseal(_ id: Data, generation: UInt64) async {
        guard let session = currentSession(generation), let row = try? store.outgoing(id), row.session == session,
              row.phase == .sealed || row.phase == .uploaded, row.descriptor == nil,
              let route = try? BlobRoute(row.route), let layout = try? row.layout,
              let ticket = try? reserve(Int64(layout.plaintextLength + layout.ciphertextLength), for: id, kind: row.kind)
        else {
            return
        }
        let next = row.sealGeneration + 1
        let candidate: BlobSealCandidate
        do {
            candidate = try await Self.produceSeal(
                id: id, kind: row.kind, source: URL(fileURLWithPath: row.source), expected: row.expected, route: route,
                files: files, sealGeneration: next
            )
        } catch {
            release(ticket)
            failOutgoing(id, generation: generation, error: error)
            return
        }
        defer {
            release(ticket)
            BlobFiles.remove(candidate.clone)
        }
        guard currentSession(generation) == session, var current = try? store.outgoing(id),
              current.sealGeneration == row.sealGeneration, current.descriptor == nil
        else {
            BlobFiles.remove(candidate.output)
            return
        }
        let previous = files.sealedFile(id, generation: current.sealGeneration)
        current.phase = .sealed
        current.sealGeneration = next
        current.key = candidate.sealed.key.withUnsafeBytes { Data($0) }
        current.objectID = candidate.sealed.objectID
        current.partHashes = candidate.sealed.manifest.partHashes
        current.attempts = 0
        current.retryAt = 0
        do {
            try write { try store.put(current) }
        } catch {
            BlobFiles.remove(candidate.output)
            return
        }
        adopt(candidate.output)
        removeCommitted(previous)
        notify()
    }

    private func failOutgoing(_ id: Data, generation: UInt64, error: Error) {
        guard let session = currentSession(generation), var row = try? store.outgoing(id), row.session == session,
              row.descriptor == nil
        else {
            return
        }
        switch error {
        case BlobError.sourceChanged: row.failure = "sourceChanged"
        case BlobError.exceedsSyncLimits: row.failure = "exceedsSyncLimits"
        case BlobError.imageRejected: row.failure = "imageRejected"
        case BlobError.capacity, BlobError.storageUnavailable:
            row.attempts += 1
            row.retryAt = Date().timeIntervalSince1970 + Self.backoff(attempts: row.attempts, retryAfter: nil)
            try? write { try store.put(row) }
            return
        default: row.failure = "sourceUnreadable"
        }
        let sealed = files.sealedFile(id, generation: row.sealGeneration)
        row.phase = .failed
        try? write { try store.put(row) }
        removeCommitted(sealed)
        notify()
    }

    // MARK: - Scheduler

    private func runScheduler(generation: UInt64) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.uploadLoop(generation) }
            group.addTask { await self.downloadLoop(generation) }
            group.addTask { await self.availabilityLoop(generation) }
        }
    }

    private enum Next<Work: Sendable>: Sendable {
        case work(Work)
        case wait(TimeInterval)
        case stop
    }

    private struct Context: Sendable {
        let relay: BlobRelayClient
        let access: @Sendable () async throws -> (group: Data, token: Data)
        let route: BlobRoute
    }

    private func context(_ generation: UInt64) -> Context? {
        guard isCurrent(generation), let active else { return nil }
        return Context(relay: active.relay, access: active.access, route: active.binding.route)
    }

    private enum Loop: Sendable {
        case uploads, downloads, availability
    }

    private func signal(_ generation: UInt64, _ loop: Loop) -> BlobSignal? {
        guard isCurrent(generation), let active else { return nil }
        switch loop {
        case .uploads: return active.uploads
        case .downloads: return active.downloads
        case .availability: return active.availability
        }
    }

    private nonisolated func idle(_ generation: UInt64, _ loop: Loop, seconds: TimeInterval) async {
        guard let signal = await signal(generation, loop) else { return }
        await signal.wait(seconds: seconds)
    }

    /// Checks once per binding that the relay offers blobs. Without it, no
    /// blob request is sent and the summary reports `relayUnsupported`.
    private nonisolated func requireRelaySupport(_ context: Context, token: Data, generation: UInt64) async throws {
        if await isRelayChecked(generation) { return }
        let supported = try await context.relay.supportsBlobs(group: context.route.bytes, token: token)
        await noteRelaySupport(supported, generation: generation)
        guard supported else { throw BlobRelayError.unsupported }
    }

    private var relayChecked: UInt64?

    private func isRelayChecked(_ generation: UInt64) -> Bool { relayChecked == generation && !relayUnsupported }

    private func noteRelaySupport(_ supported: Bool, generation: UInt64) {
        guard isCurrent(generation) else { return }
        relayChecked = generation
        if relayUnsupported != !supported {
            relayUnsupported = !supported
            notify()
        }
    }

    static func backoff(attempts: Int, retryAfter: TimeInterval?) -> TimeInterval {
        let base = min(3_600, pow(2, Double(max(0, min(attempts, 12)))))
        let jittered = base * Double.random(in: 0.8...1.2)
        return min(3_600, max(jittered, retryAfter ?? 0))
    }

    // MARK: Upload

    private func nextUpload(_ generation: UInt64) -> Next<BlobOutgoingRow> {
        guard let session = currentSession(generation) else { return .stop }
        if relayUnsupported { return .wait(3_600) }
        let now = Date().timeIntervalSince1970
        let rows = ((try? store.allOutgoing()) ?? []).filter {
            $0.session == session && ($0.phase == .sealed || $0.phase == .uploaded)
        }
        if let row = rows.filter({ $0.retryAt <= now }).min(by: { $0.retryAt < $1.retryAt }) {
            return .work(row)
        }
        return .wait(rows.map { $0.retryAt - now }.min() ?? 3_600)
    }

    private nonisolated func uploadLoop(_ generation: UInt64) async {
        while !Task.isCancelled {
            switch await nextUpload(generation) {
            case .stop: return
            case .wait(let seconds): await idle(generation, .uploads, seconds: seconds)
            case .work(let row): await upload(row, generation: generation)
            }
        }
    }

    private nonisolated func upload(_ row: BlobOutgoingRow, generation: UInt64) async {
        guard let context = await context(generation) else { return }
        do {
            let access = try await context.access()
            guard access.group == row.route else { throw BlobError.staleBinding }
            try await requireRelaySupport(context, token: access.token, generation: generation)
            if row.phase == .sealed {
                let manifest = try row.manifest()
                let begin = try await context.relay.begin(manifest: manifest, token: access.token)
                if !begin.complete {
                    if begin.leasedByOther { throw BlobRelayError.busy(after: 60) }
                    let file = files.sealedFile(row.id, generation: row.sealGeneration)
                    guard let handle = try? FileHandle(forReadingFrom: file) else {
                        await reseal(row.id, generation: generation)
                        return
                    }
                    defer { try? handle.close() }
                    for index in 0..<manifest.layout.partCount where !begin.present.contains(index) {
                        try handle.seek(toOffset: manifest.layout.ciphertextOffset(ofPart: index))
                        let part = try handle.read(upToCount: manifest.layout.ciphertextLength(ofPart: index)) ?? Data()
                        guard part.count == manifest.layout.ciphertextLength(ofPart: index),
                              Data(SHA256.hash(data: part)) == manifest.partHashes[index]
                        else {
                            await reseal(row.id, generation: generation)
                            return
                        }
                        _ = try await context.relay.put(
                            route: context.route, objectID: manifest.objectID, index: index, part: part, token: access.token
                        )
                    }
                }
                await commitUploaded(row.id, generation: generation, sealGeneration: row.sealGeneration)
            }
            await commitOffered(row.id, generation: generation)
        } catch BlobRelayError.partMismatch {
            await reseal(row.id, generation: generation)
        } catch {
            await retryOutgoing(row.id, generation: generation, error: error)
        }
    }

    private func commitUploaded(_ id: Data, generation: UInt64, sealGeneration: Int) {
        guard let session = currentSession(generation), var row = try? store.outgoing(id), row.session == session,
              row.phase == .sealed, row.sealGeneration == sealGeneration
        else {
            return
        }
        row.phase = .uploaded
        row.attempts = 0
        guard (try? write { try store.put(row) }) != nil else { return }
        removeCommitted(files.sealedFile(id, generation: sealGeneration))
    }

    /// Freezes the descriptor. Only from here on may `outgoing()` expose it.
    private func commitOffered(_ id: Data, generation: UInt64) {
        guard let session = currentSession(generation), var row = try? store.outgoing(id), row.session == session,
              row.phase == .uploaded, row.descriptor == nil, let descriptor = try? row.frozenDescriptor()
        else {
            return
        }
        let encoded = descriptor.encoded()
        row.descriptor = encoded
        row.digest = BlobDescriptor.digest(of: encoded)
        row.phase = .offered
        guard (try? write { try store.put(row) }) != nil else { return }
        waitingCapacity.removeValue(forKey: id)
        notify()
    }

    private func retryOutgoing(_ id: Data, generation: UInt64, error: Error) {
        if case BlobRelayError.unsupported = error {
            relayUnsupported = true
            notify()
        }
        guard let session = currentSession(generation), var row = try? store.outgoing(id), row.session == session else {
            return
        }
        row.attempts += 1
        row.retryAt = Date().timeIntervalSince1970 + Self.backoff(attempts: row.attempts, retryAfter: Self.retryAfter(error))
        try? write { try store.put(row) }
    }

    private static func retryAfter(_ error: Error) -> TimeInterval? {
        switch error {
        case BlobRelayError.busy(let after), BlobRelayError.capacity(let after): return after
        case BlobRelayError.unsupported, BlobRelayError.unauthorized, BlobRelayError.historyExpired: return 3_600
        default: return nil
        }
    }

    // MARK: Download

    private func nextDownload(_ generation: UInt64) -> Next<(BlobIncomingRow, UUID)> {
        guard let session = currentSession(generation) else { return .stop }
        if relayUnsupported { return .wait(3_600) }
        let now = Date().timeIntervalSince1970
        let rows = ((try? store.allIncoming()) ?? []).filter {
            $0.session == session && [.queued, .fetching, .unavailable].contains($0.phase)
        }
        let due = rows.filter { $0.retryAt <= now }.sorted {
            ($0.phase == .fetching ? 0 : 1, $0.retryAt) < ($1.phase == .fetching ? 0 : 1, $1.retryAt)
        }
        let byteRows = ((try? store.allIncoming()) ?? []).filter { $0.phase.holdsBytes }.count
        for var row in due {
            if let ticket = fetchTickets[row.id] { return .work((row, ticket)) }
            guard let layout = try? BlobDescriptor.stored(row.descriptor).layout else { continue }
            if row.phase != .fetching, byteRows >= Self.maxIncomingByteRows { continue }
            let existing = BlobFiles.size(files.ciphertext(row.id))
            guard let ticket = try? reserve(Int64(layout.ciphertextLength + layout.plaintextLength), for: row.id, kind: row.kind) else { continue }
            committedBytes = max(0, committedBytes - existing)
            fetchTickets[row.id] = ticket
            if row.phase != .fetching {
                row.phase = .fetching
                guard (try? write { try store.put(row) }) != nil else {
                    releaseFetch(row.id)
                    continue
                }
                notify()
            }
            return .work((row, ticket))
        }
        let soonest = rows.map { $0.retryAt - now }.filter { $0 > 0 }.min()
        return .wait(soonest ?? (rows.isEmpty ? 3_600 : 30))
    }

    private nonisolated func downloadLoop(_ generation: UInt64) async {
        while !Task.isCancelled {
            switch await nextDownload(generation) {
            case .stop: return
            case .wait(let seconds): await idle(generation, .downloads, seconds: seconds)
            case .work(let (row, _)): await download(row, generation: generation)
            }
        }
    }

    private nonisolated func download(_ row: BlobIncomingRow, generation: UInt64) async {
        await beginFetch(row.id)
        await fetch(row, generation: generation)
        await settleFetch(row.id, generation: generation)
    }

    private func beginFetch(_ id: Data) {
        activeFetches.insert(id)
    }

    /// Runs when a download worker returns. A row that is still fetching in
    /// the current session keeps its reservation for the next attempt; any
    /// other outcome frees what the worker left behind.
    private func settleFetch(_ id: Data, generation: UInt64) {
        activeFetches.remove(id)
        let row = try? store.incoming(id)
        if let row, row.phase == .fetching, row.session == currentSession(generation) {
            return
        }
        if row?.phase == .verified {
            return
        }
        discardFetch(id)
    }

    private nonisolated func fetch(_ row: BlobIncomingRow, generation: UInt64) async {
        guard let context = await context(generation), let descriptor = try? BlobDescriptor.stored(row.descriptor),
              descriptor.kind == row.kind
        else {
            return
        }
        let layout = descriptor.layout
        do {
            let access = try await context.access()
            guard access.group == row.route else { throw BlobError.staleBinding }
            try await requireRelaySupport(context, token: access.token, generation: generation)
            let remote: BlobRelayManifest
            do {
                remote = try await context.relay.manifest(route: context.route, objectID: descriptor.objectID, token: access.token)
            } catch BlobRelayError.objectMissing {
                try await context.relay.want(route: context.route, objectIDs: [descriptor.objectID], token: access.token)
                await markUnavailable(row.id, generation: generation)
                return
            }
            guard remote.complete else {
                try await context.relay.want(route: context.route, objectIDs: [descriptor.objectID], token: access.token)
                await markUnavailable(row.id, generation: generation)
                return
            }
            guard remote.ciphertextLength == layout.ciphertextLength,
                  let manifest = try? BlobManifest(route: context.route, ciphertextLength: remote.ciphertextLength,
                                                   partHashes: remote.partHashes),
                  manifest.objectID == descriptor.objectID
            else {
                await failIntegrity(row.id, generation: generation, rejection: .relayIntegrity)
                return
            }
            let ciphertext = files.ciphertext(row.id)
            if !FileManager.default.fileExists(atPath: ciphertext.path) {
                try BlobFiles.create(ciphertext).close()
            }
            var present = row.present
            for index in 0..<layout.partCount where present & (1 << UInt32(index)) == 0 {
                let part = try await context.relay.get(
                    route: context.route, objectID: descriptor.objectID, index: index,
                    length: layout.ciphertextLength(ofPart: index), token: access.token
                )
                guard Data(SHA256.hash(data: part)) == manifest.partHashes[index] else {
                    await failIntegrity(row.id, generation: generation, rejection: .relayIntegrity)
                    return
                }
                let handle = try FileHandle(forUpdating: ciphertext)
                try handle.seek(toOffset: layout.ciphertextOffset(ofPart: index))
                try handle.write(contentsOf: part)
                try handle.synchronize()
                try handle.close()
                present |= 1 << UInt32(index)
                guard await commitPresent(row.id, generation: generation, present: present) else { return }
            }
            let opened = files.opened(row.id)
            do {
                try await BlobWorkGate.open.run {
                    let input = try FileHandle(forReadingFrom: ciphertext)
                    defer { try? input.close() }
                    let output = try BlobFiles.create(opened)
                    defer { try? output.close() }
                    try BlobCipher.open(ciphertext: input, manifest: manifest, descriptor: descriptor, output: output)
                }
            } catch {
                await failIntegrity(row.id, generation: generation, rejection: .relayIntegrity)
                return
            }
            if descriptor.kind == .applicationData {
                guard let info = try? BlobDataDescriptorInfo(descriptor: row.descriptor), let hooks = await hooks,
                      await hooks.acceptsData(opened, info)
                else {
                    await reject(row.id, generation: generation, rejection: .dataRefused)
                    return
                }
                await commitVerified(row.id, generation: generation)
                return
            }
            let image: BlobImageInfo
            do {
                image = try await Self.validate(opened)
            } catch {
                await reject(row.id, generation: generation, rejection: .imageRejected)
                return
            }
            guard image.mediaType == descriptor.mediaType, image.pixelWidth == descriptor.pixelWidth,
                  image.pixelHeight == descriptor.pixelHeight
            else {
                await reject(row.id, generation: generation, rejection: .descriptorMismatch)
                return
            }
            if let hooks = await hooks, !(await hooks.acceptsImage(opened, image)) {
                await reject(row.id, generation: generation, rejection: .imageRejected)
                return
            }
            await commitVerified(row.id, generation: generation)
        } catch {
            await retryIncoming(row.id, generation: generation, error: error)
        }
    }

    private func commitPresent(_ id: Data, generation: UInt64, present: UInt32) -> Bool {
        guard let session = currentSession(generation), var row = try? store.incoming(id), row.session == session,
              row.phase == .fetching
        else {
            return false
        }
        row.present = present
        return (try? write { try store.put(row) }) != nil
    }

    private func commitVerified(_ id: Data, generation: UInt64) {
        let opened = files.opened(id)
        guard let session = currentSession(generation), var row = try? store.incoming(id), row.session == session,
              row.phase == .fetching, let ticket = fetchTickets[id]
        else {
            BlobFiles.remove(opened)
            return
        }
        let verified = files.verifiedFile(id)
        do {
            BlobFiles.remove(verified)
            try FileManager.default.moveItem(at: opened, to: verified)
        } catch {
            BlobFiles.remove(opened)
            return
        }
        BlobFiles.synchronize(directory: files.verified)
        row.phase = .verified
        row.present = 0
        row.attempts = 0
        guard (try? write { try store.put(row) }) != nil else {
            BlobFiles.remove(verified)
            return
        }
        adopt(verified)
        BlobFiles.remove(files.ciphertext(id))
        fetchTickets[id] = nil
        release(ticket)
        notify()
    }

    /// Frees an incoming row's partial files unless a worker still owns them;
    /// that worker frees them when it returns. Files under a fetch reservation
    /// leave with it; files adopted at open leave the committed count.
    private func dropFetchFiles(_ id: Data) {
        guard !activeFetches.contains(id) else { return }
        if fetchTickets[id] != nil {
            discardFetch(id)
        } else {
            BlobFiles.remove(files.opened(id))
            removeCommitted(files.ciphertext(id))
        }
    }

    private func discardFetch(_ id: Data) {
        BlobFiles.remove(files.opened(id))
        BlobFiles.remove(files.ciphertext(id))
        releaseFetch(id)
    }

    private func failIntegrity(_ id: Data, generation: UInt64, rejection: BlobRejection) {
        guard let session = currentSession(generation), var row = try? store.incoming(id), row.session == session else { return }
        discardFetch(id)
        row.attempts += 1
        row.present = 0
        if row.attempts >= Self.maxIntegrityAttempts {
            row.phase = .rejected
            row.rejection = rejection.storageName
        } else {
            row.phase = .queued
            row.retryAt = Date().timeIntervalSince1970 + Self.backoff(attempts: row.attempts, retryAfter: nil)
        }
        try? write { try store.put(row) }
        notify()
    }

    private func reject(_ id: Data, generation: UInt64, rejection: BlobRejection) {
        guard let session = currentSession(generation), var row = try? store.incoming(id), row.session == session else { return }
        discardFetch(id)
        row.phase = .rejected
        row.rejection = rejection.storageName
        row.present = 0
        try? write { try store.put(row) }
        notify()
    }

    private func markUnavailable(_ id: Data, generation: UInt64) {
        guard let session = currentSession(generation), var row = try? store.incoming(id), row.session == session else { return }
        discardFetch(id)
        row.phase = .unavailable
        row.present = 0
        let waits = min(row.attempts + 6, 12)
        row.retryAt = Date().timeIntervalSince1970 + Self.backoff(attempts: waits, retryAfter: nil)
        try? write { try store.put(row) }
        active?.availability.fire()
        notify()
    }

    private func retryIncoming(_ id: Data, generation: UInt64, error: Error) {
        if case BlobRelayError.unsupported = error {
            relayUnsupported = true
            notify()
        }
        guard let session = currentSession(generation), var row = try? store.incoming(id), row.session == session else { return }
        if case BlobRelayError.partMissing = error {
            discardFetch(id)
            row.phase = .queued
            row.present = 0
        }
        let transient = row.phase == .fetching && fetchTickets[id] != nil
        if !transient {
            releaseFetch(id)
        }
        row.retryAt = Date().timeIntervalSince1970 + Self.backoff(attempts: 2, retryAfter: Self.retryAfter(error))
        try? write { try store.put(row) }
    }

    // MARK: Availability

    private struct Reupload: Sendable {
        let objectID: Data
        let descriptor: BlobDescriptor
        let outgoing: Data?
        let source: URL?
        let ticket: UUID
    }

    private func hasAvailabilityWork(_ generation: UInt64) -> Next<Void> {
        guard let session = currentSession(generation) else { return .stop }
        if relayUnsupported { return .wait(3_600) }
        let offered = ((try? store.allOutgoing()) ?? []).contains { $0.session == session && $0.phase == .offered }
        let registered = ((try? store.availableCount()) ?? 0) > 0
        return offered || registered ? .work(()) : .wait(Self.availabilityInterval)
    }

    private nonisolated func availabilityLoop(_ generation: UInt64) async {
        while !Task.isCancelled {
            switch await hasAvailabilityWork(generation) {
            case .stop: return
            case .wait(let seconds): await idle(generation, .availability, seconds: seconds)
            case .work:
                await serveWanted(generation)
                await idle(generation, .availability, seconds: Self.availabilityInterval)
            }
        }
    }

    private nonisolated func serveWanted(_ generation: UInt64) async {
        guard let context = await context(generation) else { return }
        do {
            let access = try await context.access()
            guard access.group == context.route.bytes else { return }
            try await requireRelaySupport(context, token: access.token, generation: generation)
            let wanted = try await context.relay.wanted(route: context.route, token: access.token)
            for objectID in wanted {
                guard let job = await reuploadJob(objectID, generation: generation) else { continue }
                await reupload(job, context: context, token: access.token, generation: generation)
            }
        } catch {
            return
        }
    }

    /// An offered row of this session or a registered object with `objectID`,
    /// with the host file to re-derive it from.
    private func reuploadJob(_ objectID: Data, generation: UInt64) async -> Reupload? {
        guard let session = currentSession(generation), let route = active?.binding.route else { return nil }
        var descriptor: BlobDescriptor?
        var outgoing: Data?
        var source: URL?
        if let row = ((try? store.allOutgoing()) ?? []).first(where: {
            $0.session == session && $0.phase == .offered && $0.objectID == objectID
        }), let encoded = row.descriptor {
            descriptor = try? BlobDescriptor.stored(encoded)
            outgoing = row.id
            source = URL(fileURLWithPath: row.source)
        } else if let encoded = try? store.available(route: route.bytes, objectID: objectID) {
            descriptor = try? BlobDescriptor.stored(encoded)
        }
        guard let descriptor else { return nil }
        if source == nil || !FileManager.default.fileExists(atPath: source!.path), let hooks {
            source = await hooks.verifiedContentURL(descriptor.contentHash)
        }
        guard isCurrent(generation),
              let ticket = try? reserve(Int64(descriptor.layout.ciphertextLength), for: objectID, kind: descriptor.kind)
        else {
            return nil
        }
        return Reupload(objectID: objectID, descriptor: descriptor, outgoing: outgoing, source: source, ticket: ticket)
    }

    private nonisolated func reupload(_ job: Reupload, context: Context, token: Data, generation: UInt64) async {
        let output = files.reuploadFile(job.objectID)
        defer {
            BlobFiles.remove(output)
            Task { await self.release(job.ticket) }
        }
        let prepared: BlobPreparedObject
        do {
            guard let source = job.source else { throw BlobCodecError.sourceMismatch }
            prepared = try await BlobWorkGate.seal.run {
                let input = try FileHandle(forReadingFrom: source)
                defer { try? input.close() }
                let handle = try BlobFiles.create(output)
                defer { try? handle.close() }
                return try BlobCipher.prepareReupload(descriptor: job.descriptor, route: context.route, source: input, output: handle)
            }
        } catch {
            if let id = job.outgoing {
                await commitRepairRequired(id, generation: generation)
            }
            return
        }
        do {
            let begin = try await context.relay.begin(manifest: prepared.manifest, token: token)
            guard !begin.complete, !begin.leasedByOther else { return }
            let handle = try FileHandle(forReadingFrom: output)
            defer { try? handle.close() }
            let layout = prepared.manifest.layout
            for index in 0..<layout.partCount where !begin.present.contains(index) {
                try handle.seek(toOffset: layout.ciphertextOffset(ofPart: index))
                let part = try handle.read(upToCount: layout.ciphertextLength(ofPart: index)) ?? Data()
                _ = try await context.relay.put(route: context.route, objectID: job.objectID, index: index, part: part, token: token)
            }
        } catch {
            return
        }
    }

    private func commitRepairRequired(_ id: Data, generation: UInt64) {
        guard let session = currentSession(generation), var row = try? store.outgoing(id), row.session == session,
              row.phase == .offered
        else {
            return
        }
        row.phase = .repairRequired
        try? write { try store.put(row) }
        notify()
    }
}

struct BlobSealCandidate: Sendable {
    let sealed: BlobSealedObject
    let image: BlobImageInfo
    let clone: URL
    let output: URL
}

/// Wakes one loop; a timeout is a task that fires the same signal.
final class BlobSignal: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let waiting = OSAllocatedUnfairLock(initialState: false)

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    func fire() {
        continuation.yield()
    }

    /// One waiter at a time: each signal belongs to a single loop.
    func wait(seconds: TimeInterval) async {
        guard waiting.withLock({ busy in defer { busy = true }; return !busy }) else { return }
        defer { waiting.withLock { $0 = false } }
        let timeout = Task { [continuation] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.05, min(seconds, 86_400)) * 1_000_000_000))
            continuation.yield()
        }
        defer { timeout.cancel() }
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}

extension BlobOutgoingFailure {
    init(_ name: String?) {
        switch name {
        case "sourceChanged": self = .sourceChanged
        case "exceedsSyncLimits": self = .exceedsSyncLimits
        case "imageRejected": self = .imageRejected
        default: self = .sourceUnreadable
        }
    }
}

extension BlobRejection {
    var storageName: String {
        switch self {
        case .relayIntegrity: "relayIntegrity"
        case .descriptorMismatch: "descriptorMismatch"
        case .imageRejected: "imageRejected"
        case .dataRefused: "dataRefused"
        }
    }

    init(_ name: String?) {
        switch name {
        case "descriptorMismatch": self = .descriptorMismatch
        case "imageRejected": self = .imageRejected
        case "dataRefused": self = .dataRefused
        default: self = .relayIntegrity
        }
    }
}
