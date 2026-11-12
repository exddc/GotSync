import Foundation
import os
import XCTest
@testable import GotSync

@MainActor
final class BlobRelayClientTests: XCTestCase {
    private let baseURL = URL(string: "https://relay.example.test/v2/mls")!
    private let group = Data(repeating: 1, count: 32)
    private let token = Data(repeating: 2, count: 32)

    func testInvalidatedSessionRefusesMetadataDownloadsAndUploads() async throws {
        BlobLifecycleProtocol.configure()
        let client = makeClient()
        client.invalidate()
        client.invalidate()
        let route = try BlobRoute(bytes: group)
        for operation in 0..<3 {
            do {
                switch operation {
                case 0: _ = try await client.supportsBlobs(group: group, token: token)
                case 1: _ = try await client.get(route: route, objectID: group, index: 0, length: 1, token: token)
                default: _ = try await client.put(route: route, objectID: group, index: 0, part: Data([1]), token: token)
                }
                XCTFail("a retired session started operation \(operation)")
            } catch is CancellationError {}
        }
        XCTAssertEqual(BlobLifecycleProtocol.starts, 0)
    }

    func testInvalidationCancelsAnAlreadyStartedRequest() async throws {
        let started = expectation(description: "request started")
        BlobLifecycleProtocol.configure(body: nil, started: { started.fulfill() })
        let client = makeClient()
        let request = Task { try await client.supportsBlobs(group: group, token: token) }
        await fulfillment(of: [started], timeout: 3)
        client.invalidate()
        do {
            _ = try await request.value
            XCTFail("an invalidated request completed")
        } catch is CancellationError {}
        XCTAssertEqual(BlobLifecycleProtocol.starts, 1)
    }

    func testConcurrentCreationAndInvalidationReturnsANormalOutcome() async throws {
        BlobLifecycleProtocol.configure()
        for _ in 0..<20 {
            let client = makeClient()
            let group = group
            let token = token
            let request = Task.detached { try await client.supportsBlobs(group: group, token: token) }
            await Task.detached { client.invalidate() }.value
            do {
                let supported = try await request.value
                XCTAssertTrue(supported)
            } catch is CancellationError {}
        }
    }

    func testUnknownLengthMetadataAndUploadResponsesRemainBounded() async throws {
        BlobLifecycleProtocol.configure(body: Data(repeating: 0x20, count: BlobRelayClient.metadataResponseBytes + 1))
        let client = makeClient()
        defer { client.invalidate() }
        let route = try BlobRoute(bytes: group)
        for upload in [false, true] {
            do {
                if upload {
                    _ = try await client.put(route: route, objectID: group, index: 0, part: Data([1]), token: token)
                } else {
                    _ = try await client.supportsBlobs(group: group, token: token)
                }
                XCTFail("an oversized response was accepted")
            } catch let error as BlobRelayError {
                XCTAssertEqual(error, .invalidResponse)
            }
        }
    }

    private func makeClient() -> BlobRelayClient {
        BlobRelayClient(baseURL: baseURL, policy: .production, protocolClasses: [BlobLifecycleProtocol.self])
    }
}

private final class BlobLifecycleProtocol: URLProtocol {
    private struct State {
        var body: Data?
        var started: (@Sendable () -> Void)?
        var starts = 0
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())
    static var starts: Int { state.withLock { $0.starts } }

    static func configure(
        body: Data? = Data(#"{"version":2,"blobs":{"version":1,"partBytes":524304,"maxParts":20}}"#.utf8),
        started: (@Sendable () -> Void)? = nil
    ) {
        state.withLock { $0 = State(body: body, started: started) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let (body, started) = Self.state.withLock { state in
            state.starts += 1
            return (state.body, state.started)
        }
        started?()
        guard let body else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
