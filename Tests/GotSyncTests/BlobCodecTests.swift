import CryptoKit
import XCTest
@testable import GotSync

final class BlobCodecTests: XCTestCase {
    func testLayoutMatchesFrozenBoundaryVectorsInBothDirections() throws {
        for vector in BlobVectors.accepted {
            let sender = try BlobPartLayout(plaintextLength: vector.plaintextLength)
            XCTAssertEqual(sender.partCount, vector.partCount)
            XCTAssertEqual(sender.ciphertextLength, vector.ciphertextLength)
            XCTAssertEqual(sender.ciphertextLength(ofPart: sender.partCount - 1), vector.lastPartLength)

            let relay = try BlobPartLayout(ciphertextLength: vector.ciphertextLength)
            XCTAssertEqual(relay, sender)
            assertPartsTile(relay)
        }
        for length in BlobVectors.rejectedPlaintextLengths {
            XCTAssertThrowsError(try BlobPartLayout(plaintextLength: length)) {
                XCTAssertEqual($0 as? BlobCodecError, .invalidPlaintextLength(length))
            }
        }
        for length in BlobVectors.rejectedCiphertextLengths + [UInt64.max, UInt64.max - 15] {
            XCTAssertThrowsError(try BlobPartLayout(ciphertextLength: length)) {
                XCTAssertEqual($0 as? BlobCodecError, .invalidCiphertextLength(length))
            }
        }
    }

    func testRelayDerivationAcceptsExactlyTheSenderLengths() throws {
        let partLength = UInt64(BlobFormat.ciphertextPartLength)
        var lengths = Set<UInt64>(1...64)
        for count in UInt64(1)...21 {
            let boundary = count * partLength
            lengths.formUnion(boundary - 40...boundary + 40)
        }
        for ciphertextLength in lengths.sorted() {
            let lastLength = ciphertextLength - (ciphertextLength - 1) / partLength * partLength
            let valid = ciphertextLength <= BlobFormat.maxCiphertextLength && lastLength >= 17
            guard let layout = try? BlobPartLayout(ciphertextLength: ciphertextLength) else {
                XCTAssertFalse(valid, "\(ciphertextLength)")
                continue
            }
            XCTAssertTrue(valid, "\(ciphertextLength)")
            XCTAssertEqual(try BlobPartLayout(plaintextLength: layout.plaintextLength), layout)
            assertPartsTile(layout)
        }
        for count in 1...BlobFormat.maxPartCount {
            let boundary = UInt64(count * BlobFormat.plaintextPartLength)
            for plaintextLength in [boundary - 1, boundary, boundary + 1] where plaintextLength <= BlobFormat.maxPlaintextLength {
                let layout = try BlobPartLayout(plaintextLength: plaintextLength)
                XCTAssertEqual(try BlobPartLayout(ciphertextLength: layout.ciphertextLength), layout)
                assertPartsTile(layout)
            }
        }
    }

    func testManifestRejectsCountAndHashMismatches() throws {
        let route = try BlobRoute(Data(blobHex: BlobVectors.route))
        let hash = Data(repeating: 7, count: 32)
        let partLength = UInt64(BlobFormat.ciphertextPartLength)
        XCTAssertThrowsError(try BlobManifest(route: route, ciphertextLength: partLength + 17, partHashes: [hash])) {
            XCTAssertEqual($0 as? BlobCodecError, .partCountMismatch(expected: 2, actual: 1))
        }
        XCTAssertThrowsError(try BlobManifest(route: route, ciphertextLength: partLength + 17, partHashes: [hash, hash, hash])) {
            XCTAssertEqual($0 as? BlobCodecError, .partCountMismatch(expected: 2, actual: 3))
        }
        XCTAssertThrowsError(try BlobManifest(
            route: route,
            ciphertextLength: BlobFormat.maxCiphertextLength,
            partHashes: Array(repeating: hash, count: 21)
        )) {
            XCTAssertEqual($0 as? BlobCodecError, .partCountMismatch(expected: 20, actual: 21))
        }
        XCTAssertThrowsError(try BlobManifest(route: route, ciphertextLength: partLength + 17, partHashes: [hash, hash.prefix(31)])) {
            XCTAssertEqual($0 as? BlobCodecError, .invalidPartHash(index: 1))
        }
        XCTAssertThrowsError(try BlobRoute(Data(count: 31))) {
            XCTAssertEqual($0 as? BlobCodecError, .invalidRoute)
        }
        XCTAssertThrowsError(try BlobRoute(Data(count: 33)))
    }

