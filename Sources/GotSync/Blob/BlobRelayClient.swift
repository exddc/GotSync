import Foundation
import os

enum BlobRelayError: Error, Equatable {
    /// The relay has no blob lane, or the request did not reach it.
    case unsupported
    case unauthorized
    case objectMissing
    case partMissing
    case partMismatch
    case historyExpired
    /// Transient refusal; retry no sooner than `after` seconds.
    case busy(after: TimeInterval?)
    /// No relay space for now (`507`).
    case capacity(after: TimeInterval?)
    case invalidRequest
    case invalidResponse
    case transport
}

struct BlobBeginResult: Equatable, Sendable {
    let complete: Bool
    let present: Set<Int>
    let leasedByOther: Bool
}

struct BlobRelayManifest: Equatable, Sendable {
    let ciphertextLength: UInt64
    let partHashes: [Data]
    let present: Set<Int>
    let complete: Bool
}

/// One dedicated relay session for blob requests: two connections, no cache,
/// cookies or redirects, capped bodies and at most four request starts per second.
/// `invalidate` cancels every task it has started.
final class BlobRelayClient: Sendable {
    static let metadataResponseBytes = 64 * 1_024
    private static let version = MLSRelayLimits.version

    private let baseURL: URL
    private let policy: EndpointSecurityPolicy
    private let session: URLSession
    private let pacer = BlobRequestPacer(interval: 0.25)
    private let invalidated = OSAllocatedUnfairLock(initialState: false)

    init(baseURL: URL, policy: EndpointSecurityPolicy, protocolClasses: [AnyClass]? = nil) {
        self.baseURL = baseURL
        self.policy = policy
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        session = URLSession(configuration: configuration, delegate: BlobNoRedirectDelegate(), delegateQueue: nil)
    }

    func invalidate() {
        invalidated.withLock { invalidated in
            guard !invalidated else { return }
            invalidated = true
            session.invalidateAndCancel()
        }
    }

    // MARK: Endpoints

    func supportsBlobs(group: Data, token: Data) async throws -> Bool {
        struct Request: Encodable { let version: Int; let group: String }
        struct Response: Decodable { let blobs: Capability? }
        struct Capability: Decodable { let version: Int; let partBytes: Int; let maxParts: Int }
        let data = try await metadata("capabilities", Request(version: Self.version, group: group.base64URLString), token: token)
        guard let response = try? CanonicalJSON.decoder.decode(Response.self, from: data) else {
            throw BlobRelayError.invalidResponse
        }
        guard let blobs = response.blobs else { return false }
        return blobs.version == 1 && blobs.partBytes == BlobFormat.ciphertextPartLength && blobs.maxParts == BlobFormat.maxPartCount
    }

    func begin(manifest: BlobManifest, token: Data) async throws -> BlobBeginResult {
        struct Request: Encodable {
            let version: Int; let group: String; let object: String; let length: UInt64; let parts: [String]
        }
        struct Response: Decodable { let complete: Bool; let present: [Int]; let leasedByOther: Bool }
        let request = Request(
            version: Self.version, group: manifest.route.bytes.base64URLString, object: manifest.objectID.base64URLString,
            length: manifest.layout.ciphertextLength, parts: manifest.partHashes.map(\.base64URLString)
        )
        let response: Response = try decode(try await metadata("blob/begin", request, token: token))
        return BlobBeginResult(
            complete: response.complete,
            present: try indexes(response.present, count: manifest.layout.partCount),
            leasedByOther: response.leasedByOther
        )
    }

    func manifest(route: BlobRoute, objectID: Data, token: Data) async throws -> BlobRelayManifest {
        struct Request: Encodable { let version: Int; let group: String; let object: String }
        struct Response: Decodable { let length: UInt64; let parts: [String]; let present: [Int]; let complete: Bool }
        let response: Response = try decode(try await metadata(
            "blob/manifest",
            Request(version: Self.version, group: route.bytes.base64URLString, object: objectID.base64URLString),
            token: token
        ))
        let hashes = try response.parts.map { try canonical($0, bytes: BlobFormat.hashLength) }
        guard let layout = try? BlobPartLayout(ciphertextLength: response.length), layout.partCount == hashes.count else {
            throw BlobRelayError.invalidResponse
        }
        return BlobRelayManifest(
            ciphertextLength: response.length, partHashes: hashes,
            present: try indexes(response.present, count: hashes.count), complete: response.complete
        )
    }

    func want(route: BlobRoute, objectIDs: [Data], token: Data) async throws {
        struct Request: Encodable { let version: Int; let group: String; let objects: [String] }
        guard (1...16).contains(objectIDs.count) else { throw BlobRelayError.invalidRequest }
        _ = try await metadata(
            "blob/want",
            Request(version: Self.version, group: route.bytes.base64URLString, objects: objectIDs.map(\.base64URLString)),
            token: token
        )
    }

