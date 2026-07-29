import Foundation

enum RelayEvent: Equatable, Sendable {
    case peerReady
    case peerLeft
    case binary(Data)
    case error(String)
}

enum RelaySocketError: Error, Equatable, LocalizedError {
    case invalidRelayURL
    case invalidRoute
    case notConnected
    case unexpectedControl
    case invalidControl
    case messageTooLarge
    case peerLeft
    case connectionTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidRelayURL:
            "The relay URL is invalid."
        case .invalidRoute:
            "The relay route is invalid."
        case .notConnected:
            "The relay is not connected."
        case .unexpectedControl:
            "The relay sent an unsupported control message."
        case .invalidControl:
            "The relay sent a malformed control message."
        case .messageTooLarge:
            "A relay message exceeded the protocol limit."
        case .peerLeft:
            "The other device disconnected."
        case .connectionTimedOut:
            "The relay connection timed out."
        }
    }
}

actor RelaySocket {
    private struct Registration: Encodable {
        let route: String
        let type = "register"
        let version = Int(SyncProtocol.version)
    }

    private struct Control: Decodable {
        let type: String
        let version: Int
        let code: String?
    }

    private let url: URL
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var openObserver: RelayOpenObserver?
    private var sendTail: Task<Void, Error>?
    private var secureSession: SecureSession?

    init(url: URL) {
        self.url = url
    }

    func connect(route: Data) async throws {
        guard route.count == 32 else {
            throw RelaySocketError.invalidRoute
        }
        guard (try? SyncEndpointConfiguration.validateRelayURL(
            url,
            policy: .runtime
        )) != nil else {
            throw RelaySocketError.invalidRelayURL
        }

        cancel()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.waitsForConnectivity = false
        let observer = RelayOpenObserver()
        let session = URLSession(
            configuration: configuration,
            delegate: observer,
            delegateQueue: nil
        )
        var request = URLRequest(url: url)
        request.setValue("GotDoneRelay/1", forHTTPHeaderField: "User-Agent")
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = ProtocolLimits.webSocketMessageBytes
        openObserver = observer
        self.session = session
        self.socket = socket
        socket.resume()

        do {
            try await observer.waitUntilOpen()
            let registration = Registration(route: route.base64URLString)
            let encoded = try RelaySocket.encodeRegistration(registration)
            try await socket.send(.string(encoded))
        } catch {
            cancel()
            throw error
        }
    }

    func receive() async throws -> RelayEvent {
        guard let socket else {
            throw RelaySocketError.notConnected
        }
        let message = try await socket.receive()
        switch message {
        case .data(let data):
            guard data.count <= ProtocolLimits.webSocketMessageBytes else {
                throw RelaySocketError.messageTooLarge
            }
            return .binary(data)
        case .string(let text):
            return try RelaySocket.parseControl(text)
        @unknown default:
            throw RelaySocketError.unexpectedControl
        }
    }

    func send(_ data: Data) async throws {
        guard data.count <= ProtocolLimits.webSocketMessageBytes else {
            throw RelaySocketError.messageTooLarge
        }
        guard let socket else {
            throw RelaySocketError.notConnected
        }
        try await enqueue(data, on: socket)
    }

    func installSecureSession(
        material: HandshakeMaterial,
        role: DeviceRole
    ) throws {
        secureSession = try material.makeSecureSession(role: role)
    }

    func sendEncrypted(_ plaintext: Data) async throws {
        guard let socket, var secureSession else {
            throw RelaySocketError.notConnected
        }
        let frame = try secureSession.seal(plaintext)
        self.secureSession = secureSession
        try await enqueue(frame, on: socket)
    }

    func openEncrypted(_ frame: Data) throws -> Data {
        guard var secureSession else {
            throw RelaySocketError.notConnected
        }
        let plaintext = try secureSession.open(frame)
        self.secureSession = secureSession
        return plaintext
    }

    func clearSecureSession() {
        secureSession = nil
    }

    private func enqueue(
        _ data: Data,
        on socket: URLSessionWebSocketTask
    ) async throws {
        let previous = sendTail
        let queued = Task {
            if let previous {
                try await previous.value
            }
            try Task.checkCancellation()
            try await socket.send(.data(data))
        }
        sendTail = queued
        try await queued.value
    }

    func cancel() {
        socket?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        sendTail?.cancel()
        socket = nil
        session = nil
        openObserver = nil
        sendTail = nil
        secureSession = nil
    }

    static func registrationText(route: Data) throws -> String {
        guard route.count == 32 else {
            throw RelaySocketError.invalidRoute
        }
        return try encodeRegistration(Registration(route: route.base64URLString))
    }

    static func parseControl(_ text: String) throws -> RelayEvent {
        guard text.utf8.count <= ProtocolLimits.registrationBytes else {
            throw RelaySocketError.messageTooLarge
        }
        guard let data = text.data(using: .utf8) else {
            throw RelaySocketError.invalidControl
        }
        let control: Control
        do {
            control = try JSONDecoder().decode(Control.self, from: data)
        } catch {
            throw RelaySocketError.invalidControl
        }
        guard control.version == Int(SyncProtocol.version) else {
            throw RelaySocketError.invalidControl
        }
        switch control.type {
        case "peerReady":
            return .peerReady
        case "peerLeft":
            return .peerLeft
        case "error":
            guard let code = control.code, !code.isEmpty else {
                throw RelaySocketError.invalidControl
            }
            return .error(code)
        default:
            throw RelaySocketError.unexpectedControl
        }
    }

    private static func encodeRegistration(_ registration: Registration) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(registration)
        guard data.count <= ProtocolLimits.registrationBytes,
              let text = String(data: data, encoding: .utf8)
        else {
            throw RelaySocketError.messageTooLarge
        }
        return text
    }
}

private final class RelayOpenObserver: NSObject,
    URLSessionWebSocketDelegate,
    @unchecked Sendable
{
    private enum State {
        case waiting
        case open
        case failed(Error)
    }

    private let lock = NSLock()
    private var state: State = .waiting
    private var continuation: CheckedContinuation<Void, Error>?

    func waitUntilOpen() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            switch state {
            case .waiting:
                self.continuation = continuation
                lock.unlock()
                Task {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    self.resolve(.failure(RelaySocketError.connectionTimedOut))
                }
            case .open:
                lock.unlock()
                continuation.resume()
            case .failed(let error):
                lock.unlock()
                continuation.resume(throwing: error)
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        resolve(.success(()))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            resolve(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        resolve(.failure(RelaySocketError.invalidRelayURL))
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        resolve(.failure(URLError(.networkConnectionLost)))
    }

    private func resolve(_ result: Result<Void, Error>) {
        lock.lock()
        guard case .waiting = state else {
            lock.unlock()
            return
        }
        switch result {
        case .success:
            state = .open
        case .failure(let error):
            state = .failed(error)
        }
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
