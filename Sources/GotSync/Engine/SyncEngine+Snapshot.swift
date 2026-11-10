import CryptoKit
import Foundation
import os

// Snapshot bootstrap (L2b). A provider exports the app's compact state at a
// causally complete cut and offers it with `complete`; a joiner that asked
// for it verifies the anchors against records it received itself, fetches
// and assembles the content, has the app merge it, then skips covered
// records. Every record stays retained; nothing here discards bytes.

/// Descriptor digests the recipient expects for the current offer. Read by
/// the snapshot service's admission hook off the main actor.
final class HostSnapshotAdmission: Sendable {
    private let digests = OSAllocatedUnfairLock<Set<Data>>(initialState: [])

    func expect(_ expected: Set<Data>) {
        digests.withLock { $0 = expected }
    }

    func admits(_ digest: Data) -> Bool {
        digests.withLock { $0.contains(digest) }
    }
}

/// The provider's exports, by recipient, kept apart from the reply
/// obligation so an export finishing during a reply cannot be overwritten.
struct HostSnapshotExportLedger: Codable, Equatable, Sendable {
    static let filename = "exports.json"
    static let version = 1

    struct Entry: Codable, Equatable, Sendable {
        let member: Data
        var id: Data
        let schema: String
        var attempts: Int
        var offer: HostSnapshotOffer?
        var refusal: HostSnapshotRefusalReason?

        var isResolved: Bool { offer != nil || refusal != nil }
    }

    var version = Self.version
    var entries: [Entry] = []

    subscript(member: Data) -> Entry? {
        get { entries.first { $0.member == member } }
        set {
            entries.removeAll { $0.member == member }
            if let newValue { entries.append(newValue) }
        }
    }

    static func load(from url: URL) throws -> HostSnapshotExportLedger {
        guard FileManager.default.fileExists(atPath: url.path) else { return HostSnapshotExportLedger() }
        let ledger = try ReplicaCanonicalJSON.decode(HostSnapshotExportLedger.self, from: Data(contentsOf: url))
        guard ledger.version == version, ledger.entries.count <= SyncGroupProfile.supportedMemberCeiling else {
            throw ReplicaError.corruptArchive("The snapshot export ledger is unreadable.")
        }
        return ledger
    }

    static func save(_ ledger: HostSnapshotExportLedger, to url: URL) throws {
        if ledger.entries.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ProtectedStorage.write(ReplicaCanonicalJSON.encode(ledger), to: url)
    }
}

/// A provider-side reason to answer with a refusal instead of an offer.
private struct HostSnapshotExportRefused: Error {
    let reason: HostSnapshotRefusalReason
}

/// One packed export: its length, hash and chunk files in order.
private struct HostSnapshotPacked: Sendable {
    let length: UInt64
    let contentHash: Data
    let chunks: [(url: URL, hash: Data)]
}

// MARK: - Host registration

@_spi(HostJournalPreview) extension SyncEngine {
    /// Registers the app's snapshot host, or removes it with nil. A joiner
    /// asks for a snapshot only while a host is registered and its journal
    /// is fresh; a provider exports only for a joiner of the same schema.
    /// Without a host, bootstrap keeps full history.
    public func registerSnapshotHost(_ hooks: HostSnapshotHooks?) {
        snapshotHooks = hooks
        requestSyncCycle(force: true)
    }

    /// Ends a held snapshot bootstrap so every record is delivered. Throws
    /// `bootstrapPending` while the install hook is running.
    public func declineSnapshotBootstrap() async throws {
        guard let store = hostAdapter?.store else { throw HostJournalError.fenced }
        guard store.view.isDeliveryHeld else { return }
        let declined: Bool
        do {
            declined = try await store.refuseSnapshot(.declinedByHost, in: [.requested, .offered, .fetching, .assembled])
        } catch {
            throw HostJournalError.surfaced(error)
        }
        guard declined || store.view.bootstrap?.phase.holdsDelivery != true else { throw HostJournalError.bootstrapPending }
        requestSyncCycle(force: true)
    }
}