    func testManifestObjectIDsMatchFrozenVectors() throws {
        let route = try BlobRoute(Data(blobHex: BlobVectors.route))
        let wrongRoute = try BlobRoute(Data(blobHex: BlobVectors.wrongRoute))
        for vector in BlobVectors.accepted {
            let manifest = try BlobManifest(
                route: route,
                ciphertextLength: vector.ciphertextLength,
                partHashes: vector.partHashes.map { Data(blobHex: $0) }
            )
            XCTAssertEqual(manifest.objectID.blobHex, vector.objectID)
            let wrongManifest = try BlobManifest(
                route: wrongRoute,
                ciphertextLength: vector.ciphertextLength,
                partHashes: vector.wrongRoutePartHashes.map { Data(blobHex: $0) }
            )
            XCTAssertEqual(wrongManifest.objectID.blobHex, vector.wrongRouteObjectID)
        }
    }

    func testPythonFixtureMatchesSwiftFixture() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/blob-vectors-v1.json")
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(fixture["key"] as? String, BlobVectors.key)
        XCTAssertEqual(fixture["route"] as? String, BlobVectors.route)
        XCTAssertEqual(fixture["wrong_route"] as? String, BlobVectors.wrongRoute)

        let constants = try XCTUnwrap(fixture["constants"] as? [String: Any])
        XCTAssertEqual(constants["plaintext_part"] as? Int, BlobFormat.plaintextPartLength)
        XCTAssertEqual(constants["tag"] as? Int, BlobFormat.tagLength)
        XCTAssertEqual(constants["ciphertext_part"] as? Int, BlobFormat.ciphertextPartLength)
        XCTAssertEqual(constants["max_plaintext_length"] as? Int, Int(BlobFormat.maxPlaintextLength))
        XCTAssertEqual(constants["max_part_count"] as? Int, BlobFormat.maxPartCount)
        XCTAssertEqual(constants["max_ciphertext_length"] as? Int, Int(BlobFormat.maxCiphertextLength))
        XCTAssertEqual(constants["part_prefix"] as? String, "475342312d70617274")
        XCTAssertEqual(constants["object_prefix"] as? String, "475342312d6f626a656374")
        XCTAssertEqual(BlobFormat.partPrefix.blobHex, "475342312d70617274")
        XCTAssertEqual(BlobFormat.objectPrefix.blobHex, "475342312d6f626a656374")

        let accepted = try XCTUnwrap(fixture["accepted"] as? [[String: Any]])
        XCTAssertEqual(accepted.count, BlobVectors.accepted.count)
        for (entry, vector) in zip(accepted, BlobVectors.accepted) {
            XCTAssertEqual(entry["plaintext_length"] as? Int, Int(vector.plaintextLength))
            XCTAssertEqual(entry["part_count"] as? Int, vector.partCount)
            XCTAssertEqual(entry["ciphertext_length"] as? Int, Int(vector.ciphertextLength))
            XCTAssertEqual(entry["last_part_length"] as? Int, vector.lastPartLength)
            XCTAssertEqual(entry["content_hash"] as? String, vector.contentHash)
            XCTAssertEqual(entry["part_hashes"] as? [String], vector.partHashes)
            XCTAssertEqual(entry["object_id"] as? String, vector.objectID)
            XCTAssertEqual(entry["wrong_route_part_hashes"] as? [String], vector.wrongRoutePartHashes)
            XCTAssertEqual(entry["wrong_route_object_id"] as? String, vector.wrongRouteObjectID)
        }
        XCTAssertEqual(accepted.first?["ciphertext"] as? String, BlobVectors.oneByteCiphertext)
        XCTAssertEqual(
            (fixture["rejected_plaintext_lengths"] as? [Int])?.map(UInt64.init),
            BlobVectors.rejectedPlaintextLengths
        )
        let rejectedCiphertext = try XCTUnwrap(fixture["rejected_ciphertext_lengths"] as? [[String: Any]])
        XCTAssertEqual(rejectedCiphertext.compactMap { ($0["ciphertext_length"] as? Int).map(UInt64.init) }, BlobVectors.rejectedCiphertextLengths)

