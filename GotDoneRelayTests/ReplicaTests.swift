import Foundation
import XCTest
@testable import GotDoneRelay

final class ReplicaTests: XCTestCase {
    func testLocalSequencesAndLamportStartAtOne() throws {
        var replica = try TaskReplica(deviceID: device(1))
        let taskID = task(1)

        let create = try replica.createTask(id: taskID, title: "First")
        let complete = try replica.setCompleted(taskID: taskID, completed: true)

        XCTAssertEqual(create.originSequence, 1)
        XCTAssertEqual(create.lamport, 1)
        XCTAssertEqual(complete.originSequence, 2)
        XCTAssertEqual(complete.lamport, 2)
        XCTAssertEqual(replica.versionVector[device(1)], 2)
        XCTAssertEqual(replica.lamport, 2)
    }

    func testVisibleTasksAreNewestCreatedFirstDeterministically() throws {
        let olderID = task(301)
        let tieLowID = task(302)
        let tieHighID = task(303)
        let older = operation(
            origin: 1,
            sequence: 1,
            lamport: 4,
            taskID: olderID,
            mutation: .create(title: "Older", completed: false)
        )
        let tieLow = operation(
            origin: 2,
            sequence: 1,
            lamport: 7,
            taskID: tieLowID,
            mutation: .create(title: "Tie low", completed: false)
        )
        let tieHigh = operation(
            origin: 3,
            sequence: 1,
            lamport: 7,
            taskID: tieHighID,
            mutation: .create(title: "Tie high", completed: false)
        )

        for delivery in permutations(of: [older, tieHigh, tieLow]) {
            var replica = try TaskReplica(deviceID: device(9))
            try replica.applyRemote(delivery)
            XCTAssertEqual(
                replica.tasks.map(\.id),
                [tieHighID, tieLowID, olderID]
            )
        }
    }

    func testPermutationsAndDuplicatesConverge() throws {
        let taskID = task(2)
        let create = operation(
            origin: 1,
            sequence: 1,
            lamport: 1,
            taskID: taskID,
            mutation: .create(title: "Initial", completed: false)
        )
        let titleA = operation(
            origin: 2,
            sequence: 1,
            lamport: 2,
            taskID: taskID,
            mutation: .setTitle("A")
        )
        let completed = operation(
            origin: 3,
            sequence: 1,
            lamport: 2,
            taskID: taskID,
            mutation: .setCompleted(true)
        )
        let titleB = operation(
            origin: 4,
            sequence: 1,
            lamport: 2,
            taskID: taskID,
            mutation: .setTitle("B")
        )

        var expected: Data?
        for permutation in permutations(of: [create, titleA, completed, titleB]) {
            var replica = try TaskReplica(deviceID: device(9))
            XCTAssertEqual(try replica.applyRemote(permutation), 4)
            XCTAssertEqual(try replica.applyRemote(permutation), 0)
            XCTAssertEqual(replica.task(id: taskID)?.titleValue, "B")
            XCTAssertEqual(replica.task(id: taskID)?.isCompleted, true)

            let data = try replica.atomicArchiveData()
            if let expected {
                XCTAssertEqual(data, expected)
            } else {
                expected = data
            }
        }
    }

    func testRemoteUpdateBeforeCreateIsHiddenAndCannotBeEditedLocally() throws {
        let taskID = task(16)
        let update = operation(
            origin: 1,
            sequence: 1,
            lamport: 3,
            taskID: taskID,
            mutation: .setTitle("Arrived first")
        )
        let create = operation(
            origin: 2,
            sequence: 1,
            lamport: 1,
            taskID: taskID,
            mutation: .create(title: "Initial", completed: false)
        )
        var replica = try TaskReplica(deviceID: device(9))

        XCTAssertEqual(try replica.applyRemote([update]), 1)
        XCTAssertTrue(replica.tasks.isEmpty)
        XCTAssertThrowsError(
            try replica.setCompleted(taskID: taskID, completed: true)
        ) {
            XCTAssertEqual($0 as? ReplicaError, .unknownTask(taskID))
        }

        XCTAssertEqual(try replica.applyRemote([create]), 1)
        XCTAssertEqual(replica.tasks.map(\.id), [taskID])
        XCTAssertEqual(replica.task(id: taskID)?.titleValue, "Arrived first")
        XCTAssertEqual(replica.task(id: taskID)?.isCompleted, false)
    }

