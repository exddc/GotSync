import Foundation

@_spi(HostJournalPreview) extension SyncEngine {
    /// The composed host view; nil for task profiles.
    public var hostJournalView: HostJournalView? {
        hostView.map(HostJournalView.init)
    }

    /// Retired journals in this engine's directory, read on demand.
    /// Available while unlinked.
    public func hostJournalArchives() throws -> [HostJournalArchive] {
        do {
            return try hostJournalListings().compactMap(HostJournalArchive.init)
        } catch {
            throw HostJournalError.surfaced(error)
        }
    }

    /// One page of a journal's records, own first, then remote, pending,
    /// quarantined and held inbox, with exact bytes. A compacted journal's
    /// first page starts with its checkpoint. Read-only; nothing is sent. The
    /// cursor is bound to the journal and its committed revision.
    public func exportHostJournal(_ journalID: Data, after cursor: HostArchiveCursor?, limit: Int) throws -> HostArchivePage {
        guard let directory = hostJournalDirectory, journalID.count == 16 else {
            throw HostJournalError.invalidArgument
        }
        do {
            let page = try exportHostJournal(
                HostJournalStore.fileURL(in: directory, journalID: journalID), after: cursor?.value, limit: limit
            )
            let items = try page.items.map { item -> HostArchiveItem in
                if case .checkpoint(let offer) = item {
                    return .checkpoint(floor: offer.coverage, length: offer.length, contentHash: offer.contentHash,
                                       chunks: checkpointChunks(journal: journalID, offer: offer) ?? [])
                }
                return try HostArchiveItem(item)
            }
            return HostArchivePage(items: items, next: page.next.map { HostArchiveCursor(value: $0) })
        } catch {
            throw HostJournalError.surfaced(error)
        }
    }

    /// Deletes one retired journal, only when `confirmingJournalID` repeats
    /// its ID. The only destructive host call.
    public func discardRetiredHostJournal(_ journalID: Data, confirmingJournalID: Data) async throws {
        do {
            try await discardRetiredHostJournal(journalID, confirming: confirmingJournalID)
            discardCheckpointArtifacts(journal: journalID)
        } catch {
            throw HostJournalError.surfaced(error)
        }
    }
}
