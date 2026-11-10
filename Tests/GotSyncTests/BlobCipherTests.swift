import CryptoKit
import XCTest
@_spi(HostJournalPreview) @_spi(BlobPreview) @testable import GotSync

final class BlobCipherTests: XCTestCase {
    private var directory: URL!
    private var route: BlobRoute!
    private var wrongRoute: BlobRoute!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        route = try BlobRoute(Data(blobHex: BlobVectors.route))
        wrongRoute = try BlobRoute(Data(blobHex: BlobVectors.wrongRoute))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testReuploadOfFrozenVectorsReproducesIndependentCiphertext() throws {
        for vector in BlobVectors.accepted {
            let source = try patternFile(length: vector.plaintextLength)
            let descriptor = try frozenDescriptor(vector, objectID: vector.objectID)

            let first = try scratch()
            let prepared = try BlobCipher.prepareReupload(descriptor: descriptor, route: route, source: source.handle, output: first.handle)
            XCTAssertEqual(prepared.manifest.partHashes.map(\.blobHex), vector.partHashes)
            XCTAssertEqual(prepared.manifest.objectID.blobHex, vector.objectID)
            XCTAssertEqual(try size(first.url), vector.ciphertextLength)
            if vector.plaintextLength == 1 {
                XCTAssertEqual(try Data(contentsOf: first.url).blobHex, BlobVectors.oneByteCiphertext)
            }

            let second = try scratch()
            let again = try BlobCipher.prepareReupload(descriptor: descriptor, route: route, source: source.handle, output: second.handle)
            XCTAssertEqual(again, prepared)
            XCTAssertTrue(FileManager.default.contentsEqual(atPath: first.url.path, andPath: second.url.path))

            let wrongRouteDescriptor = try frozenDescriptor(vector, objectID: vector.wrongRouteObjectID)
            let wrongRouteOutput = try scratch()
            let wrongRouteObject = try BlobCipher.prepareReupload(
                descriptor: wrongRouteDescriptor, route: wrongRoute, source: source.handle, output: wrongRouteOutput.handle
            )
            XCTAssertEqual(wrongRouteObject.manifest.partHashes.map(\.blobHex), vector.wrongRoutePartHashes)

            let opened = try scratch()
            try BlobCipher.open(ciphertext: first.handle, manifest: prepared.manifest, descriptor: descriptor, output: opened.handle)
            XCTAssertEqual(try fileHash(opened.url), vector.contentHash)
        }
    }

    func testReuploadUnderWrongRouteReturnsMismatchWithoutParts() throws {
        let vector = try XCTUnwrap(BlobVectors.accepted.first { $0.partCount == 2 })
        let source = try patternFile(length: vector.plaintextLength)
        let descriptor = try frozenDescriptor(vector, objectID: vector.objectID)
        let meter = BlobBufferMeter()
        let output = try scratch()

        XCTAssertThrowsError(try BlobCipher.prepareReupload(
            descriptor: descriptor, route: wrongRoute, source: source.handle, output: output.handle, meter: meter
        )) {
            XCTAssertEqual($0 as? BlobCodecError, .routeOrDescriptorMismatch)
        }
        XCTAssertEqual(meter.snapshot.encryptedParts, vector.partCount)
        XCTAssertEqual(try size(output.url), 0)

        let otherObject = try frozenDescriptor(vector, objectID: vector.wrongRouteObjectID)
        let otherOutput = try scratch()
        XCTAssertThrowsError(try BlobCipher.prepareReupload(
            descriptor: otherObject, route: route, source: source.handle, output: otherOutput.handle
        )) {
            XCTAssertEqual($0 as? BlobCodecError, .routeOrDescriptorMismatch)
        }
        XCTAssertEqual(try size(otherOutput.url), 0)
    }

