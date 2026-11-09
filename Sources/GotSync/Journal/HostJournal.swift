import Foundation

/// The main-actor face of one journal generation. Every call takes a ticket
/// synchronously, then runs on the generation's writer strictly in ticket
/// order. A caller sees its outcome only after the snapshot the command left
/// is adopted, and an admitted command runs to its outcome even when its
/// caller is cancelled. `view` and the origin inventory are read from the
/// adopted snapshot without touching the file.
@MainActor
final class HostJournal {
    enum Admission {
        /// Host enrollment, submission, application and readiness.
        case host
        /// Engine intake, proofs, promotion, metadata and reads.
        case engine
        /// Retirement and the handoff proof, still allowed while closing.
        case handoff
        /// The writer fence and the connection close.
        case `internal`
    }

    enum Fence: Int, Comparable {
        case open
        /// Host calls are refused.
        case host
        /// Only the handoff remains.
        case closing
        /// The connection is closed.
        case closed

        static func < (lhs: Fence, rhs: Fence) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let url: URL
    let limits: HostJournalLimits
    let generation: UUID
    private let writer: HostJournalWriter
    private(set) var snapshot: HostJournalSnapshot
    private(set) var fence = Fence.open
    /// The last ticket issued and the last whose outcome was delivered.
    private(set) var admitted: UInt64 = 0
    private(set) var settled: UInt64 = 0
    private var closingCutoff: UInt64?
    private var waiters: [UInt64: @Sendable () async -> Void] = [:]
    private var tail: (@Sendable () async -> Void)?
    private var intakeTickets: Set<UInt64> = []
    /// The enrollment a resume on this generation confirmed; a later
    /// generation of the same file in this process inherits it.
    private(set) var resumedEnrollment: Data?
    /// Called when a snapshot is adopted and whenever the journal turns
    /// busy or settled.
    var changed: (@MainActor () -> Void)?
    var faultHookForTesting: (@Sendable (HostJournalCommitPoint) throws -> Void)?
    /// Awaited before a command runs on the writer, for tests that hold it.
    var executionGateForTesting: (@MainActor (String) async -> Void)?
    /// Awaited after a command ran and before its outcome is adopted.
    var deliveryGateForTesting: (@MainActor (String) async -> Void)?
    /// Called with the command name whenever its snapshot is adopted.
    var adoptionHookForTesting: (@MainActor (String) -> Void)?
    /// Receives the main-actor duration of each command's admission and
    /// of its settlement, for segment measurements.
    var segmentHookForTesting: (@MainActor (String, Duration) -> Void)?

    var view: HostJournalCoreView { snapshot.view }
    var hasPromotable: Bool { snapshot.hasPromotable }
    var origins: [Data] { snapshot.origins }
    var receivedVector: [Data: UInt64] { snapshot.received }
    /// No accepted command waits for its outcome.
    var isSettled: Bool { settled == admitted }
    /// An accepted intake, which may add origins, has no outcome yet.
    var isIntakeOutstanding: Bool { !intakeTickets.isEmpty }
    var isClosed: Bool { fence == .closed }

    private init(url: URL, limits: HostJournalLimits, writer: HostJournalWriter, snapshot: HostJournalSnapshot) {
        self.url = url
        self.limits = limits
        self.writer = writer
        self.snapshot = snapshot
        generation = snapshot.generation
    }

    static func create(
        in directory: URL, group: Data, founder: Bool = false, limits: HostJournalLimits = .standard
    ) async throws -> HostJournal {
        let writer = HostJournalWriter()
        let snapshot = try await writer.create(in: directory, group: group, founder: founder, limits: limits)
        let url = HostJournalStore.fileURL(in: directory, journalID: snapshot.view.journalID)
        return HostJournal(url: url, limits: limits, writer: writer, snapshot: snapshot)
    }

