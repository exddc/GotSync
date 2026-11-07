import CryptoKit
import Foundation
import GotSyncMLS

struct SecretStoreMLSStateKey: MLSStateKeyProvider {
    static let account = "mls-state-key-v2"

    let store: any SecretStore
    var account = Self.account

    func key() throws -> SymmetricKey {
        if let existing = try store.read(account: account) {
            guard existing.count == 32 else { throw MLSStoreError.unreadable }
            return SymmetricKey(data: existing)
        }
        let generated = try Data.secureRandom(count: 32)
        try store.write(generated, account: account, accessibility: .afterFirstUnlockThisDeviceOnly)
        return SymmetricKey(data: generated)
    }
}

struct MLSPublishedKeyPackage: Equatable, Sendable {
    let reference: Data
    let fingerprint: Data
}

enum MLSSubmission: Equatable, Sendable {
    case accepted(cursor: UInt64)
    case superseded
}

enum MLSSessionError: Error, Equatable {
    case notInGroup
    case groupMismatch
    case removed
    case unresolvedConflict
    case profileMismatch
}

actor MLSSession {
    static let directoryName = "mls-v2"
    private static let maximumSubmitAttempts = 8

    let client: MLSClient
    private let transport: any MLSRelayTransport
    private let fetchLimit: Int
    private var acknowledged: UInt64 = 0
    private var keepsInbox = true
    private var tail: Task<Void, Never>?

    init(
        directory: URL,
        deviceID: Data,
        secretStore: any SecretStore,
        keyAccount: String = SecretStoreMLSStateKey.account,
        transport: any MLSRelayTransport,
        fetchLimit: Int = 8
    ) throws {
        precondition(1...MLSRelayLimits.fetchCount ~= fetchLimit)
        client = try MLSClient(
            directory: directory,
            deviceID: deviceID,
            stateKey: SecretStoreMLSStateKey(store: secretStore, account: keyAccount)
        )
        self.transport = transport
        self.fetchLimit = fetchLimit
    }

    static func directory(in storageDirectory: URL) -> URL {
        storageDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func erase(
        directory: URL,
        secretStore: any SecretStore,
        keyAccount: String = SecretStoreMLSStateKey.account
    ) throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try secretStore.delete(account: keyAccount)
    }

    func fingerprint() async throws -> Data { try await client.fingerprint() }
    func group() async throws -> Data? { try await client.group() }
    func epoch() async throws -> UInt64 { try await client.epoch() }
    func cursor() async throws -> UInt64 { try await client.cursor() }
    func members() async throws -> [MLSMember] { try await client.members() }
    func groupProfile() async throws -> Data? { try await client.groupProfile() }
    func spokenMembers() async throws -> Set<Data> { try await client.spokenMembers() }
    func isRemoved() async throws -> Bool { try await client.isRemoved() }
    func pendingDelivery() async throws -> MLSDelivery? { try await client.pendingDelivery() }
    func rejectedCommit() async throws -> MLSDelivery? { try await client.rejectedCommit() }
    func inbox() async throws -> [MLSInboxMessage] { try await client.inbox() }
    func rejectedApplicationCursors() async throws -> [UInt64] { try await client.rejectedApplicationCursors() }

    /// Log cursors where this member's recent tracked messages with
    /// `plaintext` landed.
    func sentCursors(of plaintext: Data) async throws -> [UInt64] {
        let digest = Data(SHA256.hash(data: plaintext))
        return try await client.sentMessages().filter { $0.digest == digest }.map(\.cursor)
    }
    func departures() async throws -> [Data] { try await client.departures() }

    func acknowledgeInbox(through cursor: UInt64) async throws {
        try await client.acknowledgeInbox(through: cursor)
    }

    func publishKeyPackage(pairingToken: Data, profile: Data?) async throws -> MLSPublishedKeyPackage {
        guard pairingToken.count == 32 else { throw MLSRelayError.invalidRequest }
        return try await exclusive { session in
            let identity = try await session.client.joiningIdentity(profile: profile)
            let reference = try await session.transport.publishKeyPackage(
                identity.keyPackage,
                authorization: session.client.transportAuthorization(),
                pairingHash: Data(SHA256.hash(data: pairingToken))
            )
            return MLSPublishedKeyPackage(reference: reference, fingerprint: identity.fingerprint)
        }
    }

    func fetchKeyPackage(reference: Data, pairingToken: Data) async throws -> Data? {
        try await transport.fetchKeyPackage(reference: reference, pairingToken: pairingToken)
    }

    /// Creates the group with `profile`, or registers it again with the
    /// relay when this member already holds it with the same profile.
    func createGroup(_ id: Data, profile: Data?) async throws {
        guard id.count == 32 else { throw MLSRelayError.invalidRequest }
        try await exclusive { session in
            switch try await session.client.group() {
            case nil: try await session.client.createGroup(id: id, profile: profile)
            case id?: break
            default: throw MLSSessionError.groupMismatch
            }
            guard try await session.client.groupProfile() == profile else { throw MLSSessionError.profileMismatch }
            try await session.transport.createGroup(id, authorization: session.client.transportAuthorization())
        }
    }

    /// With `beforeEpoch`, the Add is prepared only while the group epoch is
    /// below it; otherwise the result is `.superseded`. The check runs in the
    /// same serialized step that prepares the commit.
    func add(
        keyPackage: Data,
        verifiedFingerprint: Data,
        reference: Data,
        beforeEpoch: UInt64? = nil
    ) async throws -> MLSSubmission {
        try await exclusive { session in
            try await session.submit { client in
                if let beforeEpoch {
                    guard try await client.epoch() < beforeEpoch else {
                        return nil
                    }
                }
                return try await client.prepareAdd(
                    keyPackage: keyPackage, verifiedFingerprint: verifiedFingerprint, reference: reference
                )
            }
        }
    }

    /// With `onlyIfSilent`, the member is kept if it has sent an
    /// authenticated application message, checked in the same serialized
    /// step that prepares the Remove.
    func remove(fingerprint: Data, onlyIfSilent: Bool = false) async throws -> MLSSubmission {
        try await exclusive { session in
            try await session.submit { client in
                let spoken = onlyIfSilent ? try await client.spokenMembers() : []
                guard try await client.members().contains(where: { $0.fingerprint == fingerprint }),
                      !spoken.contains(fingerprint)
                else {
                    return nil
                }
                return try await client.prepareRemove(fingerprint: fingerprint)
            }
        }
    }

    /// A `tracked` message is listed by `sentCursors(of:)` once it lands.
    func send(_ plaintext: Data, tracked: Bool = false) async throws -> MLSSubmission {
        try await exclusive { session in
            try await session.commitDepartures()
            return try await session.submit { try await $0.prepareMessage(plaintext, tracked: tracked) }
        }
    }

    /// Publishes a proposal removing this member and revokes its relay
    /// access. Another member commits the removal. From then on the session
    /// drops unread plaintext when its inbox is full, and a full relay log
    /// makes it catch up and acknowledge first, so neither backlog can block
    /// the leave.
    ///
    /// First, an Add still pending is delivered, because its outcome may be
    /// unknown. After reading the log, the member it added and the members in
    /// `withdrawing` are removed unless they sent an application message:
    /// only this member knows they may never have joined.
    func leave(withdrawing: [Data] = []) async throws {
        try await exclusive { session in
            session.keepsInbox = false
            guard let group = try await session.client.group() else { throw MLSSessionError.notInGroup }
            if try await session.client.isRemoved() {
                try await session.acknowledgeRemoval(group: group)
                throw MLSSessionError.removed
            }
            let authorization = try await session.client.transportAuthorization()
            try await session.client.withdrawPendingAdd()
            for _ in 0..<Self.maximumSubmitAttempts {
                if try await session.client.isRemoved() { throw MLSSessionError.removed }
                if let pending = try await session.client.pendingDelivery(), pending.kind != .proposal {
                    do {
                        _ = try await session.deliverPending()
                    } catch MLSRelayError.capacityReached {
                        _ = try await session.catchUp()
                    }
                    continue
                }
                let writer = try await session.client.withdrawnAddWriter()
                if writer != nil || !withdrawing.isEmpty, try await session.client.pendingDelivery() == nil {
                    _ = try await session.catchUp()
                    if try await session.client.isRemoved() { throw MLSSessionError.removed }
                    var removing = false
                    _ = try await session.submit { client in
                        let own = try await client.fingerprint()
                        let spoken = try await client.spokenMembers()
                        guard let target = try await client.members().first(where: {
                            $0.fingerprint != own && !spoken.contains($0.fingerprint)
                                && (withdrawing.contains($0.fingerprint) || $0.writerHash == writer)
                        }) else { return nil }
                        removing = true
                        return try await client.prepareRemove(fingerprint: target.fingerprint)
                    }
                    if removing { continue }
                    if writer != nil {
                        try await session.client.clearWithdrawnAdd()
                    }
                }
                let proposal: MLSDelivery
                if let pending = try await session.client.pendingDelivery() {
                    proposal = pending
                } else {
                    proposal = try await session.client.prepareLeave()
                }
                let result: MLSAppendResult
                do {
                    result = try await session.transport.append(proposal, authorization: authorization)
                } catch MLSRelayError.epochConflict, MLSRelayError.capacityReached {
                    _ = try await session.catchUp()
                    continue
                }
                guard case .accepted(let cursor) = result else { throw MLSRelayError.invalidResponse }
                try? await session.transport.acknowledge(group: group, through: cursor, authorization: authorization)
                return
            }
            throw MLSSessionError.unresolvedConflict
        }
    }

    func flush() async throws -> MLSSubmission? {
        try await exclusive { session in
            guard try await session.client.pendingDelivery() != nil else { return nil }
            return try await session.deliverPending()
        }
    }

    @discardableResult
    func synchronize() async throws -> Int {
        try await exclusive { session in try await session.catchUp() }
    }

    func join(group: Data, keyPackageReference: Data, verifiedInviterFingerprint: Data, profile: Data?) async throws -> Bool {
        try await exclusive { session in
            guard try await session.client.group() == nil else { throw MLSSessionError.groupMismatch }
            let authorization = try await session.client.transportAuthorization()
            var after: UInt64 = 0
            while true {
                try Task.checkCancellation()
                let entries: [MLSRelayEntry]
                do {
                    entries = try await session.transport.fetch(
                        group: group, after: after, limit: session.fetchLimit, authorization: authorization
                    )
                } catch MLSRelayError.unauthorized, MLSRelayError.historyExpired {
                    return false
                }
                guard let last = entries.last else { return false }
                if let entry = entries.first(where: {
                    $0.delivery.kind == .commit && $0.delivery.keyPackageReference == keyPackageReference
                }), let welcome = entry.delivery.welcome {
                    try await session.client.join(
                        welcome: welcome,
                        group: group,
                        verifiedInviterFingerprint: verifiedInviterFingerprint,
                        cursor: entry.cursor,
                        expectedProfile: profile
                    )
                    _ = try await session.catchUp()
                    return true
                }
                after = last.cursor
            }
        }
    }

    private func commitDepartures() async throws {
        for _ in 0..<Self.maximumSubmitAttempts {
            guard let departed = try await client.departures().first else { return }
            _ = try await submit { client in
                guard try await client.members().contains(where: { $0.fingerprint == departed }) else { return nil }
                return try await client.prepareRemove(fingerprint: departed)
            }
        }
        throw MLSSessionError.unresolvedConflict
    }

    private func submit(_ prepare: (MLSClient) async throws -> MLSDelivery?) async throws -> MLSSubmission {
        if try await client.pendingDelivery() != nil {
            _ = try await deliverPending()
        }
        guard try await prepare(client) != nil else { return .superseded }
        return try await deliverPending()
    }

    /// A pending entry leaves only on a terminal answer from the delivery
    /// store: accepted, including as a duplicate of an earlier copy, refused
    /// with a journaled `keyPackageUnavailable`, or overtaken by another
    /// commit at its epoch. Any other failure keeps it, and a later call sends
    /// the same bytes again, which the store deduplicates.
    private func deliverPending() async throws -> MLSSubmission {
        let authorization = try await client.transportAuthorization()
        for _ in 0..<Self.maximumSubmitAttempts {
            guard let pending = try await client.pendingDelivery() else { return .superseded }
            let result: MLSAppendResult
            do {
                result = try await transport.append(pending, authorization: authorization)
            } catch MLSRelayError.epochConflict {
                _ = try await catchUp()
                if try await client.isRemoved() { throw MLSSessionError.removed }
                continue
            }
            switch result {
            case .accepted(let cursor):
                do {
                    _ = try await catchUp()
                } catch MLSClientError.capacityReached where pending.kind == .application {
                    try await client.confirmAcceptedApplication(pending, cursor: cursor)
                }
                return .accepted(cursor: cursor)
            case .keyPackageUnavailable(let epoch):
                try await client.rejectAddForUnavailableKeyPackage(commit: pending.payload, rejectedEpoch: epoch)
                return .superseded
            }
        }
        throw MLSSessionError.unresolvedConflict
    }

    private func catchUp() async throws -> Int {
        guard let group = try await client.group() else { throw MLSSessionError.notInGroup }
        if try await client.isRemoved() {
            try await acknowledgeRemoval(group: group)
            return 0
        }
        let authorization = try await client.transportAuthorization()
        var processed = 0
        while true {
            try Task.checkCancellation()
            let cursor = try await client.cursor()
            if acknowledged < cursor {
                try await transport.acknowledge(group: group, through: cursor, authorization: authorization)
                acknowledged = cursor
            }
            let entries = try await transport.fetch(
                group: group, after: cursor, limit: fetchLimit, authorization: authorization
            )
            guard !entries.isEmpty else { return processed }
            for entry in entries {
                try await process(entry)
                processed += 1
                if try await client.isRemoved() {
                    try await acknowledgeRemoval(group: group)
                    return processed
                }
            }
        }
    }

    private func process(_ entry: MLSRelayEntry) async throws {
        do {
            try await client.process(entry.delivery, cursor: entry.cursor)
        } catch MLSClientError.capacityReached where !keepsInbox {
            try await client.acknowledgeInbox(through: entry.cursor)
            try await client.process(entry.delivery, cursor: entry.cursor)
        }
    }

    private func acknowledgeRemoval(group: Data) async throws {
        guard let authorization = try await client.removalAuthorization() else { return }
        do {
            try await transport.acknowledge(group: group, through: client.cursor(), authorization: authorization)
        } catch MLSRelayError.unauthorized, MLSRelayError.historyExpired {}
        try await client.confirmRemovalAcknowledged()
    }

    private func exclusive<T: Sendable>(
        _ operation: @escaping @Sendable (isolated MLSSession) async throws -> T
    ) async throws -> T {
        let previous = tail
        let task = Task {
            _ = await previous?.result
            return try await operation(self)
        }
        tail = Task { _ = await task.result }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
