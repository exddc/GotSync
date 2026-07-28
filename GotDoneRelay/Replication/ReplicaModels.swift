import Foundation

enum ReplicaLimits {
    static let maxTitleUnicodeScalars = 200
    static let maxTitleUTF8Bytes = 512
    static let maxTasks = 1_000
    static let maxOperations = 10_000
    static let maxOrigins = 8
    static let maxBatchOperations = 256
    static let maxBatchEncodedBytes = 256 * 1_024
    static let archiveFormatVersion = 1
}

enum ReplicaError: Error, Equatable, Sendable {
    case invalidDeviceIDLength(Int)
    case invalidDeviceIDEncoding
    case invalidTaskID(UUID)
    case invalidOriginSequence(UInt64)
    case invalidLamport(UInt64)
    case titleExceedsUnicodeScalarLimit(Int)
    case titleExceedsUTF8Limit(Int)
    case batchExceedsOperationLimit(Int)
    case batchExceedsEncodedLimit(Int)
    case tooManyTasks(Int)
    case tooManyOperations(Int)
    case tooManyOrigins(Int)
    case sequenceGap(origin: ReplicaDeviceID, expected: UInt64, received: UInt64)
    case operationFork(origin: ReplicaDeviceID, sequence: UInt64)
    case retainedOperationMissing(origin: ReplicaDeviceID, sequence: UInt64)
    case unknownTask(UUID)
    case tombstonedTask(UUID)
    case registerConflict(taskID: UUID, field: String)
    case lamportExhausted
    case originSequenceExhausted
    case unsupportedArchiveVersion(Int)
    case nonCanonicalArchive
    case archiveDeviceMismatch(expected: ReplicaDeviceID, actual: ReplicaDeviceID)
    case corruptArchive(String)
    case provisioningRequiresEmptyReplica
    case provisioningDeviceCollision(ReplicaDeviceID)
}

extension ReplicaError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidDeviceIDLength(let count):
            "A device ID must contain 16 bytes, not \(count)."
        case .invalidDeviceIDEncoding:
            "The device ID is not canonical base64url."
        case .invalidTaskID(let id):
            "The task ID \(id) is invalid."
        case .invalidOriginSequence(let sequence):
            "Origin sequence \(sequence) is invalid."
        case .invalidLamport(let lamport):
            "Lamport value \(lamport) is invalid."
        case .titleExceedsUnicodeScalarLimit(let count):
            "The title contains \(count) Unicode scalars."
        case .titleExceedsUTF8Limit(let count):
            "The title contains \(count) UTF-8 bytes."
        case .batchExceedsOperationLimit(let count):
            "The batch contains \(count) operations."
        case .batchExceedsEncodedLimit(let count):
            "The encoded batch contains \(count) bytes."
        case .tooManyTasks(let count):
            "The replica would contain \(count) tasks and tombstones."
        case .tooManyOperations(let count):
            "The replica would retain \(count) operations."
        case .tooManyOrigins(let count):
            "The replica would contain \(count) origins."
        case .sequenceGap(let origin, let expected, let received):
            "Origin \(origin) expected sequence \(expected), received \(received)."
        case .operationFork(let origin, let sequence):
            "Origin \(origin) forked at sequence \(sequence)."
        case .retainedOperationMissing(let origin, let sequence):
            "Origin \(origin) is missing retained sequence \(sequence)."
        case .unknownTask(let id):
            "Task \(id) does not exist."
        case .tombstonedTask(let id):
            "Task \(id) is permanently deleted."
        case .registerConflict(let taskID, let field):
            "Task \(taskID) has conflicting values for the \(field) register."
        case .lamportExhausted:
            "The Lamport clock is exhausted."
        case .originSequenceExhausted:
            "The local origin sequence is exhausted."
        case .unsupportedArchiveVersion(let version):
            "Archive version \(version) is unsupported."
        case .nonCanonicalArchive:
            "The archive is not canonically encoded."
        case .archiveDeviceMismatch(let expected, let actual):
            "Archive device \(actual) does not match \(expected)."
        case .corruptArchive(let reason):
            "The replica archive is corrupt: \(reason)"
        case .provisioningRequiresEmptyReplica:
            "Provisioning requires an empty replica."
        case .provisioningDeviceCollision(let deviceID):
            "Provisioning already contains device \(deviceID)."
        }
    }
}

