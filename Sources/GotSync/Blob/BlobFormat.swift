import CryptoKit
import Foundation

enum BlobFormat {
    static let plaintextPartLength = 524_288
    static let tagLength = 16
    static let ciphertextPartLength = plaintextPartLength + tagLength
    static let maxPlaintextLength: UInt64 = 10_485_760
    static let maxPartCount = 20
    static let maxCiphertextLength: UInt64 = 10_486_080
    static let hashLength = 32
    static let partPrefix = Data("GSB1-part".utf8)
    static let objectPrefix = Data("GSB1-object".utf8)
}

enum BlobCodecError: Error, Equatable {
    case invalidRoute
    case invalidPlaintextLength(UInt64)
    case invalidCiphertextLength(UInt64)
    case partCountMismatch(expected: Int, actual: Int)
    case invalidPartHash(index: Int)
    case malformedDescriptor
    case unsupportedDescriptor(version: UInt8, flags: UInt8)
    case outputNotEmpty
    case sourceChanged
    case ciphertextLengthMismatch(expected: UInt64, actual: UInt64)
    case objectIDMismatch
    case partHashMismatch(index: Int)
    case authenticationFailed(index: Int)
    case contentHashMismatch
    case sourceMismatch
    case routeOrDescriptorMismatch
    case storedOutputMismatch
}

struct BlobRoute: Hashable, Sendable {
    let bytes: Data

    init(_ bytes: Data) throws {
        guard bytes.count == 32 else {
            throw BlobCodecError.invalidRoute
        }
        self.bytes = Data(bytes)
    }
}

struct BlobPartLayout: Equatable, Sendable {
    let plaintextLength: UInt64
    let partCount: Int

    init(plaintextLength: UInt64) throws {
        guard plaintextLength >= 1, plaintextLength <= BlobFormat.maxPlaintextLength else {
            throw BlobCodecError.invalidPlaintextLength(plaintextLength)
        }
        let partLength = UInt64(BlobFormat.plaintextPartLength)
        self.plaintextLength = plaintextLength
        partCount = Int((plaintextLength + partLength - 1) / partLength)
    }

    init(ciphertextLength: UInt64) throws {
        guard ciphertextLength >= 1, ciphertextLength <= BlobFormat.maxCiphertextLength else {
            throw BlobCodecError.invalidCiphertextLength(ciphertextLength)
        }
        let partLength = UInt64(BlobFormat.ciphertextPartLength)
        let count = (ciphertextLength + partLength - 1) / partLength
        let lastLength = ciphertextLength - (count - 1) * partLength
        guard count <= UInt64(BlobFormat.maxPartCount), lastLength > UInt64(BlobFormat.tagLength) else {
            throw BlobCodecError.invalidCiphertextLength(ciphertextLength)
        }
        try self.init(plaintextLength: ciphertextLength - UInt64(BlobFormat.tagLength) * count)
        guard self.ciphertextLength == ciphertextLength, partCount == Int(count) else {
            throw BlobCodecError.invalidCiphertextLength(ciphertextLength)
        }
    }

    var ciphertextLength: UInt64 {
        plaintextLength + UInt64(BlobFormat.tagLength * partCount)
    }

    func plaintextLength(ofPart index: Int) -> Int {
        precondition(index >= 0 && index < partCount)
        guard index == partCount - 1 else {
            return BlobFormat.plaintextPartLength
        }
        return Int(plaintextLength - UInt64(index * BlobFormat.plaintextPartLength))
    }

    func ciphertextLength(ofPart index: Int) -> Int {
        plaintextLength(ofPart: index) + BlobFormat.tagLength
    }

    func ciphertextOffset(ofPart index: Int) -> UInt64 {
        precondition(index >= 0 && index < partCount)
        return UInt64(index * BlobFormat.ciphertextPartLength)
    }

    func nonce(ofPart index: Int) throws -> AES.GCM.Nonce {
        var bytes = Data(count: 4)
        bytes.appendBigEndian(UInt64(index))
        return try AES.GCM.Nonce(data: bytes)
    }

    func authenticatedData(ofPart index: Int, route: BlobRoute) -> Data {
        var data = BlobFormat.partPrefix
        data.append(route.bytes)
        data.appendBigEndian(plaintextLength)
        data.appendBigEndian(UInt32(partCount))
        data.appendBigEndian(UInt32(index))
        return data
    }
}

struct BlobManifest: Equatable, Sendable {
    let route: BlobRoute
    let layout: BlobPartLayout
    let partHashes: [Data]

    init(route: BlobRoute, ciphertextLength: UInt64, partHashes: [Data]) throws {
        let layout = try BlobPartLayout(ciphertextLength: ciphertextLength)
        guard partHashes.count == layout.partCount else {
            throw BlobCodecError.partCountMismatch(expected: layout.partCount, actual: partHashes.count)
        }
        for (index, hash) in partHashes.enumerated() where hash.count != BlobFormat.hashLength {
            throw BlobCodecError.invalidPartHash(index: index)
        }
        self.route = route
        self.layout = layout
        self.partHashes = partHashes.map { Data($0) }
    }

    var objectID: Data {
        var hasher = SHA256()
        hasher.update(data: BlobFormat.objectPrefix)
        hasher.update(data: route.bytes)
        var lengths = Data()
        lengths.appendBigEndian(layout.ciphertextLength)
        lengths.appendBigEndian(UInt32(layout.partCount))
        hasher.update(data: lengths)
        for hash in partHashes {
            hasher.update(data: hash)
        }
        return Data(hasher.finalize())
    }
}

extension Data {
    mutating func appendBigEndian<Value: FixedWidthInteger>(_ value: Value) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
