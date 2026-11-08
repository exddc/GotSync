import Foundation
import XCTest
@testable import GotSync

final class HostJournalMessageTests: XCTestCase {
    private let member = Data(repeating: 0x21, count: 32)
    private let origin = try! ReplicaDeviceID(bytes: Data(repeating: 0x31, count: 16))

    func testEveryKindRoundTripsAndControlsMapToTheEngineValues() throws {
        let vector = try ReplicaVersionVector([origin: 4])
        let controls: [ReplicationMessage] = [
            .hello(vector: vector, provider: member),
            .hello(vector: ReplicaVersionVector(), provider: nil),
            .reservation(member: member, origins: [origin], epoch: 3),
            .release(member: member, reservation: 9),
            .reservations([OriginReservation(member: member, owner: member, origins: [origin], epoch: 1, cursor: 2)], overflowed: true, for: member),
            .reservations([], overflowed: false, for: member),
        ]
        for control in controls {
            let message = try HostJournalMessage(control: control)
            let decoded = try HostJournalMessage.decode(message.encoded())
            XCTAssertEqual(decoded, message)
            XCTAssertEqual(decoded.version, 3)
            XCTAssertEqual(decoded.control, control)
        }
        let records = HostJournalMessage.records([Data([1]), Data([2, 3])])
        XCTAssertEqual(try HostJournalMessage.decode(records.encoded()), records)
        XCTAssertNil(records.control)
        let complete = HostJournalMessage.complete(member: member, through: vector)
        XCTAssertEqual(try HostJournalMessage.decode(complete.encoded()), complete)
        XCTAssertThrowsError(try HostJournalMessage(control: .operations([])))
    }

    func testDecodingIsStrict() throws {
        let vector = try ReplicaVersionVector([origin: 1])
        func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
        let invalid: [[String: Any]] = [
            ["version": 3, "kind": "records", "records": [] as [String]],
            ["version": 3, "kind": "records", "records": [Data([1]).base64EncodedString()], "member": member.base64EncodedString()],
            ["version": 3, "kind": "records", "records": Array(repeating: Data([1]).base64EncodedString(), count: 257)],
            ["version": 3, "kind": "records", "records": [Data(count: 262_145).base64EncodedString()]],
            ["version": 3, "kind": "records", "records": [""]],
            ["version": 3, "kind": "complete", "member": member.base64EncodedString()],
            ["version": 3, "kind": "complete", "through": [] as [Any]],
            ["version": 3, "kind": "hello"],
            ["version": 3, "kind": "release", "member": member.base64EncodedString()],
        ]
        for object in invalid {
            XCTAssertThrowsError(try HostJournalMessage.decode(json(object)), "\(object)")
        }
        let demo = try ReplicationMessage.hello(vector: vector, provider: nil).encoded()
        XCTAssertThrowsError(try HostJournalMessage.decode(demo)) { XCTAssertEqual($0 as? WireMessageError, .invalidVersion) }
        let host = try HostJournalMessage(control: .hello(vector: vector, provider: nil)).encoded()
        XCTAssertThrowsError(try ReplicationMessage.decode(host)) { XCTAssertEqual($0 as? WireMessageError, .invalidVersion) }
        XCTAssertThrowsError(try HostJournalMessage.decode(Data(count: ProtocolLimits.plaintextBytes + 1)))
    }

    func testTheLargestRecordsMessageFitsThePlaintextLimit() throws {
        let envelopes = Array(repeating: Data(count: HostJournalMessage.maxRecordBytes / 256), count: 256)
        let message = HostJournalMessage.records(envelopes)
        let encoded = try message.encoded()
        XCTAssertLessThanOrEqual(encoded.count, ProtocolLimits.plaintextBytes)
        XCTAssertEqual(try HostJournalMessage.decode(encoded), message)
    }
}