    func wanted(route: BlobRoute, token: Data) async throws -> [Data] {
        struct Request: Encodable { let version: Int; let group: String }
        struct Response: Decodable { let objects: [String] }
        let response: Response = try decode(try await metadata(
            "blob/wanted", Request(version: Self.version, group: route.bytes.base64URLString), token: token
        ))
        guard response.objects.count <= 64 else { throw BlobRelayError.invalidResponse }
        return try response.objects.map { try canonical($0, bytes: BlobFormat.hashLength) }
    }

    func release(route: BlobRoute, objectIDs: [Data], token: Data) async throws {
        struct Request: Encodable { let version: Int; let group: String; let objects: [String] }
        guard (1...16).contains(objectIDs.count) else { throw BlobRelayError.invalidRequest }
        _ = try await metadata(
            "blob/release",
            Request(version: Self.version, group: route.bytes.base64URLString, objects: objectIDs.map(\.base64URLString)),
            token: token
        )
    }

    /// Stores one part; `true` when the object is now complete.
    func put(route: BlobRoute, objectID: Data, index: Int, part: Data, token: Data) async throws -> Bool {
        struct Response: Decodable { let stored: Bool; let complete: Bool }
        guard (1...BlobFormat.ciphertextPartLength).contains(part.count) else { throw BlobRelayError.invalidRequest }
        let url = try binaryURL("put", route: route, objectID: objectID, index: index)
        var request = baseRequest(url, token: token)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await execute(request, upload: part, limit: Self.metadataResponseBytes)
        let http = try check(response, url: url, data: data)
        guard data.count <= Self.metadataResponseBytes else { throw BlobRelayError.invalidResponse }
        try require(http, data: data)
        let decoded: Response = try decode(data)
        guard decoded.stored else { throw BlobRelayError.invalidResponse }
        return decoded.complete
    }

    /// Reads one part of exactly `length` bytes, refusing anything longer.
    func get(route: BlobRoute, objectID: Data, index: Int, length: Int, token: Data) async throws -> Data {
        let url = try binaryURL("get", route: route, objectID: objectID, index: index)
        var request = baseRequest(url, token: token)
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        request.httpBody = Data()
        return try await perform(request, url: url, limit: max(length, Self.metadataResponseBytes), binary: length)
    }

    // MARK: Transport

    private func metadata<Body: Encodable>(_ endpoint: String, _ body: Body, token: Data) async throws -> Data {
        let url = try endpointURL(endpoint)
        var request = baseRequest(url, token: token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try CanonicalJSON.encoder.encode(body)
        guard request.httpBody!.count <= 4_096 else { throw BlobRelayError.invalidRequest }
        return try await perform(request, url: url, limit: Self.metadataResponseBytes, binary: nil)
    }

    private func perform(_ request: URLRequest, url: URL, limit: Int, binary: Int?) async throws -> Data {
        let (data, response) = try await execute(request, limit: limit)
        let http = try check(response, url: url, data: data)
        try require(http, data: data)
        if let binary {
            guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("application/octet-stream") == true,
                  data.count == binary
            else {
                throw BlobRelayError.invalidResponse
            }
            return data
        }
        struct Version: Decodable { let version: Int }
        guard (try? CanonicalJSON.decoder.decode(Version.self, from: data))?.version == Self.version else {
            throw BlobRelayError.invalidResponse
        }
        return data
    }

    private func execute(_ request: URLRequest, upload: Data? = nil, limit: Int) async throws -> (Data, HTTPURLResponse) {
        await pacer.admit()
        try Task.checkCancellation()
        let response = BlobRelayResponse(url: request.url!, limit: limit)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                invalidated.withLock { invalidated in
                    guard !invalidated else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let task: URLSessionDataTask
                    if let upload {
                        task = session.uploadTask(with: request, from: upload)
                    } else {
                        task = session.dataTask(with: request)
                    }
                    task.delegate = response
                    response.start(task, continuation: continuation)
                }
            }
        } onCancel: {
            response.cancel()
        }
    }

    private func check(_ response: URLResponse, url: URL, data: Data) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse, http.url == url,
              http.value(forHTTPHeaderField: "Content-Encoding") == nil
        else {
            throw BlobRelayError.invalidResponse
        }
        return http
    }

    private func require(_ http: HTTPURLResponse, data: Data) throws {
        guard http.statusCode != 200 else { return }
        struct Failure: Decodable { let error: String }
        let code = (try? CanonicalJSON.decoder.decode(Failure.self, from: data))?.error
        let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        switch (http.statusCode, code) {
        case (404, "objectMissing"): throw BlobRelayError.objectMissing
        case (404, "partMissing"): throw BlobRelayError.partMissing
        case (404, _): throw BlobRelayError.unsupported
        case (403, _): throw BlobRelayError.unauthorized
        case (409, "partMismatch"): throw BlobRelayError.partMismatch
        case (410, _): throw BlobRelayError.historyExpired
        case (429, _), (503, _): throw BlobRelayError.busy(after: retryAfter)
        case (507, _): throw BlobRelayError.capacity(after: retryAfter)
        case (400, _), (413, _): throw BlobRelayError.invalidRequest
        default: throw BlobRelayError.busy(after: retryAfter)
        }
    }

    private func baseRequest(_ url: URL, token: Data) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("GotSync/2", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token.base64URLString)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func endpointURL(_ endpoint: String) throws -> URL {
        do {
            try SyncEndpointConfiguration.validateMailboxURL(baseURL, policy: policy)
        } catch {
            throw BlobRelayError.invalidRequest
        }
        return baseURL.appendingPathComponent(endpoint)
    }

    private func binaryURL(_ operation: String, route: BlobRoute, objectID: Data, index: Int) throws -> URL {
        guard (0..<BlobFormat.maxPartCount).contains(index), objectID.count == BlobFormat.hashLength else {
            throw BlobRelayError.invalidRequest
        }
        return try endpointURL("blob/\(operation)/\(route.bytes.base64URLString)/\(objectID.base64URLString)/\(index)")
    }

    private func decode<Response: Decodable>(_ data: Data) throws -> Response {
        do {
            return try CanonicalJSON.decoder.decode(Response.self, from: data)
        } catch {
            throw BlobRelayError.invalidResponse
        }
    }

    private func canonical(_ value: String, bytes: Int) throws -> Data {
        guard let decoded = try? Data(base64URL: value), decoded.count == bytes, decoded.base64URLString == value else {
            throw BlobRelayError.invalidResponse
        }
        return decoded
    }

    private func indexes(_ values: [Int], count: Int) throws -> Set<Int> {
        let set = Set(values)
        guard set.count == values.count, set.allSatisfy({ (0..<count).contains($0) }) else {
            throw BlobRelayError.invalidResponse
        }
        return set
    }
}