    func testChangedSourceIsRejectedBeforeEncryption() throws {
        let vector = try XCTUnwrap(BlobVectors.accepted.first { $0.partCount == 2 })
        let descriptor = try frozenDescriptor(vector, objectID: vector.objectID)
        let length = Int(vector.plaintextLength)

        for offset in [0, length / 2, length - 1] {
            let source = try patternFile(length: vector.plaintextLength) { start, chunk in
                if (start..<(start + chunk.count)).contains(offset) { chunk[offset - start] ^= 0x01 }
            }
            let meter = BlobBufferMeter()
            let output = try scratch()
            XCTAssertThrowsError(try BlobCipher.prepareReupload(
                descriptor: descriptor, route: route, source: source.handle, output: output.handle, meter: meter
            )) {
                XCTAssertEqual($0 as? BlobCodecError, .sourceMismatch)
            }
            XCTAssertEqual(meter.snapshot.encryptedParts, 0, "offset \(offset)")
            XCTAssertEqual(try size(output.url), 0)
        }

        for changedLength in [vector.plaintextLength - 1, vector.plaintextLength + 1] {
            let source = try patternFile(length: changedLength)
            let meter = BlobBufferMeter()
            let output = try scratch()
            XCTAssertThrowsError(try BlobCipher.prepareReupload(
                descriptor: descriptor, route: route, source: source.handle, output: output.handle, meter: meter
            )) {
                XCTAssertEqual($0 as? BlobCodecError, .sourceMismatch)
            }
            XCTAssertEqual(meter.snapshot.reads, 0)
            XCTAssertEqual(meter.snapshot.encryptedParts, 0)
        }
    }

    func testIndependentSealsOfOnePlaintextAreUnrelatedAndBothOpen() throws {
        for length: UInt64 in [1, 524_289] {
            let source = try patternFile(length: length)
            let firstOutput = try scratch()
            let secondOutput = try scratch()
            let first = try BlobCipher.seal(source: source.handle, route: route, output: firstOutput.handle)
            let second = try BlobCipher.seal(source: source.handle, route: route, output: secondOutput.handle)

            let firstDescriptor = try first.descriptor(pixelWidth: 4, pixelHeight: 3, mediaType: "public.png")
            let secondDescriptor = try second.descriptor(pixelWidth: 4, pixelHeight: 3, mediaType: "public.png")
            XCTAssertNotEqual(firstDescriptor.key, secondDescriptor.key)
            XCTAssertNotEqual(first.objectID, second.objectID)
            XCTAssertTrue(Set(first.manifest.partHashes).isDisjoint(with: second.manifest.partHashes))
            XCTAssertNotEqual(firstDescriptor.digest, secondDescriptor.digest)
            XCTAssertEqual(first.contentHash, second.contentHash)
            XCTAssertEqual(first.contentHash.blobHex, try fileHash(source.url))

            for (sealed, descriptor, output) in [(first, firstDescriptor, firstOutput), (second, secondDescriptor, secondOutput)] {
                let opened = try scratch()
                try BlobCipher.open(ciphertext: output.handle, manifest: sealed.manifest, descriptor: descriptor, output: opened.handle)
                XCTAssertTrue(FileManager.default.contentsEqual(atPath: opened.url.path, andPath: source.url.path))
            }
        }
    }

    func testSealOpenAndReuploadRoundTripAtEveryBoundaryLength() throws {
        for vector in BlobVectors.accepted {
            let source = try patternFile(length: vector.plaintextLength)
            let output = try scratch()
            let sealed = try BlobCipher.seal(source: source.handle, route: route, output: output.handle)
            XCTAssertEqual(sealed.manifest.layout.partCount, vector.partCount)
            XCTAssertEqual(try size(output.url), vector.ciphertextLength)
            XCTAssertEqual(sealed.contentHash.blobHex, vector.contentHash)
            let descriptor = try sealed.descriptor(pixelWidth: 1, pixelHeight: 1, mediaType: "public.heic")
            XCTAssertEqual(try BlobDescriptor(decoding: descriptor.encoded()), descriptor)

            let opened = try scratch()
            try BlobCipher.open(ciphertext: output.handle, manifest: sealed.manifest, descriptor: descriptor, output: opened.handle)
            XCTAssertTrue(FileManager.default.contentsEqual(atPath: opened.url.path, andPath: source.url.path))

            let rederived = try scratch()
            let prepared = try BlobCipher.prepareReupload(descriptor: descriptor, route: route, source: source.handle, output: rederived.handle)
            XCTAssertEqual(prepared.manifest, sealed.manifest)
            XCTAssertTrue(FileManager.default.contentsEqual(atPath: rederived.url.path, andPath: output.url.path))
        }
    }