extension SyncEngine {
    static let snapshotDirectoryName = "host-snapshot-v1"
    /// Continuous unavailability of snapshot content after which the
    /// recipient refuses it and continues on full history.
    static let snapshotUnavailableLimit: Duration = .seconds(600)

    private var unavailableLimit: Duration { snapshotUnavailableLimitForTesting ?? Self.snapshotUnavailableLimit }

    // MARK: - Transfers

    func openSnapshotService() async -> BlobTransferService? {
        if let snapshotService {
            return snapshotService
        }
        guard let snapshotDirectory else { return nil }
        let directory = snapshotDirectory.appendingPathComponent("blobs", isDirectory: true)
        if snapshotOpenTask == nil, let protocols = snapshotRelayProtocolsForTesting {
            let service = try? BlobTransferService(
                directory: directory, relayURL: mailboxURL, policy: endpointPolicy, relayProtocols: protocols
            )
            snapshotOpenTask = Task { service }
        }
        let task = snapshotOpenTask ?? Task { [mailboxURL, endpointPolicy] in
            try? await BlobTransferService.open(directory: directory, relayURL: mailboxURL, policy: endpointPolicy)
        }
        snapshotOpenTask = task
        guard let service = await task.value else {
            if snapshotOpenTask == task {
                snapshotOpenTask = nil
            }
            return nil
        }
        if snapshotService == nil {
            snapshotService = service
            let admission = snapshotAdmission
            await service.setHooks(BlobHostHooks(
                verifiedContentURL: { _ in nil },
                acceptsImage: { _, _ in false },
                acceptsData: { _, info in admission.admits(info.digest) }
            ))
            snapshotUpdatesTask = Task { [weak self] in
                for await _ in service.updates() {
                    guard let self else { return }
                    if self.hostAdapter?.store?.view.bootstrap?.phase == .fetching {
                        self.requestSyncCycle(force: true)
                    }
                }
            }
            if snapshotRetirePending {
                snapshotRetirePending = false
                await service.retire()
            }
        }
        return snapshotService
    }

    /// Binds the snapshot service like the host's blob service and returns
    /// the route, or nil when the membership changed meanwhile.
    @discardableResult
    func bindSnapshotService(_ session: MLSSession) async -> BlobRoute? {
        guard snapshotDirectory != nil, let service = await openSnapshotService() else { return nil }
        let epoch = blobBindingEpoch
        let token = service.bindingToken
        let client = session.client
        guard let access = try? await client.blobAccess(),
              let member = try? await client.fingerprint(),
              let route = try? BlobRoute(bytes: access.group),
              isCurrentBlobSession(session), blobBindingEpoch == epoch
        else {
            return nil
        }
        guard (try? await service.ensureBound(route: route, member: member, notRetiredSince: token) {
            try await client.blobAccess()
        }) != nil else { return nil }
        return route
    }

    func retireSnapshotTransfers() {
        snapshotAdmission.expect([])
        if let snapshotService {
            snapshotService.retireNow()
        } else if snapshotDirectory != nil {
            snapshotRetirePending = true
        }
    }

    private static func transferID(_ snapshot: Data, _ index: Int) throws -> BlobTransferID {
        try BlobTransferID(bytes: HostSnapshotOffer.transferID(snapshot: snapshot, index: index))
    }

    private func snapshotFile(_ name: String, _ id: Data) -> URL? {
        snapshotDirectory?.appendingPathComponent("\(name)-\(id.map { String(format: "%02x", $0) }.joined())")
    }

    // MARK: - Joiner request

    /// Requests a snapshot before a provider hello, for a fresh journal while
    /// a host is registered. The hello then carries the schema.
    func requestSnapshotBootstrap(binding: HostBinding, session: MLSSession) async throws {
        guard let hooks = snapshotHooks, let store = hostAdapter?.store, store.view.bootstrap == nil else { return }
        try await store.requestSnapshot(schema: hooks.schema.name)
        try requireHostBinding(binding, session)
    }

    // MARK: - Provider

