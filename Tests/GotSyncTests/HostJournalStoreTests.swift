import Foundation
import XCTest
@_spi(HostJournalPreview) @testable import GotSync

@MainActor
final class HostJournalStoreTests: XCTestCase {
    private var root: URL!
    private var directory: URL!

    override func setUp() async throws {
        root = try JournalFixture.directory()
        directory = root
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func enrolled(limits: HostJournalLimits = .standard) throws -> (HostJournalStore, HostStandIn) {
        let store = try HostJournalStore.create(in: directory, group: JournalFixture.group, limits: limits)
        let host = try HostStandIn(url: directory.appendingPathComponent("host.json"))
        try host.save(try store.enroll())
        _ = try store.resume(XCTUnwrap(host.provenance))
        return (store, host)
    }

    private func reopen(_ store: HostJournalStore) throws -> HostJournalStore {
        try HostJournalStore.open(store.url, limits: store.limits)
    }

    // MARK: - Files

    func testCreatedFileIsProtectedAndReopensToTheSameView() throws {
        let store = try HostJournalStore.create(in: directory, group: JournalFixture.group)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try store.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(store.view.group, JournalFixture.group)
        XCTAssertEqual(store.view.journalID.count, 16)
        XCTAssertEqual(store.view.origin.count, 16)
        XCTAssertEqual(store.view.enrollment, .none)
        XCTAssertEqual(try reopen(store).view, store.view)
        let other = try HostJournalStore.create(in: directory, group: JournalFixture.group)
        XCTAssertNotEqual(other.view.journalID, store.view.journalID)
        XCTAssertNotEqual(other.view.origin, store.view.origin)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".creating") }, [])
    }

    func testMissingUnreadableUnsupportedAndCorruptFilesStopWithoutWriting() throws {
        let missing = HostJournalStore.fileURL(in: directory, journalID: Data(count: 16))
        XCTAssertThrowsError(try HostJournalStore.open(missing)) { XCTAssertEqual($0 as? JournalStoreError, .storeMissing) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))

        let garbage = HostJournalStore.fileURL(in: directory, journalID: Data(repeating: 1, count: 16))
        try Data(repeating: 0x42, count: 8_192).write(to: garbage)
        let garbageHash = try JournalFixture.fileHash(garbage)
        XCTAssertThrowsError(try HostJournalStore.open(garbage)) {
            guard case .storeUnreadable = $0 as? JournalStoreError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try JournalFixture.fileHash(garbage), garbageHash)

        let (store, _) = try enrolled()
        let url = store.url
        _ = try store.intake([JournalFixture.arrival(try JournalFixture.chain(JournalFixture.origin(2), count: 3), cursor: 1)])
        try JournalFixture.tamper(url, "PRAGMA user_version = 5")
        let unsupported = try JournalFixture.fileHash(url)
        XCTAssertThrowsError(try HostJournalStore.open(url)) { XCTAssertEqual($0 as? JournalStoreError, .formatUnsupported(5)) }
        XCTAssertEqual(try JournalFixture.fileHash(url), unsupported)
        try JournalFixture.tamper(url, "PRAGMA user_version = 3")

        for damage in [
            "UPDATE records SET envelope = randomblob(length(envelope)) WHERE position = 2",
            "UPDATE records SET digest = zeroblob(32) WHERE position = 2",
            "UPDATE meta SET value = 99 WHERE key = 'recordCount'",
            "UPDATE records SET position = 7 WHERE position = 3",
            "DELETE FROM records WHERE position = 2",
            "UPDATE origins SET applied = 5",
        ] {
            let copy = directory.appendingPathComponent("copy-\(UUID().uuidString).sqlite3")
            try FileManager.default.copyItem(at: url, to: copy)
            try JournalFixture.tamper(copy, damage)
            let before = try JournalFixture.fileHash(copy)
            XCTAssertThrowsError(try HostJournalStore.open(copy), damage) {
                guard case .storeCorrupt = $0 as? JournalStoreError else { return XCTFail("\(damage): \($0)") }
            }
            XCTAssertEqual(try JournalFixture.fileHash(copy), before, damage)
        }
    }

    func testUnsupportedWALStoreIsPreservedExactly() throws {
        let url = HostJournalStore.fileURL(in: directory, journalID: Data(repeating: 3, count: 16))
        try JournalFixture.tamper(url, "PRAGMA journal_mode=WAL; CREATE TABLE example(x INTEGER); INSERT INTO example VALUES(42); PRAGMA user_version=5", create: true)
        let before = JournalFixture.storedState(url)
        XCTAssertEqual(Array(try XCTUnwrap(before[""])[18...19]), [2, 2])
        XCTAssertThrowsError(try HostJournalStore.open(url)) { XCTAssertEqual($0 as? JournalStoreError, .formatUnsupported(5)) }
        XCTAssertEqual(JournalFixture.storedState(url), before)
    }

    func testSupportedFormatWALStoreIsReportedWithoutConversion() throws {
        let (store, _) = try enrolled()
        _ = try store.intake([JournalFixture.arrival(try JournalFixture.chain(JournalFixture.origin(2), count: 2), cursor: 1)])
        let withIndex = directory.appendingPathComponent("wal-index.sqlite3")
        try FileManager.default.copyItem(at: store.url, to: withIndex)
        try JournalFixture.tamper(withIndex, "PRAGMA journal_mode=WAL; UPDATE meta SET value = value WHERE key = 'revision'")
        XCTAssertTrue(FileManager.default.fileExists(atPath: withIndex.path + "-shm"))
        let indexed = JournalFixture.storedState(withIndex)
        XCTAssertEqual(Array(try XCTUnwrap(indexed[""])[18...19]), [2, 2])
        XCTAssertThrowsError(try HostJournalStore.open(withIndex)) { XCTAssertEqual($0 as? JournalStoreError, .storeCorrupt("journal mode wal")) }
        XCTAssertEqual(JournalFixture.storedState(withIndex), indexed)

        let withoutIndex = directory.appendingPathComponent("wal-bare.sqlite3")
        try FileManager.default.copyItem(at: store.url, to: withoutIndex)
        try JournalFixture.tamper(withoutIndex, "PRAGMA journal_mode=WAL")
        XCTAssertFalse(FileManager.default.fileExists(atPath: withoutIndex.path + "-shm"))
        let bare = JournalFixture.storedState(withoutIndex)
        XCTAssertEqual(Array(try XCTUnwrap(bare[""])[18...19]), [2, 2])
        XCTAssertThrowsError(try HostJournalStore.open(withoutIndex)) {
            guard case .storeUnreadable(let reason) = $0 as? JournalStoreError, reason.hasPrefix("14:") else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(JournalFixture.storedState(withoutIndex), bare)
        XCTAssertFalse(FileManager.default.fileExists(atPath: withoutIndex.path + "-shm"))
    }

    func testHotRollbackJournalIsRecoveredToTheCommittedState() throws {
        let (store, _) = try enrolled()
        _ = try store.intake([JournalFixture.arrival(try JournalFixture.chain(JournalFixture.origin(2), count: 3), cursor: 1)])
        let committed = store.view
        let original = JournalFixture.storedState(store.url)
        let copy = try JournalFixture.hotImage(of: store.url, into: directory.appendingPathComponent("hot", isDirectory: true))
        XCTAssertEqual(JournalFixture.storedState(store.url), original)
        let journal = try Data(contentsOf: URL(fileURLWithPath: copy.path + "-journal"))
        XCTAssertEqual(Array(journal.prefix(8)), [0xD9, 0xD5, 0x05, 0xF9, 0x20, 0xA1, 0x63, 0xD7], "the image must hold a hot journal")
        XCTAssertNotEqual(try Data(contentsOf: copy), try XCTUnwrap(original[""]))
        let recovered = try HostJournalStore.open(copy)
        XCTAssertEqual(recovered.view, committed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path + "-journal"))
        XCTAssertEqual(try Data(contentsOf: copy), try XCTUnwrap(original[""]))
        XCTAssertEqual(try HostJournalStore.open(copy).view, committed)
    }

    func testSameOriginPositionInversionIsRejectedBeforeUse() throws {
        let (store, _) = try enrolled()
        _ = try store.intake([JournalFixture.arrival(try JournalFixture.chain(JournalFixture.origin(2), count: 2), cursor: 1)])
        try JournalFixture.tamper(store.url, """
            BEGIN IMMEDIATE; UPDATE records SET position = 3 WHERE position = 1;
            UPDATE records SET position = 1 WHERE position = 2; UPDATE records SET position = 2 WHERE position = 3; COMMIT
            """)
        let before = JournalFixture.storedState(store.url)
        XCTAssertThrowsError(try HostJournalStore.open(store.url)) { XCTAssertEqual($0 as? JournalStoreError, .storeCorrupt("position order")) }
        XCTAssertEqual(JournalFixture.storedState(store.url), before)
    }

    func testInterleavedOriginsReopenAndApplyInPositionOrder() throws {
        let (store, host) = try enrolled()
        let a = try JournalFixture.chain(JournalFixture.origin(2), count: 2)
        let b = try JournalFixture.chain(JournalFixture.origin(3), count: 2)
        _ = try store.intake([a[0], b[0], a[1], b[1]].enumerated().map { JournalFixture.arrival([$0.element], cursor: UInt64($0.offset + 1)) })
        let reopened = try reopen(store)
        _ = try reopened.resume(XCTUnwrap(host.provenance))
        XCTAssertEqual(try reopened.incoming(after: 0, limit: 4).map(\.record), [a[0].id, b[0].id, a[1].id, b[1].id])
        try reopened.markApplied(through: 3)
        try reopened.markApplied(through: 4)
        XCTAssertEqual(try reopen(reopened).view.appliedThrough, 4)
    }

    func testNegativeRawCursorsAreRejectedBeforeUse() throws {
        let (store, _) = try enrolled()
        _ = try store.intake([JournalFixture.raw(Data("raw".utf8), cursor: 1)])
        try JournalFixture.tamper(store.url, "UPDATE quarantine SET cursor = -1")
        let quarantine = JournalFixture.storedState(store.url)
        XCTAssertThrowsError(try HostJournalStore.open(store.url)) { XCTAssertEqual($0 as? JournalStoreError, .storeCorrupt("quarantine")) }
        XCTAssertEqual(JournalFixture.storedState(store.url), quarantine)

        directory = root.appendingPathComponent("held", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let retired = try HostJournalStore.create(in: directory, group: JournalFixture.group)
        try retired.retire(.unlink, heldInbox: [HostJournalHeldMessage(sender: JournalFixture.sender, cursor: 4, plaintext: Data("h".utf8))])
        try JournalFixture.tamper(retired.url, "UPDATE heldInbox SET cursor = -4")
        let held = JournalFixture.storedState(retired.url)
        XCTAssertThrowsError(try HostJournalStore.open(retired.url)) { XCTAssertEqual($0 as? JournalStoreError, .storeCorrupt("heldInbox")) }
        XCTAssertEqual(JournalFixture.storedState(retired.url), held)
    }

    func testSymbolicLinkIsNotFollowed() throws {
        let store = try HostJournalStore.create(in: directory, group: JournalFixture.group)
        let link = directory.appendingPathComponent("host-journal-link.sqlite3")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: store.url)
        XCTAssertThrowsError(try HostJournalStore.open(link)) {
            guard case .storeUnreadable = $0 as? JournalStoreError else { return XCTFail("\($0)") }
        }
    }

    // MARK: - Enrollment and continuity

    func testLostProvenanceAfterEmptyConfirmedEnrollmentDoesNotEnrollAgain() throws {
        let (store, _) = try enrolled()
        let reopened = try reopen(store)
        let before = try JournalFixture.fileHash(reopened.url)
        XCTAssertThrowsError(try reopened.enroll()) { XCTAssertEqual($0 as? JournalStoreError, .hostProvenanceMissing) }
        XCTAssertEqual(try JournalFixture.fileHash(reopened.url), before)
        XCTAssertFalse(reopened.isResumed)
        XCTAssertThrowsError(try reopened.submit([HostJournalMutation(id: JournalFixture.mutationID(1), payload: Data())], capturedThrough: 1)) {
            XCTAssertEqual($0 as? JournalStoreError, .notResumed)
        }
    }

    func testPendingEnrollmentCrashBeforeHostSaveEnrollsAgain() throws {
        let store = try HostJournalStore.create(in: directory, group: JournalFixture.group)
        let lost = try store.enroll()
        let reopened = try reopen(store)
        let host = try HostStandIn(url: directory.appendingPathComponent("host.json"))
        try host.save(try reopened.enroll())
        XCTAssertThrowsError(try reopened.resume(lost)) { XCTAssertEqual($0 as? JournalStoreError, .hostProvenanceMismatch) }
        XCTAssertNoThrow(try reopened.resume(XCTUnwrap(host.provenance)))
        XCTAssertEqual(reopened.view.enrollment, .confirmed(try XCTUnwrap(host.state.enrollmentID)))
    }

    func testPendingEnrollmentCrashAfterHostSaveConfirmsOnResume() throws {
        let store = try HostJournalStore.create(in: directory, group: JournalFixture.group)
        let host = try HostStandIn(url: directory.appendingPathComponent("host.json"))
        try host.save(try store.enroll())
        let reopened = try reopen(store)
        XCTAssertEqual(reopened.view.enrollment, .pending(try XCTUnwrap(host.state.enrollmentID)))
        XCTAssertNoThrow(try reopened.resume(XCTUnwrap(host.provenance)))
        XCTAssertTrue(reopened.isResumed)
    }

    func testRestoredHostBehindASubmittedLocalCaptureStops() throws {
        let (store, host) = try enrolled()
        _ = try store.intake([JournalFixture.arrival(try JournalFixture.chain(JournalFixture.origin(2), count: 2), cursor: 1)])
        try host.applyAll(store)
        let backup = try host.snapshot()
        try host.capture(Data("local edit".utf8))
        let submitted = try host.submitOutbox(store)
        XCTAssertEqual(submitted.count, 1)
        try host.restore(backup)
        let reopened = try reopen(store)
        XCTAssertEqual(host.provenance?.appliedThrough, reopened.view.appliedThrough)
        let before = try JournalFixture.fileHash(reopened.url)
        XCTAssertThrowsError(try reopened.resume(XCTUnwrap(host.provenance))) {
            XCTAssertEqual($0 as? JournalStoreError, .hostCaptureRegressed)
        }
        XCTAssertEqual(try JournalFixture.fileHash(reopened.url), before)
        XCTAssertFalse(reopened.isResumed)
        let own = try JournalFixture.exportAll(reopened.url).compactMap { item -> Data? in
            if case .own(_, _, let envelope) = item { return try JournalEnvelope(parsing: envelope).payload }
            return nil
        }
        XCTAssertEqual(own, [Data("local edit".utf8)])
    }

    func testCrashAfterSubmitCommitBeforeReturnRetriesTheSameRecord() throws {
        let (store, host) = try enrolled()
        let id = try host.capture(Data("edit".utf8))
        store.faultHookForTesting = { if $0 == .afterCommit("submit") { throw CancellationError() } }
        XCTAssertThrowsError(try host.submitOutbox(store))
        XCTAssertEqual(host.state.outbox.count, 1)
        let reopened = try reopen(store)
        XCTAssertEqual(reopened.view.ownHead, 1)
        XCTAssertNoThrow(try reopened.resume(XCTUnwrap(host.provenance)))
        let records = try reopened.submit([HostJournalMutation(id: id, payload: Data("edit".utf8))], capturedThrough: host.state.capturedThrough)
        XCTAssertEqual(records, [JournalRecordID(origin: reopened.view.origin, sequence: 1)])
        XCTAssertEqual(reopened.view.ownHead, 1)
    }

    func testHostAheadCaptureIsKeptAndHostAheadApplicationAdvancesTheJournal() throws {
        let (store, host) = try enrolled()
        _ = try store.intake([
            JournalFixture.arrival(try JournalFixture.chain(JournalFixture.origin(2), count: 3), cursor: 1),
            JournalFixture.arrival(try JournalFixture.chain(JournalFixture.origin(3), count: 2), cursor: 2),
        ])
        try host.capture(Data("a".utf8))
        _ = try host.submitOutbox(store)
        try host.capture(Data("b".utf8))
        try host.capture(Data("c".utf8))
        var state = host.state
        for item in try store.incoming(after: 0, limit: 4) { state.business[item.position] = item.payload }
        state.appliedThrough = 4
        try host.restore(try JSONEncoder().encode(state))
        let reopened = try reopen(store)
        XCTAssertEqual(reopened.view.capturedThrough, 1)
        let resumed = try reopened.resume(XCTUnwrap(host.provenance))
        XCTAssertEqual(resumed.capturedThrough, 3)
        XCTAssertEqual(resumed.appliedThrough, 4)
        XCTAssertEqual(reopened.view.appliedThrough, 4)
        XCTAssertEqual(reopened.view.capturedThrough, 1)
        XCTAssertEqual(try reopen(reopened).view.appliedThrough, 4)
    }

    func testApplicationRegressionStaleIDAndOverreachStop() throws {
        let (store, host) = try enrolled()
        _ = try store.intake([JournalFixture.arrival(try JournalFixture.chain(JournalFixture.origin(2), count: 2), cursor: 1)])
        let backup = try host.snapshot()
        try host.applyAll(store)
        try host.restore(backup)
        let reopened = try reopen(store)
        let provenance = try XCTUnwrap(host.provenance)
        let before = try JournalFixture.fileHash(reopened.url)
        XCTAssertThrowsError(try reopened.resume(provenance)) { XCTAssertEqual($0 as? JournalStoreError, .hostApplicationRegressed) }
        let stale = HostJournalProvenance(journalID: Data(count: 16), enrollmentID: provenance.enrollmentID, appliedThrough: 2, capturedThrough: 0)
        XCTAssertThrowsError(try reopened.resume(stale)) { XCTAssertEqual($0 as? JournalStoreError, .staleJournal) }
        let mismatched = HostJournalProvenance(journalID: provenance.journalID, enrollmentID: Data(count: 16), appliedThrough: 2, capturedThrough: 0)
        XCTAssertThrowsError(try reopened.resume(mismatched)) { XCTAssertEqual($0 as? JournalStoreError, .hostProvenanceMismatch) }
        let beyond = HostJournalProvenance(journalID: provenance.journalID, enrollmentID: provenance.enrollmentID, appliedThrough: 3, capturedThrough: 0)
        XCTAssertThrowsError(try reopened.resume(beyond)) { XCTAssertEqual($0 as? JournalStoreError, .positionOutOfRange(3)) }
        XCTAssertEqual(try JournalFixture.fileHash(reopened.url), before)
        XCTAssertFalse(reopened.isResumed)
    }

    // MARK: - Submission

    func testRepeatedIDsAreIdempotentAndConflictsWriteNothing() throws {
        let (store, _) = try enrolled()
        let first = HostJournalMutation(id: JournalFixture.mutationID(1), payload: Data("é".utf8))
        let records = try store.submit([first, first], capturedThrough: 1)
        XCTAssertEqual(records.map(\.sequence), [1, 1])
        XCTAssertEqual(store.view.ownHead, 1)
        let revision = store.view.revision
        let before = try JournalFixture.fileHash(store.url)
        let decomposed = HostJournalMutation(id: first.id, payload: Data("e\u{301}".utf8))
        XCTAssertThrowsError(try store.submit([HostJournalMutation(id: JournalFixture.mutationID(2), payload: Data()), decomposed], capturedThrough: 2)) {
            XCTAssertEqual($0 as? JournalStoreError, .hostMutationConflict(first.id))
        }
        XCTAssertEqual(try JournalFixture.fileHash(store.url), before)
        XCTAssertEqual(store.view.revision, revision)
        XCTAssertEqual(try store.submit([first], capturedThrough: 2), records.prefix(1).map { $0 })
        let reopened = try reopen(store)
        _ = try reopened.resume(HostJournalProvenance(
            journalID: reopened.view.journalID, enrollmentID: try enrollmentID(reopened), appliedThrough: 0, capturedThrough: 2
        ))
        XCTAssertEqual(try reopened.submit([first], capturedThrough: 2), [records[0]])
    }

    func testSubmissionBoundsAndRegressedCaptureWriteNothing() throws {
        var limits = HostJournalLimits.standard
        limits.submitRecords = 3
        let (store, _) = try enrolled(limits: limits)
        let before = try JournalFixture.fileHash(store.url)
        XCTAssertThrowsError(try store.submit([HostJournalMutation(id: JournalFixture.mutationID(1), payload: Data(count: 65_537))], capturedThrough: 1)) {
            XCTAssertEqual($0 as? JournalStoreError, .payloadTooLarge(65_537))
        }
        XCTAssertThrowsError(try store.submit([], capturedThrough: 1))
        XCTAssertThrowsError(try store.submit((0..<257).map { HostJournalMutation(id: JournalFixture.mutationID($0), payload: Data()) }, capturedThrough: 1))
        XCTAssertThrowsError(try store.submit([HostJournalMutation(id: Data(count: 15), payload: Data())], capturedThrough: 1))
        XCTAssertThrowsError(try store.submit([HostJournalMutation(id: JournalFixture.mutationID(1), payload: Data())], capturedThrough: UInt64.max)) {
            XCTAssertEqual($0 as? JournalStoreError, .valueOutOfRange)
        }
        XCTAssertThrowsError(try store.submit((1...4).map { HostJournalMutation(id: JournalFixture.mutationID($0), payload: Data()) }, capturedThrough: 1)) {
            XCTAssertEqual($0 as? JournalStoreError, .capacity(.submitBudget))
        }
        XCTAssertEqual(try JournalFixture.fileHash(store.url), before)
        _ = try store.submit([HostJournalMutation(id: JournalFixture.mutationID(1), payload: Data(count: 65_536))], capturedThrough: 5)
        XCTAssertThrowsError(try store.submit([HostJournalMutation(id: JournalFixture.mutationID(2), payload: Data())], capturedThrough: 4)) {
            XCTAssertEqual($0 as? JournalStoreError, .hostCaptureRegressed)
        }
        XCTAssertEqual(store.view.ownHead, 1)
    }

    // MARK: - Intake

    func testContiguousIntakeEnumeratesPositionsAndPersistsTheAppliedVector() throws {
        let (store, host) = try enrolled()
        let a = try JournalFixture.chain(JournalFixture.origin(2), count: 3)
        let b = try JournalFixture.chain(JournalFixture.origin(3), count: 2)
        let result = try store.intake([JournalFixture.arrival(a, cursor: 1), JournalFixture.arrival(b + [], cursor: 2)])
        XCTAssertEqual(result, HostJournalIntake(ownedArrivals: 2, refusal: nil))
        let incoming = try store.incoming(after: 0, limit: 10)
        XCTAssertEqual(incoming.map(\.position), [1, 2, 3, 4, 5])
        XCTAssertEqual(incoming.map(\.payload), (a + b).map(\.payload))
        try host.applyAll(store)
        XCTAssertEqual(store.view.appliedThrough, 5)
        XCTAssertEqual(store.view.undelivered, 0)
        let reopened = try reopen(store)
        XCTAssertEqual(reopened.view.appliedThrough, 5)
        XCTAssertEqual(reopened.view.delivered, 5)
    }

    func testDuplicatesAreFreeAndEveryForkWritesNothing() throws {
        let (store, _) = try enrolled()
        let origin = JournalFixture.origin(2)
        let run = try JournalFixture.chain(origin, count: 2, payload: { _ in Data("é".utf8) })
        _ = try store.intake([JournalFixture.arrival(run, cursor: 1)])
        let gap = try JournalFixture.chain(origin, count: 1, from: 4, prior: Data(repeating: 9, count: 32))
        _ = try store.intake([JournalFixture.arrival(gap, cursor: 2)])
        XCTAssertEqual(try store.intake([JournalFixture.arrival(run + gap, cursor: 3)]).ownedArrivals, 1)
        XCTAssertEqual(store.view.recordCount, 2)
        XCTAssertEqual(store.view.pendingCount, 1)
        let before = try JournalFixture.fileHash(store.url)
        let revision = store.view.revision

        let retainedFork = try JournalEnvelope(origin: origin, sequence: 2, prior: run[0].digest, payload: Data("e\u{301}".utf8))
        let pendingFork = try JournalEnvelope(origin: origin, sequence: 4, prior: Data(repeating: 8, count: 32), payload: Data())
        let other = try JournalFixture.chain(JournalFixture.origin(3), count: 1)
        let otherFork = try JournalEnvelope(origin: other[0].origin, sequence: 1, prior: JournalEnvelope.zeroDigest, payload: Data("x".utf8))
        let predecessor = try JournalEnvelope(origin: origin, sequence: 3, prior: Data(repeating: 1, count: 32), payload: Data())
        let hidden = try JournalEnvelope(origin: origin, sequence: 3, prior: run[1].digest, payload: Data())
        let cases: [(String, [HostJournalArrival], JournalStoreError)] = [
            ("retained", [JournalFixture.arrival(other, cursor: 4), JournalFixture.arrival([retainedFork], cursor: 5)],
             .fork(origin: origin, sequence: 2)),
            ("pending", [JournalFixture.arrival(other, cursor: 4), JournalFixture.arrival([pendingFork], cursor: 5)],
             .fork(origin: origin, sequence: 4)),
            ("incoming", [JournalFixture.arrival(other, cursor: 4), JournalFixture.arrival([otherFork], cursor: 5)],
             .fork(origin: other[0].origin, sequence: 1)),
            ("predecessor", [JournalFixture.arrival(other, cursor: 4), JournalFixture.arrival([predecessor], cursor: 5)],
             .fork(origin: origin, sequence: 3)),
            ("promotion", [JournalFixture.arrival(other, cursor: 4), JournalFixture.arrival([hidden], cursor: 5)],
             .fork(origin: origin, sequence: 4)),
        ]
        for (name, arrivals, expected) in cases {
            XCTAssertThrowsError(try store.intake(arrivals), name) { XCTAssertEqual($0 as? JournalStoreError, expected, name) }
            XCTAssertEqual(try JournalFixture.fileHash(store.url), before, name)
            XCTAssertEqual(store.view.revision, revision, name)
        }
    }

    func testGapSurvivesRestartAndPromotesWithoutDoubleCounting() throws {
        let (store, host) = try enrolled()
        let run = try JournalFixture.chain(JournalFixture.origin(2), count: 4)
        _ = try store.intake([JournalFixture.arrival(Array(run[2...]), cursor: 1)])
        XCTAssertEqual(store.view.pendingCount, 2)
        let pendingBytes = store.view.pendingBytes
        let reopened = try reopen(store)
        XCTAssertEqual(reopened.view.pendingCount, 2)
        XCTAssertEqual(reopened.view.retainedBytes, pendingBytes)
        _ = try reopened.resume(XCTUnwrap(host.provenance))
        _ = try reopened.intakeAndPromote([JournalFixture.arrival(Array(run[..<2]), cursor: 2)])
        XCTAssertEqual(reopened.view.pendingCount, 0)
        XCTAssertEqual(reopened.view.recordCount, 4)
        XCTAssertEqual(reopened.view.retainedBytes, UInt64(run.map(\.bytes.count).reduce(0, +)))
        XCTAssertEqual(try reopened.incoming(after: 0, limit: 10).map(\.record.sequence), [1, 2, 3, 4])
        XCTAssertEqual(try reopen(reopened).view, reopened.view)
    }

    func testOwnOriginInputIsADuplicateOrAForeignContinuation() throws {
        let (store, host) = try enrolled()
        try host.capture(Data("mine".utf8))
        _ = try host.submitOutbox(store)
        let own = try XCTUnwrap(try JournalFixture.exportAll(store.url).compactMap { item -> Data? in
            if case .own(_, _, let envelope) = item { return envelope }
            return nil
        }.first)
        let echo = HostJournalArrival(sender: JournalFixture.sender, cursor: 1, plaintext: Data(), envelopes: [own])
        XCTAssertEqual(try store.intake([echo]).ownedArrivals, 1)
        XCTAssertEqual(store.view.recordCount, 1)
        let before = try JournalFixture.fileHash(store.url)
        let foreign = try JournalEnvelope(origin: store.view.origin, sequence: 2, prior: try JournalEnvelope(parsing: own).digest, payload: Data())
        XCTAssertThrowsError(try store.intake([JournalFixture.arrival([foreign], cursor: 2)])) {
            XCTAssertEqual($0 as? JournalStoreError, .foreignOwnOrigin(sequence: 2))
        }
        XCTAssertEqual(try JournalFixture.fileHash(store.url), before)
    }

    func testUnknownInputIsQuarantinedIdempotentlyBySenderAndCursor() throws {
        let (store, _) = try enrolled()
        let unordered = try JournalFixture.chain(JournalFixture.origin(2), count: 2).reversed()
        let arrivals = [
            JournalFixture.raw(Data("not a record".utf8), cursor: 1),
            HostJournalArrival(sender: JournalFixture.sender, cursor: 2, plaintext: Data("bad".utf8), envelopes: [Data("GSJ1".utf8)]),
            HostJournalArrival(sender: JournalFixture.sender, cursor: 3, plaintext: Data("order".utf8), envelopes: unordered.map(\.bytes)),
            HostJournalArrival(sender: JournalFixture.sender, cursor: 4, plaintext: Data("empty".utf8), envelopes: []),
        ]
        XCTAssertEqual(try store.intake(arrivals).ownedArrivals, 4)
        XCTAssertEqual(store.view.quarantineCount, 4)
        XCTAssertEqual(store.view.recordCount, 0)
        let revision = store.view.revision
        XCTAssertEqual(try store.intake(arrivals).ownedArrivals, 4)
        XCTAssertEqual(store.view.quarantineCount, 4)
        XCTAssertEqual(store.view.quarantineBytes, UInt64(arrivals.map(\.plaintext.count).reduce(0, +)))
        XCTAssertEqual(store.view.revision, revision + 1)
        let before = try JournalFixture.fileHash(store.url)
        XCTAssertThrowsError(try store.intake([JournalFixture.raw(Data("changed".utf8), cursor: 1)])) {
            XCTAssertEqual($0 as? JournalStoreError, .quarantineConflict(sender: JournalFixture.sender, cursor: 1))
        }
        XCTAssertEqual(try JournalFixture.fileHash(store.url), before)
        XCTAssertThrowsError(try store.intake([JournalFixture.raw(Data(), cursor: UInt64.max)])) {
            XCTAssertEqual($0 as? JournalStoreError, .valueOutOfRange)
        }
        XCTAssertThrowsError(try store.intake([HostJournalArrival(sender: Data(count: 31), cursor: 9, plaintext: Data(), envelopes: nil)]))
    }

    func testAnArrivalIsOwnedCompletelyOrLeftWithItsOwner() throws {
        var limits = HostJournalLimits.standard
        limits.historyRecords = 4
        let (store, _) = try enrolled(limits: limits)
        let run = try JournalFixture.chain(JournalFixture.origin(2), count: 6)
        let arrivals = [
            JournalFixture.arrival(Array(run[0..<2]), cursor: 1),
            JournalFixture.arrival(Array(run[2..<5]), cursor: 2),
            JournalFixture.arrival(Array(run[5...]), cursor: 3),
        ]
        XCTAssertEqual(try store.intake(arrivals), HostJournalIntake(ownedArrivals: 1, refusal: .history))
        XCTAssertEqual(store.view.recordCount, 2)
        XCTAssertEqual(try store.incoming(after: 0, limit: 10).count, 2)
        XCTAssertEqual(try store.intake(Array(arrivals[0...0])).ownedArrivals, 1)
        XCTAssertEqual(store.view.recordCount, 2)
    }

    func testEveryIntakeLimitRefusesWithoutEviction() throws {
        let origin = JournalFixture.origin(2)
        let run = try JournalFixture.chain(origin, count: 6, payload: { _ in Data(count: 100) })
        let envelope = UInt64(run[0].bytes.count)
        var history = HostJournalLimits.standard
        history.historyBytes = envelope * 3
        var pending = HostJournalLimits.standard
        pending.pendingRecords = 2
        var pendingBytes = HostJournalLimits.standard
        pendingBytes.pendingBytes = envelope * 2
        var quarantine = HostJournalLimits.standard
        quarantine.quarantineItems = 2
        var quarantineBytes = HostJournalLimits.standard
        quarantineBytes.quarantineBytes = 10
        var origins = HostJournalLimits.standard
        origins.origins = 3
        let gap = Array(run[2...])
        let cases: [(HostJournalLimits, [HostJournalArrival], JournalCapacity, Int)] = [
            (history, run.map { JournalFixture.arrival([$0], cursor: $0.sequence) }, .history, 3),
            (pending, gap.map { JournalFixture.arrival([$0], cursor: $0.sequence) }, .pending, 2),
            (pendingBytes, gap.map { JournalFixture.arrival([$0], cursor: $0.sequence) }, .pending, 2),
            (history, gap.map { JournalFixture.arrival([$0], cursor: $0.sequence) }, .history, 3),
            (quarantine, (1...3).map { JournalFixture.raw(Data([UInt8($0)]), cursor: UInt64($0)) }, .quarantine, 2),
            (quarantineBytes, (1...3).map { JournalFixture.raw(Data(count: 5), cursor: UInt64($0)) }, .quarantine, 2),
            (origins, (2...5).map { JournalFixture.arrival(try! JournalFixture.chain(JournalFixture.origin(UInt8($0)), count: 1), cursor: UInt64($0)) },
             .origins, 2),
        ]
        for (index, (limits, arrivals, refusal, owned)) in cases.enumerated() {
            directory = root.appendingPathComponent("case\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let (store, _) = try enrolled(limits: limits)
            XCTAssertEqual(try store.intake(arrivals), HostJournalIntake(ownedArrivals: owned, refusal: refusal), "case \(index)")
            let after = store.view
            let hash = try JournalFixture.fileHash(store.url)
            XCTAssertEqual(try store.intake(Array(arrivals[owned...])), HostJournalIntake(ownedArrivals: 0, refusal: refusal), "case \(index)")
            XCTAssertEqual(store.view, after, "case \(index)")
            XCTAssertEqual(try JournalFixture.fileHash(store.url), hash, "case \(index)")
            XCTAssertEqual(try reopen(store).view, after, "case \(index)")
        }
    }

    func testSequencesUpToTheSignedLimitArePreservedExactly() throws {
        let (store, _) = try enrolled()
        let far = try JournalEnvelope(origin: JournalFixture.origin(2), sequence: UInt64(Int64.max), prior: Data(repeating: 5, count: 32), payload: Data())
        _ = try store.intake([JournalFixture.arrival([far], cursor: UInt64(Int64.max))])
        let items = try JournalFixture.exportAll(try reopen(store).url)
        XCTAssertEqual(items, [.pending(origin: far.origin, sequence: UInt64(Int64.max), envelope: far.bytes)])
    }

    // MARK: - Transactions

    func testAFaultBeforeCommitKeepsTheViewAndTheFile() throws {
        let (store, host) = try enrolled()
        _ = try store.intake([JournalFixture.arrival(try JournalFixture.chain(JournalFixture.origin(2), count: 2), cursor: 1)])
        try host.capture(Data("x".utf8))
        let provenance = try XCTUnwrap(host.provenance)
        let operations: [(String, () throws -> Void)] = [
            ("submit", { _ = try store.submit([HostJournalMutation(id: JournalFixture.mutationID(9), payload: Data())], capturedThrough: provenance.capturedThrough) }),
            ("intake", { _ = try store.intake([JournalFixture.arrival(try JournalFixture.chain(JournalFixture.origin(3), count: 1), cursor: 2)]) }),
            ("markApplied", { try store.markApplied(through: 2) }),
            ("retire", { try store.retire(.unlink, heldInbox: [HostJournalHeldMessage(sender: JournalFixture.sender, cursor: 3, plaintext: Data("h".utf8))]) }),
        ]
        for (name, operation) in operations {
            let view = store.view
            store.faultHookForTesting = { if $0 == .beforeCommit(name) { throw CancellationError() } }
            XCTAssertThrowsError(try operation(), name)
            XCTAssertEqual(store.view, view, name)
            XCTAssertEqual(try HostJournalStore.open(store.url).view, view, name)
        }
        store.faultHookForTesting = nil
        let reopened = try reopen(store)
        reopened.faultHookForTesting = { if $0 == .beforeCommit("resume") { throw CancellationError() } }
        var advanced = host.state
        advanced.appliedThrough = 2
        try host.restore(try JSONEncoder().encode(advanced))
        XCTAssertThrowsError(try reopened.resume(XCTUnwrap(host.provenance)))
        XCTAssertFalse(reopened.isResumed)
        XCTAssertEqual(reopened.view.appliedThrough, 0)
    }

    func testCrashImagesReopenIntoThePreviousOrTheCommittedState() throws {
        let (store, host) = try enrolled()
        let images = directory.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        var captured: [HostJournalCommitPoint: URL] = [:]
        store.faultHookForTesting = { point in
            let target = images.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            for suffix in ["", "-journal"] where FileManager.default.fileExists(atPath: store.url.path + suffix) {
                try FileManager.default.copyItem(atPath: store.url.path + suffix, toPath: target.appendingPathComponent(store.url.lastPathComponent).path + suffix)
            }
            captured[point] = target.appendingPathComponent(store.url.lastPathComponent)
        }
        let id = try host.capture(Data("crash".utf8))
        let operations: [(String, () throws -> Void)] = [
            ("intake", { _ = try store.intake([JournalFixture.arrival(try JournalFixture.chain(JournalFixture.origin(2), count: 3), cursor: 1)]) }),
            ("submit", { _ = try store.submit([HostJournalMutation(id: id, payload: Data("crash".utf8))], capturedThrough: host.state.capturedThrough) }),
            ("markApplied", { try store.markApplied(through: 2) }),
            ("retire", { try store.retire(.unlink, heldInbox: [HostJournalHeldMessage(sender: JournalFixture.sender, cursor: 9, plaintext: Data(count: 50_000))]) }),
        ]
        for (name, operation) in operations {
            captured = [:]
            let before = store.view
            try operation()
            let after = store.view
            XCTAssertNotEqual(before, after, name)
            let midTransaction = try XCTUnwrap(captured[.beforeCommit(name)], name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: midTransaction.path + "-journal"), name)
            XCTAssertEqual(try HostJournalStore.open(midTransaction).view, before, name)
            XCTAssertEqual(try HostJournalStore.open(try XCTUnwrap(captured[.afterCommit(name)])).view, after, name)
        }
    }

    func testAFaultDuringEnrollmentLeavesNoEnrollment() throws {
        let store = try HostJournalStore.create(in: directory, group: JournalFixture.group)
        store.faultHookForTesting = { if $0 == .beforeCommit("enroll") { throw CancellationError() } }
        XCTAssertThrowsError(try store.enroll())
        XCTAssertEqual(store.view.enrollment, .none)
        XCTAssertEqual(try reopen(store).view.enrollment, .none)
    }

    func testRetirementCopiesHeldMessagesAtomicallyAndIdempotently() throws {
        let (store, _) = try enrolled()
        let held = [
            HostJournalHeldMessage(sender: JournalFixture.sender, cursor: 7, plaintext: Data("seven".utf8)),
            HostJournalHeldMessage(sender: JournalFixture.sender, cursor: 7, plaintext: Data("seven".utf8)),
            HostJournalHeldMessage(sender: Data(repeating: 0xD0, count: 32), cursor: 8, plaintext: Data()),
        ]
        let conflicting = held + [HostJournalHeldMessage(sender: JournalFixture.sender, cursor: 7, plaintext: Data("other".utf8))]
        let before = try JournalFixture.fileHash(store.url)
        XCTAssertThrowsError(try store.retire(.removed, heldInbox: conflicting)) {
            XCTAssertEqual($0 as? JournalStoreError, .heldInboxConflict(sender: JournalFixture.sender, cursor: 7))
        }
        XCTAssertEqual(try JournalFixture.fileHash(store.url), before)
        XCTAssertFalse(store.view.isRetired)
        try store.retire(.removed, heldInbox: held)
        XCTAssertEqual(store.view.retirement, .removed)
        XCTAssertEqual(store.view.heldCount, 2)
        XCTAssertEqual(store.view.heldBytes, 5)
        XCTAssertFalse(store.isResumed)
        for operation: () throws -> Void in [
            { _ = try store.intake([JournalFixture.raw(Data(), cursor: 1)]) },
            { try store.retire(.unlink, heldInbox: []) },
            { _ = try store.enroll() },
        ] {
            XCTAssertThrowsError(try operation()) { XCTAssertEqual($0 as? JournalStoreError, .retired) }
        }
        XCTAssertEqual(try reopen(store).view, store.view)
    }

    // MARK: - Timing

    func testMacTransactionTimes() throws {
        let (store, host) = try enrolled()
        var samples: [String: [Double]] = [:]
        func measure(_ name: String, _ body: () throws -> Void) rethrows {
            let start = ContinuousClock.now
            try body()
            let elapsed = ContinuousClock.now - start
            samples[name, default: []].append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1e3)
        }
        let origin = JournalFixture.origin(2)
        var prior = JournalEnvelope.zeroDigest
        var sequence: UInt64 = 1
        var cursor: UInt64 = 1
        for index in 0..<200 {
            let id = try host.capture(Data(count: 120))
            try measure("submit.1") { _ = try store.submit([HostJournalMutation(id: id, payload: Data(count: 120))], capturedThrough: host.state.capturedThrough) }
            let one = try JournalFixture.chain(origin, count: 1, from: sequence, prior: prior, payload: { _ in Data(count: 120) })
            try measure("intake.1") { _ = try store.intake([JournalFixture.arrival(one, cursor: cursor)]) }
            prior = one[0].digest
            sequence += 1
            cursor += 1
            try measure("markApplied") { try store.markApplied(through: store.view.delivered) }
            if index < 40 {
                let run = try JournalFixture.chain(origin, count: 256, from: sequence, prior: prior, payload: { _ in Data(count: 120) })
                try measure("intake.256") { _ = try store.intake([JournalFixture.arrival(run, cursor: cursor)]) }
                prior = run[255].digest
                sequence += 256
                cursor += 1
                let batch = (0..<256).map { HostJournalMutation(id: JournalFixture.mutationID(100_000 + index * 256 + $0), payload: Data(count: 120)) }
                try measure("submit.256") { _ = try store.submit(batch, capturedThrough: host.state.capturedThrough) }
            }
        }
        for (name, values) in samples.sorted(by: { $0.key < $1.key }) {
            let sorted = values.sorted()
            let p50 = sorted[sorted.count / 2]
            let p99 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
            print(String(format: "JOURNAL_TIMING %@ n=%d p50=%.3fms p99=%.3fms max=%.3fms", name, sorted.count, p50, p99, sorted.last!))
        }
    }

    private func enrollmentID(_ store: HostJournalStore) throws -> Data {
        guard case .confirmed(let id) = store.view.enrollment else { throw JournalStoreError.enrollmentRequired }
        return id
    }
}