    func testOpenRejectsTamperedSubstitutedAndMisboundParts() throws {
        let length = UInt64(2 * BlobFormat.plaintextPartLength + 1_000)
        let source = try patternFile(length: length)
        let sealedOutput = try scratch()
        let sealed = try BlobCipher.seal(source: source.handle, route: route, output: sealedOutput.handle)
        let descriptor = try sealed.descriptor(pixelWidth: 2, pixelHeight: 2, mediaType: "public.jpeg")
        let original = try Data(contentsOf: sealedOutput.url)
        let otherOutput = try scratch()
        let other = try BlobCipher.seal(source: source.handle, route: route, output: otherOutput.handle)
        let otherBytes = try Data(contentsOf: otherOutput.url)
        let partLength = BlobFormat.ciphertextPartLength
        let parts = (0..<3).map { Data(original[($0 * partLength)..<min(($0 + 1) * partLength, original.count)]) }

        var flipped = original
        flipped[partLength + 100] ^= 0x01
        try assertOpenFails(flipped, sealed: sealed, descriptor: descriptor, error: .partHashMismatch(index: 1))
        try assertForgedOpenFails(flipped, route: route, descriptor: descriptor, error: .authenticationFailed(index: 1))

        var tagFlipped = original
        tagFlipped[original.count - 1] ^= 0x80
        try assertForgedOpenFails(tagFlipped, route: route, descriptor: descriptor, error: .authenticationFailed(index: 2))

        let swapped = parts[1] + parts[0] + parts[2]
        try assertOpenFails(swapped, sealed: sealed, descriptor: descriptor, error: .partHashMismatch(index: 0))
        try assertForgedOpenFails(swapped, route: route, descriptor: descriptor, error: .authenticationFailed(index: 0))

        let repeated = parts[0] + parts[0] + parts[2]
        try assertForgedOpenFails(repeated, route: route, descriptor: descriptor, error: .authenticationFailed(index: 1))

        let foreign = parts[0] + otherBytes[partLength..<(2 * partLength)] + parts[2]
        XCTAssertEqual(Data(SHA256.hash(data: otherBytes[partLength..<(2 * partLength)])), other.manifest.partHashes[1])
        try assertOpenFails(foreign, sealed: sealed, descriptor: descriptor, error: .partHashMismatch(index: 1))
        try assertForgedOpenFails(foreign, route: route, descriptor: descriptor, error: .authenticationFailed(index: 1))

        let dropped = parts[0] + parts[1]
        try assertOpenFails(dropped, sealed: sealed, descriptor: descriptor, error: .ciphertextLengthMismatch(
            expected: sealed.manifest.layout.ciphertextLength, actual: UInt64(dropped.count)
        ))
        let truncatedDescriptor = try BlobDescriptor(
            objectID: descriptor.objectID,
            key: descriptor.key,
            plaintextLength: UInt64(2 * BlobFormat.plaintextPartLength),
            contentHash: Data(SHA256.hash(data: try Data(contentsOf: source.url).prefix(2 * BlobFormat.plaintextPartLength))),
            pixelWidth: 2,
            pixelHeight: 2,
            mediaType: "public.jpeg"
        )
        try assertForgedOpenFails(dropped, route: route, descriptor: truncatedDescriptor, error: .authenticationFailed(index: 0))

        try assertOpenFails(original + Data([0]), sealed: sealed, descriptor: descriptor, error: .ciphertextLengthMismatch(
            expected: sealed.manifest.layout.ciphertextLength, actual: UInt64(original.count + 1)
        ))

        let wrongKey = try BlobDescriptor(
            objectID: descriptor.objectID,
            key: Data(repeating: 0xA5, count: 32),
            plaintextLength: length,
            contentHash: descriptor.contentHash,
            pixelWidth: 2,
            pixelHeight: 2,
            mediaType: "public.jpeg"
        )
        try assertOpenFails(original, sealed: sealed, descriptor: wrongKey, error: .authenticationFailed(index: 0))

        let wrongRouteManifest = try BlobManifest(
            route: wrongRoute, ciphertextLength: sealed.manifest.layout.ciphertextLength, partHashes: sealed.manifest.partHashes
        )
        try assertOpenFails(original, manifest: wrongRouteManifest, descriptor: descriptor, error: .objectIDMismatch)
        try assertForgedOpenFails(original, route: wrongRoute, descriptor: descriptor, error: .authenticationFailed(index: 0))

        try assertOpenFails(original, manifest: other.manifest, descriptor: descriptor, error: .objectIDMismatch)

        let wrongContent = try BlobDescriptor(
            objectID: descriptor.objectID,
            key: descriptor.key,
            plaintextLength: length,
            contentHash: Data(repeating: 0, count: 32),
            pixelWidth: 2,
            pixelHeight: 2,
            mediaType: "public.jpeg"
        )
        try assertOpenFails(original, sealed: sealed, descriptor: wrongContent, error: .contentHashMismatch)
    }

