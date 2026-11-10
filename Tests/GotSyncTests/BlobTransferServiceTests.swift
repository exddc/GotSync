import CryptoKit
import ImageIO
import os
import UniformTypeIdentifiers
import XCTest
@_spi(BlobPreview) @testable import GotSync

final class BlobTransferServiceTests: XCTestCase {
    private var directory: URL!
    private let relayURL = URL(string: "https://relay.example.test/v2/mls")!
    private let route = try! BlobRoute(bytes: Data(repeating: 0x21, count: 32))
    private let token = Data(repeating: 0x07, count: 32)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FakeBlobRelay.reset()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSealedImageIsOfferedHandedOffFetchedAndPublished() async throws {
        let source = directory.appendingPathComponent("image.png")
        try Self.writePNG(to: source, width: 64, height: 48)
        let original = try Data(contentsOf: source)
        let contentHash = Data(SHA256.hash(data: original))

        let sender = try service("sender")
        let outgoingID = try BlobTransferID(bytes: Data(repeating: 1, count: 16))
        let sealed = try await sender.seal(outgoingID, route: route, source: source, expectedContentHash: contentHash)
        XCTAssertEqual(sealed.state, .uploading)
        let repeated = try await sender.seal(outgoingID, route: route, source: source, expectedContentHash: contentHash)
        XCTAssertEqual(repeated.id, outgoingID)
        do {
            _ = try await sender.seal(outgoingID, route: route, source: source, expectedContentHash: Data(repeating: 9, count: 32))
            XCTFail("a different hash under the same ID was accepted")
        } catch BlobError.transferMismatch {}

        let offered = try await waitForOutgoing(sender) { statuses in
            statuses.compactMap { status -> (Data, Data)? in
                if case .readyForHandoff(let descriptor, let digest) = status.state { return (descriptor, digest) }
                return nil
            }.first
        }
        let info = try BlobDescriptorInfo(descriptor: offered.0)
        XCTAssertEqual(info.contentHash, contentHash)
        XCTAssertEqual(info.image, BlobImageInfo(mediaType: "public.png", pixelWidth: 64, pixelHeight: 48))
        XCTAssertEqual(info.digest, offered.1)
        XCTAssertEqual(try Data(contentsOf: source), original, "the host file is unchanged")

        do {
            try await sender.confirmHandoff(outgoingID, descriptorDigest: Data(repeating: 0, count: 32))
            XCTFail("a stale digest deleted the row")
        } catch BlobError.staleConfirmation {}
        try await sender.confirmHandoff(outgoingID, descriptorDigest: offered.1)
        let remaining = await sender.outgoing()
        XCTAssertTrue(remaining.isEmpty)

        let receiver = try service("receiver")
        let incomingID = try BlobTransferID(bytes: Data(repeating: 2, count: 16))
        try await receiver.requestIncoming(incomingID, route: route, descriptor: offered.0)
        try await receiver.requestIncoming(incomingID, route: route, descriptor: offered.0)
        let published = try await waitForIncoming(receiver) { statuses in
            statuses.compactMap { status -> (URL, Data)? in
                if case .awaitingPublish(let file, let hash, _) = status.state { return (file, hash) }
                return nil
            }.first
        }
        XCTAssertEqual(published.1, contentHash)
        XCTAssertEqual(try Data(contentsOf: published.0), original)
        try await receiver.confirmPublished(incomingID, descriptorDigest: offered.1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: published.0.path))
        let summary = await receiver.summary()
        XCTAssertEqual(summary.libraryBytes, 0)
    }

    func testRetiredBindingRefusesNewWork() async throws {
        let sender = try service("retired")
        sender.retireNow()
        let source = directory.appendingPathComponent("image.png")
        try Self.writePNG(to: source, width: 8, height: 8)
        let hash = Data(SHA256.hash(data: try Data(contentsOf: source)))
        do {
            _ = try await sender.seal(try BlobTransferID(bytes: Data(repeating: 3, count: 16)), route: route, source: source,
                                      expectedContentHash: hash)
            XCTFail("a retired binding sealed")
        } catch BlobError.notBound {}
    }

    // MARK: - Helpers

    private func service(_ name: String) throws -> BlobTransferService {
        let service = try BlobTransferService(
            directory: directory.appendingPathComponent(name), relayURL: relayURL, policy: .production,
            relayProtocols: [FakeBlobRelay.self]
        )
        let route = route
        let token = token
        let expectation = expectation(description: "bound")
        Task {
            try await service.ensureBound(route: route, member: Data(name.utf8), notRetiredSince: service.bindingToken) {
                (route.bytes, token)
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        return service
    }

    private func waitForOutgoing<T>(
        _ service: BlobTransferService,
        _ match: @escaping ([BlobOutgoingStatus]) -> T?
    ) async throws -> T {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let found = match(await service.outgoing()) { return found }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out: \(await service.outgoing())")
        throw CancellationError()
    }

    private func waitForIncoming<T>(
        _ service: BlobTransferService,
        _ match: @escaping ([BlobIncomingStatus]) -> T?
    ) async throws -> T {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let found = match(await service.incoming()) { return found }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out: \(await service.incoming())")
        throw CancellationError()
    }

    static func writePNG(to url: URL, width: Int, height: Int) throws {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

/// An in-memory relay blob lane for the service's own requests.
final class FakeBlobRelay: URLProtocol {
    struct Object {
        var length: UInt64
        var hashes: [Data]
        var parts: [Int: Data] = [:]
        var complete: Bool { parts.count == hashes.count }
    }

    private static let objects = OSAllocatedUnfairLock(initialState: [Data: Object]())

    static func reset() {
        objects.withLock { $0 = [:] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let components = url.path.split(separator: "/").map(String.init)
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        let document = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        switch components.dropFirst(2).first {
        case "capabilities":
            json(["version": 2, "conditionalAppend": true,
                  "blobs": ["version": 1, "partBytes": 524_304, "maxObjectBytes": 10_486_080, "maxParts": 20,
                            "groupQuotaBytes": 201_326_592, "retentionSeconds": 2_592_000, "incompleteSeconds": 86_400]])
        case "blob":
            blob(Array(components.dropFirst(3)), body: body, document: document)
        default:
            json(["version": 2, "error": "notFound"], status: 404)
        }
    }

    private func blob(_ path: [String], body: Data, document: [String: Any]) {
        @Sendable func id(_ value: String?) -> Data { (try? Data(base64URL: value ?? "")) ?? Data() }
        switch path.first {
        case "begin":
            let object = id(document["object"] as? String)
            let hashes = (document["parts"] as? [String] ?? []).map { id($0) }
            let length = (document["length"] as? NSNumber)?.uint64Value ?? 0
            let stored = Self.objects.withLock { objects in
                objects[object] = objects[object] ?? Object(length: length, hashes: hashes)
                return objects[object]!
            }
            json(["version": 2, "complete": stored.complete, "present": Array(stored.parts.keys).sorted(), "leasedByOther": false])
        case "put":
            let object = id(path[2])
            let index = Int(path[3])!
            let accepted = Self.objects.withLock { objects -> Object? in
                guard var stored = objects[object], index < stored.hashes.count,
                      Data(SHA256.hash(data: body)) == stored.hashes[index]
                else {
                    return nil
                }
                stored.parts[index] = body
                objects[object] = stored
                return stored
            }
            guard let accepted else {
                json(["version": 2, "error": "partMismatch"], status: 409)
                return
            }
            json(["version": 2, "stored": true, "complete": accepted.complete])
        case "manifest":
            let object = id(document["object"] as? String)
            guard let stored = Self.objects.withLock({ $0[object] }) else {
                json(["version": 2, "error": "objectMissing"], status: 404)
                return
            }
            json(["version": 2, "length": stored.length, "parts": stored.hashes.map(\.base64URLString),
                  "present": Array(stored.parts.keys).sorted(), "complete": stored.complete])
        case "get":
            let object = id(path[2])
            let index = Int(path[3])!
            guard let part = Self.objects.withLock({ $0[object]?.parts[index] }) else {
                json(["version": 2, "error": "partMissing"], status: 404)
                return
            }
            respond(part, status: 200, type: "application/octet-stream")
        case "want":
            json(["version": 2, "accepted": 1])
        case "wanted":
            json(["version": 2, "objects": [String]()])
        default:
            json(["version": 2], status: 200)
        }
    }

    private func json(_ object: [String: Any], status: Int = 200) {
        respond(try! JSONSerialization.data(withJSONObject: object), status: status, type: "application/json")
    }

    private func respond(_ data: Data, status: Int, type: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": type, "Content-Length": "\(data.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
