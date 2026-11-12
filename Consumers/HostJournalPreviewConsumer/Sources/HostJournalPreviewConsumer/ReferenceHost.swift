import Foundation
import os
@_spi(HostJournalPreview) import GotSync

@_spi(HostJournalPreview) @MainActor
public protocol ReferenceHostInbox: AnyObject {
    func incoming(after position: JournalPosition?, limit: Int) async throws -> [IncomingRecord]
    func markApplied(through position: JournalPosition) async throws
}

@_spi(HostJournalPreview) extension HostJournal: ReferenceHostInbox {}

/// A minimal host of the preview journal: registers, a
/// capture counter, an outbox and the stored provenance, saved as one JSON
/// file. It follows the host obligations: capture and outbox are saved
/// before submission, outbox rows leave only after their call's accepted
/// result, and the business state is saved before `markApplied`.
@_spi(HostJournalPreview) @MainActor
public final class ReferenceHost {
    public struct Register: Codable, Equatable, Sendable {
        public let name: String
        public let value: String
    }

    public struct Pending: Codable, Equatable, Sendable {
        public let id: HostMutationID
        public let payload: Data
    }

    public struct State: Codable, Equatable, Sendable {
        public var registers: [String: String] = [:]
        public var capturedThrough: UInt64 = 0
        public var outbox: [Pending] = []
        public var provenance: HostProvenance?
        public var appliedThrough: JournalPosition?
    }

    public let url: URL
    public private(set) var state: State

    public init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
        } else {
            state = State()
        }
    }

    /// Sets a register locally and queues it, saving both before anything
    /// is submitted.
    public func capture(_ name: String, _ value: String) throws {
        guard state.capturedThrough < UInt64(Int64.max) else { throw HostJournalError.invalidArgument }
        var next = state
        next.registers[name] = value
        next.capturedThrough += 1
        let payload = try JSONEncoder().encode(Register(name: name, value: value))
        next.outbox.append(Pending(id: HostMutationID(UUID()), payload: payload))
        try save(next)
    }

    /// Enrolls once, then resumes with the saved provenance on every launch.
    public func enrollOrResume(_ journal: HostJournal) async throws {
        if state.provenance == nil {
            let pending = try await journal.enroll()
            var next = state
            next.provenance = pending
            try save(next)
        }
        guard let stored = state.provenance else { return }
        let confirmed = try await journal.resume(HostProvenance(
            journalID: stored.journalID, enrollmentID: stored.enrollmentID,
            appliedThrough: state.appliedThrough, capturedThrough: state.capturedThrough
        ))
        var next = state
        next.provenance = confirmed
        try save(next)
    }

    /// Submits the outbox in calls of at most `maxBytes` encoded bytes and
    /// removes each call's rows only after its accepted result.
    public func submitOutbox(_ journal: HostJournal, maxBytes: Int = 262_144) async throws {
        while !state.outbox.isEmpty {
            var chunk: [Pending] = []
            var bytes = 0
            for pending in state.outbox {
                guard chunk.count < 256 else { break }
                let size = 64 + pending.payload.count
                guard chunk.isEmpty || bytes + size <= maxBytes else { break }
                chunk.append(pending)
                bytes += size
            }
            _ = try await journal.submit(chunk.map { HostMutation(id: $0.id, payload: $0.payload) }, capturedThrough: state.capturedThrough)
            let accepted = Set(chunk.map(\.id))
            var next = state
            next.outbox.removeAll { accepted.contains($0.id) }
            try save(next)
        }
    }

    /// Declares readiness only when no captured row is still unsent.
    @discardableResult
    public func declareReadyIfSubmitted(_ journal: HostJournal) async throws -> Bool {
        guard state.outbox.isEmpty else { return false }
        try await journal.declareReady(capturedThrough: state.capturedThrough)
        return true
    }

    /// Applies every delivered remote record, saving the business state
    /// before acknowledging it. Returns how many were applied.
    @discardableResult
    public func applyIncoming(_ journal: any ReferenceHostInbox) async throws -> Int {
        if let position = state.appliedThrough {
            try await journal.markApplied(through: position)
        }
        var applied = 0
        while true {
            let received = try await journal.incoming(after: state.appliedThrough, limit: 64)
            let batch = received.filter { record in
                state.appliedThrough.map { record.position > $0 } ?? true
            }
            guard let last = batch.last else { return applied }
            var next = state
            for record in batch {
                let register = try JSONDecoder().decode(Register.self, from: record.payload)
                next.registers[register.name] = register.value
            }
            next.appliedThrough = last.position
            try save(next)
            try await journal.markApplied(through: last.position)
            applied += batch.count
        }
    }

    private func save(_ next: State) throws {
        try JSONEncoder().encode(next).write(to: url, options: .atomic)
        state = next
    }
}

/// A secret store kept in memory, for tests and previews.
public final class MemorySecrets: SecretStore {
    private let values = OSAllocatedUnfairLock<[String: Data]>(initialState: [:])

    public init() {}

    public func read(account: String) throws -> Data? { values.withLock { $0[account] } }
    public func write(_ data: Data, account: String) throws { values.withLock { $0[account] = data } }
    public func delete(account: String) throws { _ = values.withLock { $0.removeValue(forKey: account) } }
}