struct ReplicaDeviceID: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    let bytes: Data

    init(bytes: Data) throws {
        guard bytes.count == 16 else {
            throw ReplicaError.invalidDeviceIDLength(bytes.count)
        }
        self.bytes = bytes
    }

    init(uuid: UUID) {
        let hex = uuid.uuidString.replacingOccurrences(of: "-", with: "")
        var result = Data()
        result.reserveCapacity(16)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            result.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        bytes = result
    }

    init(base64URL: String) throws {
        guard !base64URL.contains("="),
              !base64URL.contains("+"),
              !base64URL.contains("/")
        else {
            throw ReplicaError.invalidDeviceIDEncoding
        }
        let remainder = base64URL.utf8.count % 4
        let padding = remainder == 0 ? "" : String(repeating: "=", count: 4 - remainder)
        let standard = base64URL
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            + padding
        guard let decoded = Data(base64Encoded: standard) else {
            throw ReplicaError.invalidDeviceIDEncoding
        }
        try self.init(bytes: decoded)
        guard self.base64URL == base64URL else {
            throw ReplicaError.invalidDeviceIDEncoding
        }
    }

    var base64URL: String {
        bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    var description: String {
        base64URL
    }

    static func < (lhs: ReplicaDeviceID, rhs: ReplicaDeviceID) -> Bool {
        lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(base64URL: container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(base64URL)
    }
}

struct ReplicaStamp: Codable, Equatable, Comparable, Sendable {
    let lamport: UInt64
    let originDeviceID: ReplicaDeviceID

    static func < (lhs: ReplicaStamp, rhs: ReplicaStamp) -> Bool {
        if lhs.lamport != rhs.lamport {
            return lhs.lamport < rhs.lamport
        }
        return lhs.originDeviceID < rhs.originDeviceID
    }
}

enum TaskMutation: Equatable, Sendable {
    case create(title: String, completed: Bool)
    case setTitle(String)
    case setCompleted(Bool)
    case delete
}

extension TaskMutation: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case title
        case completed
    }

    private enum Kind: String, Codable {
        case create
        case setTitle
        case setCompleted
        case delete
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        switch kind {
        case .create:
            guard container.contains(.title), container.contains(.completed) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Create requires title and completed values."
                )
            }
            self = try .create(
                title: container.decode(String.self, forKey: .title),
                completed: container.decode(Bool.self, forKey: .completed)
            )
        case .setTitle:
            guard container.contains(.title), !container.contains(.completed) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "setTitle requires only a title value."
                )
            }
            self = try .setTitle(container.decode(String.self, forKey: .title))
        case .setCompleted:
            guard !container.contains(.title), container.contains(.completed) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "setCompleted requires only a completed value."
                )
            }
            self = try .setCompleted(container.decode(Bool.self, forKey: .completed))
        case .delete:
            guard !container.contains(.title), !container.contains(.completed) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Delete has no value."
                )
            }
            self = .delete
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .create(let title, let completed):
            try container.encode(Kind.create, forKey: .type)
            try container.encode(title, forKey: .title)
            try container.encode(completed, forKey: .completed)
        case .setTitle(let title):
            try container.encode(Kind.setTitle, forKey: .type)
            try container.encode(title, forKey: .title)
        case .setCompleted(let completed):
            try container.encode(Kind.setCompleted, forKey: .type)
            try container.encode(completed, forKey: .completed)
        case .delete:
            try container.encode(Kind.delete, forKey: .type)
        }
    }
}

struct TaskOperation: Codable, Equatable, Sendable {
    let originDeviceID: ReplicaDeviceID
    let originSequence: UInt64
    let lamport: UInt64
    let taskID: UUID
    let mutation: TaskMutation

    init(
        originDeviceID: ReplicaDeviceID,
        originSequence: UInt64,
        lamport: UInt64,
        taskID: UUID,
        mutation: TaskMutation
    ) {
        self.originDeviceID = originDeviceID
        self.originSequence = originSequence
        self.lamport = lamport
        self.taskID = taskID
        self.mutation = mutation
    }

    var stamp: ReplicaStamp {
        ReplicaStamp(lamport: lamport, originDeviceID: originDeviceID)
    }

    func canonicalData() throws -> Data {
        try ReplicaCanonicalJSON.encode(self)
    }

    static func decodeCanonical(from data: Data) throws -> TaskOperation {
        let operation = try ReplicaCanonicalJSON.decode(TaskOperation.self, from: data)
        guard try operation.canonicalData() == data else {
            throw ReplicaError.nonCanonicalArchive
        }
        return operation
    }
}

struct LWWRegister<Value>: Codable, Equatable, Sendable
where Value: Codable & Equatable & Sendable {
    let value: Value
    let stamp: ReplicaStamp
}

