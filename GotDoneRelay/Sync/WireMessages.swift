import Foundation

enum WireMessageError: Error, Equatable {
    case invalidMessage
    case invalidVersion
    case messageTooLarge
}

struct PairWireMessage: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case provision
        case ready
        case commit
        case receipt
    }

    let version: UInt8
    let kind: Kind
    let archive: Data?
    let archiveHash: Data?
    let hostDeviceID: Data?
    let joinerDeviceID: Data?
    let pairID: Data?

    static func provision(
        archive: Data,
        archiveHash: Data,
        hostDeviceID: Data
    ) -> PairWireMessage {
        PairWireMessage(
            version: SyncProtocol.version,
            kind: .provision,
            archive: archive,
            archiveHash: archiveHash,
            hostDeviceID: hostDeviceID,
            joinerDeviceID: nil,
            pairID: nil
        )
    }

    static func ready(
        archiveHash: Data,
        joinerDeviceID: Data
    ) -> PairWireMessage {
        PairWireMessage(
            version: SyncProtocol.version,
            kind: .ready,
            archive: nil,
            archiveHash: archiveHash,
            hostDeviceID: nil,
            joinerDeviceID: joinerDeviceID,
            pairID: nil
        )
    }

    static func commit(pairID: Data) -> PairWireMessage {
        PairWireMessage(
            version: SyncProtocol.version,
            kind: .commit,
            archive: nil,
            archiveHash: nil,
            hostDeviceID: nil,
            joinerDeviceID: nil,
            pairID: pairID
        )
    }

    static func receipt(pairID: Data) -> PairWireMessage {
        PairWireMessage(
            version: SyncProtocol.version,
            kind: .receipt,
            archive: nil,
            archiveHash: nil,
            hostDeviceID: nil,
            joinerDeviceID: nil,
            pairID: pairID
        )
    }
}

struct SyncWireMessage: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case hello
        case operations
        case acknowledgement
        case ping
        case pong
    }

    let version: UInt8
    let kind: Kind
    let vector: ReplicaVersionVector?
    let operations: [TaskOperation]?
    let pingID: Data?

    static func hello(vector: ReplicaVersionVector) -> SyncWireMessage {
        SyncWireMessage(
            version: SyncProtocol.version,
            kind: .hello,
            vector: vector,
            operations: nil,
            pingID: nil
        )
    }

    static func operations(_ operations: [TaskOperation]) -> SyncWireMessage {
        SyncWireMessage(
            version: SyncProtocol.version,
            kind: .operations,
            vector: nil,
            operations: operations,
            pingID: nil
        )
    }

    static func acknowledgement(vector: ReplicaVersionVector) -> SyncWireMessage {
        SyncWireMessage(
            version: SyncProtocol.version,
            kind: .acknowledgement,
            vector: vector,
            operations: nil,
            pingID: nil
        )
    }

    static func ping(id: Data) -> SyncWireMessage {
        SyncWireMessage(
            version: SyncProtocol.version,
            kind: .ping,
            vector: nil,
            operations: nil,
            pingID: id
        )
    }

    static func pong(id: Data) -> SyncWireMessage {
        SyncWireMessage(
            version: SyncProtocol.version,
            kind: .pong,
            vector: nil,
            operations: nil,
            pingID: id
        )
    }
}

enum WireCodec {
    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= ProtocolLimits.plaintextBytes else {
            throw WireMessageError.messageTooLarge
        }
        return data
    }

    static func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data
    ) throws -> Value {
        guard data.count <= ProtocolLimits.plaintextBytes else {
            throw WireMessageError.messageTooLarge
        }
        let value = try JSONDecoder().decode(type, from: data)
        return value
    }
}

enum OperationBatcher {
    static func batches(_ operations: [TaskOperation]) throws -> [[TaskOperation]] {
        guard !operations.isEmpty else {
            return []
        }
        var result: [[TaskOperation]] = []
        var current: [TaskOperation] = []
        var currentEncodedBytes = 2

        for operation in operations {
            let operationBytes = try operation.canonicalData().count
            let candidateBytes = currentEncodedBytes
                + (current.isEmpty ? 0 : 1)
                + operationBytes
            if current.count == ReplicaLimits.maxBatchOperations
                || candidateBytes > ReplicaLimits.maxBatchEncodedBytes
            {
                guard !current.isEmpty else {
                    throw ReplicaError.batchExceedsEncodedLimit(candidateBytes)
                }
                result.append(current)
                current = [operation]
                let singleBytes = operationBytes + 2
                guard singleBytes <= ReplicaLimits.maxBatchEncodedBytes else {
                    throw ReplicaError.batchExceedsEncodedLimit(singleBytes)
                }
                currentEncodedBytes = singleBytes
            } else {
                current.append(operation)
                currentEncodedBytes = candidateBytes
            }
        }

        if !current.isEmpty {
            result.append(current)
        }
        return result
    }
}
