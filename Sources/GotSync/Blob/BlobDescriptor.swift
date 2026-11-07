import CryptoKit
import Foundation

struct BlobDescriptor: Equatable, Sendable {
    static let magic = Data("GSB1".utf8)
    static let version: UInt8 = 1
    static let fixedLength = 119
    static let maxMediaTypeLength = 64
    static let maxLength = fixedLength + maxMediaTypeLength

    let objectID: Data
    let key: Data
    let layout: BlobPartLayout
    let contentHash: Data
    let pixelWidth: UInt32
    let pixelHeight: UInt32
    let mediaType: String

    init(
        objectID: Data,
        key: Data,
        plaintextLength: UInt64,
        contentHash: Data,
        pixelWidth: UInt32,
        pixelHeight: UInt32,
        mediaType: String
    ) throws {
        let mediaTypeBytes = Array(mediaType.utf8)
        guard objectID.count == BlobFormat.hashLength,
              key.count == 32,
              let layout = try? BlobPartLayout(plaintextLength: plaintextLength),
              contentHash.count == BlobFormat.hashLength,
              pixelWidth >= 1, pixelHeight >= 1,
              Self.isValidMediaType(mediaTypeBytes)
        else {
            throw BlobCodecError.malformedDescriptor
        }
        self.objectID = Data(objectID)
        self.key = Data(key)
        self.layout = layout
        self.contentHash = Data(contentHash)
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.mediaType = mediaType
    }

    init(decoding encoded: Data) throws {
        let header = [UInt8](encoded.prefix(6))
        guard header.count == 6, Data(header.prefix(4)) == Self.magic else {
            throw BlobCodecError.malformedDescriptor
        }
        guard header[4] == Self.version, header[5] == 0 else {
            throw BlobCodecError.unsupportedDescriptor(version: header[4], flags: header[5])
        }
        guard encoded.count > Self.fixedLength, encoded.count <= Self.maxLength else {
            throw BlobCodecError.malformedDescriptor
        }
        let bytes = [UInt8](encoded)
        let mediaTypeBytes = Array(bytes[Self.fixedLength...])
        guard Int(bytes[118]) == mediaTypeBytes.count else {
            throw BlobCodecError.malformedDescriptor
        }
        try self.init(
            objectID: Data(bytes[6..<38]),
            key: Data(bytes[38..<70]),
            plaintextLength: Self.bigEndian(bytes[70..<78]),
            contentHash: Data(bytes[78..<110]),
            pixelWidth: Self.bigEndian(bytes[110..<114]),
            pixelHeight: Self.bigEndian(bytes[114..<118]),
            mediaType: String(decoding: mediaTypeBytes, as: UTF8.self)
        )
    }

    static func digest(of encoded: Data) -> Data {
        Data(SHA256.hash(data: encoded))
    }

    var plaintextLength: UInt64 { layout.plaintextLength }

    func encoded() -> Data {
        let mediaTypeBytes = Data(mediaType.utf8)
        var data = Self.magic
        data.reserveCapacity(Self.fixedLength + mediaTypeBytes.count)
        data.append(Self.version)
        data.append(0)
        data.append(objectID)
        data.append(key)
        data.appendBigEndian(plaintextLength)
        data.append(contentHash)
        data.appendBigEndian(pixelWidth)
        data.appendBigEndian(pixelHeight)
        data.append(UInt8(mediaTypeBytes.count))
        data.append(mediaTypeBytes)
        return data
    }

    var digest: Data {
        Self.digest(of: encoded())
    }

    private static func isValidMediaType(_ bytes: [UInt8]) -> Bool {
        (1...maxMediaTypeLength).contains(bytes.count) && bytes.allSatisfy { (0x21...0x7E).contains($0) }
    }

    private static func bigEndian<Value: FixedWidthInteger>(_ bytes: ArraySlice<UInt8>) -> Value {
        bytes.reduce(Value.zero) { $0 << 8 | Value($1) }
    }
}