    func testTenMebibyteObjectsUseBoundedExplicitBuffers() throws {
        let length = BlobFormat.maxPlaintextLength
        let layout = try BlobPartLayout(plaintextLength: length)
        let source = try patternFile(length: length)
        let partLimit = BlobFormat.plaintextPartLength + BlobFormat.ciphertextPartLength

        let sealMeter = BlobBufferMeter()
        let output = try scratch()
        let sealed = try BlobCipher.seal(source: source.handle, route: route, output: output.handle, meter: sealMeter)
        assertBounded(sealMeter.snapshot, limit: partLimit)
        XCTAssertEqual(sealMeter.snapshot.encryptedParts, 20)
        XCTAssertEqual(sealMeter.snapshot.bytesRead, length + layout.ciphertextLength)
        XCTAssertEqual(try size(output.url), layout.ciphertextLength)

        let descriptor = try sealed.descriptor(pixelWidth: 1, pixelHeight: 1, mediaType: "public.jpeg")
        let openMeter = BlobBufferMeter()
        let opened = try scratch()
        try BlobCipher.open(ciphertext: output.handle, manifest: sealed.manifest, descriptor: descriptor, output: opened.handle, meter: openMeter)
        assertBounded(openMeter.snapshot, limit: partLimit)
        XCTAssertEqual(openMeter.snapshot.decryptedParts, 20)
        XCTAssertEqual(openMeter.snapshot.bytesRead, layout.ciphertextLength)
        XCTAssertTrue(FileManager.default.contentsEqual(atPath: opened.url.path, andPath: source.url.path))

        let reuploadMeter = BlobBufferMeter()
        let rederived = try scratch()
        _ = try BlobCipher.prepareReupload(descriptor: descriptor, route: route, source: source.handle, output: rederived.handle, meter: reuploadMeter)
        assertBounded(reuploadMeter.snapshot, limit: partLimit)
        XCTAssertEqual(reuploadMeter.snapshot.encryptedParts, 20)
        XCTAssertEqual(reuploadMeter.snapshot.bytesRead, 2 * length + layout.ciphertextLength)
    }

    func testInvalidLengthsAndNonEmptyOutputAreRejectedBeforeReading() throws {
        for length in [UInt64(0), BlobFormat.maxPlaintextLength + 1] {
            let url = directory.appendingPathComponent(UUID().uuidString)
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
            let writer = try FileHandle(forWritingTo: url)
            try writer.truncate(atOffset: length)
            try writer.close()
            let source = try FileHandle(forReadingFrom: url)
            let meter = BlobBufferMeter()
            let output = try scratch()
            XCTAssertThrowsError(try BlobCipher.seal(source: source, route: route, output: output.handle, meter: meter)) {
                XCTAssertEqual($0 as? BlobCodecError, .invalidPlaintextLength(length))
            }
            XCTAssertEqual(meter.snapshot, BlobBufferMeter.Snapshot())
        }

        let source = try patternFile(length: 10)
        let output = try scratch()
        try output.handle.write(contentsOf: Data("keep".utf8))
        let meter = BlobBufferMeter()
        XCTAssertThrowsError(try BlobCipher.seal(source: source.handle, route: route, output: output.handle, meter: meter)) {
            XCTAssertEqual($0 as? BlobCodecError, .outputNotEmpty)
        }
        XCTAssertEqual(meter.snapshot, BlobBufferMeter.Snapshot())
        XCTAssertEqual(try Data(contentsOf: output.url), Data("keep".utf8))
    }

