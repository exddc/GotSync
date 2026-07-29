import Foundation

struct TaskReplica: Sendable {
    private(set) var archive: ReplicaArchive
    let persistenceURL: URL?

    init(deviceID: ReplicaDeviceID, persistenceURL: URL? = nil) throws {
        self.persistenceURL = persistenceURL
        if let persistenceURL, FileManager.default.fileExists(atPath: persistenceURL.path) {
            let data = try Data(contentsOf: persistenceURL)
            let stored = try ReplicaArchive.decodeCanonical(from: data)
            guard stored.deviceID == deviceID else {
                throw ReplicaError.archiveDeviceMismatch(
                    expected: deviceID,
                    actual: stored.deviceID
                )
            }
            try Self.validateArchive(stored)
            archive = stored
        } else {
            archive = ReplicaArchive(
                formatVersion: ReplicaLimits.archiveFormatVersion,
                deviceID: deviceID,
                nextLocalOriginSequence: 1,
                lamport: 0,
                versionVector: ReplicaVersionVector(),
                taskRecords: [],
                operations: []
            )
            try persist()
        }
    }

    private init(archive: ReplicaArchive, persistenceURL: URL?) throws {
        self.archive = archive.normalized()
        self.persistenceURL = persistenceURL
        try Self.validateArchive(self.archive)
        try persist()
    }

    var deviceID: ReplicaDeviceID {
        archive.deviceID
    }

    var lamport: UInt64 {
        archive.lamport
    }

    var versionVector: ReplicaVersionVector {
        archive.versionVector
    }