    func testConcurrentSameAndDifferentFieldsUseIndependentLWWRegisters() throws {
        let taskID = task(3)
        var replica = try TaskReplica(deviceID: device(9))
        try replica.applyRemote([
            operation(
                origin: 1,
                sequence: 1,
                lamport: 1,
                taskID: taskID,
                mutation: .create(title: "Initial", completed: false)
            )
        ])

        try replica.applyRemote([
            operation(
                origin: 3,
                sequence: 1,
                lamport: 7,
                taskID: taskID,
                mutation: .setTitle("Higher device")
            ),
            operation(
                origin: 2,
                sequence: 1,
                lamport: 7,
                taskID: taskID,
                mutation: .setTitle("Lower device")
            ),
            operation(
                origin: 4,
                sequence: 1,
                lamport: 6,
                taskID: taskID,
                mutation: .setCompleted(true)
            )
        ])

        let record = try XCTUnwrap(replica.task(id: taskID))
        XCTAssertEqual(record.titleValue, "Higher device")
        XCTAssertEqual(record.title?.stamp.originDeviceID, device(3))
        XCTAssertEqual(record.isCompleted, true)
        XCTAssertEqual(record.completed?.stamp.originDeviceID, device(4))
    }

    func testDeleteIsGrowOnlyAndDominatesExistingUpdates() throws {
        let taskID = task(4)
        var replica = try TaskReplica(deviceID: device(9))
        let create = operation(
            origin: 1,
            sequence: 1,
            lamport: 1,
            taskID: taskID,
            mutation: .create(title: "Initial", completed: false)
        )
        let update = operation(
            origin: 2,
            sequence: 1,
            lamport: 3,
            taskID: taskID,
            mutation: .setTitle("Updated")
        )
        let delete = operation(
            origin: 3,
            sequence: 1,
            lamport: 2,
            taskID: taskID,
            mutation: .delete
        )

        try replica.applyRemote([create, update, delete])

        XCTAssertTrue(try XCTUnwrap(replica.task(id: taskID)).isDeleted)
        XCTAssertTrue(replica.tasks.isEmpty)
        XCTAssertEqual(try replica.applyRemote([update]), 0)
        XCTAssertThrowsError(try replica.setTitle(taskID: taskID, title: "Restore")) {
            XCTAssertEqual($0 as? ReplicaError, .tombstonedTask(taskID))
        }
        XCTAssertThrowsError(
            try replica.createTask(id: taskID, title: "Restore")
        ) {
            XCTAssertEqual($0 as? ReplicaError, .tombstonedTask(taskID))
        }
    }

    func testDeleteOfUnknownTaskCreatesPermanentTombstone() throws {
        let taskID = task(5)
        var replica = try TaskReplica(deviceID: device(9))
        try replica.applyRemote([
            operation(
                origin: 1,
                sequence: 1,
                lamport: 1,
                taskID: taskID,
                mutation: .delete
            )
        ])

        let record = try XCTUnwrap(replica.task(id: taskID))
        XCTAssertTrue(record.isDeleted)
        XCTAssertNil(record.title)
        XCTAssertNil(record.completed)
        XCTAssertEqual(
            try replica.applyRemote([
                operation(
                    origin: 2,
                    sequence: 1,
                    lamport: 2,
                    taskID: taskID,
                    mutation: .create(title: "Too late", completed: false)
                )
            ]),
            1
        )
        XCTAssertTrue(try XCTUnwrap(replica.task(id: taskID)).isDeleted)
        XCTAssertEqual(replica.task(id: taskID)?.titleValue, "Too late")
        XCTAssertTrue(replica.tasks.isEmpty)
        XCTAssertEqual(replica.versionVector[device(2)], 1)
        XCTAssertThrowsError(
            try replica.createTask(id: taskID, title: "Local restore")
        ) {
            XCTAssertEqual($0 as? ReplicaError, .tombstonedTask(taskID))
        }
    }

