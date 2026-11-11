import CryptoKit
import Foundation
import os

// Retention floors (L2c). In a compacting group the roster's lowest
// fingerprint proposes a floor at its export cut with a checkpoint; every
// other current member accepts by its own authenticated vote only after it
// holds the checkpoint durably and its host attests its cut. Each member
// commits from the same votes and then removes the records at or below the
// floor. Joiners adopt a floor every other current member corroborates.

/// Checkpoint chunk files by content hash, for re-upload by the snapshot
/// service off the main actor.
final class HostCheckpointFiles: Sendable {
    private let files = OSAllocatedUnfairLock<[Data: URL]>(initialState: [:])

    func register(_ hash: Data, _ url: URL) {
        files.withLock { $0[hash] = url }
    }

    func url(for hash: Data) -> URL? {
        guard let url = files.withLock({ $0[hash] }), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}

/// One open round on this member, in memory only: a restart, a roster
/// change or a newer round drops it.
struct HostRetentionRound {
    let proposal: HostRetentionProposal
    let digest: Data
    let proposer: Data
    var votes: [Data: HostRetentionVote] = [:]
    var voted = false
    let opened = ContinuousClock.now
}

extension SyncEngine {
    /// Registers the app's retention host, or removes it with nil. Without a
    /// host this member declines every floor. A compacting group also needs
    /// a snapshot host of the profile's schema before pairing.
    public func registerRetentionHost(_ hooks: HostRetentionHooks?) {
        retentionHooks = hooks
        requestSyncCycle(force: true)
    }

    /// Starts a round when this member coordinates the current roster. The
    /// floor commits only once every current member accepted it.
    public func proposeRetentionFloor() async throws -> HostRetentionProposalOutcome {
        guard groupProfile.schema.allowsRetention else { return .notCompacting }
        guard let session, isPaired else { throw HostJournalError.fenced }
        return try await startRetentionProposal(session: session)
    }
}

extension SyncEngine {
    /// A compacting group's member can only take part, and a joiner can only
    /// bootstrap, with both hosts registered for the profile's schema.
    var retentionParticipationReady: Bool {
        guard let required = groupProfile.schema.retentionSnapshotSchema else { return true }
        return snapshotHooks?.schema.name == required && retentionHooks != nil
    }

    // MARK: - Artifacts

    private func checkpointsDirectory(journal: Data) -> URL? {
        snapshotDirectory?.appendingPathComponent("checkpoints", isDirectory: true)
            .appendingPathComponent(Self.hex(journal), isDirectory: true)
    }

    private func checkpointDirectory(journal: Data, checkpoint: Data) -> URL? {
        checkpointsDirectory(journal: journal)?.appendingPathComponent(Self.hex(checkpoint), isDirectory: true)
    }

    func checkpointDirectoryForJoiner(journal: Data, checkpoint: Data) -> URL? {
        checkpointDirectory(journal: journal, checkpoint: checkpoint)
    }

    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// The chunk files of a stored checkpoint in order, or nil if any is absent.
    func checkpointChunks(journal: Data, offer: HostSnapshotOffer) -> [URL]? {
        guard let directory = checkpointDirectory(journal: journal, checkpoint: offer.id) else { return nil }
        let urls = offer.chunks.indices.map { directory.appendingPathComponent("chunk-\($0)") }
        guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
        return urls
    }

    nonisolated static func checkpointMatches(_ chunks: [URL], offer: HostSnapshotOffer) throws -> Bool {
        guard offer.isWellFormed, chunks.count == offer.chunks.count else { return false }
        var whole = SHA256()
        var length: UInt64 = 0
        for (chunk, descriptor) in zip(chunks, offer.chunks) {
            guard let info = try? BlobDataDescriptorInfo(descriptor: descriptor),
                  info.plaintextLength <= UInt64(HostSnapshotBounds.chunkBytes)
            else { return false }
            let values = try chunk.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size >= 0,
                  UInt64(size) == info.plaintextLength
            else { return false }
            let data = try Data(contentsOf: chunk)
            guard UInt64(data.count) == info.plaintextLength,
                  Data(SHA256.hash(data: data)) == info.contentHash
            else { return false }
            whole.update(data: data)
            length += UInt64(data.count)
        }
        return length == offer.length && Data(whole.finalize()) == offer.contentHash
    }

