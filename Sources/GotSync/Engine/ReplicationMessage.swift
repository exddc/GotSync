import Foundation

/// Plaintext of one MLS application message.
///
/// `operations` carries task operations from any origin. `hello` reports the
/// sender's version vector so other members can send what it lacks. A joiner
/// names its inviter as `provider`, which answers with every missing origin.
struct ReplicationMessage: Codable, Equatable, Sendable {
    static let version = 2

    enum Kind: String, Codable, Sendable {
        case operations
        case hello
    }

    let version: Int
    let kind: Kind
    let operations: [TaskOperation]?
    let vector: ReplicaVersionVector?
    let provider: Data?

    static func operations(_ operations: [TaskOperation]) -> ReplicationMessage {
        ReplicationMessage(version: version, kind: .operations, operations: operations, vector: nil, provider: nil)
    }

    static func hello(vector: ReplicaVersionVector, provider: Data?) -> ReplicationMessage {
        ReplicationMessage(version: version, kind: .hello, operations: nil, vector: vector, provider: provider)
    }

    func encoded() throws -> Data {
        let data = try ReplicaCanonicalJSON.encode(self)
        guard data.count <= ProtocolLimits.plaintextBytes else { throw WireMessageError.messageTooLarge }
        return data
    }

    static func decode(_ data: Data) throws -> ReplicationMessage {
        guard data.count <= ProtocolLimits.plaintextBytes else { throw WireMessageError.messageTooLarge }
        let message = try ReplicaCanonicalJSON.decode(ReplicationMessage.self, from: data)
        guard message.version == version else { throw WireMessageError.invalidVersion }
        switch message.kind {
        case .operations:
            guard
                let operations = message.operations,
                !operations.isEmpty,
                operations.count <= ReplicaLimits.maxBatchOperations,
                message.vector == nil,
                message.provider == nil
            else {
                throw WireMessageError.invalidMessage
            }
        case .hello:
            guard
                message.operations == nil,
                message.vector != nil,
                message.provider.map({ $0.count == 32 }) ?? true
            else {
                throw WireMessageError.invalidMessage
            }
        }
        return message
    }
}

/// Engine state for the current MLS group that MLS itself does not hold.
struct ReplicationCheckpoint: Codable, Equatable, Sendable {
    static let filename = "sync-v2.json"
    static let version = 2

    var version = Self.version
    let group: Data
    var uploadedThrough: UInt64
    var memberDeviceIDs: [Data]
    var joinPending: Bool
    var provider: Data?

    init(group: Data, memberDeviceIDs: [Data], joinPending: Bool, provider: Data?) {
        self.group = group
        uploadedThrough = 0
        self.memberDeviceIDs = memberDeviceIDs
        self.joinPending = joinPending
        self.provider = provider
    }

    static func load(from url: URL) throws -> ReplicationCheckpoint? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let checkpoint = try ReplicaCanonicalJSON.decode(ReplicationCheckpoint.self, from: Data(contentsOf: url))
        guard checkpoint.version == version, checkpoint.group.count == 32 else {
            throw SyncError.invalidCredentials
        }
        return checkpoint
    }

    func save(to url: URL) throws {
        var options: Data.WritingOptions = .atomic
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try ReplicaCanonicalJSON.encode(self).write(to: url, options: options)
        try FileManager.default.setAttributes(ProtectedStorage.backgroundFileAttributes, ofItemAtPath: url.path)
    }

    static func remove(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