    func testConcurrentCreateUpdateDeleteConvergesAcrossDeliveryOrders() throws {
        let taskID = task(15)
        let initialCreate = operation(
            origin: 1,
            sequence: 1,
            lamport: 1,
            taskID: taskID,
            mutation: .create(title: "Initial", completed: false)
        )
        let concurrentCreate = operation(
            origin: 2,
            sequence: 1,
            lamport: 4,
            taskID: taskID,
            mutation: .create(title: "Created again", completed: true)
        )
        let concurrentUpdate = operation(
            origin: 3,
            sequence: 1,
            lamport: 5,
            taskID: taskID,
            mutation: .setTitle("Updated")
        )
        let concurrentDelete = operation(
            origin: 4,
            sequence: 1,
            lamport: 2,
            taskID: taskID,
            mutation: .delete
        )

        var expectedArchive: Data?
        var expectedRecords: [ReplicatedTask]?
        var expectedVector: ReplicaVersionVector?
        var expectedLog: [TaskOperation]?

        for delivery in permutations(
            of: [concurrentCreate, concurrentUpdate, concurrentDelete]
        ) {
            var replica = try TaskReplica(deviceID: device(9))
            try replica.applyRemote([initialCreate])
            XCTAssertEqual(try replica.applyRemote(delivery), 3)

            let record = try XCTUnwrap(replica.task(id: taskID))
            XCTAssertTrue(record.isDeleted)
            XCTAssertEqual(record.titleValue, "Updated")
            XCTAssertEqual(record.isCompleted, true)
            XCTAssertTrue(replica.tasks.isEmpty)
            XCTAssertEqual(replica.versionVector[device(2)], 1)
            XCTAssertEqual(replica.versionVector[device(3)], 1)
            XCTAssertEqual(replica.versionVector[device(4)], 1)

            let archive = try replica.atomicArchiveData()
            if let expectedArchive,
               let expectedRecords,
               let expectedVector,
               let expectedLog {
                XCTAssertEqual(archive, expectedArchive)
                XCTAssertEqual(replica.taskRecords, expectedRecords)
                XCTAssertEqual(replica.versionVector, expectedVector)
                XCTAssertEqual(replica.retainedOperations, expectedLog)
            } else {
                expectedArchive = archive
                expectedRecords = replica.taskRecords
                expectedVector = replica.versionVector
                expectedLog = replica.retainedOperations
            }
        }
    }

    func testGapAndForkRejectWholeBatch() throws {
        let taskID = task(6)
        let first = operation(
            origin: 1,
            sequence: 1,
            lamport: 1,
            taskID: taskID,
            mutation: .create(title: "One", completed: false)
        )
        let third = operation(
            origin: 1,
            sequence: 3,
            lamport: 3,
            taskID: taskID,
            mutation: .setTitle("Three")
        )
        var replica = try TaskReplica(deviceID: device(9))
        let before = try replica.atomicArchiveData()

        XCTAssertThrowsError(try replica.applyRemote([first, third])) {
            XCTAssertEqual(
                $0 as? ReplicaError,
                .sequenceGap(origin: device(1), expected: 2, received: 3)
            )
        }
        XCTAssertEqual(try replica.atomicArchiveData(), before)

        XCTAssertEqual(try replica.applyRemote([first]), 1)
        XCTAssertEqual(try replica.applyRemote([first]), 0)

        let fork = operation(
            origin: 1,
            sequence: 1,
            lamport: 1,
            taskID: taskID,
            mutation: .create(title: "Fork", completed: false)
        )
        XCTAssertThrowsError(try replica.applyRemote([fork])) {
            XCTAssertEqual(
                $0 as? ReplicaError,
                .operationFork(origin: device(1), sequence: 1)
            )
        }
    }

    func testPersistenceReloadAndProvisioning() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hostURL = directory.appendingPathComponent("host.json")
        let joinerURL = directory.appendingPathComponent("joiner.json")
        let taskID = task(7)

        var host = try TaskReplica(deviceID: device(1), persistenceURL: hostURL)
        try host.createTask(id: taskID, title: "Durable")
        try host.setCompleted(taskID: taskID, completed: true)
        let expectedData = try host.atomicArchiveData()

        var reloaded = try TaskReplica(deviceID: device(1), persistenceURL: hostURL)
        XCTAssertEqual(try reloaded.atomicArchiveData(), expectedData)
        XCTAssertEqual(reloaded.task(id: taskID)?.isCompleted, true)
        let third = try reloaded.setTitle(taskID: taskID, title: "Reloaded")
        XCTAssertEqual(third.originSequence, 3)

        let provisioningA = try reloaded.exportProvisioningArchive()
        let provisioningB = try reloaded.exportProvisioningArchive()
        XCTAssertEqual(provisioningA, provisioningB)

