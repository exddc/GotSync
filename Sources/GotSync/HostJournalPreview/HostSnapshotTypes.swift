import Foundation

/// The compact-state format a snapshot host exports and installs. A
/// joiner installs only an offer of exactly its own schema.
public struct HostSnapshotSchema: Hashable, Sendable {
    public let label: String
    public let version: UInt16

    /// `label` uses lowercase ASCII letters, digits, `.` and `-`, starting
    /// with a letter; `version` is positive.
    public init(label: String, version: UInt16) throws {
        guard version > 0, HostSnapshotSchemaName.isLabel(label) else { throw HostJournalError.invalidArgument }
        self.label = label
        self.version = version
    }

    var name: String { HostSnapshotSchemaName.make(label: label, version: version) }
}

/// Identifies one exported snapshot; an install is idempotent per ID.
public struct HostSnapshotID: Hashable, Sendable {
    public let uuid: UUID

    init(bytes: Data) {
        uuid = HostMutationID(bytes: bytes).uuid
    }

    var bytes: Data { HostMutationID(uuid).bytes }
}

public enum HostSnapshotLimits {
    /// The largest export a provider offers. A larger one is refused after
    /// Add and the joiner continues on full history.
    public static let maxBytes = HostSnapshotBounds.maxBytes
}

/// What a provider's export must reflect: exactly the remote records the
/// host applied through `appliedThrough`, and every record it submitted.
/// Read the compact state in one store transaction whose application
/// marker equals `appliedThrough` and whose capture counter equals
/// `capturedThrough`; exclude captured mutations not yet submitted.
public struct HostSnapshotCut: Sendable {
    public let id: HostSnapshotID
    public let journalID: Data
    public let appliedThrough: JournalPosition?
    public let capturedThrough: UInt64
    /// Write the snapshot here. The library owns the file afterwards.
    public let destination: URL
}

/// The markers the export read, in the same transaction as its content.
public struct HostSnapshotExport: Sendable {
    public let appliedThrough: JournalPosition?
    public let capturedThrough: UInt64

    public init(appliedThrough: JournalPosition?, capturedThrough: UInt64) {
        self.appliedThrough = appliedThrough
        self.capturedThrough = capturedThrough
    }
}

public enum HostSnapshotExportResult: Sendable {
    case exported(HostSnapshotExport)
    /// The store is not at the cut, for example with unsubmitted outbox
    /// rows; the library reads a fresh cut and asks again.
    case notAtCut
    /// The host's encoded compact state exceeds `HostSnapshotLimits.maxBytes`.
    case tooLarge
}

/// A verified snapshot to merge into the host's store.
public struct HostSnapshotInstall: Sendable {
    public let id: HostSnapshotID
    public let schema: HostSnapshotSchema
    public let journalID: Data
    /// The member that exported it, for provenance.
    public let provider: Data
    /// Save this recipient-local application mark atomically with the merged
    /// state and snapshot ID before returning `installed`.
    public let appliedThrough: JournalPosition?
    /// Library-owned and read-only; gone after the install returns.
    public let file: URL
    public let length: UInt64
    public let contentHash: Data
    /// The highest sequence the snapshot reflects for each origin. Records
    /// up to these are never delivered by `incoming` after the install.
    public let coverage: [Data: UInt64]
}

public enum HostSnapshotInstallOutcome: Sendable {
    /// Merged and saved in one transaction with the snapshot ID, or already
    /// installed earlier.
    case installed
    /// Not installable, such as undecodable content; the store is unchanged
    /// and the joiner continues on full history.
    case refused
}

/// The app's snapshot host. The hooks run off the main actor and are
/// cancelled with the engine's work; each must be idempotent.
public struct HostSnapshotHooks: Sendable {
    public let schema: HostSnapshotSchema
    public let export: @Sendable (HostSnapshotCut) async throws -> HostSnapshotExportResult
    /// Merges, never replaces: local data, unsent outbox rows and drafts stay.
    /// Throwing retries later.
    public let install: @Sendable (HostSnapshotInstall) async throws -> HostSnapshotInstallOutcome
    /// The library released its copy; the bootstrap continues on the tail.
    public let completed: @Sendable (HostSnapshotID) async -> Void

    public init(
        schema: HostSnapshotSchema,
        export: @escaping @Sendable (HostSnapshotCut) async throws -> HostSnapshotExportResult,
        install: @escaping @Sendable (HostSnapshotInstall) async throws -> HostSnapshotInstallOutcome,
        completed: @escaping @Sendable (HostSnapshotID) async -> Void
    ) {
        self.schema = schema
        self.export = export
        self.install = install
        self.completed = completed
    }
}

public enum HostSnapshotRefusal: Equatable, Sendable {
    case notOffered
    case schemaMismatch
    case providerNotRegistered
    case tooLarge
    case notAtCut
    case exportFailed
    case transferFailed
    case malformedOffer
    case anchorMismatch
    case contentUnavailable
    case contentRejected
    case contentMismatch
    case hostRefused
    case declinedByHost
    case noProvider
    case corroborationMismatch

    init(_ reason: HostSnapshotRefusalReason) {
        switch reason {
        case .notOffered: self = .notOffered
        case .schemaMismatch: self = .schemaMismatch
        case .notRegistered: self = .providerNotRegistered
        case .tooLarge: self = .tooLarge
        case .notAtCut: self = .notAtCut
        case .exportFailed: self = .exportFailed
        case .transferFailed: self = .transferFailed
        case .malformedOffer: self = .malformedOffer
        case .anchorMismatch: self = .anchorMismatch
        case .contentUnavailable: self = .contentUnavailable
        case .contentRejected: self = .contentRejected
        case .contentMismatch: self = .contentMismatch
        case .hostRefused: self = .hostRefused
        case .declinedByHost: self = .declinedByHost
        case .noProvider: self = .noProvider
        case .corroborationMismatch: self = .corroborationMismatch
        }
    }
}

/// Where a joiner's snapshot bootstrap stands. Every case from `requested`
/// to `installing` holds delivery: `incoming` returns nothing and
/// `markApplied` throws `bootstrapPending`.
public enum HostSnapshotBootstrap: Equatable, Sendable {
    /// No snapshot was requested; every record is delivered.
    case fullHistory
    case requested
    case offered(HostSnapshotID)
    case fetching(HostSnapshotID)
    case assembled(HostSnapshotID)
    case installing(HostSnapshotID)
    /// Covered records are skipped; the tail is delivered.
    case installed(HostSnapshotID)
    case completed(HostSnapshotID)
    /// Nothing was installed. Full-history groups deliver every record;
    /// a compacted floor remains held until its checkpoint is installed.
    case refused(HostSnapshotRefusal)

    init(_ state: HostJournalBootstrapState?) {
        guard let state else {
            self = .fullHistory
            return
        }
        let id = state.offer.map { HostSnapshotID(bytes: $0.id) }
        switch (state.phase, id) {
        case (.requested, _): self = .requested
        case (.offered, let id?): self = .offered(id)
        case (.fetching, let id?): self = .fetching(id)
        case (.assembled, let id?): self = .assembled(id)
        case (.installing, let id?): self = .installing(id)
        case (.installed, let id?): self = .installed(id)
        case (.completed, let id?): self = .completed(id)
        case (.refused, _): self = .refused(HostSnapshotRefusal(state.refusal ?? .notOffered))
        case (_, nil): self = .requested
        }
    }

    public var holdsDelivery: Bool {
        switch self {
        case .requested, .offered, .fetching, .assembled, .installing: true
        case .fullHistory, .installed, .completed, .refused: false
        }
    }
}
