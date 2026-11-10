import Foundation
import os

/// What a writer command returned, with the snapshot of the last commit on
/// its connection; nil once the connection is closed.
struct HostJournalOutcome<T: Sendable>: Sendable {
    let result: Result<T, any Error>
    let snapshot: HostJournalSnapshot?
}

/// The only owner of one journal generation's connection. Commands run one
/// at a time on the writer's own serial queue, never on the main actor, and
/// each runs its checks and its transaction without suspending.
actor HostJournalWriter {
    /// Writer connections open per journal path, and the most ever open on
    /// one path at once, for tests of same-path overlap.
    nonisolated static let connectionsForTesting = OSAllocatedUnfairLock(initialState: (open: [String: Int](), peak: 0))

    private let queue = DispatchSerialQueue(label: "GotSync.HostJournalWriter", qos: .userInitiated)
    private var store: HostJournalStore? {
        didSet {
            if let openPath { Self.count(openPath, -1) }
            openPath = store?.url.path
            if let openPath { Self.count(openPath, 1) }
        }
    }
    private var openPath: String?

    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    func create(in directory: URL, group: Data, founder: Bool, limits: HostJournalLimits) throws -> HostJournalSnapshot {
        precondition(store == nil)
        let created = try HostJournalStore.create(in: directory, group: group, founder: founder, limits: limits)
        store = created
        return created.snapshot
    }

    func prepare(_ url: URL, cancellation: HostJournalCancellation) throws -> PreparedHostJournal {
        try HostJournalPreparation.prepare(url, cancellation: cancellation)
    }

    /// Binds the prepared file; nil when it changed since `prepare` or is busy.
    /// `resumedEnrollment` is a resume this process confirmed on an earlier
    /// connection to the same file.
    func install(
        _ prepared: PreparedHostJournal, limits: HostJournalLimits, resumedEnrollment: Data? = nil
    ) throws -> HostJournalSnapshot? {
        precondition(store == nil)
        guard let installed = try HostJournalStore.install(prepared, limits: limits) else { return nil }
        if let resumedEnrollment {
            installed.adoptResumption(enrollmentID: resumedEnrollment)
        }
        store = installed
        return installed.snapshot
    }

    func execute<T: Sendable>(
        hook: (@Sendable (HostJournalCommitPoint) throws -> Void)?, _ body: @Sendable (HostJournalStore) throws -> T
    ) -> HostJournalOutcome<T> {
        guard let store else {
            return HostJournalOutcome(result: .failure(JournalStoreError.fenced), snapshot: nil)
        }
        store.faultHookForTesting = hook
        defer { store.faultHookForTesting = nil }
        return HostJournalOutcome(result: Result { try body(store) }, snapshot: store.snapshot)
    }

    /// Closes the connection; every later command fails with `fenced`.
    func close() {
        store = nil
    }

    deinit {
        if let openPath { Self.count(openPath, -1) }
    }

    private static func count(_ path: String, _ delta: Int) {
        connectionsForTesting.withLock { state in
            state.open[path, default: 0] += delta
            state.peak = max(state.peak, state.open[path] ?? 0)
        }
    }
}