    /// Copies verified chunk files into the journal's checkpoint directory,
    /// checks every chunk and the whole content against the offer, and syncs
    /// the files before returning true.
    nonisolated static func storeCheckpoint(_ chunks: [URL], offer: HostSnapshotOffer, into directory: URL) throws -> Bool {
        guard try checkpointMatches(chunks, offer: offer) else { return false }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var whole = SHA256()
        var length: UInt64 = 0
        for (index, (chunk, descriptor)) in zip(chunks, offer.chunks).enumerated() {
            let data = try Data(contentsOf: chunk)
            guard let info = try? BlobDataDescriptorInfo(descriptor: descriptor), Data(SHA256.hash(data: data)) == info.contentHash else {
                return false
            }
            whole.update(data: data)
            length += UInt64(data.count)
            let target = directory.appendingPathComponent("chunk-\(index)")
            if chunk.standardizedFileURL != target.standardizedFileURL {
                try data.write(to: target, options: .atomic)
            }
            let handle = try FileHandle(forWritingTo: target)
            try handle.synchronize()
            try handle.close()
        }
        guard chunks.count == offer.chunks.count, length == offer.length, Data(whole.finalize()) == offer.contentHash else {
            return false
        }
        try ReplicaCanonicalJSON.encode(offer).write(to: directory.appendingPathComponent("offer.json"), options: .atomic)
        return true
    }

    /// Keeps the checkpoint directories of `keep` for `journal`, removing the rest.
    private func pruneCheckpointArtifacts(journal: Data, keep: Set<Data>) {
        guard let parent = checkpointsDirectory(journal: journal),
              let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path)
        else { return }
        let kept = Set(keep.map(Self.hex))
        for name in names where !kept.contains(name) {
            try? FileManager.default.removeItem(at: parent.appendingPathComponent(name))
        }
    }

    /// Removes every checkpoint of a discarded journal.
    func discardCheckpointArtifacts(journal: Data) {
        guard let parent = checkpointsDirectory(journal: journal) else { return }
        try? FileManager.default.removeItem(at: parent)
    }

    /// Registers the committed checkpoint's chunks for re-upload from this member.
    func registerCheckpointAvailability(_ service: BlobTransferService, route: BlobRoute) async {
        guard let store = hostAdapter?.store, let retention = store.view.retention, retention.floorApplied,
              let chunks = checkpointChunks(journal: store.view.journalID, offer: retention.checkpoint)
        else { return }
        for (descriptor, url) in zip(retention.checkpoint.chunks, chunks) {
            guard let info = try? BlobDataDescriptorInfo(descriptor: descriptor) else { continue }
            checkpointFiles.register(info.contentHash, url)
            try? await service.registerAvailableData(route: route, descriptor: descriptor)
        }
    }

    // MARK: - Proposals

