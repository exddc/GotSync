import Foundation
@_spi(HostJournalPreview) import GotSync
@_spi(HostJournalPreview) import HostJournalPreviewConsumer
import XCTest

final class ValueTests: XCTestCase {
    func testPositionsArePositiveAndWithinStorageRange() throws {
        XCTAssertNil(JournalPosition(rawValue: 0))
        XCTAssertNil(JournalPosition(rawValue: UInt64(Int64.max) + 1))
        let first = try XCTUnwrap(JournalPosition(rawValue: 1))
        let last = try XCTUnwrap(JournalPosition(rawValue: UInt64(Int64.max)))
        XCTAssertLessThan(first, last)
    }

    func testDecodingRejectsZeroAndOutOfRangePositions() throws {
        let decoder = JSONDecoder()
        XCTAssertThrowsError(try decoder.decode(JournalPosition.self, from: Data("0".utf8)))
        XCTAssertThrowsError(try decoder.decode(JournalPosition.self, from: Data("\(UInt64(Int64.max) + 1)".utf8)))
        XCTAssertEqual(try decoder.decode(JournalPosition.self, from: Data("7".utf8)).rawValue, 7)
    }

    func testProvenanceSurvivesPersistence() throws {
        let journalID = Data((0..<16).map { UInt8($0) })
        let enrollmentID = Data((16..<32).map { UInt8($0) })
        for applied in [nil, JournalPosition(rawValue: 42)] {
            let provenance = HostProvenance(journalID: journalID, enrollmentID: enrollmentID, appliedThrough: applied, capturedThrough: 9)
            let decoded = try JSONDecoder().decode(HostProvenance.self, from: JSONEncoder().encode(provenance))
            XCTAssertEqual(decoded, provenance)
        }
    }

    func testProvenanceWithZeroAppliedPositionDoesNotDecode() throws {
        let provenance = HostProvenance(
            journalID: Data(count: 16), enrollmentID: Data(count: 16),
            appliedThrough: JournalPosition(rawValue: 3), capturedThrough: 1
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(provenance)) as? [String: Any])
        object["appliedThrough"] = 0
        let tampered = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(HostProvenance.self, from: tampered))
    }

    func testMutationsAreBuiltFromHostValues() throws {
        let uuid = UUID()
        let mutation = HostMutation(id: HostMutationID(uuid), payload: Data("x".utf8))
        XCTAssertEqual(mutation.id, HostMutationID(uuid))
        XCTAssertEqual(mutation.id.uuid, uuid)
        XCTAssertEqual(mutation.payload, Data("x".utf8))
    }

    func testArchiveCursorDecodingRejectsInvalidSectionsAndKeys() throws {
        for section in [-1, 0, 2, 5] {
            let raw: [String: Any] = ["version": 1, "value": [
                "journalID": Data(count: 16).base64EncodedString(), "revision": 1,
                "section": section, "key": [],
            ]]
            let data = try JSONSerialization.data(withJSONObject: raw)
            XCTAssertThrowsError(try JSONDecoder().decode(HostArchiveCursor.self, from: data))
        }
    }

    @MainActor
    func testReferenceHostKeepsCapturedRowsAcrossLaunches() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let host = try ReferenceHost(url: url)
        try host.capture("a", "1")
        try host.capture("b", "2")
        let relaunched = try ReferenceHost(url: url)
        XCTAssertEqual(relaunched.state, host.state)
        XCTAssertEqual(relaunched.state.capturedThrough, 2)
        XCTAssertEqual(relaunched.state.outbox.count, 2)
        XCTAssertNil(relaunched.state.appliedThrough)
    }

    @MainActor
    func testFailedCaptureSaveDoesNotPublishUnsavedState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try ReferenceHost(url: directory.appendingPathComponent("host.json"))
        let before = host.state
        XCTAssertThrowsError(try host.capture("a", "1"))
        XCTAssertEqual(host.state, before)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try host.capture("a", "1")
        XCTAssertEqual(host.state.capturedThrough, 1)
        XCTAssertEqual(host.state.outbox.count, 1)
    }

    @MainActor
    func testCaptureAtTheCounterLimitPreservesTheSavedState() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var state: [String: Any] = [
            "registers": ["a": "old"], "capturedThrough": UInt64(Int64.max), "outbox": [],
        ]
        let data = try JSONSerialization.data(withJSONObject: state, options: .sortedKeys)
        try data.write(to: url)
        let host = try ReferenceHost(url: url)
        let before = host.state
        XCTAssertThrowsError(try host.capture("a", "new")) {
            XCTAssertEqual($0 as? HostJournalError, .invalidArgument)
        }
        XCTAssertEqual(host.state, before)
        XCTAssertEqual(try Data(contentsOf: url), data)

        state["capturedThrough"] = UInt64(Int64.max) - 1
        try JSONSerialization.data(withJSONObject: state).write(to: url)
        let last = try ReferenceHost(url: url)
        try last.capture("a", "last")
        XCTAssertEqual(last.state.capturedThrough, UInt64(Int64.max))
    }
}
