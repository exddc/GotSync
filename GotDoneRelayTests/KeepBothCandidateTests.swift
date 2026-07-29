import Foundation
import XCTest
@testable import GotDoneRelay

final class KeepBothCandidateTests: XCTestCase {
    func testExactMatchesAreReusedAndConflictsAreDeterministic() throws {
        let sharedID = task(1)
        let conflictID = task(2)
        let localOnlyID = task(3)
        var staged = try TaskReplica(deviceID: device(9))
        try staged.createTask(
            id: sharedID,
            title: "Shared",
            completed: true
        )
        try staged.createTask(id: conflictID, title: "Host")

        var local = try TaskReplica(deviceID: device(9))
        try local.createTask(
            id: sharedID,
            title: "Shared",
            completed: true
        )
        try local.createTask(
            id: conflictID,
            title: "Local",
            completed: true
        )
        try local.createTask(id: localOnlyID, title: "Local only")

        let stagedBefore = try staged.atomicArchiveData()
        let localBefore = try local.atomicArchiveData()
        let first = try TaskReplica.keepBothCandidate(
            staged: staged,
            local: local,
            pairID: pairID
        )
        let second = try TaskReplica.keepBothCandidate(
            staged: staged,
            local: local,
            pairID: pairID
        )

        XCTAssertEqual(try first.atomicArchiveData(), try second.atomicArchiveData())
        XCTAssertEqual(try staged.atomicArchiveData(), stagedBefore)
        XCTAssertEqual(try local.atomicArchiveData(), localBefore)
        XCTAssertNil(first.persistenceURL)
        XCTAssertEqual(first.tasks.count, 4)
        XCTAssertEqual(first.task(id: sharedID)?.titleValue, "Shared")
        XCTAssertEqual(first.task(id: sharedID)?.isCompleted, true)
        XCTAssertEqual(first.task(id: conflictID)?.titleValue, "Host")
        XCTAssertEqual(
            first.tasks.filter {
                $0.titleValue == "Local" && $0.isCompleted == true
            }.count,
            1
        )
        XCTAssertEqual(
            first.tasks.filter {
                $0.titleValue == "Local only" && $0.isCompleted == false
            }.count,
            1
        )
    }

    func testTaskLimitFailureLeavesPersistedStagedAndLocalUntouched() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stagedURL = directory.appendingPathComponent("staged.json")
        let staged = try provisionedReplica(
            deviceID: device(9),
            operations: (1...ReplicaLimits.maxTasks).map { sequence in
                operation(
                    origin: 1,
                    sequence: UInt64(sequence),
                    taskID: task(UInt16(sequence)),
                    mutation: .create(title: "Host \(sequence)", completed: false)
                )
            },
            persistenceURL: stagedURL
        )
        var local = try TaskReplica(deviceID: device(9))
        try local.createTask(id: task(2_000), title: "Local")
        let stagedBefore = try Data(contentsOf: stagedURL)
        let localBefore = try local.atomicArchiveData()