    private func assertBounded(_ snapshot: BlobBufferMeter.Snapshot, limit: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(snapshot.largestRead, BlobFormat.ciphertextPartLength, file: file, line: line)
        XCTAssertLessThanOrEqual(snapshot.peakLiveBuffers, 2, file: file, line: line)
        XCTAssertLessThanOrEqual(snapshot.peakLiveBytes, limit, file: file, line: line)
        XCTAssertEqual(snapshot.liveBuffers, 0, file: file, line: line)
        XCTAssertEqual(snapshot.liveBytes, 0, file: file, line: line)
    }

    private func assertOpenFails(
        _ ciphertext: Data,
        sealed: BlobSealedObject,
        descriptor: BlobDescriptor,
        error: BlobCodecError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try assertOpenFails(ciphertext, manifest: sealed.manifest, descriptor: descriptor, error: error, file: file, line: line)
    }

    private func assertForgedOpenFails(
        _ ciphertext: Data,
        route: BlobRoute,
        descriptor: BlobDescriptor,
        error: BlobCodecError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let layout = try BlobPartLayout(ciphertextLength: UInt64(ciphertext.count))
        let hashes = (0..<layout.partCount).map { index in
            let start = Int(layout.ciphertextOffset(ofPart: index))
            return Data(SHA256.hash(data: ciphertext[start..<(start + layout.ciphertextLength(ofPart: index))]))
        }
        let manifest = try BlobManifest(route: route, ciphertextLength: UInt64(ciphertext.count), partHashes: hashes)
        let forged = try BlobDescriptor(
            objectID: manifest.objectID,
            key: descriptor.key,
            plaintextLength: descriptor.plaintextLength,
            contentHash: descriptor.contentHash,
            pixelWidth: descriptor.pixelWidth,
            pixelHeight: descriptor.pixelHeight,
            mediaType: descriptor.mediaType
        )
        try assertOpenFails(ciphertext, manifest: manifest, descriptor: forged, error: error, file: file, line: line)
    }

    private func assertOpenFails(
        _ ciphertext: Data,
        manifest: BlobManifest,
        descriptor: BlobDescriptor,
        error: BlobCodecError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let input = directory.appendingPathComponent(UUID().uuidString)
        try ciphertext.write(to: input)
        let output = try scratch()
        XCTAssertThrowsError(try BlobCipher.open(
            ciphertext: try FileHandle(forReadingFrom: input),
            manifest: manifest,
            descriptor: descriptor,
            output: output.handle
        ), file: file, line: line) {
            XCTAssertEqual($0 as? BlobCodecError, error, file: file, line: line)
        }
        XCTAssertEqual(try size(output.url), 0, file: file, line: line)
    }

    private func frozenDescriptor(_ vector: BlobVector, objectID: String) throws -> BlobDescriptor {
        try BlobDescriptor(
            objectID: Data(blobHex: objectID),
            key: Data(blobHex: BlobVectors.key),
            plaintextLength: vector.plaintextLength,
            contentHash: Data(blobHex: vector.contentHash),
            pixelWidth: 1600,
            pixelHeight: 1200,
            mediaType: "public.jpeg"
        )
    }

    private func patternFile(
        length: UInt64,
        mutate: (_ chunkOffset: Int, _ chunk: inout Data) -> Void = { _, _ in }
    ) throws -> (url: URL, handle: FileHandle) {
        let url = directory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let writer = try FileHandle(forWritingTo: url)
        var offset = 0
        while offset < Int(length) {
            let count = min(1 << 20, Int(length) - offset)
            var chunk = Data((offset..<(offset + count)).map { UInt8($0 % 251) })
            mutate(offset, &chunk)
            try writer.write(contentsOf: chunk)
            offset += count
        }
        try writer.close()
        return (url, try FileHandle(forReadingFrom: url))
    }

    private func scratch() throws -> (url: URL, handle: FileHandle) {
        let url = directory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        return (url, try FileHandle(forUpdating: url))
    }

    private func size(_ url: URL) throws -> UInt64 {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64)
    }

    private func fileHash(_ url: URL) throws -> String {
        Data(SHA256.hash(data: try Data(contentsOf: url))).blobHex
    }
}