    private var snapshotLedgerURL: URL? {
        snapshotDirectory?.appendingPathComponent(HostSnapshotExportLedger.filename)
    }

    private func snapshotLedger() -> HostSnapshotExportLedger {
        if let snapshotLedgerCache { return snapshotLedgerCache }
        let loaded = snapshotLedgerURL.flatMap { try? HostSnapshotExportLedger.load(from: $0) } ?? HostSnapshotExportLedger()
        snapshotLedgerCache = loaded
        return loaded
    }

    private func saveSnapshotLedger(_ ledger: HostSnapshotExportLedger) throws {
        snapshotLedgerCache = ledger
        if let snapshotLedgerURL {
            try HostSnapshotExportLedger.save(ledger, to: snapshotLedgerURL)
        }
    }

    /// A request without a snapshot, or one whose export is resolved, may
    /// take its completion cut.
    func isSnapshotExportResolved(_ request: ReplyObligation.Bootstrap) -> Bool {
        request.snapshot == nil || snapshotLedger()[request.member]?.isResolved == true
    }

    func snapshotExport(for member: Data) -> HostSnapshotExportLedger.Entry? {
        snapshotLedger()[member]
    }

    /// Resolves at once what needs no export, starts one export per waiting
    /// request, and drops entries and rows whose request is gone.
    func prepareSnapshotExports(session: MLSSession) async throws {
        let requests = (replyObligation?.bootstrap ?? []).filter { $0.cut == nil && $0.snapshot != nil }
        var ledger = snapshotLedger()
        let live = Set((replyObligation?.bootstrap ?? []).filter { $0.snapshot != nil }.map(\.member))
        for entry in ledger.entries where !live.contains(entry.member) && snapshotExportTasks[entry.member] == nil {
            await dropSnapshotRows(entry.id)
            ledger[entry.member] = nil
        }
        var starts: [HostSnapshotExportLedger.Entry] = []
        var certified: Bool?
        for request in requests {
            guard let schema = request.snapshot, snapshotExportTasks[request.member] == nil else { continue }
            let existing = ledger[request.member]
            if existing?.isResolved == true { continue }
            var entry = existing ?? HostSnapshotExportLedger.Entry(
                member: request.member, id: HostJournalStore.randomBytes(16), schema: schema, attempts: 0
            )
            guard let hooks = snapshotHooks else {
                entry.refusal = .notRegistered
                ledger[request.member] = entry
                continue
            }
            guard hooks.schema.name == schema else {
                entry.refusal = .schemaMismatch
                ledger[request.member] = entry
                continue
            }
            if certified == nil {
                certified = try await hostMayCertify(session: session)
            }
            guard certified == true else { break }
            if existing != nil {
                await dropSnapshotRows(entry.id)
                entry.id = HostJournalStore.randomBytes(16)
            }
            entry.attempts += 1
            if entry.attempts > HostSnapshotBounds.exportAttempts {
                entry.refusal = .exportFailed
            } else {
                starts.append(entry)
            }
            ledger[request.member] = entry
        }
        if ledger != snapshotLedger() {
            try saveSnapshotLedger(ledger)
        }
        for entry in starts {
            startSnapshotExport(entry, session: session)
        }
    }

    private func startSnapshotExport(_ entry: HostSnapshotExportLedger.Entry, session: MLSSession) {
        guard let hooks = snapshotHooks else { return }
        snapshotExportTasks[entry.member] = Task { [weak self] in
            guard let self else { return }
            let result: Result<HostSnapshotOffer, HostSnapshotExportRefused>
            do {
                result = .success(try await self.produceSnapshotOffer(id: entry.id, schema: entry.schema, hooks: hooks, session: session))
            } catch let refused as HostSnapshotExportRefused {
                result = .failure(refused)
            } catch is CancellationError {
                self.snapshotExportTasks[entry.member] = nil
                return
            } catch HostEngineError.generationChanged {
                self.snapshotExportTasks[entry.member] = nil
                return
            } catch {
                result = .failure(HostSnapshotExportRefused(reason: .exportFailed))
            }
            self.snapshotExportTasks[entry.member] = nil
            var ledger = self.snapshotLedger()
            guard var stored = ledger[entry.member], stored.id == entry.id, !stored.isResolved else { return }
            switch result {
            case .success(let offer): stored.offer = offer
            case .failure(let refused): stored.refusal = refused.reason
            }
            ledger[entry.member] = stored
            try? self.saveSnapshotLedger(ledger)
            self.requestSyncCycle(force: true)
        }
    }

