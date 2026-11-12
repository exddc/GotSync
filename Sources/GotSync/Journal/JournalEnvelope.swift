import CryptoKit
import Foundation

enum JournalEnvelopeError: Error, Equatable {
    case invalidOrigin
    case invalidSequence
    case invalidPrior
    case payloadTooLarge(Int)
    case truncated
    case badMagic
    case lengthMismatch(expected: Int, actual: Int)
}

/// One host record as `"GSJ1" | origin | sequence | prior | payloadLength | payload`.
/// Its identity is the origin, the sequence and the SHA-256 digest of the
/// exact encoded bytes; `prior` is the digest of the same origin's previous
/// record, or zero bytes for the first.
struct JournalEnvelope: Equatable, Sendable {
    static let magic = Data("GSJ1".utf8)
    static let originLength = 16
    static let digestLength = 32
    static let headerLength = 4 + originLength + 8 + digestLength + 4
    static let maxPayloadLength = 65_536
    static let maxLength = headerLength + maxPayloadLength
    /// Sequences are stored as SQLite integers, so they stop at `Int64.max`.
    static let maxSequence = UInt64(Int64.max)
    static let zeroDigest = Data(count: digestLength)

    let origin: Data
    let sequence: UInt64
    let prior: Data
    let payload: Data
    let bytes: Data
    let digest: Data

    init(origin: Data, sequence: UInt64, prior: Data, payload: Data) throws {
        try Self.validate(origin: origin, sequence: sequence, prior: prior, payloadLength: payload.count)
        var bytes = Data(capacity: Self.headerLength + payload.count)
        bytes.append(Self.magic)
        bytes.append(origin)
        withUnsafeBytes(of: sequence.bigEndian) { bytes.append(contentsOf: $0) }
        bytes.append(prior)
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { bytes.append(contentsOf: $0) }
        bytes.append(payload)
        self.origin = Data(origin)
        self.sequence = sequence
        self.prior = Data(prior)
        self.payload = Data(payload)
        self.bytes = bytes
        digest = Data(SHA256.hash(data: bytes))
    }

    /// Parses exactly one envelope. Lengths are checked before any slice.
    init(parsing input: Data) throws {
        guard input.count >= Self.headerLength else {
            throw JournalEnvelopeError.truncated
        }
        guard input.count <= Self.maxLength else {
            throw JournalEnvelopeError.payloadTooLarge(input.count - Self.headerLength)
        }
        let bytes = Data(input)
        guard bytes.prefix(4) == Self.magic else {
            throw JournalEnvelopeError.badMagic
        }
        var offset = 4
        let origin = bytes.subdata(in: offset..<offset + Self.originLength)
        offset += Self.originLength
        let sequence = bytes.subdata(in: offset..<offset + 8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        offset += 8
        let prior = bytes.subdata(in: offset..<offset + Self.digestLength)
        offset += Self.digestLength
        let declared = bytes.subdata(in: offset..<offset + 4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        offset += 4
        guard UInt64(declared) <= UInt64(Self.maxPayloadLength) else {
            throw JournalEnvelopeError.payloadTooLarge(Int(declared))
        }
        let expected = Self.headerLength + Int(declared)
        guard bytes.count == expected else {
            throw JournalEnvelopeError.lengthMismatch(expected: expected, actual: bytes.count)
        }
        try Self.validate(origin: origin, sequence: sequence, prior: prior, payloadLength: Int(declared))
        self.origin = origin
        self.sequence = sequence
        self.prior = prior
        payload = bytes.subdata(in: offset..<bytes.count)
        self.bytes = bytes
        digest = Data(SHA256.hash(data: bytes))
    }

    var id: JournalRecordID { JournalRecordID(origin: origin, sequence: sequence) }

    private static func validate(origin: Data, sequence: UInt64, prior: Data, payloadLength: Int) throws {
        guard origin.count == originLength else { throw JournalEnvelopeError.invalidOrigin }
        guard sequence >= 1, sequence <= maxSequence else { throw JournalEnvelopeError.invalidSequence }
        guard prior.count == digestLength, sequence > 1 || prior == zeroDigest else {
            throw JournalEnvelopeError.invalidPrior
        }
        guard payloadLength <= maxPayloadLength else { throw JournalEnvelopeError.payloadTooLarge(payloadLength) }
    }
}

struct JournalRecordID: Hashable, Sendable {
    let origin: Data
    let sequence: UInt64
}