        let route = try BlobRoute(Data(blobHex: BlobVectors.route))
        for entry in try XCTUnwrap(fixture["rejected_manifests"] as? [[String: Any]]) {
            let length = try XCTUnwrap(entry["ciphertext_length"] as? Int)
            let count = try XCTUnwrap(entry["part_count"] as? Int)
            XCTAssertThrowsError(try BlobManifest(
                route: route,
                ciphertextLength: UInt64(length),
                partHashes: Array(repeating: Data(count: 32), count: count)
            ))
        }
        for entry in try XCTUnwrap(fixture["rejected_part_lengths"] as? [[String: Any]]) {
            let layout = try BlobPartLayout(ciphertextLength: UInt64(try XCTUnwrap(entry["ciphertext_length"] as? Int)))
            let index = try XCTUnwrap(entry["index"] as? Int)
            XCTAssertNotEqual(layout.ciphertextLength(ofPart: index), entry["length"] as? Int)
        }

        let descriptor = try XCTUnwrap(fixture["descriptor"] as? [String: Any])
        XCTAssertEqual(descriptor["bytes"] as? String, BlobVectors.descriptorBytes)
        XCTAssertEqual(descriptor["digest"] as? String, BlobVectors.descriptorDigest)
        XCTAssertEqual(descriptor["plaintext_length"] as? Int, Int(BlobVectors.descriptorPlaintextLength))
    }

    func testDescriptorVectorEncodesDecodesAndDigestsCanonically() throws {
        let vector = try XCTUnwrap(BlobVectors.accepted.first { $0.plaintextLength == BlobVectors.descriptorPlaintextLength })
        let descriptor = try BlobDescriptor(
            objectID: Data(blobHex: vector.objectID),
            key: Data(blobHex: BlobVectors.key),
            plaintextLength: vector.plaintextLength,
            contentHash: Data(blobHex: vector.contentHash),
            pixelWidth: 1600,
            pixelHeight: 1200,
            mediaType: "public.jpeg"
        )
        XCTAssertEqual(descriptor.encoded().blobHex, BlobVectors.descriptorBytes)
        XCTAssertEqual(descriptor.digest.blobHex, BlobVectors.descriptorDigest)

        let bytes = Data(blobHex: BlobVectors.descriptorBytes)
        let decoded = try BlobDescriptor(decoding: bytes)
        XCTAssertEqual(decoded, descriptor)
        XCTAssertEqual(decoded.encoded(), bytes)
        XCTAssertEqual(BlobDescriptor.digest(of: bytes).blobHex, BlobVectors.descriptorDigest)
    }

    func testDescriptorDecodingIsStrict() throws {
        let valid = Data(blobHex: BlobVectors.descriptorBytes)
        func mutated(_ offset: Int, _ value: UInt8) -> Data {
            var copy = valid
            copy[offset] = value
            return copy
        }
        func withField(_ range: Range<Int>, _ bytes: [UInt8]) -> Data {
            var copy = valid
            copy.replaceSubrange(range, with: bytes)
            return copy
        }

        var malformed: [Data] = [
            Data(),
            valid + Data([0x41]),
            mutated(0, 0x48),
            mutated(3, 0x32),
            withField(70..<78, [0, 0, 0, 0, 0, 0, 0, 0]),
            withField(70..<78, [0, 0, 0, 0, 0, 0xA0, 0, 1]),
            withField(110..<114, [0, 0, 0, 0]),
            withField(114..<118, [0, 0, 0, 0]),
            withField(118..<valid.count, [0]),
            withField(118..<valid.count, [65] + Array(repeating: 0x61, count: 65)),
            withField(118..<valid.count, [64] + Array(repeating: 0x61, count: 65)),
            withField(118..<valid.count, [4, 0x61, 0x20, 0x62, 0x63]),
            withField(118..<valid.count, [4, 0x61, 0x7F, 0x62, 0x63]),
            withField(118..<valid.count, [4, 0x61, 0xC3, 0xA9, 0x63]),
            withField(118..<valid.count, [12] + Array("public.jpeg".utf8)),
            withField(118..<valid.count, [10] + Array("public.jpeg".utf8)),
        ]
        malformed += (0..<valid.count).map { valid.prefix($0) }
        for (index, bytes) in malformed.enumerated() {
            XCTAssertThrowsError(try BlobDescriptor(decoding: bytes), "case \(index)") {
                XCTAssertEqual($0 as? BlobCodecError, .malformedDescriptor, "case \(index)")
            }
        }

        let unsupported: [(Data, UInt8, UInt8)] = [
            (mutated(4, 2), 2, 0),
            (mutated(4, 0), 0, 0),
            (mutated(5, 1), 1, 1),
            (mutated(4, 2).prefix(6), 2, 0),
            (mutated(4, 2) + Data(repeating: 0xFF, count: 4_096), 2, 0),
            (mutated(5, 0x80).prefix(40), 1, 0x80),
        ]
        for (bytes, version, flags) in unsupported {
            XCTAssertThrowsError(try BlobDescriptor(decoding: bytes)) {
                XCTAssertEqual($0 as? BlobCodecError, .unsupportedDescriptor(version: version, flags: flags))
            }
        }
        XCTAssertThrowsError(try BlobDescriptor(decoding: withField(0..<4, Array("GSB2".utf8)))) {
            XCTAssertEqual($0 as? BlobCodecError, .malformedDescriptor)
        }

        let longest = try BlobDescriptor(
            objectID: Data(repeating: 1, count: 32),
            key: Data(repeating: 2, count: 32),
            plaintextLength: BlobFormat.maxPlaintextLength,
            contentHash: Data(repeating: 3, count: 32),
            pixelWidth: .max,
            pixelHeight: 1,
            mediaType: String(repeating: "~", count: 64)
        )
        XCTAssertEqual(longest.encoded().count, BlobDescriptor.maxLength)
        XCTAssertEqual(try BlobDescriptor(decoding: longest.encoded()), longest)
        let sliced = (Data([9, 9]) + longest.encoded()).dropFirst(2)
        XCTAssertEqual(try BlobDescriptor(decoding: sliced).encoded(), longest.encoded())

        for (objectID, key, contentHash) in [(31, 32, 32), (32, 33, 32), (32, 32, 0)] {
            XCTAssertThrowsError(try BlobDescriptor(
                objectID: Data(count: objectID),
                key: Data(count: key),
                plaintextLength: 1,
                contentHash: Data(count: contentHash),
                pixelWidth: 1,
                pixelHeight: 1,
                mediaType: "public.png"
            ))
        }
    }

    func testCryptoKitMatchesPublishedGCMKnownAnswer() throws {
        // McGrew & Viega, "The Galois/Counter Mode of Operation", test case 16.
        let key = SymmetricKey(data: Data(blobHex: "feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308"))
        let box = try AES.GCM.seal(
            Data(blobHex: "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39"),
            using: key,
            nonce: AES.GCM.Nonce(data: Data(blobHex: "cafebabefacedbaddecaf888")),
            authenticating: Data(blobHex: "feedfacedeadbeeffeedfacedeadbeefabaddad2")
        )
        XCTAssertEqual(
            box.ciphertext.blobHex,
            "522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662"
        )
        XCTAssertEqual(box.tag.blobHex, "76fc6ece0f4e1768cddf8853bb2d551b")
    }

    func testPartNonceAndAuthenticatedDataUseExactBytes() throws {
        let layout = try BlobPartLayout(plaintextLength: 524_289)
        let route = try BlobRoute(Data(blobHex: BlobVectors.route))
        XCTAssertEqual(Data(try layout.nonce(ofPart: 1)).blobHex, "000000000000000000000001")
        XCTAssertEqual(
            layout.authenticatedData(ofPart: 1, route: route).blobHex,
            "475342312d70617274" + BlobVectors.route + "0000000000080001" + "00000002" + "00000001"
        )
    }

    private func assertPartsTile(_ layout: BlobPartLayout, file: StaticString = #filePath, line: UInt = #line) {
        var offset: UInt64 = 0
        var plaintext: UInt64 = 0
        for index in 0..<layout.partCount {
            XCTAssertEqual(layout.ciphertextOffset(ofPart: index), offset, file: file, line: line)
            let length = layout.ciphertextLength(ofPart: index)
            XCTAssertEqual(length, layout.plaintextLength(ofPart: index) + 16, file: file, line: line)
            if index < layout.partCount - 1 {
                XCTAssertEqual(length, BlobFormat.ciphertextPartLength, file: file, line: line)
            } else {
                XCTAssertTrue((17...BlobFormat.ciphertextPartLength).contains(length), file: file, line: line)
            }
            offset += UInt64(length)
            plaintext += UInt64(layout.plaintextLength(ofPart: index))
        }
        XCTAssertEqual(offset, layout.ciphertextLength, file: file, line: line)
        XCTAssertEqual(plaintext, layout.plaintextLength, file: file, line: line)
        XCTAssertLessThanOrEqual(layout.partCount, BlobFormat.maxPartCount, file: file, line: line)
    }
}

extension Data {
    init(blobHex: String) {
        var bytes: [UInt8] = []
        var index = blobHex.startIndex
        while index < blobHex.endIndex {
            let next = blobHex.index(index, offsetBy: 2)
            bytes.append(UInt8(blobHex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }

    var blobHex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