struct ReplicatedTask: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var title: LWWRegister<String>?
    var completed: LWWRegister<Bool>?
    var deletion: ReplicaStamp?

    var isDeleted: Bool {
        deletion != nil
    }

    var titleValue: String? {
        title?.value
    }

    var isCompleted: Bool? {
        completed?.value
    }
}

struct ReplicaVersionVector: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let originDeviceID: ReplicaDeviceID
        let sequence: UInt64
    }

    private var storage: [ReplicaDeviceID: UInt64]

    init() {
        storage = [:]
    }

    init(_ watermarks: [ReplicaDeviceID: UInt64]) throws {
        let normalized = watermarks.filter { $0.value != 0 }
        guard normalized.count <= ReplicaLimits.maxOrigins else {
            throw ReplicaError.tooManyOrigins(normalized.count)
        }
        storage = normalized
    }

    var entries: [Entry] {
        storage
            .map(Entry.init(originDeviceID:sequence:))
            .sorted { $0.originDeviceID < $1.originDeviceID }
    }

    var origins: [ReplicaDeviceID] {
        storage.keys.sorted()
    }

    subscript(origin: ReplicaDeviceID) -> UInt64 {
        storage[origin, default: 0]
    }

    func isAtLeast(_ other: ReplicaVersionVector) -> Bool {
        other.storage.allSatisfy { self[$0.key] >= $0.value }
    }

    mutating func setSequence(_ sequence: UInt64, for origin: ReplicaDeviceID) {
        if sequence == 0 {
            storage.removeValue(forKey: origin)
        } else {
            storage[origin] = sequence
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let entries = try container.decode([Entry].self)
        var result: [ReplicaDeviceID: UInt64] = [:]
        for entry in entries {
            guard entry.sequence > 0 else {
                throw ReplicaError.invalidOriginSequence(entry.sequence)
            }
            guard result.updateValue(entry.sequence, forKey: entry.originDeviceID) == nil else {
                throw ReplicaError.corruptArchive("The version vector repeats an origin.")
            }
        }
        try self.init(result)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entries)
    }
}

struct ReplicaArchive: Codable, Equatable, Sendable {
    let formatVersion: Int
    let deviceID: ReplicaDeviceID
    var nextLocalOriginSequence: UInt64
    var lamport: UInt64
    var versionVector: ReplicaVersionVector
    var taskRecords: [ReplicatedTask]
    var operations: [TaskOperation]

    func canonicalData() throws -> Data {
        try ReplicaCanonicalJSON.encode(normalized())
    }

    func normalized() -> ReplicaArchive {
        var result = self
        result.taskRecords.sort(by: ReplicaOrdering.tasks)
        result.operations.sort(by: ReplicaOrdering.operations)
        return result
    }

    static func decodeCanonical(from data: Data) throws -> ReplicaArchive {
        let archive = try ReplicaCanonicalJSON.decode(ReplicaArchive.self, from: data)
        guard try archive.canonicalData() == data else {
            throw ReplicaError.nonCanonicalArchive
        }
        return archive.normalized()
    }
}

struct ReplicaProvisioningArchive: Codable, Equatable, Sendable {
    let formatVersion: Int
    let sourceDeviceID: ReplicaDeviceID
    let lamport: UInt64
    let versionVector: ReplicaVersionVector
    var taskRecords: [ReplicatedTask]
    var operations: [TaskOperation]

    func canonicalData() throws -> Data {
        try ReplicaCanonicalJSON.encode(normalized())
    }

    func normalized() -> ReplicaProvisioningArchive {
        var result = self
        result.taskRecords.sort(by: ReplicaOrdering.tasks)
        result.operations.sort(by: ReplicaOrdering.operations)
        return result
    }

    static func decodeCanonical(from data: Data) throws -> ReplicaProvisioningArchive {
        let archive = try ReplicaCanonicalJSON.decode(ReplicaProvisioningArchive.self, from: data)
        guard try archive.canonicalData() == data else {
            throw ReplicaError.nonCanonicalArchive
        }
        return archive.normalized()
    }
}

enum ReplicaCanonicalJSON {
    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try JSONDecoder().decode(type, from: data)
    }
}

enum ReplicaOrdering {
    static func tasks(_ lhs: ReplicatedTask, _ rhs: ReplicatedTask) -> Bool {
        lhs.id.uuidString < rhs.id.uuidString
    }

    static func operations(_ lhs: TaskOperation, _ rhs: TaskOperation) -> Bool {
        if lhs.originDeviceID != rhs.originDeviceID {
            return lhs.originDeviceID < rhs.originDeviceID
        }
        return lhs.originSequence < rhs.originSequence
    }
}
