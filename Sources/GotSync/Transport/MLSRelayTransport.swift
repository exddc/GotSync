import CryptoKit
import Foundation
import GotSyncMLS

enum MLSRelayLimits {
    static let version = 2
    static let payloadBytes = 448 * 1_024
    static let keyPackageBytes = 64 * 1_024
    static let requestBytes = 1_024 * 1_024
    static let responseBytes = 16 * 1_024 * 1_024
    static let fetchCount = 32
    static let maximumCursor: UInt64 = 1 << 53
}

enum MLSRelayError: Error, Equatable {
    case invalidURL
    case insecureTransport
    case invalidRequest
    case invalidResponse
    case responseTooLarge
    case unsupportedVersion
    case unauthorized
    case epochConflict
    /// The delivery store refused the request for lack of room.
    case capacityReached
    /// HTTP 429 from anything other than the delivery store, such as the
    /// relay's admission rate limit or a proxy. The request never reached the
    /// store.
    case rateLimited
    case historyExpired
    case rejected(status: Int, code: String)
}

struct MLSRelayEntry: Equatable, Sendable {
    let cursor: UInt64
    let delivery: MLSDelivery
}

enum MLSAppendResult: Equatable, Sendable {
    case accepted(cursor: UInt64)
    case keyPackageUnavailable(epoch: UInt64)
    /// A conditional append was refused because the log had moved past the
    /// expected head. The head only grows, so every copy of the same request
    /// is refused too.
    case headAdvanced(head: UInt64)
}

protocol MLSRelayTransport: Sendable {
    func publishKeyPackage(_ keyPackage: Data, authorization: Data, pairingHash: Data) async throws -> Data
    func fetchKeyPackage(reference: Data, pairingToken: Data) async throws -> Data?
    func createGroup(_ group: Data, authorization: Data) async throws
    func append(_ delivery: MLSDelivery, authorization: Data) async throws -> MLSAppendResult
    /// Appends a Remove commit only while the group's log head equals
    /// `delivery.expectedHead`.
    func appendIfHead(_ delivery: MLSDelivery, authorization: Data) async throws -> MLSAppendResult
    /// Whether the relay offers `appendIfHead`. Earlier relays answer the
    /// request as invalid, which reports `false`.
    func supportsConditionalAppend(group: Data, authorization: Data) async throws -> Bool
    func fetch(group: Data, after cursor: UInt64, limit: Int, authorization: Data) async throws -> [MLSRelayEntry]
    func acknowledge(group: Data, through cursor: UInt64, authorization: Data) async throws
}

final class HTTPMLSRelayTransport: MLSRelayTransport, @unchecked Sendable {
    private struct PublishRequest: Encodable {
        let version = MLSRelayLimits.version
        let payload: String
        let pairingHash: String
    }

    private struct PublishResponse: Decodable {
        let reference: String
    }

    private struct PackageFetchRequest: Encodable {
        let version = MLSRelayLimits.version
        let reference: String
        let pairingToken: String
    }

    private struct PackageFetchResponse: Decodable {
        let payload: String?
    }

    private struct CreateRequest: Encodable {
        let version = MLSRelayLimits.version
        let group: String
    }

    private struct AppendRequest: Encodable {
        let version = MLSRelayLimits.version
        let group: String
        let epoch: UInt64
        let kind: String
        let payload: String
        let welcome: String?
        let reference: String?
        let addWriter: String?
        let removeWriter: String?
        var expectedHead: UInt64? = nil
    }

    private struct CapabilitiesRequest: Encodable {
        let version = MLSRelayLimits.version
        let group: String
    }

    private struct CapabilitiesResponse: Decodable {
        let conditionalAppend: Bool?
    }

    private struct Entry: Decodable {
        let cursor: UInt64
        let epoch: UInt64
        let kind: String
        let payload: String
        let welcome: String?
        let reference: String?
        let addWriter: String?
        let removeWriter: String?
    }

    private struct AppendResponse: Decodable {
        let entry: Entry
    }

    private struct FetchRequest: Encodable {
        let version = MLSRelayLimits.version
        let group: String
        let after: UInt64
        let limit: Int
    }