    /// Exports at a fresh cut, packs and seals the chunks, and waits until
    /// every chunk is uploaded.
    private func produceSnapshotOffer(
        id: Data, schema: String, hooks: HostSnapshotHooks, session: MLSSession
    ) async throws -> HostSnapshotOffer {
        guard let directory = snapshotDirectory, let destination = snapshotFile("export", id) else {
            throw HostSnapshotExportRefused(reason: .exportFailed)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        for attempt in 1...HostSnapshotBounds.exportAttempts {
            let binding = try hostBinding(session)
            guard let store = hostAdapter?.store else { throw HostEngineError.generationChanged }
            let cut = try await store.snapshotExportCut()
            try requireHostBinding(binding, session)
            try? FileManager.default.removeItem(at: destination)
            let outcome = try await hooks.export(HostSnapshotCut(
                id: HostSnapshotID(bytes: id), journalID: cut.journalID, appliedThrough: JournalPosition.stored(cut.appliedThrough),
                capturedThrough: cut.capturedThrough, destination: destination
            ))
            try Task.checkCancellation()
            try requireHostBinding(binding, session)
            guard case .exported(let echo) = outcome, echo.appliedThrough?.rawValue ?? 0 == cut.appliedThrough,
                  echo.capturedThrough == cut.capturedThrough
            else {
                if attempt < HostSnapshotBounds.exportAttempts {
                    try await Task.sleep(for: .seconds(1))
                    continue
                }
                throw HostSnapshotExportRefused(reason: .notAtCut)
            }
            let packed = try await Task.detached(priority: .utility) {
                try Self.pack(destination, id: id, into: directory)
            }.value
            defer { for chunk in packed.chunks { try? FileManager.default.removeItem(at: chunk.url) } }
            let chunks = try await sealSnapshot(id: id, packed: packed, session: session)
            return HostSnapshotOffer(
                id: id, schema: schema, anchors: cut.anchors, length: packed.length, contentHash: packed.contentHash, chunks: chunks
            )
        }
        throw HostSnapshotExportRefused(reason: .notAtCut)
    }

    /// Splits `file` into chunk files and hashes the whole and every chunk.
    nonisolated private static func pack(_ file: URL, id: Data, into directory: URL) throws -> HostSnapshotPacked {
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, let size = values?.fileSize, size > 0 else {
            throw HostSnapshotExportRefused(reason: .exportFailed)
        }
        guard UInt64(size) <= HostSnapshotBounds.maxBytes else { throw HostSnapshotExportRefused(reason: .tooLarge) }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var whole = SHA256()
        var chunks: [(url: URL, hash: Data)] = []
        var index = 0
        while let data = try handle.read(upToCount: HostSnapshotBounds.chunkBytes), !data.isEmpty {
            whole.update(data: data)
            let url = directory.appendingPathComponent("chunk-\(id.map { String(format: "%02x", $0) }.joined())-\(index)")
            try data.write(to: url, options: .atomic)
            chunks.append((url, Data(SHA256.hash(data: data))))
            index += 1
        }
        guard chunks.count <= HostSnapshotBounds.maxChunks else { throw HostSnapshotExportRefused(reason: .tooLarge) }
        return HostSnapshotPacked(length: UInt64(size), contentHash: Data(whole.finalize()), chunks: chunks)
    }

    /// Seals every chunk and returns their descriptors once all are uploaded.
    private func sealSnapshot(id: Data, packed: HostSnapshotPacked, session: MLSSession) async throws -> [Data] {
        guard let service = await openSnapshotService(), let route = await bindSnapshotService(session) else {
            throw HostSnapshotExportRefused(reason: .transferFailed)
        }
        let ids = try packed.chunks.indices.map { try Self.transferID(id, $0) }
        do {
            for (transfer, chunk) in zip(ids, packed.chunks) {
                _ = try await service.sealData(transfer, route: route, source: chunk.url, expectedContentHash: chunk.hash)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HostSnapshotExportRefused(reason: .transferFailed)
        }
        var updates = service.updates().makeAsyncIterator()
        while true {
            try Task.checkCancellation()
            let statuses = await service.outgoing()
            var descriptors: [Data] = []
            for transfer in ids {
                switch statuses.first(where: { $0.id == transfer })?.state {
                case .readyForHandoff(let descriptor, _)?:
                    descriptors.append(descriptor)
                case .uploading?:
                    break
                default:
                    throw HostSnapshotExportRefused(reason: .transferFailed)
                }
            }
            if descriptors.count == ids.count {
                return descriptors
            }
            guard await updates.next() != nil else { throw CancellationError() }
        }
    }

    /// After the offer was sent: the chunks are handed off and the entry
    /// removed.
    func finishSnapshotExport(for member: Data) async {
        var ledger = snapshotLedger()
        guard let entry = ledger[member], snapshotExportTasks[member] == nil else { return }
        await dropSnapshotRows(entry.id)
        ledger[member] = nil
        try? saveSnapshotLedger(ledger)
    }

    /// Removes the outgoing rows of export `id`: offered ones are handed
    /// off, unsent ones cancelled. Staging files go too.
    private func dropSnapshotRows(_ id: Data) async {
        for name in ["export"] {
            if let url = snapshotFile(name, id) { try? FileManager.default.removeItem(at: url) }
        }
        guard let service = await openSnapshotService() else { return }
        let ids = Set((0..<HostSnapshotBounds.maxChunks).compactMap { try? Self.transferID(id, $0) })
        for status in await service.outgoing() where ids.contains(status.id) {
            switch status.state {
            case .readyForHandoff(_, let digest), .repairRequired(_, let digest), .retired(_, let digest?):
                try? await service.confirmHandoff(status.id, descriptorDigest: digest)
            default:
                try? await service.cancelOutgoing(status.id)
            }
        }
    }

    // MARK: - Recipient

    /// Moves a requested bootstrap forward as far as it can in this cycle.
    func advanceSnapshotBootstrap(session: MLSSession) async throws {
        for _ in 0..<6 {
            guard let store = hostAdapter?.store, hostWorkAllowed, snapshotRecipientTask == nil,
                  let bootstrap = store.view.bootstrap
            else { return }
            let before = bootstrap
            try await snapshotStep(bootstrap, store: store, session: session)
            guard hostAdapter?.store?.view.bootstrap != before else { return }
        }
    }

    private func snapshotStep(_ bootstrap: HostJournalBootstrapState, store: HostJournal, session: MLSSession) async throws {
        let binding = try hostBinding(session)
        switch bootstrap.phase {
        case .requested:
            return
        case .offered:
            guard store.view.historyComplete, let offer = bootstrap.offer, let hooks = snapshotHooks else { return }
            if offer.schema != bootstrap.schema || hooks.schema.name != offer.schema {
                try await store.refuseSnapshot(.schemaMismatch, in: [.offered], id: offer.id)
            } else if !Self.descriptorsMatch(offer) {
                try await store.refuseSnapshot(.malformedOffer, in: [.offered], id: offer.id)
            } else if try await store.verifySnapshotAnchors() {
                try requireHostBinding(binding, session)
                try await store.advanceSnapshot(id: offer.id, from: .offered, to: .fetching)
            } else {
                try requireHostBinding(binding, session)
                try await store.refuseSnapshot(.anchorMismatch, in: [.offered], id: offer.id)
            }
        case .fetching:
            guard let offer = bootstrap.offer else { return }
            try await fetchSnapshot(offer, store: store, binding: binding, session: session)
        case .assembled:
            guard let offer = bootstrap.offer else { return }
            let present = snapshotFile("snapshot", offer.id).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            try await store.advanceSnapshot(id: offer.id, from: .assembled, to: present ? .installing : .fetching)
        case .installing:
            guard let offer = bootstrap.offer, let hooks = snapshotHooks, let file = snapshotFile("snapshot", offer.id) else { return }
            guard FileManager.default.fileExists(atPath: file.path) else {
                try await store.advanceSnapshot(id: offer.id, from: .installing, to: .fetching)
                return
            }
            startSnapshotInstall(offer, file: file, hooks: hooks, store: store, binding: binding, session: session)
        case .installed:
            guard let offer = bootstrap.offer, let hooks = snapshotHooks else { return }
            startSnapshotCompletion(offer, hooks: hooks, store: store, binding: binding, session: session)
        case .completed, .refused:
            guard let offer = bootstrap.offer, !snapshotCleanedIDs.contains(offer.id) else { return }
            snapshotCleanedIDs.insert(offer.id)
            snapshotAdmission.expect([])
            await releaseSnapshotContent(offer)
        }
    }

    /// Every descriptor is an application-data descriptor within the chunk
    /// bound, and their lengths add up to the offer's.
    private static func descriptorsMatch(_ offer: HostSnapshotOffer) -> Bool {
        var total: UInt64 = 0
        for descriptor in offer.chunks {
            guard let info = try? BlobDataDescriptorInfo(descriptor: descriptor),
                  info.plaintextLength > 0, info.plaintextLength <= UInt64(HostSnapshotBounds.chunkBytes)
            else { return false }
            total += info.plaintextLength
        }
        return total == offer.length
    }

    private func fetchSnapshot(_ offer: HostSnapshotOffer, store: HostJournal, binding: HostBinding, session: MLSSession) async throws {
        guard let service = await openSnapshotService(), let route = await bindSnapshotService(session),
              let file = snapshotFile("snapshot", offer.id)
        else { return }
        try requireHostBinding(binding, session)
        snapshotAdmission.expect(Set(offer.chunks.map(BlobDescriptor.digest(of:))))
        let ids = try offer.chunks.indices.map { try Self.transferID(offer.id, $0) }
        for (transfer, descriptor) in zip(ids, offer.chunks) {
            do {
                try await service.requestIncomingData(transfer, route: route, descriptor: descriptor)
            } catch BlobError.capacity, BlobError.notBound, BlobError.routeMismatch, BlobError.staleBinding {
                return
            } catch {
                try await store.refuseSnapshot(.malformedOffer, in: [.fetching], id: offer.id)
                return
            }
        }
        let statuses = await service.incoming()
        var files: [URL] = []
        var unavailable = false
        for transfer in ids {
            switch statuses.first(where: { $0.id == transfer })?.state {
            case .awaitingPublish(let chunk, _, _)?:
                files.append(chunk)
            case .rejected?:
                try requireHostBinding(binding, session)
                try await store.refuseSnapshot(.contentRejected, in: [.fetching], id: offer.id)
                return
            case .unavailable?:
                unavailable = true
            default:
                break
            }
        }
        if unavailable {
            let since = snapshotUnavailableSince ?? ContinuousClock.now
            snapshotUnavailableSince = since
            if ContinuousClock.now - since >= unavailableLimit {
                try requireHostBinding(binding, session)
                try await store.refuseSnapshot(.contentUnavailable, in: [.fetching], id: offer.id)
            }
            return
        }
        snapshotUnavailableSince = nil
        guard files.count == ids.count else { return }
        let assembled = try await Task.detached(priority: .utility) {
            try Self.assemble(files, into: file, length: offer.length, hash: offer.contentHash)
        }.value
        try requireHostBinding(binding, session)
        if assembled {
            try await store.advanceSnapshot(id: offer.id, from: .fetching, to: .assembled)
        } else {
            try await store.refuseSnapshot(.contentMismatch, in: [.fetching], id: offer.id)
        }
    }

    /// Writes the chunks in order to `file`; false and no file when the
    /// length or the whole-content hash differs from the offer.
    nonisolated private static func assemble(_ chunks: [URL], into file: URL, length: UInt64, hash: Data) throws -> Bool {
        let staging = file.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: staging)
        FileManager.default.createFile(atPath: staging.path, contents: nil)
        let output = try FileHandle(forWritingTo: staging)
        var whole = SHA256()
        var written: UInt64 = 0
        do {
            for chunk in chunks {
                let input = try FileHandle(forReadingFrom: chunk)
                defer { try? input.close() }
                while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
                    whole.update(data: data)
                    written += UInt64(data.count)
                    try output.write(contentsOf: data)
                }
            }
            try output.synchronize()
            try output.close()
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        guard written == length, Data(whole.finalize()) == hash else {
            try? FileManager.default.removeItem(at: staging)
            return false
        }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: staging, to: file)
        return true
    }

