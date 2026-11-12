import Foundation
import XCTest
@testable import GotSync

@MainActor
final class HostJournalReaderTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = try JournalFixture.directory()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func journal(_ payload: String) throws -> HostJournalStore {
        let store = try HostJournalStore.create(in: directory, group: JournalFixture.group)
        _ = try store.resume(store.enroll())
        _ = try store.submit([HostJournalMutation(id: JournalFixture.mutationID(1), payload: Data(payload.utf8))], capturedThrough: 1)
        return store
    }

    func testReadsActiveAndRetiredJournalsWithoutChangingFiles() throws {
        let active = try journal("active")
        let retired = try journal("retired")
        try retired.retire(.unlink, heldInbox: [])
        let reader = try HostJournalReader(storageDirectory: directory)
        let before = try [active, retired].map { try JournalFixture.fileHash($0.url) }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        let inventory = try reader.journals()
        XCTAssertEqual(Set(inventory.map(\.journalID)), [active.view.journalID, retired.view.journalID])
        XCTAssertNil(inventory.first { $0.journalID == active.view.journalID }?.retirement)
        XCTAssertEqual(inventory.first { $0.journalID == retired.view.journalID }?.retirement, .unlink)
        for (store, text) in [(active, "active"), (retired, "retired")] {
            let page = try reader.export(store.view.journalID, after: nil, limit: 1)
            guard case .own(_, _, _, let payload)? = page.items.first else { return XCTFail("missing owned record") }
            XCTAssertEqual(payload, Data(text.utf8))
        }
        XCTAssertEqual(try [active, retired].map { try JournalFixture.fileHash($0.url) }, before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), names)
    }

    func testMissingAndUnreadableStorageNeverLooksEmpty() throws {
        let missing = directory.appendingPathComponent("missing")
        let absent = try HostJournalReader(storageDirectory: missing)
        XCTAssertThrowsError(try absent.journals())
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let reader = try HostJournalReader(storageDirectory: directory)
        XCTAssertEqual(try reader.journals(), [])
        let file = HostJournalStore.fileURL(in: directory, journalID: Data(repeating: 7, count: 16))
        try Data("unreadable".utf8).write(to: file)
        let before = try Data(contentsOf: file)
        XCTAssertThrowsError(try reader.journals()) {
            XCTAssertEqual($0 as? HostJournalError, .repairRequired(.journalUnreadable))
        }
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertThrowsError(try reader.export(Data(), after: nil, limit: 1)) {
            XCTAssertEqual($0 as? HostJournalError, .invalidArgument)
        }
    }

    func testCursorsStillRefuseConcurrentJournalChanges() throws {
        let store = try journal("first")
        let reader = try HostJournalReader(storageDirectory: directory)
        let cursor = try XCTUnwrap(reader.export(store.view.journalID, after: nil, limit: 1).next)
        _ = try store.submit([HostJournalMutation(id: JournalFixture.mutationID(2), payload: Data("second".utf8))], capturedThrough: 2)
        XCTAssertThrowsError(try reader.export(store.view.journalID, after: cursor, limit: 1)) {
            XCTAssertEqual($0 as? HostJournalError, .exportRevisionChanged)
        }
    }

    func testCompactedExportKeepsItsCheckpointAndReportsMissingFiles() throws {
        let store = try journal("one")
        let record = try XCTUnwrap(store.ownRecords(after: 0, maxBytes: 1 << 20, maxCount: 1).first)
        let offer = HostSnapshotOffer(
            id: Data(repeating: 8, count: 16), schema: "test.state/1",
            anchors: [HostSnapshotAnchor(origin: record.origin, sequence: 1, digest: record.digest)], length: 3,
            contentHash: Data(repeating: 9, count: 32), chunks: [Data(repeating: 1, count: 152)]
        )
        XCTAssertTrue(try store.commitRetentionFloor(round: Data(repeating: 2, count: 16), proposal: Data(repeating: 3, count: 32), checkpoint: offer))
        XCTAssertEqual(try store.pruneBelowFloor(), 1)
        let parent = directory.appendingPathComponent(SyncEngine.snapshotDirectoryName)
            .appendingPathComponent("checkpoints").appendingPathComponent(hex(store.view.journalID)).appendingPathComponent(hex(offer.id))
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let chunk = parent.appendingPathComponent("chunk-0")
        try Data([1, 2, 3]).write(to: chunk)
        let reader = try HostJournalReader(storageDirectory: directory)
        guard case .checkpoint(let floor, let length, let hash, let files)? = try reader.export(store.view.journalID, after: nil, limit: 1).items.first else {
            return XCTFail("missing compacted checkpoint")
        }
        XCTAssertEqual(floor, [record.origin: 1])
        XCTAssertEqual(length, 3)
        XCTAssertEqual(hash, offer.contentHash)
        XCTAssertEqual(files, [chunk])
        try FileManager.default.removeItem(at: chunk)
        guard case .checkpoint(_, _, _, let absent)? = try reader.export(store.view.journalID, after: nil, limit: 1).items.first else {
            return XCTFail("missing unavailable checkpoint")
        }
        XCTAssertTrue(absent.isEmpty)
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