        XCTAssertThrowsError(
            try TaskReplica.keepBothCandidate(
                staged: staged,
                local: local,
                pairID: pairID
            )
        ) {
            XCTAssertEqual($0 as? ReplicaError, .tooManyTasks(1_001))
        }
        XCTAssertEqual(try Data(contentsOf: stagedURL), stagedBefore)
        XCTAssertEqual(try local.atomicArchiveData(), localBefore)
    }

    func testOperationLimitFailureLeavesSourcesUntouched() throws {
        let taskID = task(1)
        var operations = [
            operation(
                origin: 1,
                sequence: 1,
                taskID: taskID,
                mutation: .create(title: "Host", completed: false)
            )
        ]
        operations.reserveCapacity(ReplicaLimits.maxOperations)
        for sequence in 2...ReplicaLimits.maxOperations {
            operations.append(
                operation(
                    origin: 1,
                    sequence: UInt64(sequence),
                    taskID: taskID,
                    mutation: .setCompleted(sequence.isMultiple(of: 2))
                )
            )
        }
        let staged = try provisionedReplica(
            deviceID: device(9),
            operations: operations
        )
        var local = try TaskReplica(deviceID: device(9))
        try local.createTask(id: task(2), title: "Local")
        let stagedBefore = try staged.atomicArchiveData()
        let localBefore = try local.atomicArchiveData()

        XCTAssertThrowsError(
            try TaskReplica.keepBothCandidate(
                staged: staged,
                local: local,
                pairID: pairID
            )
        ) {
            XCTAssertEqual(
                $0 as? ReplicaError,
                .tooManyOperations(ReplicaLimits.maxOperations + 1)
            )
        }
        XCTAssertEqual(try staged.atomicArchiveData(), stagedBefore)
        XCTAssertEqual(try local.atomicArchiveData(), localBefore)
    }

    func testOriginLimitFailureLeavesSourcesUntouched() throws {
        let operations = (1...ReplicaLimits.maxOrigins).map { origin in
            operation(
                origin: UInt8(origin),
                sequence: 1,
                taskID: task(UInt16(100 + origin)),
                mutation: .delete
            )
        }
        let staged = try provisionedReplica(
            deviceID: device(9),
            operations: operations
        )
        var local = try TaskReplica(deviceID: device(9))
        try local.createTask(id: task(1), title: "Local")
        let stagedBefore = try staged.atomicArchiveData()
        let localBefore = try local.atomicArchiveData()

        XCTAssertThrowsError(
            try TaskReplica.keepBothCandidate(
                staged: staged,
                local: local,
                pairID: pairID
            )
        ) {
            XCTAssertEqual(
                $0 as? ReplicaError,
                .tooManyOrigins(ReplicaLimits.maxOrigins + 1)
            )
        }
        XCTAssertEqual(try staged.atomicArchiveData(), stagedBefore)
        XCTAssertEqual(try local.atomicArchiveData(), localBefore)
    }

    private var pairID: Data {
        Data(repeating: 0x41, count: 16)
    }

    private func provisionedReplica(
        deviceID: ReplicaDeviceID,
        operations: [TaskOperation],
        persistenceURL: URL? = nil
    ) throws -> TaskReplica {
        var sequences: [ReplicaDeviceID: UInt64] = [:]
        var records: [UUID: ReplicatedTask] = [:]
        for operation in operations {
            sequences[operation.originDeviceID] = max(
                sequences[operation.originDeviceID, default: 0],
                operation.originSequence
            )
            var record = records[operation.taskID] ?? ReplicatedTask(
                id: operation.taskID,
                title: nil,
                completed: nil,
                deletion: nil
            )
            switch operation.mutation {
            case .create(let title, let completed):
                record.title = LWWRegister(
                    value: title,
                    stamp: operation.stamp
                )
                record.completed = LWWRegister(
                    value: completed,
                    stamp: operation.stamp
                )
            case .setTitle(let title):
                record.title = LWWRegister(
                    value: title,
                    stamp: operation.stamp
                )
            case .setCompleted(let completed):
                record.completed = LWWRegister(
                    value: completed,
                    stamp: operation.stamp
                )
            case .delete:
                record.deletion = max(record.deletion ?? operation.stamp, operation.stamp)
            }
            records[operation.taskID] = record
        }
        let archive = ReplicaProvisioningArchive(
            formatVersion: ReplicaLimits.archiveFormatVersion,
            sourceDeviceID: operations.first?.originDeviceID ?? device(1),
            lamport: operations.map(\.lamport).max() ?? 0,
            versionVector: try ReplicaVersionVector(sequences),
            taskRecords: Array(records.values),
            operations: operations
        )
        return try TaskReplica.provision(
            deviceID: deviceID,
            from: archive.canonicalData(),
            persistenceURL: persistenceURL
        )
    }

    private func device(_ byte: UInt8) -> ReplicaDeviceID {
        try! ReplicaDeviceID(bytes: Data(repeating: byte, count: 16))
    }

    private func task(_ value: UInt16) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", value))!
    }

    private func operation(
        origin: UInt8,
        sequence: UInt64,
        taskID: UUID,
        mutation: TaskMutation
    ) -> TaskOperation {
        TaskOperation(
            originDeviceID: device(origin),
            originSequence: sequence,
            lamport: sequence,
            taskID: taskID,
            mutation: mutation
        )
    }
}