    private func startSnapshotInstall(
        _ offer: HostSnapshotOffer, file: URL, hooks: HostSnapshotHooks, store: HostJournal, binding: HostBinding, session: MLSSession
    ) {
        guard let provider = store.view.completionProvider else { return }
        snapshotRecipientTask = Task { [weak self] in
            defer { self?.snapshotRecipientTask = nil }
            do {
                guard let appliedThrough = try await store.snapshotInstallPosition(id: offer.id), let self else { return }
                try self.requireHostBinding(binding, session)
                let install = HostSnapshotInstall(
                    id: HostSnapshotID(bytes: offer.id), schema: hooks.schema, journalID: store.view.journalID, provider: provider,
                    appliedThrough: JournalPosition.stored(appliedThrough), file: file, length: offer.length,
                    contentHash: offer.contentHash, coverage: offer.coverage
                )
                let outcome = try await hooks.install(install)
                try Task.checkCancellation()
                try self.requireHostBinding(binding, session)
                switch outcome {
                case .installed: try await store.commitSnapshotInstall(id: offer.id, appliedThrough: appliedThrough)
                case .refused: try await store.refuseSnapshot(.hostRefused, in: [.installing], id: offer.id)
                }
                self.snapshotRecipientTask = nil
                self.requestSyncCycle(force: true)
            } catch {
                // An interrupted or failed install is asked again with the same ID.
            }
        }
    }

