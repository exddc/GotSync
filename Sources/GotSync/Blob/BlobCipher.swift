import CryptoKit
import Foundation

struct BlobSealedObject: Sendable {
    let key: SymmetricKey
    let contentHash: Data
    let manifest: BlobManifest

    fileprivate init(key: SymmetricKey, contentHash: Data, manifest: BlobManifest) {
        self.key = key
        self.contentHash = contentHash
        self.manifest = manifest
    }

    var objectID: Data { manifest.objectID }

    func descriptor(pixelWidth: UInt32, pixelHeight: UInt32, mediaType: String) throws -> BlobDescriptor {
        try BlobDescriptor(
            objectID: objectID,
            key: key.withUnsafeBytes { Data($0) },
            plaintextLength: manifest.layout.plaintextLength,
            contentHash: contentHash,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            mediaType: mediaType
        )
    }
}

struct BlobPreparedObject: Equatable, Sendable {
    let manifest: BlobManifest

    fileprivate init(manifest: BlobManifest) {
        self.manifest = manifest
    }
}

/// Counts the reads and the plaintext/ciphertext buffers the codec holds. CryptoKit-internal
/// copies and other process allocations are not observed.
final class BlobBufferMeter: @unchecked Sendable {
    struct Snapshot: Equatable {
        var reads = 0
        var largestRead = 0
        var bytesRead: UInt64 = 0
        var liveBuffers = 0
        var liveBytes = 0
        var peakLiveBuffers = 0
        var peakLiveBytes = 0
        var encryptedParts = 0
        var decryptedParts = 0
    }

    private let lock = NSLock()
    private var state = Snapshot()

    var snapshot: Snapshot { lock.withLock { state } }

    fileprivate func willRead(_ count: Int) {
        lock.withLock {
            state.reads += 1
            state.largestRead = max(state.largestRead, count)
        }
    }

    fileprivate func acquire(_ count: Int, read: Bool = false) {
        lock.withLock {
            if read { state.bytesRead += UInt64(count) }
            state.liveBuffers += 1
            state.liveBytes += count
            state.peakLiveBuffers = max(state.peakLiveBuffers, state.liveBuffers)
            state.peakLiveBytes = max(state.peakLiveBytes, state.liveBytes)
        }
    }

    fileprivate func release(_ count: Int) {
        lock.withLock {
            state.liveBuffers -= 1
            state.liveBytes -= count
        }
    }

    fileprivate func didEncrypt() { lock.withLock { state.encryptedParts += 1 } }
    fileprivate func didDecrypt() { lock.withLock { state.decryptedParts += 1 } }
}

/// Streaming seal, open and re-derivation of blob objects, one part at a time.
///
/// Every `source` must be a stable private clone that nothing modifies during the call; it is
/// only read. Every `output` must be an empty private scratch file opened for reading and
/// writing that nothing else reads or publishes until the call returns successfully. On any
/// thrown error the output content is unverified: it is truncated as a best effort and must be
/// discarded by the caller. These functions never create, rename or delete files.
enum BlobCipher {
    static func seal(
        source: FileHandle,
        route: BlobRoute,
        output: FileHandle,
        meter: BlobBufferMeter? = nil
    ) throws -> BlobSealedObject {
        try discardingOutputOnFailure(output) {
            try requireEmpty(output)
            let layout = try BlobPartLayout(plaintextLength: try source.seekToEnd())
            let key = SymmetricKey(size: .bits256)
            var contentHasher = SHA256()
            let partHashes = try encrypt(
                source: source, layout: layout, key: key, route: route,
                output: output, contentHasher: &contentHasher, meter: meter
            )
            let manifest = try BlobManifest(route: route, ciphertextLength: layout.ciphertextLength, partHashes: partHashes)
            try verifyStored(output, manifest: manifest, meter: meter)
            return BlobSealedObject(key: key, contentHash: Data(contentHasher.finalize()), manifest: manifest)
        }
    }

