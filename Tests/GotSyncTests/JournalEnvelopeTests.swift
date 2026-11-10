import CryptoKit
import Foundation
import XCTest
@_spi(HostJournalPreview) @testable import GotSync

final class JournalEnvelopeTests: XCTestCase {
    private let origin = Data(repeating: 0xA1, count: 16)

    func testEncodingIsTheExactFixedLayout() throws {
        let prior = Data(repeating: 0x07, count: 32)
        let envelope = try JournalEnvelope(origin: origin, sequence: 0x0102_0304_0506_0708, prior: prior, payload: Data([0xFE, 0xFF]))
        var expected = Data("GSJ1".utf8)
        expected.append(origin)
        expected.append(contentsOf: [1, 2, 3, 4, 5, 6, 7, 8])
        expected.append(prior)
        expected.append(contentsOf: [0, 0, 0, 2, 0xFE, 0xFF])
        XCTAssertEqual(envelope.bytes, expected)
        XCTAssertEqual(envelope.digest, Data(SHA256.hash(data: expected)))
        XCTAssertEqual(try JournalEnvelope(parsing: expected), envelope)
        XCTAssertEqual(
            envelope.digest.map { String(format: "%02x", $0) }.joined(),
            "f0bbf064d95d2d55af099a05be0ab58122ed9046b5d809fec435b1bf0bbdfdd9"
        )
    }

    func testFirstRecordNeedsAZeroPredecessor() throws {
        XCTAssertNoThrow(try JournalEnvelope(origin: origin, sequence: 1, prior: JournalEnvelope.zeroDigest, payload: Data()))
        XCTAssertThrowsError(try JournalEnvelope(origin: origin, sequence: 1, prior: Data(repeating: 1, count: 32), payload: Data())) {
            XCTAssertEqual($0 as? JournalEnvelopeError, .invalidPrior)
        }
        XCTAssertThrowsError(try JournalEnvelope(origin: origin, sequence: 2, prior: Data(count: 31), payload: Data())) {
            XCTAssertEqual($0 as? JournalEnvelopeError, .invalidPrior)
        }
    }

    func testSequenceBoundsAreCheckedWithoutWrapping() throws {
        let prior = Data(repeating: 2, count: 32)
        XCTAssertNoThrow(try JournalEnvelope(origin: origin, sequence: UInt64(Int64.max), prior: prior, payload: Data()))
        for sequence in [UInt64(0), UInt64(Int64.max) + 1, UInt64.max] {
            XCTAssertThrowsError(try JournalEnvelope(origin: origin, sequence: sequence, prior: prior, payload: Data())) {
                XCTAssertEqual($0 as? JournalEnvelopeError, .invalidSequence)
            }
            var bytes = try JournalEnvelope(origin: origin, sequence: 5, prior: prior, payload: Data()).bytes
            bytes.replaceSubrange(20..<28, with: withUnsafeBytes(of: sequence.bigEndian) { Data($0) })
            XCTAssertThrowsError(try JournalEnvelope(parsing: bytes)) {
                XCTAssertEqual($0 as? JournalEnvelopeError, .invalidSequence)
            }
        }
    }

    func testPayloadBoundIsSixtyFourKibibytes() throws {
        let prior = Data(repeating: 3, count: 32)
        let largest = try JournalEnvelope(origin: origin, sequence: 2, prior: prior, payload: Data(count: 65_536))
        XCTAssertEqual(largest.bytes.count, JournalEnvelope.maxLength)
        XCTAssertEqual(try JournalEnvelope(parsing: largest.bytes), largest)
        XCTAssertThrowsError(try JournalEnvelope(origin: origin, sequence: 2, prior: prior, payload: Data(count: 65_537))) {
            XCTAssertEqual($0 as? JournalEnvelopeError, .payloadTooLarge(65_537))
        }
        XCTAssertThrowsError(try JournalEnvelope(parsing: largest.bytes + Data([0]))) {
            XCTAssertEqual($0 as? JournalEnvelopeError, .payloadTooLarge(65_537))
        }
    }

    func testMalformedInputIsRejectedBeforeSlicing() throws {
        let valid = try JournalEnvelope(origin: origin, sequence: 3, prior: Data(repeating: 9, count: 32), payload: Data("abc".utf8)).bytes
        XCTAssertThrowsError(try JournalEnvelope(parsing: Data())) { XCTAssertEqual($0 as? JournalEnvelopeError, .truncated) }
        XCTAssertThrowsError(try JournalEnvelope(parsing: valid.prefix(63))) { XCTAssertEqual($0 as? JournalEnvelopeError, .truncated) }
        XCTAssertThrowsError(try JournalEnvelope(parsing: valid.dropLast())) {
            XCTAssertEqual($0 as? JournalEnvelopeError, .lengthMismatch(expected: 67, actual: 66))
        }
        XCTAssertThrowsError(try JournalEnvelope(parsing: valid + Data([0]))) {
            XCTAssertEqual($0 as? JournalEnvelopeError, .lengthMismatch(expected: 67, actual: 68))
        }
        var magic = valid
        magic[0] = UInt8(ascii: "X")
        XCTAssertThrowsError(try JournalEnvelope(parsing: magic)) { XCTAssertEqual($0 as? JournalEnvelopeError, .badMagic) }
        var huge = valid
        huge.replaceSubrange(60..<64, with: Data([0xFF, 0xFF, 0xFF, 0xFF]))
        XCTAssertThrowsError(try JournalEnvelope(parsing: huge)) {
            XCTAssertEqual($0 as? JournalEnvelopeError, .payloadTooLarge(Int(UInt32.max)))
        }
        XCTAssertThrowsError(try JournalEnvelope(parsing: Data(count: JournalEnvelope.maxLength + 1))) {
            XCTAssertEqual($0 as? JournalEnvelopeError, .payloadTooLarge(65_537))
        }
    }

    func testParsingASliceUsesItsOwnIndices() throws {
        let valid = try JournalEnvelope(origin: origin, sequence: 4, prior: Data(repeating: 4, count: 32), payload: Data("xyz".utf8))
        let framed = Data([0xEE, 0xEE]) + valid.bytes
        XCTAssertEqual(try JournalEnvelope(parsing: framed.dropFirst(2)), valid)
    }
}
