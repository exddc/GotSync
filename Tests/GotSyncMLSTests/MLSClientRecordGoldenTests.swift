import CryptoKit
import Foundation
import XCTest
@testable import GotSyncMLS

/// The persisted client record of a demo session must carry exactly the
/// fields and values it did before optional host fields existed. The default
/// encoder's key order varies, so the sorted form is compared.
final class MLSClientRecordGoldenTests: XCTestCase {
    func testDemoClientRecordBytesAreUnchanged() throws {
        var record = ClientRecord(
            state: Data([1, 2, 3]), deviceID: Data(repeating: 0x0D, count: 16),
            identity: IdentityRecord(fingerprint: Data(repeating: 0xF1, count: 32)), writerToken: Data(repeating: 0x77, count: 32)
        )
        record.group = Data(repeating: 0x9A, count: 32)
        record.epoch = 7
        record.cursor = 42
        record.pending = MLSDelivery(group: Data(repeating: 0x9A, count: 32), epoch: 7, kind: .application, payload: Data([9]))
        record.pendingPlaintext = Data("pending".utf8)
        record.rejectedApplicationCursors = [3, 5]
        record.inbox = [MLSInboxMessage(cursor: 41, sender: Data(repeating: 0xE2, count: 32), plaintext: Data("hello".utf8))]
        record.departures = [Data(repeating: 0xD1, count: 32)]
        record.pendingTracked = true
        record.sent = [MLSSentMessage(cursor: 40, digest: Data(repeating: 0x5E, count: 32))]
        record.spoke = [Data(repeating: 0xE2, count: 32)]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let encoded = try encoder.encode(record)
        let stored = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? NSDictionary
        XCTAssertEqual(stored, try JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
        XCTAssertEqual(SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined(), Self.recordedDigest)
        XCTAssertEqual(encoded.count, Self.recordedLength)
    }

    private static let recordedDigest = "fb326d3be6dcae64a9cfd889ebb5850f15ffb297ea1599237d292581cbef10d7"
    private static let recordedLength = 789
}
