import Foundation

enum WireMessageError: Error, Equatable {
    case invalidMessage
    case invalidVersion
    case messageTooLarge
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
