import Foundation

/// One journal discovered without opening an engine. An active journal can still have
/// associated MLS-owned inbox data that this reader cannot inspect.
public struct HostJournalInfo: Equatable, Sendable {
    public let journalID: Data
    public let group: Data
    public let retirement: HostRetirementReason?
}

/// Read-only journal inspection without an engine, secret store or network activity.
/// Cleanup must hold the host's reference fence and either inspect every other owner or
/// require all journals retired after a completed handoff. Stopping a writer alone is insufficient.
@MainActor
public struct HostJournalReader {
    private let directory: URL

    /// The same storage directory supplied to `SyncConfiguration`. Nothing is created.
    public init(storageDirectory: URL) throws {
        guard storageDirectory.isFileURL else { throw HostJournalError.invalidArgument }
        directory = storageDirectory
    }

    /// Every active and retired journal. Missing, unreadable and incomplete storage throws;
    /// none is interpreted as an empty inventory.
    public func journals() throws -> [HostJournalInfo] {
        do {
            var identifiers = Set<Data>()
            var journals: [HostJournalInfo] = []
            for listing in try HostJournalFiles.discover(in: directory) {
                guard case .journal(_, let view) = listing else {
                    throw HostJournalError.repairRequired(.journalUnreadable)
                }
                guard identifiers.insert(view.journalID).inserted else {
                    throw HostJournalError.repairRequired(.journalCorrupt)
                }
                journals.append(HostJournalInfo(journalID: view.journalID, group: view.group,
                                                retirement: view.retirement.map(HostRetirementReason.init)))
            }
            return journals.sorted { $0.journalID.lexicographicallyPrecedes($1.journalID) }
        } catch {
            throw HostJournalError.surfaced(error)
        }
    }

    /// A revision-bound page with every owned record class. A compacted journal starts with
    /// its checkpoint. Verify checkpoint length and hash before interpreting its files;
    /// absent chunks are reported as an empty file list, never an empty checkpoint.
    public func export(_ journalID: Data, after cursor: HostArchiveCursor?, limit: Int) throws -> HostArchivePage {
        guard journalID.count == 16 else { throw HostJournalError.invalidArgument }
        do {
            let page = try HostJournalFiles.export(
                HostJournalStore.fileURL(in: directory, journalID: journalID), after: cursor?.value, limit: limit
            )
            let items = try page.items.map { item -> HostArchiveItem in
                guard case .checkpoint(let offer) = item else { return try HostArchiveItem(item) }
                let parent = directory.appendingPathComponent(SyncEngine.snapshotDirectoryName, isDirectory: true)
                    .appendingPathComponent("checkpoints", isDirectory: true)
                    .appendingPathComponent(Self.hex(journalID), isDirectory: true)
                    .appendingPathComponent(Self.hex(offer.id), isDirectory: true)
                let files = offer.chunks.indices.map { parent.appendingPathComponent("chunk-\($0)") }
                return .checkpoint(
                    floor: offer.coverage, length: offer.length, contentHash: offer.contentHash,
                    chunks: files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) } ? files : []
                )
            }
            return HostArchivePage(items: items, next: page.next.map { HostArchiveCursor(value: $0) })
        } catch {
            throw HostJournalError.surfaced(error)
        }
    }

    private static func hex(_ bytes: Data) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