    /// Validates `url` and binds it on a new writer. A file that changed or
    /// was busy after validation is validated again after a short pause,
    /// three times at most. `prepared` runs between validation and binding.
    static func open(
        _ url: URL, limits: HostJournalLimits = .standard, resumedEnrollment: Data? = nil,
        prepared: (@MainActor (URL) async -> Void)? = nil
    ) async throws -> HostJournal {
        let writer = HostJournalWriter()
        for delay: UInt64 in [0, 50, 100, 200] {
            if delay > 0 {
                try await Task.sleep(nanoseconds: delay * 1_000_000)
            }
            let cancellation = HostJournalCancellation()
            let validated = try await withTaskCancellationHandler {
                try await writer.prepare(url, cancellation: cancellation)
            } onCancel: {
                cancellation.cancel()
            }
            try Task.checkCancellation()
            await prepared?(url)
            try Task.checkCancellation()
            if let snapshot = try await writer.install(validated, limits: limits, resumedEnrollment: resumedEnrollment) {
                let journal = HostJournal(url: url, limits: limits, writer: writer, snapshot: snapshot)
                journal.resumedEnrollment = resumedEnrollment
                return journal
            }
        }
        throw HostJournalError.storeUnreadable("changed or contended while opening")
    }

    // MARK: - Host calls

    func enroll() async throws -> HostJournalProvenance {
        resumedEnrollment = nil
        return try await perform("enroll", .host) { try $0.enroll() }
    }

    func resume(_ stored: HostJournalProvenance) async throws -> HostJournalProvenance {
        let confirmed = try await perform("resume", .host) { try $0.resume(stored) }
        resumedEnrollment = confirmed.enrollmentID
        return confirmed
    }

    func submit(_ batch: [HostJournalMutation], capturedThrough: UInt64) async throws -> [JournalRecordID] {
        try await perform("submit", .host) { try $0.submit(batch, capturedThrough: capturedThrough) }
    }

    func incoming(after position: UInt64, limit: Int) async throws -> [HostJournalIncoming] {
        try await perform("incoming", .host) { try $0.incoming(after: position, limit: limit) }
    }

    func markApplied(through position: UInt64) async throws {
        try await perform("markApplied", .host) { try $0.markApplied(through: position) }
    }

    func declareReady(capturedThrough: UInt64) async throws {
        try await perform("declareReady", .host) { try $0.declareReady(capturedThrough: capturedThrough) }
    }

    // MARK: - Engine calls

    /// Starts a window proof that replaces any earlier one.
    func beginProof(_ arrivals: [HostJournalArrival]) async throws -> UUID {
        try await perform("beginProof", .engine) { try $0.beginActiveProof(arrivals) }
    }

    func extendProof(_ id: UUID) async throws -> Bool {
        try await perform("extendProof", .engine) { try $0.extendActiveProof(id) }
    }

    /// Takes proof `id`'s arrivals `start..<start + count`, and reports
    /// whether pending records grew.
    func intake(next count: Int, ofProof id: UUID, from start: Int) async throws -> (intake: HostJournalIntake, pendingGrew: Bool) {
        try await perform("intake", .engine, intake: true) { store in
            let before = store.view.pendingCount
            let result = try store.intake(next: count, ofActive: id, from: start)
            return (result, store.view.pendingCount > before)
        }
    }

    @discardableResult
    func promote() async throws -> Int {
        try await perform("promote", .engine) { try $0.promote() }
    }

    func markEstablished() async throws {
        try await perform("markEstablished", .engine) { try $0.markEstablished() }
    }

    func recordCompletionTarget(provider: Data, through target: [Data: UInt64]) async throws {
        try await perform("recordCompletionTarget", .engine) { _ = try $0.recordCompletionTarget(provider: provider, through: target) }
    }

    func setHistoryProvider(_ member: Data) async throws {
        try await perform("setHistoryProvider", .engine) { try $0.setHistoryProvider(member) }
    }

    func enterControlRepair() async throws {
        try await perform("enterControlRepair", .engine) { try $0.enterControlRepair() }
    }

    /// Runs a read on the writer in ticket order.
    func read<T: Sendable>(_ name: String, _ body: @escaping @Sendable (HostJournalStore) throws -> T) async throws -> T {
        try await perform(name, .engine, body)
    }

    // MARK: - Handoff

    func retire(_ reason: HostJournalRetirement, heldInbox: [HostJournalHeldMessage]) async throws {
        resumedEnrollment = nil
        try await perform("retire", .handoff) { try $0.retire(reason, heldInbox: heldInbox) }
    }

    func holdsInbox(_ messages: [HostJournalHeldMessage]) async throws -> Bool {
        try await perform("holdsInbox", .handoff) { try $0.holdsInbox(messages) }
    }

