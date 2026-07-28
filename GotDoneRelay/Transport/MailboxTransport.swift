import Foundation

enum MailboxTransportError: Error, Equatable, LocalizedError {
    case invalidURL
    case insecureTransport
    case invalidRequest
    case requestTooLarge
    case invalidResponse
    case responseTooLarge
    case rejected(status: Int, code: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The mailbox URL is invalid."
        case .insecureTransport:
            "The mailbox requires HTTPS outside local development."
        case .invalidRequest:
            "The mailbox request was invalid."
        case .requestTooLarge:
            "The mailbox request exceeded the protocol limit."
        case .invalidResponse:
            "The mailbox returned an invalid response."
        case .responseTooLarge:
            "The mailbox response exceeded the protocol limit."
        case .rejected(_, let code):
            "The mailbox rejected the request (\(code))."
        }
    }
}

struct MailboxStoredReceipt: Equatable, Sendable {
    let messageID: Data
    let cursor: UInt64
}

struct FetchedMailboxEnvelope: Equatable, Sendable {
    let cursor: UInt64
    let envelope: StoredMailboxEnvelope
}

struct MailboxFetchPage: Equatable, Sendable {
    let messages: [FetchedMailboxEnvelope]
    let nextCursor: UInt64
    let hasMore: Bool
}

protocol MailboxTransport: Sendable {
    func put(
        route: Data,
        authorization: Data,
        messages: [StoredMailboxEnvelope]
    ) async throws -> [MailboxStoredReceipt]

    func fetch(
        route: Data,
        authorization: Data,
        after cursor: UInt64,
        limit: Int
    ) async throws -> MailboxFetchPage

    func acknowledge(
        route: Data,
        authorization: Data,
        through cursor: UInt64
    ) async throws

    func forget(route: Data, authorization: Data) async throws
}

final class HTTPMailboxTransport: MailboxTransport, @unchecked Sendable {
    private struct Credentials: Encodable {
        let route: String
        let auth: String
    }

    private struct PutItem: Codable {
        let id: String
        let payload: String?
        let cursor: UInt64?
    }

    private struct PutRequest: Encodable {
        let route: String
        let auth: String
        let messages: [PutItem]
    }

    private struct PutResponse: Decodable {
        let version: UInt8
        let messages: [PutItem]
    }

    private struct FetchRequest: Encodable {
        let route: String
        let auth: String
        let after: UInt64
        let limit: Int
    }

    private struct FetchItem: Decodable {
        let cursor: UInt64
        let id: String
        let payload: String
    }

    private struct FetchResponse: Decodable {
        let version: UInt8
        let messages: [FetchItem]
        let nextCursor: UInt64
        let hasMore: Bool
    }

    private struct AcknowledgeRequest: Encodable {
        let route: String
        let auth: String
        let cursor: UInt64
    }

    private struct AcknowledgeResponse: Decodable {
        let version: UInt8
        let cursor: UInt64
        let acked: Int
    }

    private struct ForgetResponse: Decodable {
        let version: UInt8
        let forgotten: Bool
    }

    private struct ErrorResponse: Decodable {
        let error: String
    }

    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 10
            configuration.waitsForConnectivity = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func put(
        route: Data,
        authorization: Data,
        messages: [StoredMailboxEnvelope]
    ) async throws -> [MailboxStoredReceipt] {
        try validateCredentials(route: route, authorization: authorization)
        guard
            !messages.isEmpty,
            messages.count <= ProtocolLimits.mailboxBatchCount
        else {
            throw MailboxTransportError.invalidRequest
        }

        let request = PutRequest(
            route: route.base64URLString,
            auth: authorization.base64URLString,
            messages: messages.map {
                PutItem(
                    id: $0.messageID.base64URLString,
                    payload: $0.ciphertext.base64URLString,
                    cursor: nil
                )
            }
        )
        let response: PutResponse = try await post("put", body: request)
        guard
            response.version == SyncProtocol.version,
            response.messages.count == messages.count
        else {
            throw MailboxTransportError.invalidResponse
        }

        var seen = Set<Data>()
        var receipts: [MailboxStoredReceipt] = []
        for item in response.messages {
            guard
                item.payload == nil,
                let cursor = item.cursor,
                cursor > 0
            else {
                throw MailboxTransportError.invalidResponse
            }
            let messageID = try decodeCanonical(
                item.id,
                exactBytes: 32,
                maximumBytes: 32
            )
            guard seen.insert(messageID).inserted else {
                throw MailboxTransportError.invalidResponse
            }
            receipts.append(
                MailboxStoredReceipt(messageID: messageID, cursor: cursor)
            )
        }
        guard
            Set(receipts.map(\.messageID)) == Set(messages.map(\.messageID))
        else {
            throw MailboxTransportError.invalidResponse
        }
        return receipts
    }