    var tasks: [ReplicatedTask] {
        var creationStamps: [UUID: ReplicaStamp] = [:]
        for operation in archive.operations {
            if case .create = operation.mutation {
                creationStamps[operation.taskID] = max(
                    creationStamps[operation.taskID] ?? operation.stamp,
                    operation.stamp
                )
            }
        }
        return archive.taskRecords
            .filter {
                creationStamps[$0.id] != nil
                    && !$0.isDeleted
                    && $0.title != nil
                    && $0.completed != nil
            }
            .sorted {
                let lhsStamp = creationStamps[$0.id]!
                let rhsStamp = creationStamps[$1.id]!
                if lhsStamp != rhsStamp {
                    return lhsStamp > rhsStamp
                }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    var taskRecords: [ReplicatedTask] {
        archive.taskRecords.sorted(by: ReplicaOrdering.tasks)
    }

    var retainedOperations: [TaskOperation] {
        archive.operations.sorted(by: ReplicaOrdering.operations)
    }

    var isEmpty: Bool {
        archive.taskRecords.isEmpty
            && archive.operations.isEmpty
            && archive.versionVector.entries.isEmpty
            && archive.lamport == 0
            && archive.nextLocalOriginSequence == 1
    }

    func task(id: UUID) -> ReplicatedTask? {
        archive.taskRecords.first { $0.id == id }
    }

    @discardableResult
    mutating func createTask(
        id: UUID = UUID(),
        title: String,
        completed: Bool = false
    ) throws -> TaskOperation {
        try makeLocalOperation(
            taskID: id,
            mutation: .create(title: title, completed: completed)
        )
    }

    @discardableResult
    mutating func setTitle(taskID: UUID, title: String) throws -> TaskOperation {
        try makeLocalOperation(taskID: taskID, mutation: .setTitle(title))
    }

    @discardableResult
    mutating func setCompleted(
        taskID: UUID,
        completed: Bool
    ) throws -> TaskOperation {
        try makeLocalOperation(taskID: taskID, mutation: .setCompleted(completed))
    }

    @discardableResult
    mutating func deleteTask(taskID: UUID) throws -> TaskOperation {
        try makeLocalOperation(taskID: taskID, mutation: .delete)
    }

    @discardableResult
    mutating func applyRemote(_ operations: [TaskOperation]) throws -> Int {
        try Self.validateBatchBounds(operations)
        var candidate = self
        var acceptedCount = 0
        for operation in operations {
            if try candidate.apply(operation, isLocal: false) {
                acceptedCount += 1
            }
        }
        guard acceptedCount > 0 else {
            return 0
        }
        candidate.archive = candidate.archive.normalized()
        try candidate.persist()
        self = candidate
        return acceptedCount
    }

    func operations(missingFrom peer: ReplicaVersionVector) -> [TaskOperation] {
        archive.operations
            .filter { $0.originSequence > peer[$0.originDeviceID] }
            .sorted(by: ReplicaOrdering.operations)
    }

    func atomicArchiveData() throws -> Data {
        try archive.canonicalData()
    }

    func exportProvisioningArchive() throws -> Data {
        let provisioning = ReplicaProvisioningArchive(
            formatVersion: archive.formatVersion,
            sourceDeviceID: archive.deviceID,
            lamport: archive.lamport,
            versionVector: archive.versionVector,
            taskRecords: archive.taskRecords,
            operations: archive.operations
        )
        return try provisioning.canonicalData()
    }

    func matchesProvisioningArchive(
        sourceDeviceID: ReplicaDeviceID,
        archiveHash: Data
    ) throws -> Bool {
        guard
            sourceDeviceID != deviceID,
            archiveHash.count == 32
        else {
            return false
        }
        let provisioning = ReplicaProvisioningArchive(
            formatVersion: archive.formatVersion,
            sourceDeviceID: sourceDeviceID,
            lamport: archive.lamport,
            versionVector: archive.versionVector,
            taskRecords: archive.taskRecords,
            operations: archive.operations
        )
        return try provisioning.canonicalData().sha256 == archiveHash
    }

    func containsHistory(from baseline: TaskReplica) throws -> Bool {
        guard deviceID == baseline.deviceID else {
            return false
        }
        for operation in baseline.retainedOperations {
            guard let retained = archive.operations.first(where: {
                $0.originDeviceID == operation.originDeviceID
                    && $0.originSequence == operation.originSequence
            }) else {
                return false
            }
            guard try retained.canonicalData() == operation.canonicalData() else {
                return false
            }
        }
        return true
    }

    static func keepBothCandidate(
        staged: TaskReplica,
        local: TaskReplica,
        pairID: Data
    ) throws -> TaskReplica {
        guard staged.deviceID == local.deviceID else {
            throw ReplicaError.archiveDeviceMismatch(
                expected: staged.deviceID,
                actual: local.deviceID
            )
        }
        guard pairID.count == 16 else {
            throw ReplicaError.corruptArchive(
                "A pairing ID must contain 16 bytes."
            )
        }

        var candidate = try TaskReplica(
            archive: staged.archive,
            persistenceURL: nil
        )
        for task in local.tasks.reversed() {
            guard
                let title = task.titleValue,
                let completed = task.isCompleted
            else {
                throw ReplicaError.corruptArchive(
                    "A visible task is missing materialized fields."
                )
            }
            if let existing = candidate.task(id: task.id),
               !existing.isDeleted,
               existing.titleValue == title,
               existing.isCompleted == completed
            {
                continue
            }

            var recovered = false
            for salt in UInt16.min...UInt16.max {
                let recoveredID = recoveredTaskID(
                    originalID: task.id,
                    pairID: pairID,
                    salt: salt
                )
                if let existing = candidate.task(id: recoveredID) {
                    if
                        !existing.isDeleted,
                        existing.titleValue == title,
                        existing.isCompleted == completed
                    {
                        recovered = true
                        break
                    }
                    continue
                }
                try candidate.createTask(
                    id: recoveredID,
                    title: title,
                    completed: completed
                )
                recovered = true
                break
            }
            guard recovered else {
                throw ReplicaError.corruptArchive(
                    "No recovered task ID is available."
                )
            }
        }
        return candidate
    }

    static func provision(
        deviceID: ReplicaDeviceID,
        from data: Data,
        persistenceURL: URL? = nil
    ) throws -> TaskReplica {
        let provisioning = try ReplicaProvisioningArchive.decodeCanonical(from: data)
        guard provisioning.formatVersion == ReplicaLimits.archiveFormatVersion else {
            throw ReplicaError.unsupportedArchiveVersion(provisioning.formatVersion)
        }
        guard provisioning.sourceDeviceID != deviceID else {
            throw ReplicaError.provisioningDeviceCollision(deviceID)
        }
        let localSequence = provisioning.versionVector[deviceID]
        guard localSequence < UInt64.max else {
            throw ReplicaError.originSequenceExhausted
        }

        if let persistenceURL, FileManager.default.fileExists(atPath: persistenceURL.path) {
            let existing = try TaskReplica(
                deviceID: deviceID,
                persistenceURL: persistenceURL
            )
            guard existing.isEmpty else {
                throw ReplicaError.provisioningRequiresEmptyReplica
            }
        }

        let imported = ReplicaArchive(
            formatVersion: provisioning.formatVersion,
            deviceID: deviceID,
            nextLocalOriginSequence: localSequence + 1,
            lamport: provisioning.lamport,
            versionVector: provisioning.versionVector,
            taskRecords: provisioning.taskRecords,
            operations: provisioning.operations
        )
        return try TaskReplica(archive: imported, persistenceURL: persistenceURL)
    }

    private static func recoveredTaskID(
        originalID: UUID,
        pairID: Data,
        salt: UInt16
    ) -> UUID {
        var input = Data(
            "com.gotdone.sync/pairing-conflict-task/v2".utf8
        )
        input.append(pairID)
        input.append(ReplicaDeviceID(uuid: originalID).bytes)
        input.append(UInt8(salt >> 8))
        input.append(UInt8(salt & 0xff))
        var bytes = Array(input.sha256.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
    }

    private mutating func makeLocalOperation(
        taskID: UUID,
        mutation: TaskMutation
    ) throws -> TaskOperation {
        guard archive.lamport < UInt64.max else {
            throw ReplicaError.lamportExhausted
        }
        guard archive.nextLocalOriginSequence < UInt64.max else {
            throw ReplicaError.originSequenceExhausted
        }

        let operation = TaskOperation(
            originDeviceID: archive.deviceID,
            originSequence: archive.nextLocalOriginSequence,
            lamport: archive.lamport + 1,
            taskID: taskID,
            mutation: mutation
        )

        var candidate = self
        guard try candidate.apply(operation, isLocal: true) else {
            throw ReplicaError.corruptArchive("A fresh local operation was a duplicate.")
        }
        candidate.archive = candidate.archive.normalized()
        try candidate.persist()
        self = candidate
        return operation
    }

    private mutating func apply(
        _ operation: TaskOperation,
        isLocal: Bool
    ) throws -> Bool {
        try Self.validateOperation(operation)

        if let retained = archive.operations.first(where: {
            $0.originDeviceID == operation.originDeviceID
                && $0.originSequence == operation.originSequence
        }) {
            guard try retained.canonicalData() == operation.canonicalData() else {
                throw ReplicaError.operationFork(
                    origin: operation.originDeviceID,
                    sequence: operation.originSequence
                )
            }
            return false
        }

        let expected = archive.versionVector[operation.originDeviceID] + 1
        if operation.originSequence < expected {
            throw ReplicaError.retainedOperationMissing(
                origin: operation.originDeviceID,
                sequence: operation.originSequence
            )
        }
        guard operation.originSequence == expected else {
            throw ReplicaError.sequenceGap(
                origin: operation.originDeviceID,
                expected: expected,
                received: operation.originSequence
            )
        }

        let originCount = archive.versionVector[operation.originDeviceID] == 0
            ? archive.versionVector.entries.count + 1
            : archive.versionVector.entries.count
        guard originCount <= ReplicaLimits.maxOrigins else {
            throw ReplicaError.tooManyOrigins(originCount)
        }
        guard archive.operations.count < ReplicaLimits.maxOperations else {
            throw ReplicaError.tooManyOperations(archive.operations.count + 1)
        }
        if operation.originDeviceID == archive.deviceID,
           operation.originSequence == UInt64.max {
            throw ReplicaError.originSequenceExhausted
        }

        try applyMaterialized(operation, isLocal: isLocal)
        archive.operations.append(operation)
        archive.versionVector.setSequence(
            operation.originSequence,
            for: operation.originDeviceID
        )
        if operation.originDeviceID == archive.deviceID {
            archive.nextLocalOriginSequence = operation.originSequence + 1
        }
        archive.lamport = max(archive.lamport, operation.lamport)
        return true
    }

    private mutating func applyMaterialized(
        _ operation: TaskOperation,
        isLocal: Bool
    ) throws {
        let index = archive.taskRecords.firstIndex { $0.id == operation.taskID }
        switch operation.mutation {
        case .delete:
            if let index {
                if let deletion = archive.taskRecords[index].deletion {
                    archive.taskRecords[index].deletion = max(deletion, operation.stamp)
                } else {
                    archive.taskRecords[index].deletion = operation.stamp
                }
            } else {
                try ensureTaskCapacity()
                archive.taskRecords.append(
                    ReplicatedTask(
                        id: operation.taskID,
                        title: nil,
                        completed: nil,
                        deletion: operation.stamp
                    )
                )
            }
        case .create(let title, let completed):
            if let index {
                if isLocal, archive.taskRecords[index].deletion != nil {
                    throw ReplicaError.tombstonedTask(operation.taskID)
                }
                try replace(
                    &archive.taskRecords[index].title,
                    with: title,
                    stamp: operation.stamp,
                    taskID: operation.taskID,
                    field: "title"
                )
                try replace(
                    &archive.taskRecords[index].completed,
                    with: completed,
                    stamp: operation.stamp,
                    taskID: operation.taskID,
                    field: "completed"
                )
            } else {
                try ensureTaskCapacity()
                archive.taskRecords.append(
                    ReplicatedTask(
                        id: operation.taskID,
                        title: LWWRegister(value: title, stamp: operation.stamp),
                        completed: LWWRegister(value: completed, stamp: operation.stamp),
                        deletion: nil
                    )
                )
            }
        case .setTitle(let title):
            if let index {
                if isLocal, archive.taskRecords[index].deletion != nil {
                    throw ReplicaError.tombstonedTask(operation.taskID)
                }
                if isLocal, !hasCreateOperation(for: operation.taskID) {
                    throw ReplicaError.unknownTask(operation.taskID)
                }
                try replace(
                    &archive.taskRecords[index].title,
                    with: title,
                    stamp: operation.stamp,
                    taskID: operation.taskID,
                    field: "title"
                )
            } else {
                guard !isLocal else {
                    throw ReplicaError.unknownTask(operation.taskID)
                }
                try ensureTaskCapacity()
                archive.taskRecords.append(
                    ReplicatedTask(
                        id: operation.taskID,
                        title: LWWRegister(value: title, stamp: operation.stamp),
                        completed: nil,
                        deletion: nil
                    )
                )
            }
        case .setCompleted(let completed):
            if let index {
                if isLocal, archive.taskRecords[index].deletion != nil {
                    throw ReplicaError.tombstonedTask(operation.taskID)
                }
                if isLocal, !hasCreateOperation(for: operation.taskID) {
                    throw ReplicaError.unknownTask(operation.taskID)
                }
                try replace(
                    &archive.taskRecords[index].completed,
                    with: completed,
                    stamp: operation.stamp,
                    taskID: operation.taskID,
                    field: "completed"
                )
            } else {
                guard !isLocal else {
                    throw ReplicaError.unknownTask(operation.taskID)
                }
                try ensureTaskCapacity()
                archive.taskRecords.append(
                    ReplicatedTask(
                        id: operation.taskID,
                        title: nil,
                        completed: LWWRegister(
                            value: completed,
                            stamp: operation.stamp
                        ),
                        deletion: nil
                    )
                )
            }
        }
    }

    private func hasCreateOperation(for taskID: UUID) -> Bool {
        archive.operations.contains { operation in
            guard operation.taskID == taskID else {
                return false
            }
            if case .create = operation.mutation {
                return true
            }
            return false
        }
    }

    private mutating func ensureTaskCapacity() throws {
        guard archive.taskRecords.count < ReplicaLimits.maxTasks else {
            throw ReplicaError.tooManyTasks(archive.taskRecords.count + 1)
        }
    }

    private func persist() throws {
        guard let persistenceURL else {
            return
        }
        let directory = persistenceURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try archive.canonicalData().write(to: persistenceURL, options: .atomic)
    }

    private static func validateBatchBounds(_ operations: [TaskOperation]) throws {
        guard operations.count <= ReplicaLimits.maxBatchOperations else {
            throw ReplicaError.batchExceedsOperationLimit(operations.count)
        }
        let encoded = try ReplicaCanonicalJSON.encode(operations)
        guard encoded.count <= ReplicaLimits.maxBatchEncodedBytes else {
            throw ReplicaError.batchExceedsEncodedLimit(encoded.count)
        }
    }

    private static func validateOperation(_ operation: TaskOperation) throws {
        guard operation.taskID != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else {
            throw ReplicaError.invalidTaskID(operation.taskID)
        }
        guard operation.originSequence > 0 else {
            throw ReplicaError.invalidOriginSequence(operation.originSequence)
        }
        guard operation.lamport > 0 else {
            throw ReplicaError.invalidLamport(operation.lamport)
        }
        switch operation.mutation {
        case .create(let title, _), .setTitle(let title):
            try validateTitle(title)
        case .setCompleted, .delete:
            break
        }
    }

    private static func validateTitle(_ title: String) throws {
        let scalars = title.unicodeScalars.count
        guard scalars <= ReplicaLimits.maxTitleUnicodeScalars else {
            throw ReplicaError.titleExceedsUnicodeScalarLimit(scalars)
        }
        let bytes = title.utf8.count
        guard bytes <= ReplicaLimits.maxTitleUTF8Bytes else {
            throw ReplicaError.titleExceedsUTF8Limit(bytes)
        }
    }

    private static func validateArchive(_ archive: ReplicaArchive) throws {
        guard archive.formatVersion == ReplicaLimits.archiveFormatVersion else {
            throw ReplicaError.unsupportedArchiveVersion(archive.formatVersion)
        }
        guard archive.taskRecords.count <= ReplicaLimits.maxTasks else {
            throw ReplicaError.tooManyTasks(archive.taskRecords.count)
        }
        guard archive.operations.count <= ReplicaLimits.maxOperations else {
            throw ReplicaError.tooManyOperations(archive.operations.count)
        }
        guard archive.versionVector.entries.count <= ReplicaLimits.maxOrigins else {
            throw ReplicaError.tooManyOrigins(archive.versionVector.entries.count)
        }

        var operationIDs: Set<OperationID> = []
        var sequenceCounts: [ReplicaDeviceID: UInt64] = [:]
        var maximumLamport: UInt64 = 0
        for operation in archive.operations.sorted(by: ReplicaOrdering.operations) {
            try validateOperation(operation)
            let id = OperationID(operation)
            guard operationIDs.insert(id).inserted else {
                throw ReplicaError.corruptArchive("The operation log repeats an ID.")
            }
            let expected = sequenceCounts[operation.originDeviceID, default: 0] + 1
            guard operation.originSequence == expected else {
                throw ReplicaError.corruptArchive(
                    "Origin \(operation.originDeviceID) is not contiguous."
                )
            }
            sequenceCounts[operation.originDeviceID] = operation.originSequence
            maximumLamport = max(maximumLamport, operation.lamport)
        }

        guard sequenceCounts.count == archive.versionVector.entries.count else {
            throw ReplicaError.corruptArchive("The version vector and log origins differ.")
        }
        for entry in archive.versionVector.entries {
            guard sequenceCounts[entry.originDeviceID] == entry.sequence else {
                throw ReplicaError.corruptArchive(
                    "The version vector does not match the retained log."
                )
            }
        }
        guard archive.lamport == maximumLamport else {
            throw ReplicaError.corruptArchive("The Lamport clock does not match the log.")
        }
        guard archive.nextLocalOriginSequence
            == archive.versionVector[archive.deviceID] + 1
        else {
            throw ReplicaError.corruptArchive("The next local sequence is inconsistent.")
        }

        let expectedRecords = try reduceMaterializedRecords(archive.operations)
        guard expectedRecords.sorted(by: ReplicaOrdering.tasks)
            == archive.taskRecords.sorted(by: ReplicaOrdering.tasks)
        else {
            throw ReplicaError.corruptArchive("Materialized tasks do not match the log.")
        }
    }

    private static func reduceMaterializedRecords(
        _ operations: [TaskOperation]
    ) throws -> [ReplicatedTask] {
        var records: [UUID: ReplicatedTask] = [:]

        for operation in operations.sorted(by: {
            if $0.stamp != $1.stamp {
                return $0.stamp < $1.stamp
            }
            if $0.originDeviceID != $1.originDeviceID {
                return $0.originDeviceID < $1.originDeviceID
            }
            return $0.originSequence < $1.originSequence
        }) {
            var record = records[operation.taskID] ?? ReplicatedTask(
                id: operation.taskID,
                title: nil,
                completed: nil,
                deletion: nil
            )
            switch operation.mutation {
            case .create(let title, let completed):
                try replace(
                    &record.title,
                    with: title,
                    stamp: operation.stamp,
                    taskID: operation.taskID,
                    field: "title"
                )
                try replace(
                    &record.completed,
                    with: completed,
                    stamp: operation.stamp,
                    taskID: operation.taskID,
                    field: "completed"
                )
            case .setTitle(let title):
                try replace(
                    &record.title,
                    with: title,
                    stamp: operation.stamp,
                    taskID: operation.taskID,
                    field: "title"
                )
            case .setCompleted(let completed):
                try replace(
                    &record.completed,
                    with: completed,
                    stamp: operation.stamp,
                    taskID: operation.taskID,
                    field: "completed"
                )
            case .delete:
                if let deletion = record.deletion {
                    record.deletion = max(deletion, operation.stamp)
                } else {
                    record.deletion = operation.stamp
                }
            }
            records[operation.taskID] = record
        }

        return Array(records.values)
    }

    private struct OperationID: Hashable {
        let origin: ReplicaDeviceID
        let sequence: UInt64

        init(_ operation: TaskOperation) {
            origin = operation.originDeviceID
            sequence = operation.originSequence
        }
    }
}

private func replace<Value>(
    _ register: inout LWWRegister<Value>?,
    with value: Value,
    stamp: ReplicaStamp,
    taskID: UUID,
    field: String
) throws where Value: Codable & Equatable & Sendable {
    guard let existing = register else {
        register = LWWRegister(value: value, stamp: stamp)
        return
    }
    if existing.stamp < stamp {
        register = LWWRegister(value: value, stamp: stamp)
    } else if existing.stamp == stamp, existing.value != value {
        throw ReplicaError.registerConflict(taskID: taskID, field: field)
    }
}
