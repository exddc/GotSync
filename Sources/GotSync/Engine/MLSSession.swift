import CryptoKit
import Foundation
import GotSyncMLS

struct SecretStoreMLSStateKey: MLSStateKeyProvider {
    static let account = "mls-state-key-v2"

    let store: any SecretStore

    func key() throws -> SymmetricKey {
        if let existing = try store.read(account: Self.account) {
            guard existing.count == 32 else { throw MLSStoreError.unreadable }
            return SymmetricKey(data: existing)
        }
        let generated = try Data.secureRandom(count: 32)
        try store.write(generated, account: Self.account, accessibility: .afterFirstUnlockThisDeviceOnly)
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
}

actor MLSSession {
    static let directoryName = "mls-v2"
    private static let maximumSubmitAttempts = 8

    let client: MLSClient
    private let transport: any MLSRelayTransport
    private let fetchLimit: Int
    private var acknowledged: UInt64 = 0
    private var tail: Task<Void, Never>?

    init(
        directory: URL,
        deviceID: Data,
        secretStore: any SecretStore,
        transport: any MLSRelayTransport,
        fetchLimit: Int = 8
    ) throws {
        precondition(1...MLSRelayLimits.fetchCount ~= fetchLimit)
        client = try MLSClient(
            directory: directory,
            deviceID: deviceID,
            stateKey: SecretStoreMLSStateKey(store: secretStore)
        )
        self.transport = transport
        self.fetchLimit = fetchLimit
    }

    static func directory(in storageDirectory: URL) -> URL {
        storageDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func erase(directory: URL, secretStore: any SecretStore) throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try secretStore.delete(account: SecretStoreMLSStateKey.account)
    }

    func fingerprint() async throws -> Data { try await client.fingerprint() }
    func group() async throws -> Data? { try await client.group() }
    func epoch() async throws -> UInt64 { try await client.epoch() }
    func cursor() async throws -> UInt64 { try await client.cursor() }
    func members() async throws -> [MLSMember] { try await client.members() }
    func isRemoved() async throws -> Bool { try await client.isRemoved() }
    func pendingDelivery() async throws -> MLSDelivery? { try await client.pendingDelivery() }
    func rejectedCommit() async throws -> MLSDelivery? { try await client.rejectedCommit() }
    func inbox() async throws -> [MLSInboxMessage] { try await client.inbox() }
    func rejectedApplicationCursors() async throws -> [UInt64] { try await client.rejectedApplicationCursors() }

    func acknowledgeInbox(through cursor: UInt64) async throws {
        try await client.acknowledgeInbox(through: cursor)
    }

    func publishKeyPackage(pairingToken: Data) async throws -> MLSPublishedKeyPackage {
        guard pairingToken.count == 32 else { throw MLSRelayError.invalidRequest }
        return try await exclusive { session in
            let identity = try await session.client.joiningIdentity()
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

    func createGroup(_ id: Data) async throws {
        guard id.count == 32 else { throw MLSRelayError.invalidRequest }
        try await exclusive { session in
            switch try await session.client.group() {
            case nil: try await session.client.createGroup(id: id)
            case id?: break
            default: throw MLSSessionError.groupMismatch
            }
            try await session.transport.createGroup(id, authorization: session.client.transportAuthorization())
        }
    }

    func add(keyPackage: Data, verifiedFingerprint: Data, reference: Data) async throws -> MLSSubmission {
        try await exclusive { session in
            try await session.submit {
                try await $0.prepareAdd(keyPackage: keyPackage, verifiedFingerprint: verifiedFingerprint, reference: reference)
            }
        }
    }

    func remove(fingerprint: Data) async throws -> MLSSubmission {
        try await exclusive { session in
            try await session.submit { try await $0.prepareRemove(fingerprint: fingerprint) }
        }
    }

    func send(_ plaintext: Data) async throws -> MLSSubmission {
        try await exclusive { session in
            try await session.submit { try await $0.prepareMessage(plaintext) }
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

    func join(group: Data, keyPackageReference: Data, verifiedInviterFingerprint: Data) async throws -> Bool {
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
                } catch MLSRelayError.unauthorized {
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
                        cursor: entry.cursor
                    )
                    _ = try await session.catchUp()
                    return true
                }
                after = last.cursor
            }
        }
    }

    private func submit(_ prepare: (MLSClient) async throws -> MLSDelivery) async throws -> MLSSubmission {
        if try await client.pendingDelivery() != nil {
            _ = try await deliverPending()
        }
        _ = try await prepare(client)
        return try await deliverPending()
    }

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
                _ = try await catchUp()
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
                try await client.process(entry.delivery, cursor: entry.cursor)
                processed += 1
                if try await client.isRemoved() {
                    try await acknowledgeRemoval(group: group)
                    return processed
                }
            }
        }
    }

    private func acknowledgeRemoval(group: Data) async throws {
        guard let authorization = try await client.removalAuthorization() else { return }
        do {
            try await transport.acknowledge(group: group, through: client.cursor(), authorization: authorization)
        } catch MLSRelayError.unauthorized {}
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