    static func open(
        ciphertext: FileHandle,
        manifest: BlobManifest,
        descriptor: BlobDescriptor,
        output: FileHandle,
        meter: BlobBufferMeter? = nil
    ) throws {
        try discardingOutputOnFailure(output) {
            try requireEmpty(output)
            let layout = descriptor.layout
            guard manifest.layout == layout else {
                throw BlobCodecError.ciphertextLengthMismatch(
                    expected: layout.ciphertextLength,
                    actual: manifest.layout.ciphertextLength
                )
            }
            guard manifest.objectID == descriptor.objectID else {
                throw BlobCodecError.objectIDMismatch
            }
            let size = try ciphertext.seekToEnd()
            guard size == layout.ciphertextLength else {
                throw BlobCodecError.ciphertextLengthMismatch(expected: layout.ciphertextLength, actual: size)
            }
            try ciphertext.seek(toOffset: 0)
            let key = SymmetricKey(data: descriptor.key)
            var contentHasher = SHA256()
            for index in 0..<layout.partCount {
                let part = try read(ciphertext, count: layout.ciphertextLength(ofPart: index), meter: meter)
                defer { meter?.release(part.count) }
                guard part.count == layout.ciphertextLength(ofPart: index) else {
                    throw BlobCodecError.sourceChanged
                }
                guard Data(SHA256.hash(data: part)) == manifest.partHashes[index] else {
                    throw BlobCodecError.partHashMismatch(index: index)
                }
                let plaintext: Data
                do {
                    let box = try AES.GCM.SealedBox(
                        nonce: try layout.nonce(ofPart: index),
                        ciphertext: part.prefix(part.count - BlobFormat.tagLength),
                        tag: part.suffix(BlobFormat.tagLength)
                    )
                    plaintext = try AES.GCM.open(
                        box,
                        using: key,
                        authenticating: layout.authenticatedData(ofPart: index, route: manifest.route)
                    )
                } catch {
                    throw BlobCodecError.authenticationFailed(index: index)
                }
                meter?.didDecrypt()
                meter?.acquire(plaintext.count)
                defer { meter?.release(plaintext.count) }
                contentHasher.update(data: plaintext)
                try output.write(contentsOf: plaintext)
            }
            guard try isAtEnd(ciphertext, meter: meter) else {
                throw BlobCodecError.sourceChanged
            }
            guard Data(contentHasher.finalize()) == descriptor.contentHash else {
                throw BlobCodecError.contentHashMismatch
            }
            try output.synchronize()
        }
    }

    static func prepareReupload(
        descriptor: BlobDescriptor,
        route: BlobRoute,
        source: FileHandle,
        output: FileHandle,
        meter: BlobBufferMeter? = nil
    ) throws -> BlobPreparedObject {
        try discardingOutputOnFailure(output) {
            try requireEmpty(output)
            let layout = descriptor.layout
            guard try source.seekToEnd() == layout.plaintextLength,
                  try plaintextHash(of: source, layout: layout, meter: meter) == descriptor.contentHash
            else {
                throw BlobCodecError.sourceMismatch
            }
            var contentHasher = SHA256()
            let partHashes = try encrypt(
                source: source, layout: layout, key: SymmetricKey(data: descriptor.key), route: route,
                output: output, contentHasher: &contentHasher, meter: meter
            )
            guard Data(contentHasher.finalize()) == descriptor.contentHash else {
                throw BlobCodecError.sourceMismatch
            }
            let manifest = try BlobManifest(route: route, ciphertextLength: layout.ciphertextLength, partHashes: partHashes)
            guard manifest.objectID == descriptor.objectID else {
                throw BlobCodecError.routeOrDescriptorMismatch
            }
            try verifyStored(output, manifest: manifest, meter: meter)
            return BlobPreparedObject(manifest: manifest)
        }
    }