    private struct FetchResponse: Decodable {
        let entries: [Entry]
    }

    private struct AcknowledgeRequest: Encodable {
        let version = MLSRelayLimits.version
        let route: String
        let cursor: UInt64
    }

    private struct Empty: Decodable {}

    private struct ErrorResponse: Decodable {
        let error: String
        let epoch: UInt64?
        let head: UInt64?
    }

    private struct VersionResponse: Decodable {
        let version: Int
    }

    private enum Outcome<Response> {
        case success(Response)
        case keyPackageUnavailable(epoch: UInt64)
        case headAdvanced(head: UInt64)
    }

    private let baseURL: URL
    private let policy: EndpointSecurityPolicy
    private let session: URLSession

    init(baseURL: URL, session: URLSession? = nil, policy: EndpointSecurityPolicy = .production) {
        self.baseURL = baseURL
        self.policy = policy
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 30
            configuration.waitsForConnectivity = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func publishKeyPackage(_ keyPackage: Data, authorization: Data, pairingHash: Data) async throws -> Data {
        guard 1...MLSRelayLimits.keyPackageBytes ~= keyPackage.count, pairingHash.count == 32 else {
            throw MLSRelayError.invalidRequest
        }
        let response: PublishResponse = try await post(
            "key-package/publish",
            body: PublishRequest(payload: keyPackage.base64URLString, pairingHash: pairingHash.base64URLString),
            authorization: authorization
        )
        let reference = try decodeCanonical(response.reference, exactBytes: 32)
        guard reference == Data(SHA256.hash(data: keyPackage)) else { throw MLSRelayError.invalidResponse }
        return reference
    }

    func fetchKeyPackage(reference: Data, pairingToken: Data) async throws -> Data? {
        guard reference.count == 32, pairingToken.count == 32 else { throw MLSRelayError.invalidRequest }
        let response: PackageFetchResponse = try await post(
            "key-package/fetch",
            body: PackageFetchRequest(reference: reference.base64URLString, pairingToken: pairingToken.base64URLString),
            authorization: nil
        )
        guard let payload = response.payload else { return nil }
        let keyPackage = try decodeCanonical(payload, maximumBytes: MLSRelayLimits.keyPackageBytes)
        guard Data(SHA256.hash(data: keyPackage)) == reference else { throw MLSRelayError.invalidResponse }
        return keyPackage
    }

    func createGroup(_ group: Data, authorization: Data) async throws {
        guard group.count == 32 else { throw MLSRelayError.invalidRequest }
        let _: Empty = try await post("create", body: CreateRequest(group: group.base64URLString), authorization: authorization)
    }

    func append(_ delivery: MLSDelivery, authorization: Data) async throws -> MLSAppendResult {
        guard delivery.expectedHead == nil else { throw MLSRelayError.invalidRequest }
        return try await append(delivery, endpoint: "append", authorization: authorization)
    }

    func appendIfHead(_ delivery: MLSDelivery, authorization: Data) async throws -> MLSAppendResult {
        guard let head = delivery.expectedHead, head < MLSRelayLimits.maximumCursor,
              delivery.kind == .commit, delivery.removeWriter != nil, delivery.welcome == nil
        else {
            throw MLSRelayError.invalidRequest
        }
        return try await append(delivery, endpoint: "append-if-head", authorization: authorization)
    }

    func supportsConditionalAppend(group: Data, authorization: Data) async throws -> Bool {
        guard group.count == 32 else { throw MLSRelayError.invalidRequest }
        do {
            let response: CapabilitiesResponse = try await post(
                "capabilities", body: CapabilitiesRequest(group: group.base64URLString), authorization: authorization
            )
            return response.conditionalAppend == true
        } catch MLSRelayError.rejected(status: 400, code: "invalidRequest") {
            return false
        }
    }

    private func append(_ delivery: MLSDelivery, endpoint: String, authorization: Data) async throws -> MLSAppendResult {
        guard
            delivery.group.count == 32,
            delivery.epoch < MLSRelayLimits.maximumCursor,
            1...MLSRelayLimits.payloadBytes ~= delivery.payload.count,
            (delivery.welcome?.count ?? 0) <= MLSRelayLimits.payloadBytes
        else {
            throw MLSRelayError.invalidRequest
        }
        let request = AppendRequest(
            group: delivery.group.base64URLString,
            epoch: delivery.epoch,
            kind: delivery.kind.rawValue,
            payload: delivery.payload.base64URLString,
            welcome: delivery.welcome?.base64URLString,
            reference: delivery.keyPackageReference?.base64URLString,
            addWriter: delivery.addWriter?.base64URLString,
            removeWriter: delivery.removeWriter?.base64URLString,
            expectedHead: delivery.expectedHead
        )
        let outcome: Outcome<AppendResponse> = try await send(endpoint, body: request, authorization: authorization)
        switch outcome {
        case .keyPackageUnavailable(let epoch):
            return .keyPackageUnavailable(epoch: epoch)
        case .headAdvanced(let head):
            guard let expected = delivery.expectedHead, head > expected else { throw MLSRelayError.invalidResponse }
            return .headAdvanced(head: head)
        case .success(let response):
            let entry = try decode(response.entry, group: delivery.group)
            guard entry.delivery == delivery.withoutExpectedHead else { throw MLSRelayError.invalidResponse }
            return .accepted(cursor: entry.cursor)
        }
    }

    func fetch(group: Data, after cursor: UInt64, limit: Int, authorization: Data) async throws -> [MLSRelayEntry] {
        guard group.count == 32, cursor < MLSRelayLimits.maximumCursor, 1...MLSRelayLimits.fetchCount ~= limit else {
            throw MLSRelayError.invalidRequest
        }
        let response: FetchResponse = try await post(
            "fetch",
            body: FetchRequest(group: group.base64URLString, after: cursor, limit: limit),
            authorization: authorization
        )
        guard response.entries.count <= limit else { throw MLSRelayError.invalidResponse }
        var previous = cursor
        return try response.entries.map { item in
            let entry = try decode(item, group: group)
            guard entry.cursor > previous else { throw MLSRelayError.invalidResponse }
            previous = entry.cursor
            return entry
        }
    }

    func acknowledge(group: Data, through cursor: UInt64, authorization: Data) async throws {
        guard group.count == 32, cursor < MLSRelayLimits.maximumCursor else { throw MLSRelayError.invalidRequest }
        let _: Empty = try await post(
            "ack",
            body: AcknowledgeRequest(route: group.base64URLString, cursor: cursor),
            authorization: authorization
        )
    }

    private func decode(_ item: Entry, group: Data) throws -> MLSRelayEntry {
        guard
            item.cursor > 0,
            item.cursor < MLSRelayLimits.maximumCursor,
            item.epoch < MLSRelayLimits.maximumCursor,
            let kind = MLSDelivery.Kind(rawValue: item.kind)
        else {
            throw MLSRelayError.invalidResponse
        }
        let welcome = try item.welcome.map { try decodeCanonical($0, maximumBytes: MLSRelayLimits.payloadBytes) }
        let reference = try item.reference.map { try decodeCanonical($0, exactBytes: 32) }
        let addWriter = try item.addWriter.map { try decodeCanonical($0, exactBytes: 32) }
        let removeWriter = try item.removeWriter.map { try decodeCanonical($0, exactBytes: 32) }
        guard
            (welcome == nil) == (reference == nil),
            (welcome == nil) == (addWriter == nil),
            kind == .commit || (welcome == nil && removeWriter == nil)
        else {
            throw MLSRelayError.invalidResponse
        }
        let delivery = MLSDelivery(
            group: group,
            epoch: item.epoch,
            kind: kind,
            payload: try decodeCanonical(item.payload, maximumBytes: MLSRelayLimits.payloadBytes),
            welcome: welcome,
            keyPackageReference: reference,
            addWriter: addWriter,
            removeWriter: removeWriter
        )
        return MLSRelayEntry(cursor: item.cursor, delivery: delivery)
    }

    private func post<Request: Encodable, Response: Decodable>(
        _ endpoint: String,
        body: Request,
        authorization: Data?
    ) async throws -> Response {
        switch try await send(endpoint, body: body, authorization: authorization) as Outcome<Response> {
        case .success(let response): return response
        case .keyPackageUnavailable, .headAdvanced: throw MLSRelayError.invalidResponse
        }
    }

    private func send<Request: Encodable, Response: Decodable>(
        _ endpoint: String,
        body: Request,
        authorization: Data?
    ) async throws -> Outcome<Response> {
        if let authorization, authorization.count != 32 { throw MLSRelayError.invalidRequest }
        let url = try endpointURL(endpoint)
        let bodyData = try CanonicalJSON.encoder.encode(body)
        guard bodyData.count <= MLSRelayLimits.requestBytes else { throw MLSRelayError.invalidRequest }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("GotSync/2", forHTTPHeaderField: "User-Agent")
        if let authorization {
            request.setValue("Bearer \(authorization.base64URLString)", forHTTPHeaderField: "Authorization")
        }

        let (bytes, response) = try await session.bytes(for: request, delegate: MLSNoRedirectDelegate())
        guard let http = response as? HTTPURLResponse, http.url == url else {
            throw MLSRelayError.invalidResponse
        }
        if http.expectedContentLength > Int64(MLSRelayLimits.responseBytes) {
            throw MLSRelayError.responseTooLarge
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < MLSRelayLimits.responseBytes else { throw MLSRelayError.responseTooLarge }
            data.append(byte)
        }
        guard http.statusCode == 200 else {
            let failure = try? CanonicalJSON.decoder.decode(ErrorResponse.self, from: data)
            switch (http.statusCode, failure?.error) {
            case (409, "keyPackageUnavailable"):
                guard let epoch = failure?.epoch, epoch < MLSRelayLimits.maximumCursor else {
                    throw MLSRelayError.invalidResponse
                }
                return .keyPackageUnavailable(epoch: epoch)
            case (409, "headAdvanced"):
                guard let head = failure?.head, head < MLSRelayLimits.maximumCursor else {
                    throw MLSRelayError.invalidResponse
                }
                return .headAdvanced(head: head)
            case (409, "epochConflict"): throw MLSRelayError.epochConflict
            case (403, _): throw MLSRelayError.unauthorized
            case (410, "historyExpired"): throw MLSRelayError.historyExpired
            case (429, "deliveryCapacity"): throw MLSRelayError.capacityReached
            case (429, _): throw MLSRelayError.rateLimited
            case (_, "unsupportedVersion"): throw MLSRelayError.unsupportedVersion
            case (let status, let code): throw MLSRelayError.rejected(status: status, code: code ?? "http\(status)")
            }
        }
        let version: Int
        do { version = try CanonicalJSON.decoder.decode(VersionResponse.self, from: data).version }
        catch { throw MLSRelayError.invalidResponse }
        guard version == MLSRelayLimits.version else { throw MLSRelayError.unsupportedVersion }
        do {
            return .success(try CanonicalJSON.decoder.decode(Response.self, from: data))
        } catch {
            throw MLSRelayError.invalidResponse
        }
    }

    private func endpointURL(_ endpoint: String) throws -> URL {
        do {
            try SyncEndpointConfiguration.validateMailboxURL(baseURL, policy: policy)
        } catch {
            if baseURL.scheme?.lowercased() == "http" { throw MLSRelayError.insecureTransport }
            throw MLSRelayError.invalidURL
        }
        return baseURL.appendingPathComponent(endpoint)
    }

    private func decodeCanonical(_ value: String, exactBytes: Int? = nil, maximumBytes: Int = 32) throws -> Data {
        guard let decoded = try? Data(base64URL: value) else { throw MLSRelayError.invalidResponse }
        guard
            decoded.base64URLString == value,
            !decoded.isEmpty,
            decoded.count <= maximumBytes,
            exactBytes == nil || decoded.count == exactBytes
        else {
            throw MLSRelayError.invalidResponse
        }
        return decoded
    }
}

private final class MLSNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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
