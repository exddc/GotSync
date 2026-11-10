import Foundation
import GotSyncMLS
import XCTest
@_spi(HostJournalPreview) @testable import GotSync

/// The off-main writer boundary: ticket order, settlement of committed and
/// failed commands, caller cancellation, fences, connection close, the
/// snapshot inventory and the opening connection's lock behavior.
@MainActor
final class HostWriterBoundaryTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = try JournalFixture.directory()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func enrolled() async throws -> (HostJournal, HostProvenance) {
        let journal = try await HostJournal.create(in: directory, group: JournalFixture.group)
        let provenance = try await journal.resume(try await journal.enroll())
        return (journal, provenance)
    }

    private func mutation(_ index: Int, _ text: String = "edit") -> HostMutation {
        HostMutation(id: HostMutationID(bytes: JournalFixture.mutationID(index)), payload: Data("\(text) \(index)".utf8))
    }

    private func openConnections(_ url: URL) -> Int {
        HostJournalWriter.connectionsForTesting.withLock { $0.open[url.path] ?? 0 }
    }

    // MARK: - Order

    func testALaterCommandWaitsForAHeldEarlierOneWhateverItsPriority() async throws {
        let (journal, _) = try await enrolled()
        var gate: CheckedContinuation<Void, Never>?
        journal.executionGateForTesting = { name in
            if name == "submit", gate == nil { await withCheckedContinuation { gate = $0 } }
        }
        let first = Task { try await journal.submit([self.mutation(1)], capturedThrough: 1) }
        try await waitUntil { gate != nil }
        journal.executionGateForTesting = nil
        var secondDone = false
        let second = Task(priority: .high) {
            let records = try await journal.submit([self.mutation(2)], capturedThrough: 2)
            secondDone = true
            return records
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(secondDone, "a later ticket ran before a held earlier one")
        XCTAssertEqual(journal.admitted - journal.settled, 2)
        gate?.resume()
        let firstRecords = try await first.value
        let secondRecords = try await second.value
        XCTAssertEqual(firstRecords.map(\.sequence), [1])
        XCTAssertEqual(secondRecords.map(\.sequence), [2])
        XCTAssertTrue(journal.isSettled)
        await journal.shutdown()
    }

    // MARK: - Committed outcomes

    func testCancelledCallersReceiveTheirCommittedResults() async throws {
        let (journal, provenance) = try await enrolled()
        var gate: CheckedContinuation<Void, Never>?
        journal.deliveryGateForTesting = { _ in await withCheckedContinuation { gate = $0 } }

        let submitter = Task { try await journal.submit([self.mutation(1)], capturedThrough: 1) }
        try await waitUntil { gate != nil }
        submitter.cancel()
        XCTAssertEqual(journal.view.ownHead, 0, "the view showed a commit before its adoption")
        gate?.resume()
        gate = nil
        let records = try await submitter.value
        XCTAssertEqual(records.map(\.sequence), [1])
        XCTAssertEqual(journal.view.ownHead, 1)

        let resumer = Task {
            try await journal.resume(HostProvenance(
                journalID: provenance.journalID, enrollmentID: provenance.enrollmentID, appliedThrough: nil, capturedThrough: 1
            ))
        }
        try await waitUntil { gate != nil }
        resumer.cancel()
        gate?.resume()
        gate = nil
        let resumed = try await resumer.value
        XCTAssertEqual(resumed.capturedThrough, 1)

        journal.deliveryGateForTesting = nil
        let arrivals = [JournalFixture.arrival(try JournalFixture.chain(JournalFixture.origin(0xA1), count: 1), cursor: 1)]
        let proof = try await journal.beginProof(arrivals)
        while try await !journal.extendProof(proof) {}
        _ = try await journal.intake(next: 1, ofProof: proof, from: 0)
        let incoming = try await journal.incoming(after: nil, limit: 1)
        let position = try XCTUnwrap(incoming.first?.position)
        journal.deliveryGateForTesting = { _ in await withCheckedContinuation { gate = $0 } }
        let applier = Task { try await journal.markApplied(through: position) }
        try await waitUntil { gate != nil }
        applier.cancel()
        gate?.resume()
        gate = nil
        try await applier.value
        XCTAssertEqual(journal.view.appliedThrough, position.rawValue)
        journal.deliveryGateForTesting = nil

        let retried = try await journal.submit([mutation(1)], capturedThrough: 1)
        XCTAssertEqual(retried, records, "an exact retry got different records")
        XCTAssertEqual(journal.view.ownHead, 1)
        await XCTAssertThrowsErrorAsync(try await journal.resume(HostProvenance(
            journalID: provenance.journalID, enrollmentID: provenance.enrollmentID, appliedThrough: nil, capturedThrough: 0
        ))) { XCTAssertEqual($0 as? HostJournalError, .repairRequired(.hostCaptureRegressed)) }
        await journal.shutdown()
    }

    func testACancelledCallerIsRefusedOnlyBeforeAdmission() async throws {
        let (journal, _) = try await enrolled()
        let refused = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await journal.submit([self.mutation(1)], capturedThrough: 1)
        }
        await XCTAssertThrowsErrorAsync(try await refused.value) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(journal.view.ownHead, 0)
        XCTAssertTrue(journal.isSettled)
        await journal.shutdown()
    }

    func testAFailedCommandSettlesItsTicketAndKeepsTheSnapshot() async throws {
        let (journal, _) = try await enrolled()
        _ = try await journal.submit([mutation(1)], capturedThrough: 1)
        let snapshot = journal.snapshot
        let conflicting = HostMutation(id: HostMutationID(bytes: JournalFixture.mutationID(1)), payload: Data("different".utf8))
        await XCTAssertThrowsErrorAsync(try await journal.submit([conflicting], capturedThrough: 1)) {
            XCTAssertEqual($0 as? HostJournalError, .hostMutationConflict(conflicting.id))
        }
        XCTAssertTrue(journal.isSettled)
        XCTAssertEqual(journal.snapshot, snapshot)
        await journal.drain(through: journal.admitted)
        let later = try await journal.submit([mutation(2)], capturedThrough: 2).map(\.sequence)
        XCTAssertEqual(later, [2])
        await journal.shutdown()
    }

    // MARK: - Fences and close

    func testShutdownWaitsForAnAdmittedCommandThenClosesTheConnection() async throws {
        let (journal, _) = try await enrolled()
        XCTAssertEqual(openConnections(journal.url), 1)
        var gate: CheckedContinuation<Void, Never>?
        journal.executionGateForTesting = { name in
            if name == "submit" { await withCheckedContinuation { gate = $0 } }
        }
        let submitter = Task { try await journal.submit([self.mutation(1)], capturedThrough: 1) }
        try await waitUntil { gate != nil }
        var closed = false
        let closing = Task(priority: .high) {
            await journal.shutdown()
            closed = true
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(closed, "shutdown returned while an admitted command waited")
        await XCTAssertThrowsErrorAsync(try await journal.submit([self.mutation(2)], capturedThrough: 2)) {
            XCTAssertEqual($0 as? HostJournalError, .fenced)
        }
        gate?.resume()
        let heldRecords = try await submitter.value.map(\.sequence)
        XCTAssertEqual(heldRecords, [1])
        await closing.value
        XCTAssertTrue(journal.isClosed)
        XCTAssertEqual(openConnections(journal.url), 0, "the connection outlived shutdown")
        XCTAssertEqual(try HostJournalStore.open(journal.url).view.ownHead, 1)
    }

    // MARK: - Proofs

    func testAReplacedProofCannotBeExtendedOrTaken() async throws {
        let (journal, _) = try await enrolled()
        let chain = try JournalFixture.chain(JournalFixture.origin(3), count: 2)
        let arrivals = [JournalFixture.arrival([chain[0]], cursor: 1), JournalFixture.arrival([chain[1]], cursor: 2)]
        let first = try await journal.beginProof(arrivals)
        while try await !journal.extendProof(first) {}
        let second = try await journal.beginProof(arrivals)
        await XCTAssertThrowsErrorAsync(try await journal.extendProof(first)) { XCTAssertEqual($0 as? JournalStoreError, .proofStale) }
        await XCTAssertThrowsErrorAsync(try await journal.intake(next: 1, ofProof: first, from: 0)) {
            XCTAssertEqual($0 as? JournalStoreError, .proofStale)
        }
        while try await !journal.extendProof(second) {}
        await XCTAssertThrowsErrorAsync(try await journal.intake(next: 1, ofProof: second, from: 1)) {
            XCTAssertEqual($0 as? JournalStoreError, .proofStale, "a chunk was taken out of order")
        }
        let firstChunk = try await journal.intake(next: 1, ofProof: second, from: 0).intake.ownedArrivals
        XCTAssertEqual(firstChunk, 1)
        let secondChunk = try await journal.intake(next: 1, ofProof: second, from: 1).intake.ownedArrivals
        XCTAssertEqual(secondChunk, 1)
        XCTAssertEqual(journal.view.recordCount, 2)
        await journal.shutdown()
    }

    // MARK: - Inventory

    func testPendingOnlyOriginsAreInTheSnapshotAndTheAdapterInventory() async throws {
        let (journal, _) = try await enrolled()
        let adapter = HostJournalAdapter(directory: directory, limits: .standard)
        adapter.bind(journal)
        let pendingOrigin = JournalFixture.origin(4)
        let chain = try JournalFixture.chain(pendingOrigin, count: 2)
        let proof = try await journal.beginProof([JournalFixture.arrival([chain[1]], cursor: 1)])
        while try await !journal.extendProof(proof) {}
        _ = try await journal.intake(next: 1, ofProof: proof, from: 0)
        XCTAssertEqual(journal.view.pendingCount, 1)
        XCTAssertNil(journal.receivedVector[pendingOrigin])
        XCTAssertTrue(journal.origins.contains(pendingOrigin))
        XCTAssertTrue(journal.origins.contains(journal.view.origin))
        XCTAssertTrue(adapter.heldOrigins.contains(try ReplicaDeviceID(bytes: pendingOrigin)), "a pending-only origin was not held")
        await journal.shutdown()
    }

    // MARK: - Frozen announcement

    func testContinuousSubmissionsCannotExtendAJoinAnnouncement() async throws {
        let (journal, _) = try await enrolled()
        var captured: UInt64 = 0
        for start in stride(from: 0, to: 300, by: 100) {
            captured += 100
            _ = try await journal.submit((start..<start + 100).map { mutation($0) }, capturedThrough: captured)
        }
        let adapter = HostJournalAdapter(directory: directory, limits: .standard)
        adapter.bind(journal)
        var reads = 0
        journal.executionGateForTesting = { name in
            guard name == "joinAnnouncement" else { return }
            reads += 1
            guard reads < 50 else { return }
            captured += 1
            let next = captured
            Task { _ = try? await journal.submit([self.mutation(10_000 + Int(next))], capturedThrough: next) }
        }
        let announcement = try await adapter.joinAnnouncement()
        journal.executionGateForTesting = nil
        XCTAssertLessThan(reads, 50, "the announcement chased ongoing submissions")
        let announced = try announcement.messages.flatMap { try XCTUnwrap(HostJournalMessage.decode($0).records) }
        XCTAssertEqual(try announced.map { try JournalEnvelope(parsing: $0).sequence }, Array(1...300))
        XCTAssertEqual(announcement.vector[try ReplicaDeviceID(bytes: journal.view.origin)], 300)
        await journal.drain(through: journal.admitted)
        XCTAssertGreaterThan(journal.view.ownHead, 300)
        await journal.shutdown()
    }

    // MARK: - Opening

    func testAnOpenedConnectionWaitsForAnotherConnectionsLock() async throws {
        let created = try await HostJournal.create(in: directory, group: JournalFixture.group)
        let url = created.url
        _ = try await created.resume(try await created.enroll())
        await created.shutdown()
        let opening = Task { try await HostJournal.open(url, resumedEnrollment: created.resumedEnrollment) }
        let journal = try await opening.value
        opening.cancel()
        let holding = Task.detached {
            let database = try JournalDatabase(url: url, readOnly: false)
            try database.execute("BEGIN EXCLUSIVE")
            try await Task.sleep(for: .milliseconds(300))
            try database.execute("COMMIT")
        }
        try await Task.sleep(for: .milliseconds(50))
        let records = try await journal.submit([mutation(1)], capturedThrough: 1)
        XCTAssertEqual(records.map(\.sequence), [1], "the opened connection gave up on a lock instead of waiting")
        try await holding.value
        await journal.shutdown()
    }

    func testResumptionCarriesOnlyToTheSameConfirmedEnrollment() async throws {
        let (journal, provenance) = try await enrolled()
        let url = journal.url
        await journal.shutdown()
        let carried = try await HostJournal.open(url, resumedEnrollment: provenance.enrollmentID)
        let carriedRecords = try await carried.submit([mutation(1)], capturedThrough: 1).count
        XCTAssertEqual(carriedRecords, 1)
        await carried.shutdown()
        let foreign = try await HostJournal.open(url, resumedEnrollment: Data(repeating: 1, count: 16))
        await XCTAssertThrowsErrorAsync(try await foreign.submit([mutation(2)], capturedThrough: 2)) {
            XCTAssertEqual($0 as? HostJournalError, .notResumed)
        }
        await foreign.shutdown()
    }

    // MARK: - Demo path

    func testTaskReplicationStaysSynchronous() {
        let intake: (TaskReplicationAdapter) -> ([ReplicationWindowItem]) throws -> ReplicationChunkIntake = TaskReplicationAdapter.intake
        let reply: (TaskReplicationAdapter) -> (ReplyObligation, UInt64, ReplicaVersionVector?) throws -> (plaintext: Data, records: [(ReplicaDeviceID, UInt64)])? = TaskReplicationAdapter.reply
        let announcement: (TaskReplicationAdapter) -> () throws -> (vector: ReplicaVersionVector, messages: [Data]) = TaskReplicationAdapter.joinAnnouncement
        let upload: (TaskReplicationAdapter) -> (UInt64) throws -> (plaintext: Data, last: UInt64) = TaskReplicationAdapter.upload
        XCTAssertFalse((TaskReplicationAdapter.self as Any.Type) is any HostReplicationData.Type)
        _ = (intake, reply, announcement, upload)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// The boundary as the engine uses it: closing, stop, abandonment, stale
/// chunk intake, reply reselection, the upload ceiling and quiescence.
extension HostEngineTests {
    private func until(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func held(_ journal: HostJournal, _ command: String) -> () -> CheckedContinuation<Void, Never>? {
        var gate: CheckedContinuation<Void, Never>?
        var holding = true
        journal.executionGateForTesting = { name in
            if name == command, holding {
                holding = false
                await withCheckedContinuation { gate = $0 }
            }
        }
        return { gate }
    }

    func testClosingRetiresOnlyAfterAHeldHostSubmitAndItsCancelledCallerGetsTheRecord() async throws {
        let (_, b) = try await completedPair()
        let journal = try store(b)
        let url = journal.url
        let head = journal.view.ownHead
        let gate = held(journal, "submit")
        let next = captured["b", default: 0] + 1
        let submitter = Task { try await journal.submit([HostMutation(id: HostMutationID(UUID()), payload: Data("held".utf8))], capturedThrough: next) }
        try await until { gate() != nil }
        submitter.cancel()
        b.unlinkAndKeepTasks()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(b.hostLifecycle, .closing(.unlink))
        XCTAssertNil(journal.view.retirement, "retired before an admitted command settled")
        gate()?.resume()
        let submitted = try await submitter.value.count
        XCTAssertEqual(submitted, 1)
        try await wait("unlinked") { b.hostLifecycle == .active && !b.isPaired }
        let archived = try HostJournalStore.open(url).view
        XCTAssertEqual(archived.retirement, .unlink)
        XCTAssertEqual(archived.ownHead, head + 1)
    }

    func testStopWaitsForAHeldCommandAndAStartOpensAFreshGenerationWithoutOverlap() async throws {
        let (a, b) = try await completedPair()
        await a.stop()
        let journal = try store(b)
        let url = journal.url
        let gate = held(journal, "submit")
        let next = captured["b", default: 0] + 1
        captured["b"] = next
        let submitter = Task { try await journal.submit([HostMutation(id: HostMutationID(UUID()), payload: Data("held".utf8))], capturedThrough: next) }
        try await until { gate() != nil }
        HostJournalWriter.connectionsForTesting.withLock { $0.peak = $0.open[url.path] ?? 0 }
        var stopped = false
        let stopping = Task(priority: .high) {
            await b.stop()
            stopped = true
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(stopped, "stop returned while an admitted command waited")
        var revisions = 0
        let subscription = Task { for await _ in b.hostViewChanges() { revisions += 1 } }
        gate()?.resume()
        await stopping.value
        let submitted = try await submitter.value.count
        XCTAssertEqual(submitted, 1)
        XCTAssertTrue(journal.isClosed)
        XCTAssertNil(b.hostJournal)
        let published = revisions
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(revisions, published, "a stopped engine published")
        subscription.cancel()
        XCTAssertEqual(HostJournalWriter.connectionsForTesting.withLock { $0.open[url.path] ?? 0 }, 0)

        b.applicationDidBecomeActive()
        try await wait("fresh generation") { b.hostJournal != nil }
        let fresh = try store(b)
        XCTAssertNotEqual(fresh.generation, journal.generation)
        XCTAssertEqual(fresh.view.ownHead, journal.view.ownHead)
        try await submit(b, "b", ["after restart"])
        await XCTAssertThrowsErrorAsync(try await journal.submit([HostMutation(id: HostMutationID(UUID()), payload: Data())], capturedThrough: 99)) {
            XCTAssertEqual($0 as? HostJournalError, .fenced)
        }
        XCTAssertEqual(HostJournalWriter.connectionsForTesting.withLock { $0.peak }, 1, "two writers overlapped on one path")
    }

    func testAnApparentlyEmptyJournalWithAnAdmittedEnrollmentIsRetiredNotDeleted() async throws {
        let b = engine("b")
        try await wait("ready") { b.hostLifecycle == .active }
        _ = try await b.hostJournalIDForTesting(group: JournalFixture.group)
        let journal = try store(b)
        let url = journal.url
        XCTAssertEqual(journal.view.enrollment, .none)
        let gate = held(journal, "enroll")
        let enrolling = Task { try await journal.enroll() }
        try await until { gate() != nil }
        var abandoned = false
        let abandoning = Task {
            try await b.abandonHostJournalForTesting()
            abandoned = true
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(abandoned)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        gate()?.resume()
        _ = try await enrolling.value
        try await abandoning.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "an enrolled journal was deleted")
        XCTAssertEqual(try HostJournalStore.open(url).view.retirement, .orphaned)
        XCTAssertEqual(HostJournalWriter.connectionsForTesting.withLock { $0.open[url.path] ?? 0 }, 0)
    }

    func testAChunkIntakeWhoseGenerationChangedIsNotAcknowledgedAndReplays() async throws {
        let (a, b) = try await completedPair()
        await a.stop()
        await b.stop()
        let origin = Data(repeating: 0x63, count: 16)
        let run = try JournalFixture.chain(origin, count: 3)
        try await send(.records(run.map(\.bytes)), from: try XCTUnwrap(a.mlsSessionForTesting))
        let bSession = try XCTUnwrap(b.mlsSessionForTesting)
        _ = try await bSession.synchronize()
        let inbox = try await bSession.inbox().count
        XCTAssertGreaterThan(inbox, 0)
        b.chunkIntakeHookForTesting = {
            b.chunkIntakeHookForTesting = nil
            try? await b.replaceHostJournalGenerationForTesting()
        }
        do {
            try await b.drainInboxForTesting()
            XCTFail("a chunk was acknowledged after its generation changed")
        } catch {}
        let remaining = try await bSession.inbox().count
        XCTAssertEqual(remaining, inbox, "the inbox was acknowledged")
        let replaced = try store(b)
        XCTAssertEqual(replaced.receivedVector[origin], 3, "the committed intake was lost")
        try await b.drainInboxForTesting()
        let drained = try await bSession.inbox().count
        XCTAssertEqual(drained, 0)
        XCTAssertEqual(try store(b).view.recordCount, replaced.view.recordCount, "the replay wrote again")
    }

    func testAReplySelectionIsDiscardedWhenTheCheckpointChangesWhileItIsRead() async throws {
        let (a, b) = try await completedPair()
        await a.stop()
        await b.stop()
        try await send(
            try HostJournalMessage(control: .hello(vector: ReplicaVersionVector(), provider: nil)),
            from: try XCTUnwrap(b.mlsSessionForTesting)
        )
        _ = try await XCTUnwrapAsync(a.mlsSessionForTesting).synchronize()
        try await a.drainInboxForTesting()
        XCTAssertNotNil(a.replyObligationForTesting)
        let journal = try store(a)
        var reads = 0
        journal.executionGateForTesting = { name in
            guard name == "reply" else { return }
            reads += 1
            if reads == 1 {
                try? a.markProvisionalForTesting(Data(repeating: 0xE1, count: 32), deadline: .distantFuture)
            }
        }
        var sends = 0
        a.replyBatchHookForTesting = { sends += 1 }
        try await a.sendRepliesForTesting()
        journal.executionGateForTesting = nil
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(reads, 3, "a selection read across a checkpoint change was used")
        XCTAssertNil(a.replyObligationForTesting)
    }

    func testOngoingSubmissionsCannotKeepTheUploadLoopRunning() async throws {
        let (a, b) = try await completedPair()
        await a.stop()
        await b.stop()
        try await submit(a, "a", ["pending upload"])
        let journal = try store(a)
        var reads = 0
        journal.executionGateForTesting = { name in
            guard name == "upload" else { return }
            reads += 1
            guard reads < 20 else { return }
            Task { _ = try? await self.submit(a, "a", ["during upload \(reads)"]) }
        }
        try await a.uploadLocalOperationsForTesting()
        journal.executionGateForTesting = nil
        XCTAssertLessThan(reads, 20, "the upload loop chased ongoing submissions")
    }

    func testAPausedResultKeepsAProviderFromChoosingACut() async throws {
        let (a, b) = try await completedPair()
        await a.stop()
        await b.stop()
        try await send(
            try HostJournalMessage(control: .hello(vector: ReplicaVersionVector(), provider: try await fingerprint(a))),
            from: try XCTUnwrap(b.mlsSessionForTesting)
        )
        _ = try await XCTUnwrapAsync(a.mlsSessionForTesting).synchronize()
        try await a.drainInboxForTesting()
        XCTAssertNotNil(a.replyObligationForTesting?.bootstrap?.first)
        XCTAssertNil(a.replyObligationForTesting?.bootstrap?.first?.cut)
        let journal = try store(a)
        var gate: CheckedContinuation<Void, Never>?
        journal.deliveryGateForTesting = { name in
            if name == "incoming" { await withCheckedContinuation { gate = $0 } }
        }
        let reading = Task { try await journal.incoming(after: nil, limit: 1) }
        try await until { gate != nil }
        let replying = Task { try await a.sendRepliesForTesting() }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(a.replyObligationForTesting?.bootstrap?.first?.cut, "a cut was chosen while a result was unadopted")
        journal.deliveryGateForTesting = nil
        gate?.resume()
        _ = try await reading.value
        try await replying.value
        try await a.sendRepliesForTesting()
        XCTAssertNil(a.replyObligationForTesting?.bootstrap, "the settled provider did not certify")
    }

    func testAPausedResultIsNeitherQuiescentNorSettled() async throws {
        let (a, _) = try await completedPair()
        try await wait("quiescent") { a.hostView?.isQuiescent == true }
        let journal = try store(a)
        var gate: CheckedContinuation<Void, Never>?
        journal.deliveryGateForTesting = { name in
            if name == "incoming" { await withCheckedContinuation { gate = $0 } }
        }
        let reading = Task { try await journal.incoming(after: nil, limit: 1) }
        try await until { gate != nil }
        XCTAssertEqual(a.hostView?.journalSettled, false)
        XCTAssertEqual(a.hostView?.isQuiescent, false, "a paused result was reported quiescent")
        journal.deliveryGateForTesting = nil
        gate?.resume()
        _ = try await reading.value
        try await wait("quiescent again") { a.hostView?.isQuiescent == true }
    }
}

private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