    private func startSnapshotCompletion(
        _ offer: HostSnapshotOffer, hooks: HostSnapshotHooks, store: HostJournal, binding: HostBinding, session: MLSSession
    ) {
        snapshotRecipientTask = Task { [weak self] in
            defer { self?.snapshotRecipientTask = nil }
            guard let self else { return }
            self.snapshotAdmission.expect([])
            await self.releaseSnapshotContent(offer)
            await hooks.completed(HostSnapshotID(bytes: offer.id))
            do {
                try Task.checkCancellation()
                try self.requireHostBinding(binding, session)
                try await store.advanceSnapshot(id: offer.id, from: .installed, to: .completed)
                self.snapshotCleanedIDs.insert(offer.id)
            } catch {
                // Completion is repeated after a restart; the hook is idempotent.
            }
        }
    }

    /// Drops the fetched chunks and the assembled file of `offer`.
    private func releaseSnapshotContent(_ offer: HostSnapshotOffer) async {
        if let file = snapshotFile("snapshot", offer.id) {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: file.appendingPathExtension("partial"))
        }
        guard let service = await openSnapshotService() else { return }
        let statuses = await service.incoming()
        for (index, descriptor) in offer.chunks.enumerated() {
            guard let transfer = try? Self.transferID(offer.id, index),
                  let status = statuses.first(where: { $0.id == transfer })
            else { continue }
            if case .awaitingPublish = status.state {
                try? await service.confirmPublished(transfer, descriptorDigest: BlobDescriptor.digest(of: descriptor))
            } else {
                try? await service.cancelIncoming(transfer)
            }
        }
    }
}