        var joiner = try TaskReplica.provision(
            deviceID: device(2),
            from: provisioningA,
            persistenceURL: joinerURL
        )
        XCTAssertEqual(joiner.deviceID, device(2))
        XCTAssertEqual(joiner.task(id: taskID)?.titleValue, "Reloaded")
        XCTAssertEqual(joiner.versionVector[device(1)], 3)
        let joinerEdit = try joiner.setCompleted(taskID: taskID, completed: false)
        XCTAssertEqual(joinerEdit.originDeviceID, device(2))
        XCTAssertEqual(joinerEdit.originSequence, 1)

        let joinerReloaded = try TaskReplica(
            deviceID: device(2),
            persistenceURL: joinerURL
        )
        XCTAssertEqual(
            try joinerReloaded.atomicArchiveData(),
            try joiner.atomicArchiveData()
        )
    }

    func testProvisioningRejectsNonCanonicalAndNonemptyDestination() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("replica.json")

        var host = try TaskReplica(deviceID: device(1))
        try host.createTask(id: task(8), title: "Host")
        let canonical = try host.exportProvisioningArchive()
        var nonCanonical = canonical
        nonCanonical.append(0x0A)

        XCTAssertThrowsError(
            try TaskReplica.provision(deviceID: device(2), from: nonCanonical)
        ) {
            XCTAssertEqual($0 as? ReplicaError, .nonCanonicalArchive)
        }

        var existing = try TaskReplica(deviceID: device(2), persistenceURL: destination)
        try existing.createTask(id: task(9), title: "Existing")
        XCTAssertThrowsError(
            try TaskReplica.provision(
                deviceID: device(2),
                from: canonical,
                persistenceURL: destination
            )
        ) {
            XCTAssertEqual($0 as? ReplicaError, .provisioningRequiresEmptyReplica)
        }
    }

    func testProvisioningResumesPreviouslyLinkedDeviceSequence() throws {
        let hostID = device(1)
        let joinerID = device(2)
        var host = try TaskReplica(deviceID: hostID)
        try host.createTask(id: task(10), title: "Host")
        var firstJoin = try TaskReplica.provision(
            deviceID: joinerID,
            from: host.exportProvisioningArchive()
        )
        let firstJoinerEdit = try firstJoin.createTask(
            id: task(11),
            title: "First join"
        )
        _ = try host.applyRemote([firstJoinerEdit])

        var rejoined = try TaskReplica.provision(
            deviceID: joinerID,
            from: host.exportProvisioningArchive()
        )
        let nextJoinerEdit = try rejoined.createTask(
            id: task(12),
            title: "After rejoin"
        )

        XCTAssertEqual(rejoined.versionVector[joinerID], 2)
        XCTAssertEqual(nextJoinerEdit.originDeviceID, joinerID)
        XCTAssertEqual(nextJoinerEdit.originSequence, 2)
        XCTAssertEqual(try host.applyRemote([nextJoinerEdit]), 1)
    }

    func testMissingOperationsAndVectorEntriesAreDeterministicallySorted() throws {
        var replica = try TaskReplica(deviceID: device(9))
        let originTwoCreate = operation(
            origin: 2,
            sequence: 1,
            lamport: 1,
            taskID: task(10),
            mutation: .create(title: "Two", completed: false)
        )
        let originOneCreate = operation(
            origin: 1,
            sequence: 1,
            lamport: 1,
            taskID: task(11),
            mutation: .create(title: "One", completed: false)
        )
        let originOneUpdate = operation(
            origin: 1,
            sequence: 2,
            lamport: 2,
            taskID: task(11),
            mutation: .setTitle("One updated")
        )
        try replica.applyRemote([originTwoCreate, originOneCreate, originOneUpdate])

        let peer = try ReplicaVersionVector([device(1): 1])
        let missing = replica.operations(missingFrom: peer)

        XCTAssertEqual(missing, [originOneUpdate, originTwoCreate])
        XCTAssertEqual(
            replica.versionVector.entries.map(\.originDeviceID),
            [device(1), device(2)]
        )
        XCTAssertTrue(replica.versionVector.isAtLeast(peer))
    }

    func testTitleBatchOriginTaskAndOperationBounds() throws {
        var replica = try TaskReplica(deviceID: device(9))

        XCTAssertThrowsError(
            try replica.createTask(id: task(12), title: String(repeating: "a", count: 201))
        ) {
            XCTAssertEqual(
                $0 as? ReplicaError,
                .titleExceedsUnicodeScalarLimit(201)
            )
        }
        XCTAssertThrowsError(
            try replica.createTask(id: task(12), title: String(repeating: "🦊", count: 129))
        ) {
            XCTAssertEqual($0 as? ReplicaError, .titleExceedsUTF8Limit(516))
        }

        let repeated = Array(
            repeating: operation(
                origin: 1,
                sequence: 1,
                lamport: 1,
                taskID: task(12),
                mutation: .create(title: "Bounded", completed: false)
            ),
            count: 257
        )
        XCTAssertThrowsError(try replica.applyRemote(repeated)) {
            XCTAssertEqual($0 as? ReplicaError, .batchExceedsOperationLimit(257))
        }

        for origin in 1...8 {
            try replica.applyRemote([
                operation(
                    origin: UInt8(origin),
                    sequence: 1,
                    lamport: 1,
                    taskID: task(UInt16(100 + origin)),
                    mutation: .delete
                )
            ])
        }
        XCTAssertThrowsError(
            try replica.applyRemote([
                operation(
                    origin: 10,
                    sequence: 1,
                    lamport: 1,
                    taskID: task(200),
                    mutation: .delete
                )
            ])
        ) {
            XCTAssertEqual($0 as? ReplicaError, .tooManyOrigins(9))
        }

        XCTAssertThrowsError(
            try ReplicaVersionVector(
                Dictionary(uniqueKeysWithValues: (1...9).map {
                    (device(UInt8($0)), UInt64(1))
                })
            )
        ) {
            XCTAssertEqual($0 as? ReplicaError, .tooManyOrigins(9))
        }

        XCTAssertThrowsError(try ReplicaDeviceID(bytes: Data(repeating: 1, count: 15))) {
            XCTAssertEqual($0 as? ReplicaError, .invalidDeviceIDLength(15))
        }
    }

    func testArchiveRejectsMaterializedTaskAndOperationLimits() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let emptyVector = ReplicaVersionVector()
        let excessiveTasks = ReplicaArchive(
            formatVersion: ReplicaLimits.archiveFormatVersion,
            deviceID: device(9),
            nextLocalOriginSequence: 1,
            lamport: 0,
            versionVector: emptyVector,
            taskRecords: (1...1_001).map {
                ReplicatedTask(
                    id: task(UInt16($0)),
                    title: nil,
                    completed: nil,
                    deletion: nil
                )
            },
            operations: []
        )
        let taskURL = directory.appendingPathComponent("tasks.json")
        try excessiveTasks.canonicalData().write(to: taskURL, options: .atomic)
        XCTAssertThrowsError(
            try TaskReplica(deviceID: device(9), persistenceURL: taskURL)
        ) {
            XCTAssertEqual($0 as? ReplicaError, .tooManyTasks(1_001))
        }

        let repeatedOperation = operation(
            origin: 1,
            sequence: 1,
            lamport: 1,
            taskID: task(1),
            mutation: .delete
        )
        let excessiveOperations = ReplicaArchive(
            formatVersion: ReplicaLimits.archiveFormatVersion,
            deviceID: device(9),
            nextLocalOriginSequence: 1,
            lamport: 1,
            versionVector: try ReplicaVersionVector([device(1): 1]),
            taskRecords: [
                ReplicatedTask(
                    id: task(1),
                    title: nil,
                    completed: nil,
                    deletion: repeatedOperation.stamp
                )
            ],
            operations: Array(repeating: repeatedOperation, count: 10_001)
        )
        let operationURL = directory.appendingPathComponent("operations.json")
        try excessiveOperations.canonicalData().write(to: operationURL, options: .atomic)
        XCTAssertThrowsError(
            try TaskReplica(deviceID: device(9), persistenceURL: operationURL)
        ) {
            XCTAssertEqual($0 as? ReplicaError, .tooManyOperations(10_001))
        }
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
        lamport: UInt64,
        taskID: UUID,
        mutation: TaskMutation
    ) -> TaskOperation {
        TaskOperation(
            originDeviceID: device(origin),
            originSequence: sequence,
            lamport: lamport,
            taskID: taskID,
            mutation: mutation
        )
    }

    private func permutations<T>(of values: [T]) -> [[T]] {
        guard let first = values.first else {
            return [[]]
        }
        return permutations(of: Array(values.dropFirst())).flatMap { permutation in
            (0...permutation.count).map { index in
                var result = permutation
                result.insert(first, at: index)
                return result
            }
        }
    }
}