    private static func encrypt(
        source: FileHandle,
        layout: BlobPartLayout,
        key: SymmetricKey,
        route: BlobRoute,
        output: FileHandle,
        contentHasher: inout SHA256,
        meter: BlobBufferMeter?
    ) throws -> [Data] {
        try source.seek(toOffset: 0)
        var partHashes: [Data] = []
        for index in 0..<layout.partCount {
            let plaintext = try read(source, count: layout.plaintextLength(ofPart: index), meter: meter)
            defer { meter?.release(plaintext.count) }
            guard plaintext.count == layout.plaintextLength(ofPart: index) else {
                throw BlobCodecError.sourceChanged
            }
            contentHasher.update(data: plaintext)
            let box = try AES.GCM.seal(
                plaintext,
                using: key,
                nonce: try layout.nonce(ofPart: index),
                authenticating: layout.authenticatedData(ofPart: index, route: route)
            )
            meter?.didEncrypt()
            let ciphertext = box.ciphertext
            let tag = box.tag
            meter?.acquire(ciphertext.count + tag.count)
            defer { meter?.release(ciphertext.count + tag.count) }
            var partHasher = SHA256()
            partHasher.update(data: ciphertext)
            partHasher.update(data: tag)
            try output.write(contentsOf: ciphertext)
            try output.write(contentsOf: tag)
            partHashes.append(Data(partHasher.finalize()))
        }
        guard try isAtEnd(source, meter: meter) else {
            throw BlobCodecError.sourceChanged
        }
        return partHashes
    }

    private static func plaintextHash(of source: FileHandle, layout: BlobPartLayout, meter: BlobBufferMeter?) throws -> Data {
        try source.seek(toOffset: 0)
        var hasher = SHA256()
        for index in 0..<layout.partCount {
            let plaintext = try read(source, count: layout.plaintextLength(ofPart: index), meter: meter)
            defer { meter?.release(plaintext.count) }
            guard plaintext.count == layout.plaintextLength(ofPart: index) else {
                throw BlobCodecError.sourceMismatch
            }
            hasher.update(data: plaintext)
        }
        guard try isAtEnd(source, meter: meter) else {
            throw BlobCodecError.sourceMismatch
        }
        return Data(hasher.finalize())
    }

    private static func verifyStored(_ output: FileHandle, manifest: BlobManifest, meter: BlobBufferMeter?) throws {
        try output.synchronize()
        try output.seek(toOffset: 0)
        for index in 0..<manifest.layout.partCount {
            let part = try read(output, count: manifest.layout.ciphertextLength(ofPart: index), meter: meter)
            defer { meter?.release(part.count) }
            guard part.count == manifest.layout.ciphertextLength(ofPart: index),
                  Data(SHA256.hash(data: part)) == manifest.partHashes[index]
            else {
                throw BlobCodecError.storedOutputMismatch
            }
        }
        guard try isAtEnd(output, meter: meter) else {
            throw BlobCodecError.storedOutputMismatch
        }
    }

    private static func read(_ handle: FileHandle, count: Int, meter: BlobBufferMeter?) throws -> Data {
        precondition(count > 0 && count <= BlobFormat.ciphertextPartLength)
        meter?.willRead(count)
        var data = try handle.read(upToCount: count) ?? Data()
        while !data.isEmpty, data.count < count {
            meter?.willRead(count - data.count)
            guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else {
                break
            }
            data.append(chunk)
        }
        meter?.acquire(data.count, read: true)
        return data
    }

    private static func isAtEnd(_ handle: FileHandle, meter: BlobBufferMeter?) throws -> Bool {
        meter?.willRead(1)
        return try handle.read(upToCount: 1)?.isEmpty ?? true
    }

    private static func requireEmpty(_ output: FileHandle) throws {
        guard try output.seekToEnd() == 0 else {
            throw BlobCodecError.outputNotEmpty
        }
    }

    private static func discardingOutputOnFailure<Result>(_ output: FileHandle, _ body: () throws -> Result) throws -> Result {
        do {
            return try body()
        } catch BlobCodecError.outputNotEmpty {
            throw BlobCodecError.outputNotEmpty
        } catch {
            try? output.truncate(atOffset: 0)
            throw error
        }
    }
}
