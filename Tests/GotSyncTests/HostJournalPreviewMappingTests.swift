import Foundation
@_spi(HostJournalPreview) @testable import GotSync
import XCTest

final class HostJournalPreviewMappingTests: XCTestCase {
    private let secret = "SECRET /private/var/journal.sqlite near \"meta\""
    private let origin = Data(repeating: 7, count: 16)
    private let mutation = Data(repeating: 9, count: 16)

    func testEveryStoreErrorMapsToATypedPublicCase() {
        let table: [(JournalStoreError, HostJournalError)] = [
            (.storage(code: 13, message: secret), .storageUnavailable),
            (.valueOutOfRange, .invalidArgument),
            (.invalidArgument(secret), .invalidArgument),
            (.storeExists, .storageUnavailable),
            (.storeMissing, .repairRequired(.journalMissing)),
            (.storeUnreadable(secret), .repairRequired(.journalUnreadable)),
            (.formatUnsupported(9), .repairRequired(.journalFormat)),
            (.storeCorrupt(secret), .repairRequired(.journalCorrupt)),
            (.retired, .retired),
            (.fenced, .fenced),
            (.proofStale, .storageUnavailable),
            (.notResumed, .notResumed),
            (.enrollmentRequired, .enrollmentRequired),
            (.staleJournal, .staleJournal),
            (.hostProvenanceMissing, .repairRequired(.hostProvenanceMissing)),
            (.hostProvenanceMismatch, .repairRequired(.hostProvenanceMismatch)),
            (.hostCaptureRegressed, .repairRequired(.hostCaptureRegressed)),
            (.hostApplicationRegressed, .repairRequired(.hostApplicationRegressed)),
            (.positionOutOfRange(5), .positionOutOfRange),
            (.payloadTooLarge(70_000), .payloadTooLarge(70_000)),
            (.hostMutationConflict(mutation), .hostMutationConflict(HostMutationID(bytes: mutation))),
            (.capacity(.submitBudget), .capacity(.submitBudget)),
            (.capacity(.submitCallTooLarge(limit: 262_144)), .capacity(.submitCallTooLarge(limit: 262_144))),
            (.capacity(.history), .capacity(.history)),
            (.capacity(.pending), .capacity(.pending)),
            (.capacity(.quarantine), .capacity(.quarantine)),
            (.capacity(.origins), .capacity(.origins)),
            (.fork(origin: origin, sequence: 3), .repairRequired(.fork(origin: origin, sequence: 3))),
            (.retainedRecordMissing(origin: origin, sequence: 4), .repairRequired(.retainedRecordMissing(origin: origin, sequence: 4))),
            (.foreignOwnOrigin(sequence: 5), .repairRequired(.foreignOwnOrigin(sequence: 5))),
            (.quarantineConflict(sender: origin, cursor: 6), .repairRequired(.inboxConflict(sender: origin, cursor: 6))),
            (.heldInboxConflict(sender: origin, cursor: 7), .repairRequired(.inboxConflict(sender: origin, cursor: 7))),
            (.exportCursorMismatch, .exportCursorMismatch),
            (.exportRevisionChanged, .exportRevisionChanged),
            (.notArchived, .notArchived),
            (.confirmationMismatch, .confirmationMismatch),
        ]
        for (source, expected) in table {
            let surfaced = HostJournalError.surfaced(source)
            XCTAssertEqual(surfaced as? HostJournalError, expected, "\(source)")
            assertSanitized(surfaced)
        }
    }

    func testEveryEngineErrorMapsToATypedPublicCase() {
        let table: [(HostEngineError, HostJournalError)] = [
            (.journalUnbound, .fenced),
            (.generationChanged, .fenced),
            (.notReady, .notReady),
            (.archiveLimit, .capacity(.retiredJournals)),
            (.mlsUnreadable, .repairRequired(.mlsUnreadable)),
            (.handoffUnproven, .repairRequired(.handoffUnproven)),
            (.unsettledJoin, .unsettledJoin),
            (.launchInputsChanged, .repairRequired(.launchInputsChanged)),
            (.sessionCloseUncertain, .repairRequired(.sessionCloseUncertain)),
        ]
        for (source, expected) in table {
            XCTAssertEqual(HostJournalError.surfaced(source) as? HostJournalError, expected, "\(source)")
        }
    }

    func testEveryEngineRepairMapsWithoutItsDiagnostic() {
        let table: [(HostRepair, HostJournalRepair)] = [
            (.journalMissing, .journalMissing),
            (.journalUnreadable(secret), .journalUnreadable),
            (.ambiguousJournal, .ambiguousJournal),
            (.mlsUnreadable, .mlsUnreadable),
            (.lifecycleUnreadable, .lifecycleUnreadable),
            (.launchFailed(secret), .launchFailed),
            (.launchInputsChanged, .launchInputsChanged),
            (.sessionCloseUncertain, .sessionCloseUncertain),
        ]
        for (source, expected) in table {
            let repair = HostJournalRepair(source)
            XCTAssertEqual(repair, expected)
            XCTAssertFalse(String(reflecting: repair).contains("SECRET"))
        }
    }

    func testCancellationPassesThroughAndUnknownErrorsCarryNoDetail() {
        XCTAssertTrue(HostJournalError.surfaced(CancellationError()) is CancellationError)
        let foreign = NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: [NSFilePathErrorKey: secret])
        let surfaced = HostJournalError.surfaced(foreign)
        XCTAssertEqual(surfaced as? HostJournalError, .storageUnavailable)
        assertSanitized(surfaced)
    }

    func testArchiveExportRefusesMalformedMutationIDs() throws {
        let record = try XCTUnwrap(JournalFixture.chain(origin, count: 1).first)
        for count in [0, 15, 17] {
            XCTAssertThrowsError(try HostArchiveItem(.own(sequence: 1, mutationID: Data(count: count), envelope: record.bytes))) {
                XCTAssertEqual($0 as? HostJournalError, .repairRequired(.journalCorrupt))
            }
        }
    }

    @MainActor
    func testArchiveListingRefusesCorruptCountsWithoutChangingTheFile() throws {
        let directory = try JournalFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HostJournalStore.create(in: directory, group: JournalFixture.group)
        try store.retire(.unlink, heldInbox: [])
        try JournalFixture.tamper(store.url, "UPDATE meta SET value = 1 WHERE key = 'ownHead'")
        let before = try JournalFixture.fileHash(store.url)
        let listing = try XCTUnwrap(HostJournalFiles.discover(in: directory).first)
        XCTAssertThrowsError(try HostJournalArchive(listing)) {
            XCTAssertEqual($0 as? HostJournalError, .repairRequired(.journalCorrupt))
        }
        XCTAssertEqual(try JournalFixture.fileHash(store.url), before)
    }

    private func assertSanitized(_ error: any Error, file: StaticString = #filePath, line: UInt = #line) {
        let rendered = String(reflecting: error) + error.localizedDescription
        XCTAssertFalse(rendered.contains("SECRET"), rendered, file: file, line: line)
        XCTAssertFalse(rendered.contains(".sqlite"), rendered, file: file, line: line)
    }
}
