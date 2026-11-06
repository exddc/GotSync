import Foundation
import XCTest
@testable import GotSync

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

    func testForkedOperationReportsRetainedIDsWithDifferentContent() throws {
        let taskID = task(8)
        let first = operation(
            origin: 1,
            sequence: 1,
            lamport: 1,
            taskID: taskID,
            mutation: .create(title: "Before erase", completed: false)
        )
        var replica = try TaskReplica(deviceID: device(9))
        XCTAssertEqual(try replica.applyRemote([first]), 1)

        let reused = operation(
            origin: 1,
            sequence: 1,
            lamport: 1,
            taskID: task(9),
            mutation: .create(title: "After erase", completed: false)
        )
        let next = operation(
            origin: 1,
            sequence: 2,
            lamport: 2,
            taskID: taskID,
            mutation: .setCompleted(true)
        )
        let nextFork = operation(
            origin: 1,
            sequence: 2,
            lamport: 2,
            taskID: taskID,
            mutation: .setCompleted(false)
        )
        XCTAssertNil(try replica.forkedOperation(in: [first, next, next]))
        XCTAssertEqual(try replica.forkedOperation(in: [next, reused]), reused)
        XCTAssertEqual(try replica.forkedOperation(in: [next, nextFork]), nextFork)

        let decomposed = operation(
            origin: 1,
            sequence: 1,
            lamport: 1,
            taskID: taskID,
            mutation: .create(title: "Before erase\u{301}", completed: false)
        )
        let precomposed = operation(
            origin: 1,
            sequence: 1,
            lamport: 1,
            taskID: taskID,
            mutation: .create(title: "Before eras\u{E9}", completed: false)
        )
        XCTAssertEqual(decomposed, precomposed)
        XCTAssertFalse(decomposed.isIdentical(to: precomposed))
    }

    func testNewOriginIsDurableAndIndependentOfDeviceID() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("replica.json")

        var replica = try TaskReplica(deviceID: device(1), persistenceURL: url, newOrigin: device(2))
        let created = try replica.createTask(id: task(1), title: "New origin")
        XCTAssertEqual(created.originDeviceID, device(2))
        XCTAssertEqual(created.originSequence, 1)
        XCTAssertEqual(replica.archive.formatVersion, ReplicaLimits.archiveFormatVersion)

        var reloaded = try TaskReplica(deviceID: device(1), persistenceURL: url, newOrigin: device(3))
        XCTAssertEqual(reloaded.localOrigin, device(2))
        let updated = try reloaded.setCompleted(taskID: task(1), completed: true)
        XCTAssertEqual(updated.originDeviceID, device(2))
        XCTAssertEqual(updated.originSequence, 2)
        XCTAssertThrowsError(try TaskReplica(deviceID: device(2), persistenceURL: url)) {
            XCTAssertEqual($0 as? ReplicaError, .archiveDeviceMismatch(expected: device(2), actual: device(1)))
        }
    }

    func testVersionOneArchiveKeepsDeviceIDAsOrigin() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("replica.json")

        var legacy = try TaskReplica(deviceID: device(1), persistenceURL: url)
        try legacy.createTask(id: task(1), title: "Version 1")
        XCTAssertEqual(legacy.archive.formatVersion, ReplicaLimits.legacyArchiveFormatVersion)
        XCTAssertNil(try ReplicaArchive.decodeCanonical(from: Data(contentsOf: url)).originDeviceID)

        var reloaded = try TaskReplica(deviceID: device(1), persistenceURL: url, newOrigin: device(2))
        XCTAssertEqual(reloaded.localOrigin, device(1))
        let next = try reloaded.setTitle(taskID: task(1), title: "Still version 1")
        XCTAssertEqual(next.originDeviceID, device(1))
        XCTAssertEqual(next.originSequence, 2)
    }

    func testArchiveVersionMustMatchOriginPresence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let cases: [(Int, ReplicaDeviceID?, ReplicaError)] = [
            (ReplicaLimits.legacyArchiveFormatVersion, device(2), .corruptArchive("The origin does not match the archive version.")),
            (ReplicaLimits.archiveFormatVersion, nil, .corruptArchive("The origin does not match the archive version.")),
            (ReplicaLimits.archiveFormatVersion + 1, device(2), .unsupportedArchiveVersion(ReplicaLimits.archiveFormatVersion + 1)),
        ]
        for (version, origin, expected) in cases {
            let archive = ReplicaArchive(
                formatVersion: version,
                deviceID: device(1),
                originDeviceID: origin,
                nextLocalOriginSequence: 1,
                lamport: 0,
                versionVector: ReplicaVersionVector(),
                taskRecords: [],
                operations: []
            )
            let url = directory.appendingPathComponent("\(version)-\(origin != nil).json")
            try archive.canonicalData().write(to: url, options: .atomic)
            XCTAssertThrowsError(try TaskReplica(deviceID: device(1), persistenceURL: url)) {
                XCTAssertEqual($0 as? ReplicaError, expected)
            }
        }
    }

    func testPersistenceReload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hostURL = directory.appendingPathComponent("host.json")
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
    }

    func testRetiredOriginsOutnumberingTheGroupLimitSurviveReloadAndCatchUp() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hostURL = directory.appendingPathComponent("host.json")
        var host = try TaskReplica(deviceID: device(1), persistenceURL: hostURL)
        try host.createTask(id: task(1), title: "Host")
        for origin in 2...ReplicaLimits.maxOrigins {
            try host.applyRemote([
                operation(
                    origin: UInt8(origin),
                    sequence: 1,
                    lamport: 1,
                    taskID: task(UInt16(origin)),
                    mutation: .create(title: "Device \(origin)", completed: false)
                )
            ])
        }
        XCTAssertEqual(host.versionVector.entries.count, ReplicaLimits.maxOrigins)

        let reloaded = try TaskReplica(deviceID: device(1), persistenceURL: hostURL)
        XCTAssertEqual(try reloaded.atomicArchiveData(), try host.atomicArchiveData())
        XCTAssertEqual(reloaded.tasks.count, ReplicaLimits.maxOrigins)

        var replacement = try TaskReplica(deviceID: device(1 + UInt8(ReplicaLimits.maxOrigins)))
        let missing = reloaded.operations(missingFrom: replacement.versionVector)
        for batch in try OperationBatcher.batches(missing) {
            try replacement.applyRemote(batch)
        }
        XCTAssertEqual(replacement.versionVector, reloaded.versionVector)
        XCTAssertEqual(replacement.tasks.map(\.id), reloaded.tasks.map(\.id))
        XCTAssertThrowsError(try replacement.createTask(title: "One origin too many")) {
            XCTAssertEqual($0 as? ReplicaError, .tooManyOrigins(ReplicaLimits.maxOrigins + 1))
        }
    }

    func testHelloCarriesEveryRetainedOriginWithinThePlaintextLimit() throws {
        let full = try ReplicaVersionVector(
            Dictionary(uniqueKeysWithValues: (1...ReplicaLimits.maxOrigins).map {
                (device(UInt8($0)), UInt64.max)
            })
        )
        let encoded = try ReplicationMessage.hello(vector: full, provider: Data(repeating: 7, count: 32)).encoded()
        XCTAssertLessThan(encoded.count, 10 * 1_024)
        XCTAssertEqual(try ReplicationMessage.decode(encoded).vector, full)

        let entries = (1...ReplicaLimits.maxOrigins + 1).map {
            ReplicaVersionVector.Entry(originDeviceID: device(UInt8($0)), sequence: 1)
        }
        let oversized = try ReplicaCanonicalJSON.encode(entries)
        let message = Data(#"{"kind":"hello","vector":"#.utf8) + oversized + Data(#","version":2}"#.utf8)
        XCTAssertThrowsError(try ReplicationMessage.decode(message)) {
            XCTAssertEqual($0 as? ReplicaError, .tooManyOrigins(ReplicaLimits.maxOrigins + 1))
        }
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
        var replica = try TaskReplica(deviceID: device(250))

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

        for origin in 1...ReplicaLimits.maxOrigins {
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
                    origin: UInt8(ReplicaLimits.maxOrigins + 1),
                    sequence: 1,
                    lamport: 1,
                    taskID: task(400),
                    mutation: .delete
                )
            ])
        ) {
            XCTAssertEqual($0 as? ReplicaError, .tooManyOrigins(ReplicaLimits.maxOrigins + 1))
        }

        XCTAssertThrowsError(
            try ReplicaVersionVector(
                Dictionary(uniqueKeysWithValues: (1...ReplicaLimits.maxOrigins + 1).map {
                    (device(UInt8($0)), UInt64(1))
                })
            )
        ) {
            XCTAssertEqual($0 as? ReplicaError, .tooManyOrigins(ReplicaLimits.maxOrigins + 1))
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
            formatVersion: ReplicaLimits.legacyArchiveFormatVersion,
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
            formatVersion: ReplicaLimits.legacyArchiveFormatVersion,
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