    func startRetentionProposal(session: MLSSession) async throws -> HostRetentionProposalOutcome {
        guard retentionRound == nil, retentionTask == nil else { return .roundOpen }
        let me = try await session.fingerprint()
        let roster = try await session.members().map(\.fingerprint).sorted { $0.lexicographicallyPrecedes($1) }
        try requireCurrent(session)
        guard roster.first == me, roster.count > 1 else { return .notCoordinator }
        guard retentionParticipationReady, let hooks = snapshotHooks, let attest = retentionHooks,
              let store = hostAdapter?.store
        else { return .declined(.unsupported) }
        let binding = try hostBinding(session)
        let cut = try await store.snapshotExportCut()
        try requireHostBinding(binding, session)
        if let decline = try await store.retentionDecline(cut.anchors) {
            return .declined(HostRetentionDecline(decline))
        }
        retentionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.retentionTask = nil }
            do {
                guard let proposal = try await self.produceCheckpoint(roster: roster, hooks: hooks, attest: attest, session: session) else {
                    return
                }
                try self.requireHostBinding(binding, session)
                try await self.send(plaintext: HostJournalMessage.retentionProposal(proposal).encoded(), session: session)
                self.retentionRound = HostRetentionRound(proposal: proposal, digest: proposal.digest, proposer: me, voted: true)
                self.requestSyncCycle(force: true)
            } catch {
                // The round never opened; a later proposal starts again.
            }
        }
        return .proposed
    }

    /// Exports at a fresh cut into a durable checkpoint, seals and uploads its
    /// chunks, registers them for re-upload and returns the proposal; nil when
    /// this member's own conditions no longer hold.
    private func produceCheckpoint(
        roster: [Data], hooks: HostSnapshotHooks, attest: HostRetentionHooks, session: MLSSession
    ) async throws -> HostRetentionProposal? {
        guard let snapshotDirectory, let store = hostAdapter?.store else { return nil }
        let binding = try hostBinding(session)
        let id = HostJournalStore.randomBytes(16)
        let journal = store.view.journalID
        guard let directory = checkpointDirectory(journal: journal, checkpoint: id) else { return nil }
        pruneCheckpointArtifacts(journal: journal, keep: Set([store.view.retention?.checkpoint.id].compactMap { $0 }))
        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        let destination = snapshotDirectory.appendingPathComponent("checkpoint-export-\(Self.hex(id))")
        defer { try? FileManager.default.removeItem(at: destination) }
        let cut = try await store.snapshotExportCut()
        try requireHostBinding(binding, session)
        guard try await attests(attest, cut: cut, store: store) else { return nil }
        let outcome = try await hooks.export(HostSnapshotCut(
            id: HostSnapshotID(bytes: id), journalID: journal, appliedThrough: JournalPosition.stored(cut.appliedThrough),
            capturedThrough: cut.capturedThrough, destination: destination
        ))
        try Task.checkCancellation()
        try requireHostBinding(binding, session)
        if case .tooLarge = outcome { throw HostSnapshotExportRefused(reason: .tooLarge) }
        guard case .exported(let echo) = outcome, echo.appliedThrough?.rawValue ?? 0 == cut.appliedThrough,
              echo.capturedThrough == cut.capturedThrough
        else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let packed = try await Task.detached(priority: .utility) {
            try Self.pack(destination, id: id, into: directory)
        }.value
        let chunkFiles = packed.chunks.indices.map { directory.appendingPathComponent("chunk-\($0)") }
        for (chunk, target) in zip(packed.chunks, chunkFiles) {
            try FileManager.default.moveItem(at: chunk.url, to: target)
        }
        let descriptors = try await sealSnapshot(
            id: id, packed: HostSnapshotPacked(length: packed.length, contentHash: packed.contentHash,
                                               chunks: zip(chunkFiles, packed.chunks).map { ($0, $1.hash) }),
            session: session
        )
        let checkpoint = HostSnapshotOffer(
            id: id, schema: hooks.schema.name, anchors: cut.anchors, length: packed.length, contentHash: packed.contentHash,
            chunks: descriptors
        )
        let stored = try await Task.detached(priority: .utility) {
            try Self.storeCheckpoint(chunkFiles, offer: checkpoint, into: directory)
        }.value
        guard stored else { return nil }
        if let service = await openSnapshotService() {
            for (index, descriptor) in descriptors.enumerated() {
                if let transfer = try? BlobTransferID(bytes: HostSnapshotOffer.transferID(snapshot: id, index: index)) {
                    try? await service.confirmHandoff(transfer, descriptorDigest: BlobDescriptor.digest(of: descriptor))
                }
            }
            if let route = await bindSnapshotService(session) {
                for (descriptor, url) in zip(descriptors, chunkFiles) {
                    guard let info = try? BlobDataDescriptorInfo(descriptor: descriptor) else { continue }
                    checkpointFiles.register(info.contentHash, url)
                    try? await service.registerAvailableData(route: route, descriptor: descriptor)
                }
            }
        }
        try requireHostBinding(binding, session)
        let epoch = try await session.epoch()
        let current = try await session.members().map(\.fingerprint).sorted { $0.lexicographicallyPrecedes($1) }
        try requireCurrent(session)
        guard current == roster else { return nil }
        var proposal = HostRetentionProposal(round: HostJournalStore.randomBytes(16), epoch: epoch, roster: roster,
                                             anchors: cut.anchors, checkpoint: checkpoint)
        if groupProfile.schema.allowsReclamation, attest.reclaim != nil, !retentionReclaimDeclined,
           let declared = store.view.incarnation?.storeID, store.view.isAncestryResolved {
            proposal.reclaim = true
            proposal.store = declared
        }
        return proposal
    }

    /// The host's own durable cut equals the journal's and nothing waits in
    /// its outbox.
    private func attests(_ hooks: HostRetentionHooks, cut: HostSnapshotExportCut, store: HostJournal) async throws -> Bool {
        let attestation = try await hooks.attest(HostRetentionRequest(
            journalID: cut.journalID, appliedThrough: JournalPosition.stored(cut.appliedThrough),
            capturedThrough: cut.capturedThrough, floor: Dictionary(uniqueKeysWithValues: cut.anchors.map { ($0.origin, $0.sequence) })
        ))
        return attestation.outboxEmpty && attestation.keepsDeletionMetadata
            && attestation.appliedThrough?.rawValue ?? 0 == store.view.appliedThrough
            && attestation.capturedThrough == store.view.capturedThrough
    }

    // MARK: - Receipt (called while draining, with authenticated senders)

    func receiveRetention(_ message: HostJournalMessage, sender: Data, roster: Set<Data>, epoch: UInt64, me: Data) {
        guard groupProfile.schema.allowsRetention, roster.contains(sender) else { return }
        switch message.kind {
        case .retentionProposal:
            guard let proposal = message.retention,
                  sender == roster.min(by: { $0.lexicographicallyPrecedes($1) }),
                  proposal.roster == roster.sorted(by: { $0.lexicographicallyPrecedes($1) }), proposal.epoch == epoch,
                  proposal.roster.contains(me)
            else { return }
            let digest = proposal.digest
            guard retentionRound?.digest != digest else { return }
            retentionRound = HostRetentionRound(proposal: proposal, digest: digest, proposer: sender)
        case .retentionVote:
            guard let vote = message.vote, var round = retentionRound, vote.round == round.proposal.round,
                  vote.proposal == round.digest, round.proposal.roster.contains(sender), sender != round.proposer
            else { return }
            round.votes[sender] = vote
            retentionRound = round
        case .retentionState:
            guard let corroboration = message.corroboration, corroboration.member == me else { return }
            retentionCorroborations[sender] = corroboration
        default:
            return
        }
    }

    // MARK: - Cycle

    func advanceRetention(session: MLSSession) async throws {
        guard groupProfile.schema.allowsRetention, let store = hostAdapter?.store, hostWorkAllowed else { return }
        let binding = try hostBinding(session)
        let me = try await session.fingerprint()
        let roster = try await session.members().map(\.fingerprint).sorted { $0.lexicographicallyPrecedes($1) }
        try requireHostBinding(binding, session)

        try await advanceRetentionJoin(store: store, roster: roster, me: me, binding: binding, session: session)
        try await sendCorroborations(store: store, binding: binding, session: session)
        if let round = retentionRound {
            try await advanceRound(round, store: store, roster: roster, me: me, binding: binding, session: session)
        }
        if let retention = store.view.retention, retention.floorApplied {
            guard let chunks = checkpointChunks(journal: store.view.journalID, offer: retention.checkpoint),
                  try await Task.detached(priority: .utility, operation: {
                      try Self.checkpointMatches(chunks, offer: retention.checkpoint)
                  }).value
            else { throw HostJournalError.repairRequired(.journalCorrupt) }
            try requireHostBinding(binding, session)
            for _ in 0..<8 {
                guard try await store.pruneBelowFloor() > 0 else { break }
                try requireHostBinding(binding, session)
            }
            if groupProfile.schema.allowsReclamation {
                for _ in 0..<8 {
                    guard try await store.releaseFinalizedMappings() > 0 else { break }
                    try requireHostBinding(binding, session)
                }
                try await applyReclamation(store: store, binding: binding, session: session)
            }
        }
        if retentionRound == nil, retentionTask == nil, roster.first == me, roster.count > 1,
           store.view.retainedBytes >= HostRetentionBounds.automaticBytes {
            _ = try await startRetentionProposal(session: session)
        }
    }

    private func advanceRound(
        _ round: HostRetentionRound, store: HostJournal, roster: [Data], me: Data, binding: HostBinding, session: MLSSession
    ) async throws {
        let epoch = try await session.epoch()
        try requireHostBinding(binding, session)
        guard round.proposal.roster == roster, round.proposal.epoch == epoch,
              ContinuousClock.now - round.opened < HostRetentionBounds.roundTimeout
        else {
            dropRetentionRound(store: store)
            return
        }
        if round.votes.values.contains(where: { !$0.accept }) {
            if round.proposal.reclaim == true, round.votes.values.contains(where: { $0.reason == .unsupported }) {
                retentionReclaimDeclined = true
            }
            dropRetentionRound(store: store)
            return
        }
        if !round.voted, retentionTask == nil {
            startRetentionVote(round, me: me, session: session)
            return
        }
        let voters = roster.filter { $0 != round.proposer }
        guard voters.allSatisfy({ round.votes[$0]?.accept == true }) else { return }
        guard let chunks = checkpointChunks(journal: store.view.journalID, offer: round.proposal.checkpoint),
              try await Task.detached(priority: .utility, operation: {
                  try Self.checkpointMatches(chunks, offer: round.proposal.checkpoint)
              }).value
        else {
            dropRetentionRound(store: store)
            return
        }
        try requireHostBinding(binding, session)
        let latestEpoch = try await session.epoch()
        let latestRoster = try await session.members().map(\.fingerprint).sorted { $0.lexicographicallyPrecedes($1) }
        try requireHostBinding(binding, session)
        guard latestEpoch == round.proposal.epoch, latestRoster == round.proposal.roster else {
            dropRetentionRound(store: store)
            return
        }
        guard let current = retentionRound, current.digest == round.digest, current.voted,
              voters.allSatisfy({ current.votes[$0]?.accept == true })
        else { return }
        var stores: [Data]?
        if round.proposal.reclaim == true {
            let scope = [round.proposal.store] + voters.map { current.votes[$0]?.store }
            guard scope.allSatisfy({ $0?.count == 16 }) else {
                dropRetentionRound(store: store)
                return
            }
            stores = scope.compactMap { $0 }
        }
        let committed = try await store.commitRetentionFloor(
            round: round.proposal.round, proposal: round.digest, checkpoint: round.proposal.checkpoint, reclaimStores: stores
        )
        try requireHostBinding(binding, session)
        retentionRound = nil
        if committed {
            pruneCheckpointArtifacts(journal: store.view.journalID, keep: [round.proposal.checkpoint.id])
            if let service = await openSnapshotService(), let route = await bindSnapshotService(session) {
                await registerCheckpointAvailability(service, route: route)
            }
        }
    }

    private func dropRetentionRound(store: HostJournal) {
        if let round = retentionRound, round.proposal.checkpoint.id != store.view.retention?.checkpoint.id {
            pruneCheckpointArtifacts(journal: store.view.journalID, keep: Set([store.view.retention?.checkpoint.id].compactMap { $0 }))
        }
        retentionRound = nil
    }

    /// Fetches and stores the checkpoint, checks the journal and the host,
    /// then sends this member's vote.
    private func startRetentionVote(_ round: HostRetentionRound, me: Data, session: MLSSession) {
        retentionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.retentionTask = nil }
            let reason: HostRetentionDeclineReason?
            do {
                reason = try await self.retentionDeclineReason(round.proposal, session: session)
            } catch {
                return
            }
            guard var current = self.retentionRound, current.digest == round.digest, !current.voted else { return }
            var vote = HostRetentionVote(round: round.proposal.round, proposal: round.digest, accept: reason == nil)
            vote.reason = reason
            vote.store = self.hostAdapter?.store?.view.incarnation?.storeID
            do {
                try await self.send(plaintext: HostJournalMessage.retentionVote(vote).encoded(), session: session)
            } catch {
                return
            }
            current.voted = true
            current.votes[me] = vote
            self.retentionRound = current
            self.requestSyncCycle(force: true)
        }
    }

    private func retentionDeclineReason(_ proposal: HostRetentionProposal, session: MLSSession) async throws -> HostRetentionDeclineReason? {
        guard retentionParticipationReady, let attest = retentionHooks, let store = hostAdapter?.store,
              proposal.checkpoint.schema == groupProfile.schema.retentionSnapshotSchema
        else { return .unsupported }
        let binding = try hostBinding(session)
        if groupProfile.schema.allowsReclamation, !store.view.isAncestryResolved { return .ancestryUnresolved }
        if proposal.reclaim == true, attest.reclaim == nil || store.view.incarnation?.storeID == nil { return .unsupported }
        if let decline = try await store.retentionDecline(proposal.anchors) { return decline }
        if let failure = try await fetchCheckpoint(proposal.checkpoint, store: store, session: session) { return failure }
        try requireHostBinding(binding, session)
        let cut = try await store.snapshotExportCut()
        guard try await attests(attest, cut: cut, store: store) else { return .hostNotAtCut }
        try requireHostBinding(binding, session)
        return try await store.retentionDecline(proposal.anchors)
    }

    /// Fetches every chunk of `offer`, stores the verified checkpoint durably
    /// and registers it for re-upload; nil on success.
    private func fetchCheckpoint(
        _ offer: HostSnapshotOffer, store: HostJournal, session: MLSSession
    ) async throws -> HostRetentionDeclineReason? {
        let journal = store.view.journalID
        guard let directory = checkpointDirectory(journal: journal, checkpoint: offer.id) else { return .checkpointUnavailable }
        if let chunks = checkpointChunks(journal: journal, offer: offer) {
            let matches = try await Task.detached(priority: .utility) {
                try Self.checkpointMatches(chunks, offer: offer)
            }.value
            return matches ? nil : .checkpointMismatch
        }
        guard let service = await openSnapshotService(), let route = await bindSnapshotService(session) else {
            return .checkpointUnavailable
        }
        let digests = offer.chunks.map(BlobDescriptor.digest(of:))
        snapshotAdmission.expect(Set(digests))
        let ids = try offer.chunks.indices.map { try BlobTransferID(bytes: HostSnapshotOffer.transferID(snapshot: offer.id, index: $0)) }
        for (transfer, descriptor) in zip(ids, offer.chunks) {
            do {
                try await service.requestIncomingData(transfer, route: route, descriptor: descriptor)
            } catch {
                return .checkpointUnavailable
            }
        }
        var updates = service.updates().makeAsyncIterator()
        let deadline = ContinuousClock.now.advanced(by: .seconds(300))
        var files: [URL] = []
        while files.count < ids.count {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { return .checkpointUnavailable }
            let statuses = await service.incoming()
            files = []
            for transfer in ids {
                switch statuses.first(where: { $0.id == transfer })?.state {
                case .awaitingPublish(let file, _, _)?: files.append(file)
                case .rejected?: return .checkpointMismatch
                default: break
                }
            }
            if files.count < ids.count {
                guard await updates.next() != nil else { throw CancellationError() }
            }
        }
        let stored = try await Task.detached(priority: .utility) { [files] in
            try Self.storeCheckpoint(files, offer: offer, into: directory)
        }.value
        for (transfer, digest) in zip(ids, digests) {
            try? await service.confirmPublished(transfer, descriptorDigest: digest)
        }
        snapshotAdmission.expect([])
        guard stored, let chunks = checkpointChunks(journal: journal, offer: offer) else { return .checkpointMismatch }
        for (descriptor, url) in zip(offer.chunks, chunks) {
            guard let info = try? BlobDataDescriptorInfo(descriptor: descriptor) else { continue }
            checkpointFiles.register(info.contentHash, url)
            try? await service.registerAvailableData(route: route, descriptor: descriptor)
        }
        return nil
    }

    // MARK: - Joiners

    /// A joiner that asked for a snapshot is told this member's committed floor.
    func noteCorroborationRecipient(_ member: Data) {
        guard groupProfile.schema.allowsRetention, hostAdapter?.store?.view.retention?.floorApplied == true else { return }
        retentionCorroborationRecipients.insert(member)
    }

    private func sendCorroborations(store: HostJournal, binding: HostBinding, session: MLSSession) async throws {
        guard let retention = store.view.retention, retention.floorApplied, !retentionCorroborationRecipients.isEmpty else { return }
        for member in retentionCorroborationRecipients.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            var corroboration = HostRetentionCorroboration(
                member: member, round: retention.round, proposal: retention.proposal, anchors: retention.anchors,
                contentHash: retention.checkpoint.contentHash
            )
            if let reclamation = store.view.reclamation {
                corroboration.reclaimedThrough = HostVectorEntry.entries(reclamation.frontier)
                corroboration.stores = reclamation.stores
            }
            try await send(plaintext: HostJournalMessage.retentionState(corroboration).encoded(), session: session)
            try requireHostBinding(binding, session)
            retentionCorroborationRecipients.remove(member)
        }
    }

    /// Adopts an offered floor once every other current member reported
    /// exactly it; refuses the offer when one reports another floor.
    private func advanceRetentionJoin(
        store: HostJournal, roster: [Data], me: Data, binding: HostBinding, session: MLSSession
    ) async throws {
        guard store.view.retention == nil, let bootstrap = store.view.bootstrap, bootstrap.phase == .offered,
              let offer = bootstrap.offer, let floor = offer.floor
        else { return }
        let others = roster.filter { $0 != me }
        guard !others.isEmpty else { return }
        var round: Data?
        var reclaimed: ([HostVectorEntry]?, [Data]?)?
        for member in others {
            guard let corroboration = retentionCorroborations[member] else { return }
            guard corroboration.proposal == floor, corroboration.anchors == offer.anchors,
                  corroboration.contentHash == offer.contentHash, round == nil || round == corroboration.round,
                  reclaimed == nil || (reclaimed?.0 == corroboration.reclaimedThrough && reclaimed?.1 == corroboration.stores)
            else {
                try await store.refuseSnapshot(.corroborationMismatch, in: [.offered], id: offer.id)
                try requireHostBinding(binding, session)
                return
            }
            round = corroboration.round
            reclaimed = (corroboration.reclaimedThrough, corroboration.stores)
        }
        guard let round else { return }
        var checkpoint = offer
        checkpoint.floor = nil
        var reclamation: HostJournalReclamationState?
        if let frontier = reclaimed?.0, let stores = reclaimed?.1 {
            reclamation = HostJournalReclamationState(frontier: HostVectorEntry.vector(frontier), stores: stores, applied: false)
        }
        try await store.adoptRetentionFloor(round: round, proposal: floor, checkpoint: checkpoint, reclamation: reclamation)
        try requireHostBinding(binding, session)
        while try await store.promote() > 0 {
            try requireHostBinding(binding, session)
        }
    }

    /// A provider with a committed floor offers that floor's checkpoint,
    /// marked with the floor, instead of exporting.
    func committedCheckpointOffer() -> HostSnapshotOffer? {
        guard let store = hostAdapter?.store, let retention = store.view.retention, retention.floorApplied,
              checkpointChunks(journal: store.view.journalID, offer: retention.checkpoint) != nil
        else { return nil }
        var offer = retention.checkpoint
        offer.floor = retention.proposal
        return offer
    }
}

extension SyncEngine {
    /// Asks the host to reclaim through a committed frontier until it
    /// returns, then records that it did. Only a member that applied the
    /// floor and resolved its ancestry reclaims.
    func applyReclamation(store: HostJournal, binding: HostBinding, session: MLSSession) async throws {
        guard let reclamation = store.view.reclamation, !reclamation.applied, store.view.retention?.floorApplied == true,
              store.view.isAncestryResolved, let reclaim = retentionHooks?.reclaim, retentionTask == nil
        else { return }
        let request = HostReclamation(reclamation)
        retentionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.retentionTask = nil }
            do {
                try await reclaim(request)
                try Task.checkCancellation()
                try self.requireHostBinding(binding, session)
                try await store.markReclamationApplied(frontier: reclamation.frontier)
                self.requestSyncCycle(force: true)
            } catch {
                // Asked again in a later cycle; the hook is idempotent.
            }
        }
    }
}