private final class BlobRelayResponse: NSObject, URLSessionDataDelegate, Sendable {
    private typealias Output = (Data, HTTPURLResponse)

    private struct State {
        var task: URLSessionDataTask?
        var continuation: CheckedContinuation<Output, any Error>?
        var response: HTTPURLResponse?
        var data = Data()
        var failure: BlobRelayError?
        var cancelled = false
    }

    private let url: URL
    private let limit: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(url: URL, limit: Int) {
        self.url = url
        self.limit = limit
    }

    func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>) {
        let cancelled = state.withLock { state in
            guard !state.cancelled else { return true }
            state.task = task
            state.continuation = continuation
            task.resume()
            return false
        }
        if cancelled {
            task.cancel()
            continuation.resume(throwing: CancellationError())
        }
    }

    func cancel() {
        state.withLock { state in
            state.cancelled = true
            state.task?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let disposition: URLSession.ResponseDisposition = state.withLock { state in
            guard let http = response as? HTTPURLResponse, http.url == url,
                  http.value(forHTTPHeaderField: "Content-Encoding") == nil,
                  http.expectedContentLength <= Int64(limit) else {
                state.failure = .invalidResponse
                return .cancel
            }
            state.response = http
            return state.cancelled ? .cancel : .allow
        }
        completionHandler(disposition)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let cancel = state.withLock { state in
            guard state.failure == nil, !state.cancelled else { return true }
            guard data.count <= limit - state.data.count else {
                state.failure = .invalidResponse
                return true
            }
            state.data.append(data)
            return false
        }
        if cancel { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let completion = state.withLock { state -> (CheckedContinuation<Output, any Error>, Result<Output, any Error>)? in
            guard let continuation = state.continuation else { return nil }
            let result: Result<Output, any Error>
            if let failure = state.failure {
                result = .failure(failure)
            } else if state.cancelled || (error as? URLError)?.code == .cancelled {
                result = .failure(CancellationError())
            } else if error != nil {
                result = .failure(BlobRelayError.transport)
            } else if let response = state.response {
                result = .success((state.data, response))
            } else {
                result = .failure(BlobRelayError.invalidResponse)
            }
            state.continuation = nil
            state.task = nil
            state.response = nil
            state.data = Data()
            return (continuation, result)
        }
        if let (continuation, result) = completion { continuation.resume(with: result) }
    }
}

/// Spaces request starts at least `interval` seconds apart, without catch-up.
actor BlobRequestPacer {
    private let interval: TimeInterval
    private var next = Date.distantPast

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func admit() async {
        let now = Date()
        let start = max(now, next)
        next = start.addingTimeInterval(interval)
        let wait = start.timeIntervalSince(now)
        if wait > 0 {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }
}

private final class BlobNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
