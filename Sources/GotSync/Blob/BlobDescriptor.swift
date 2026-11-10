import CryptoKit
import Foundation

/// A descriptor of one sealed object. Version 1 describes an image. Version 2,
/// with zero flags, zero dimensions and the fixed `dataMediaType`, describes
/// one chunk of application data. `init(decoding:)` reads only version 1, so an
/// image reader reports version 2 as unsupported instead of taking it for an image.
struct BlobDescriptor: Equatable, Sendable {
    static let magic = Data("GSB1".utf8)
    static let version: UInt8 = 1
    static let dataVersion: UInt8 = 2
    static let dataMediaType = "com.gotdone.sync.application-data"
    static let fixedLength = 119
    static let maxMediaTypeLength = 64
    static let maxLength = fixedLength + maxMediaTypeLength

    let kind: BlobContentKind
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
        kind = .image
        self.objectID = Data(objectID)
        self.key = Data(key)
        self.layout = layout
        self.contentHash = Data(contentHash)
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.mediaType = mediaType
    }

    /// A version 2 descriptor of one application-data chunk.
    init(dataObjectID objectID: Data, key: Data, plaintextLength: UInt64, contentHash: Data) throws {
        guard objectID.count == BlobFormat.hashLength,
              key.count == 32,
              let layout = try? BlobPartLayout(plaintextLength: plaintextLength),
              contentHash.count == BlobFormat.hashLength
        else {
            throw BlobCodecError.malformedDescriptor
        }
        kind = .applicationData
        self.objectID = Data(objectID)
        self.key = Data(key)
        self.layout = layout
        self.contentHash = Data(contentHash)
        pixelWidth = 0
        pixelHeight = 0
        mediaType = Self.dataMediaType
    }

    /// Reads a version 1 image descriptor only.
    init(decoding encoded: Data) throws {
        try self.init(decoding: encoded, accepting: [.image])
    }

    /// Reads a descriptor of any kind in `kinds`. A kind outside `kinds`, any
    /// other version and any nonzero flags are unsupported.
    init(decoding encoded: Data, accepting kinds: Set<BlobContentKind>) throws {
        let header = [UInt8](encoded.prefix(6))
        guard header.count == 6, Data(header.prefix(4)) == Self.magic else {
            throw BlobCodecError.malformedDescriptor
        }
        let kind: BlobContentKind
        switch header[4] {
        case Self.version: kind = .image
        case Self.dataVersion: kind = .applicationData
        default: throw BlobCodecError.unsupportedDescriptor(version: header[4], flags: header[5])
        }
        guard kinds.contains(kind), header[5] == 0 else {
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
        if kind == .applicationData {
            guard bytes[110..<118].allSatisfy({ $0 == 0 }), mediaTypeBytes == Array(Self.dataMediaType.utf8) else {
                throw BlobCodecError.malformedDescriptor
            }
            try self.init(
                dataObjectID: Data(bytes[6..<38]),
                key: Data(bytes[38..<70]),
                plaintextLength: Self.bigEndian(bytes[70..<78]),
                contentHash: Data(bytes[78..<110])
            )
            return
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
        data.append(kind == .image ? Self.version : Self.dataVersion)
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