    func fetch(
        route: Data,
        authorization: Data,
        after cursor: UInt64,
        limit: Int
    ) async throws -> MailboxFetchPage {
        try validateCredentials(route: route, authorization: authorization)
        guard
            cursor <= UInt64(Int64.max),
            1...ProtocolLimits.mailboxFetchCount ~= limit
        else {
            throw MailboxTransportError.invalidRequest
        }
        let request = FetchRequest(
            route: route.base64URLString,
            auth: authorization.base64URLString,
            after: cursor,
            limit: limit
        )
        let response: FetchResponse = try await post("fetch", body: request)
        guard
            response.version == SyncProtocol.version,
            response.messages.count <= limit
        else {
            throw MailboxTransportError.invalidResponse
        }

        var previous = cursor
        var seen = Set<Data>()
        var envelopes: [FetchedMailboxEnvelope] = []
        for item in response.messages {
            guard item.cursor > previous else {
                throw MailboxTransportError.invalidResponse
            }
            let messageID = try decodeCanonical(
                item.id,
                exactBytes: 32,
                maximumBytes: 32
            )
            guard seen.insert(messageID).inserted else {
                throw MailboxTransportError.invalidResponse
            }
            let ciphertext = try decodeCanonical(
                item.payload,
                minimumBytes: 16,
                maximumBytes: ProtocolLimits.mailboxEnvelopeBytes
            )
            envelopes.append(
                FetchedMailboxEnvelope(
                    cursor: item.cursor,
                    envelope: try StoredMailboxEnvelope(
                        messageID: messageID,
                        ciphertext: ciphertext
                    )
                )
            )
            previous = item.cursor
        }

        let expectedNext = envelopes.last?.cursor ?? cursor
        guard
            response.nextCursor == expectedNext,
            !response.hasMore || !envelopes.isEmpty
        else {
            throw MailboxTransportError.invalidResponse
        }
        return MailboxFetchPage(
            messages: envelopes,
            nextCursor: response.nextCursor,
            hasMore: response.hasMore
        )
    }

    func acknowledge(
        route: Data,
        authorization: Data,
        through cursor: UInt64
    ) async throws {
        try validateCredentials(route: route, authorization: authorization)
        guard cursor > 0, cursor <= UInt64(Int64.max) else {
            throw MailboxTransportError.invalidRequest
        }
        let request = AcknowledgeRequest(
            route: route.base64URLString,
            auth: authorization.base64URLString,
            cursor: cursor
        )
        let response: AcknowledgeResponse = try await post("ack", body: request)
        guard
            response.version == SyncProtocol.version,
            response.cursor == cursor,
            response.acked >= 0
        else {
            throw MailboxTransportError.invalidResponse
        }
    }

    func forget(route: Data, authorization: Data) async throws {
        try validateCredentials(route: route, authorization: authorization)
        let request = Credentials(
            route: route.base64URLString,
            auth: authorization.base64URLString
        )
        let response: ForgetResponse = try await post("forget", body: request)
        guard response.version == SyncProtocol.version, response.forgotten else {
            throw MailboxTransportError.invalidResponse
        }
    }

