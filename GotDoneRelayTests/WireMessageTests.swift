import XCTest
@testable import GotDoneRelay

final class WireMessageTests: XCTestCase {
    func testOperationBatchesHonorCountAndEncodedByteLimits() throws {
        let origin = ReplicaDeviceID(uuid: UUID())
        let title = String(repeating: "\u{0001}", count: 200)
        let operations = (1...256).map { sequence in
            TaskOperation(
                originDeviceID: origin,
                originSequence: UInt64(sequence),
                lamport: UInt64(sequence),
                taskID: UUID(),
                mutation: .create(title: title, completed: false)
            )
        }

        let batches = try OperationBatcher.batches(operations)

        XCTAssertGreaterThan(batches.count, 1)
        XCTAssertEqual(batches.flatMap { $0 }, operations)
        for batch in batches {
            XCTAssertLessThanOrEqual(
                batch.count,
                ReplicaLimits.maxBatchOperations
            )
            XCTAssertLessThanOrEqual(
                try ReplicaCanonicalJSON.encode(batch).count,
                ReplicaLimits.maxBatchEncodedBytes
            )
        }
    }

    func testProvisioningArchiveLimitFitsEncryptedPlaintextFrame() throws {
        let archive = Data(
            repeating: 0x5a,
            count: ProtocolLimits.provisioningArchiveBytes
        )
        let message = PairWireMessage.provision(
            archive: archive,
            archiveHash: archive.sha256,
            hostDeviceID: Data(repeating: 0x11, count: 16)
        )

        XCTAssertLessThanOrEqual(
            try WireCodec.encode(message).count,
            ProtocolLimits.plaintextBytes
        )
    }
}