    // MARK: - Fences

    /// Refuses host calls from now on; earlier ones still run, and the
    /// writer refuses host work after them.
    func fenceHost() {
        guard fence == .open else { return }
        fence = .host
        _ = try? enqueue("fence", .internal) { await $0.execute(hook: nil) { $0.fenceHost() } }
    }

    /// Refuses everything but the handoff from now on and returns the
    /// cutoff: the last ticket accepted before closing began.
    @discardableResult
    func beginClosing() -> UInt64 {
        fenceHost()
        if fence < .closing {
            fence = .closing
            closingCutoff = admitted
        }
        return closingCutoff ?? admitted
    }

    /// Returns once every command through `ticket` has its outcome adopted and delivered.
    func drain(through ticket: UInt64) async {
        guard settled < ticket, let wait = waiters[ticket] else { return }
        await wait()
    }

    func drainClosing() async {
        await drain(through: beginClosing())
    }

    /// Fences everything, waits for every accepted command and closes the
    /// connection. Returns only once the connection is closed.
    func shutdown() async {
        beginClosing()
        if fence < .closed {
            fence = .closed
            _ = try? enqueue("close", .internal) { writer in
                await writer.close()
                return HostJournalOutcome(result: .success(()), snapshot: nil)
            }
        }
        await drain(through: admitted)
    }

    // MARK: - Ordering

    private func admit(_ admission: Admission) throws -> UInt64 {
        switch admission {
        case .host:
            guard fence == .open else { throw view.isRetired ? HostJournalError.retired : HostJournalError.fenced }
        case .engine:
            guard fence < .closing else { throw HostJournalError.fenced }
        case .handoff:
            guard fence < .closed else { throw HostJournalError.fenced }
        case .internal:
            break
        }
        if admission != .internal, Task.isCancelled {
            throw CancellationError()
        }
        let wasSettled = isSettled
        admitted += 1
        if wasSettled {
            changed?()
        }
        return admitted
    }

    private func perform<T: Sendable>(
        _ name: String, _ admission: Admission, intake: Bool = false,
        _ body: @escaping @Sendable (HostJournalStore) throws -> T
    ) async throws -> T {
        let start = segmentHookForTesting == nil ? nil : ContinuousClock.now
        let hook = faultHookForTesting
        let task = try enqueue(name, admission, intake: intake) { await $0.execute(hook: hook, body) }
        if let start {
            segmentHookForTesting?("\(name).admit", ContinuousClock.now - start)
        }
        return try await task.value.get()
    }

    /// Issues the next ticket and chains its command after the previous
    /// one. The command runs, is adopted and settles whether or not anyone
    /// awaits the returned task.
    @discardableResult
    private func enqueue<T: Sendable>(
        _ name: String, _ admission: Admission, intake: Bool = false,
        _ operation: @escaping @Sendable (HostJournalWriter) async -> HostJournalOutcome<T>
    ) throws -> Task<Result<T, any Error>, Never> {
        let ticket = try admit(admission)
        if intake {
            intakeTickets.insert(ticket)
        }
        let previous = tail
        let writer = writer
        let task = Task<Result<T, any Error>, Never> { @MainActor in
            await previous?()
            await self.executionGateForTesting?(name)
            let outcome = await operation(writer)
            await self.deliveryGateForTesting?(name)
            let start = self.segmentHookForTesting == nil ? nil : ContinuousClock.now
            self.settle(ticket, name, outcome.snapshot)
            if let start {
                self.segmentHookForTesting?("\(name).settle", ContinuousClock.now - start)
            }
            return outcome.result
        }
        let wait: @Sendable () async -> Void = { _ = await task.value }
        tail = wait
        waiters[ticket] = wait
        return task
    }

    private func settle(_ ticket: UInt64, _ name: String, _ committed: HostJournalSnapshot?) {
        precondition(ticket == settled + 1, "journal commands settled out of order")
        var adopted = false
        if let committed, committed.generation == generation, committed.commitSequence > snapshot.commitSequence {
            snapshot = committed
            adopted = true
        }
        settled = ticket
        waiters[ticket] = nil
        intakeTickets.remove(ticket)
        if adopted {
            adoptionHookForTesting?(name)
        }
        if adopted || isSettled {
            changed?()
        }
    }
}