    private func post<Request: Encodable, Response: Decodable>(
        _ endpoint: String,
        body: Request
    ) async throws -> Response {
        let url = try endpointURL(endpoint)
        let bodyData = try CanonicalJSON.encoder.encode(body)
        guard bodyData.count <= ProtocolLimits.mailboxRequestBytes else {
            throw MailboxTransportError.requestTooLarge
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("GotDoneRelay/1", forHTTPHeaderField: "User-Agent")

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(
                for: request,
                delegate: MailboxNoRedirectDelegate()
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            throw MailboxTransportError.invalidResponse
        }
        guard http.url == url else {
            throw MailboxTransportError.invalidResponse
        }
        if http.expectedContentLength
            > Int64(ProtocolLimits.mailboxRequestBytes)
        {
            throw MailboxTransportError.responseTooLarge
        }
        var data = Data()
        if http.expectedContentLength > 0 {
            data.reserveCapacity(
                min(
                    Int(http.expectedContentLength),
                    ProtocolLimits.mailboxRequestBytes
                )
            )
        }
        do {
            for try await byte in bytes {
                guard data.count < ProtocolLimits.mailboxRequestBytes else {
                    throw MailboxTransportError.responseTooLarge
                }
                data.append(byte)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MailboxTransportError {
            throw error
        } catch {
            throw error
        }
        guard http.statusCode == 200 else {
            let code = (
                try? CanonicalJSON.decoder.decode(ErrorResponse.self, from: data)
            )?.error ?? "http\(http.statusCode)"
            throw MailboxTransportError.rejected(
                status: http.statusCode,
                code: code
            )
        }
        do {
            return try CanonicalJSON.decoder.decode(Response.self, from: data)
        } catch {
            throw MailboxTransportError.invalidResponse
        }
    }

    private func endpointURL(_ endpoint: String) throws -> URL {
        guard
            baseURL.user == nil,
            baseURL.password == nil,
            baseURL.query == nil,
            baseURL.fragment == nil,
            baseURL.path == "/v1/mailbox",
            let scheme = baseURL.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = baseURL.host?.lowercased(),
            !host.isEmpty
        else {
            throw MailboxTransportError.invalidURL
        }
        #if DEBUG
        if scheme == "http" {
            guard host == "127.0.0.1" || host == "localhost" || host == "::1" else {
                throw MailboxTransportError.insecureTransport
            }
        }
        #else
        guard scheme == "https" else {
            throw MailboxTransportError.insecureTransport
        }
        #endif
        return baseURL.appendingPathComponent(endpoint)
    }

    private func validateCredentials(
        route: Data,
        authorization: Data
    ) throws {
        guard route.count == 32, authorization.count == 32 else {
            throw MailboxTransportError.invalidRequest
        }
    }

    private func decodeCanonical(
        _ value: String,
        exactBytes: Int? = nil,
        minimumBytes: Int = 0,
        maximumBytes: Int
    ) throws -> Data {
        let decoded: Data
        do {
            decoded = try Data(base64URL: value)
        } catch {
            throw MailboxTransportError.invalidResponse
        }
        guard
            decoded.base64URLString == value,
            decoded.count >= minimumBytes,
            decoded.count <= maximumBytes,
            exactBytes == nil || decoded.count == exactBytes
        else {
            throw MailboxTransportError.invalidResponse
        }
        return decoded
    }
}

private final class MailboxNoRedirectDelegate: NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
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

struct PairMailbox: Sendable {
    let outbound: MailboxKeyMaterial
    let inbound: MailboxKeyMaterial
    let localDeviceID: ReplicaDeviceID
    let remoteDeviceID: ReplicaDeviceID

    init(credentials: PairCredentials) throws {
        guard
            credentials.version == SyncProtocol.version,
            credentials.pairRoot.count == 32,
            credentials.pairID.count == 16
        else {
            throw MailboxCryptoError.invalidCredentials
        }
        outbound = try MailboxKeyMaterial(
            pairRoot: credentials.pairRoot,
            pairID: credentials.pairID,
            senderRole: credentials.role
        )
        inbound = try MailboxKeyMaterial(
            pairRoot: credentials.pairRoot,
            pairID: credentials.pairID,
            senderRole: credentials.role.opposite
        )
        localDeviceID = try ReplicaDeviceID(bytes: credentials.localDeviceID)
        remoteDeviceID = try ReplicaDeviceID(bytes: credentials.remoteDeviceID)
    }

    func seal(_ operation: TaskOperation) throws -> StoredMailboxEnvelope {
        guard operation.originDeviceID == localDeviceID else {
            throw MailboxCryptoError.invalidEnvelope
        }
        return try outbound.seal(operation)
    }

    func open(_ envelope: StoredMailboxEnvelope) throws -> TaskOperation {
        let operation = try inbound.open(envelope)
        guard operation.originDeviceID == remoteDeviceID else {
            throw MailboxCryptoError.invalidEnvelope
        }
        return operation
    }
}
