import CryptoKit
import Foundation
import Security

enum SyncProtocol {
    static let version: UInt8 = 1
    static let pairingVersion: UInt8 = 2
    static let appID = Data("com.gotdone.relay.poc".utf8)
    static let defaultRelayURL = URL(string: "ws://127.0.0.1:8765/v1")!
    static let defaultMailboxURL = URL(
        string: "http://127.0.0.1:8767/v1/mailbox"
    )!
}

enum EndpointSecurityPolicy: Equatable, Sendable {
    case localDevelopment
    case production

    static var runtime: EndpointSecurityPolicy {
        #if DEBUG
        .localDevelopment
        #else
        .production
        #endif
    }
}

enum SyncEndpointConfigurationError: Error, Equatable, LocalizedError {
    case missing(String)
    case invalidRelay
    case invalidMailbox

    var errorDescription: String? {
        switch self {
        case .missing(let key):
            "This build is missing the \(key) sync endpoint."
        case .invalidRelay:
            "This build has an invalid live sync endpoint."
        case .invalidMailbox:
            "This build has an invalid offline sync endpoint."
        }
    }
}

struct SyncEndpointConfiguration: Equatable, Sendable {
    static let relayInfoKey = "GotDoneRelayURL"
    static let mailboxInfoKey = "GotDoneMailboxURL"

    let relayURL: URL
    let mailboxURL: URL

    init(
        relayURL: URL,
        mailboxURL: URL,
        policy: EndpointSecurityPolicy
    ) throws {
        try Self.validateRelayURL(relayURL, policy: policy)
        try Self.validateMailboxURL(mailboxURL, policy: policy)
        self.relayURL = relayURL
        self.mailboxURL = mailboxURL
    }

    static func load(
        bundle: Bundle = .main,
        policy: EndpointSecurityPolicy = .runtime
    ) throws -> SyncEndpointConfiguration {
        try load(
            values: [
                relayInfoKey: bundle.object(
                    forInfoDictionaryKey: relayInfoKey
                ) as? String,
                mailboxInfoKey: bundle.object(
                    forInfoDictionaryKey: mailboxInfoKey
                ) as? String,
            ].compactMapValues { $0 },
            policy: policy
        )
    }

    static func load(
        values: [String: String],
        policy: EndpointSecurityPolicy
    ) throws -> SyncEndpointConfiguration {
        let relayURL = try configuredURL(
            values[relayInfoKey],
            key: relayInfoKey,
            fallback: SyncProtocol.defaultRelayURL,
            invalid: .invalidRelay,
            policy: policy
        )
        let mailboxURL = try configuredURL(
            values[mailboxInfoKey],
            key: mailboxInfoKey,
            fallback: SyncProtocol.defaultMailboxURL,
            invalid: .invalidMailbox,
            policy: policy
        )
        return try SyncEndpointConfiguration(
            relayURL: relayURL,
            mailboxURL: mailboxURL,
            policy: policy
        )
    }

    static func validateRelayURL(
        _ url: URL,
        policy: EndpointSecurityPolicy
    ) throws {
        guard
            let scheme = url.scheme?.lowercased(),
            scheme == "ws" || scheme == "wss",
            let host = url.host?.lowercased(),
            !host.isEmpty,
            url.path == "/v1",
            url.user == nil,
            url.password == nil,
            url.query == nil,
            url.fragment == nil
        else {
            throw SyncEndpointConfigurationError.invalidRelay
        }
        switch policy {
        case .localDevelopment:
            guard scheme == "wss" || isLoopback(host) else {
                throw SyncEndpointConfigurationError.invalidRelay
            }
        case .production:
            guard scheme == "wss", !isLocalOnly(host) else {
                throw SyncEndpointConfigurationError.invalidRelay
            }
        }
    }

    static func validateMailboxURL(
        _ url: URL,
        policy: EndpointSecurityPolicy
    ) throws {
        guard
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = url.host?.lowercased(),
            !host.isEmpty,
            url.path == "/v1/mailbox",
            url.user == nil,
            url.password == nil,
            url.query == nil,
            url.fragment == nil
        else {
            throw SyncEndpointConfigurationError.invalidMailbox
        }
        switch policy {
        case .localDevelopment:
            guard scheme == "https" || isLoopback(host) else {
                throw SyncEndpointConfigurationError.invalidMailbox
            }
        case .production:
            guard scheme == "https", !isLocalOnly(host) else {
                throw SyncEndpointConfigurationError.invalidMailbox
            }
        }
    }

    private static func configuredURL(
        _ rawValue: String?,
        key: String,
        fallback: URL,
        invalid: SyncEndpointConfigurationError,
        policy: EndpointSecurityPolicy
    ) throws -> URL {
        let value = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let value, !value.isEmpty, !value.contains("$(") {
            guard let url = URL(string: value) else {
                throw invalid
            }
            return url
        }
        guard policy == .localDevelopment else {
            throw SyncEndpointConfigurationError.missing(key)
        }
        return fallback
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost"
            || host == "127.0.0.1"
            || host == "::1"
    }

    private static func isLocalOnly(_ host: String) -> Bool {
        isLoopback(host) || host == "0.0.0.0" || host == "::"
    }
}

enum ProtocolLimits {
    static let registrationBytes = 512
    static let webSocketMessageBytes = 512 * 1_024
    static let plaintextBytes = 384 * 1_024
    static let provisioningArchiveBytes = 280 * 1_024
    static let operationBatchCount = 256
    static let operationBatchBytes = 256 * 1_024
    static let titleScalars = 200
    static let titleBytes = 512
    static let taskCount = 1_000
    static let operationCount = 10_000
    static let vectorOrigins = 8
    static let mailboxEnvelopeBytes = 64 * 1_024
    static let mailboxBatchCount = 128
    static let mailboxRequestBytes = 512 * 1_024
    static let mailboxFetchCount = 64
}

enum DeviceRole: String, Codable, Sendable {
    case host
    case joiner

    var wireByte: UInt8 {
        switch self {
        case .host: 0x41
        case .joiner: 0x42
        }
    }

    var opposite: DeviceRole {
        switch self {
        case .host: .joiner
        case .joiner: .host
        }
    }
}

enum ProtocolSupportError: Error, Equatable {
    case invalidRandomLength
    case randomGenerationFailed(Int32)
    case invalidBase64URL
    case invalidInteger
    case invalidRelayURL
    case invalidTranscript
}

extension Data {
    static func secureRandom(count: Int) throws -> Data {
        guard count > 0 else {
            throw ProtocolSupportError.invalidRandomLength
        }

        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return errSecParam
            }
            return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
        }
        guard result == errSecSuccess else {
            throw ProtocolSupportError.randomGenerationFailed(result)
        }
        return data
    }

    var base64URLString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init(base64URL: String) throws {
        var normalized = base64URL
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let decoded = Data(base64Encoded: normalized) else {
            throw ProtocolSupportError.invalidBase64URL
        }
        self = decoded
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(contentsOf: [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ])
    }

    mutating func appendUInt64(_ value: UInt64) {
        append(contentsOf: [
            UInt8((value >> 56) & 0xff),
            UInt8((value >> 48) & 0xff),
            UInt8((value >> 40) & 0xff),
            UInt8((value >> 32) & 0xff),
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ])
    }

    func uint64(at offset: Int) throws -> UInt64 {
        guard offset >= 0, count >= offset + 8 else {
            throw ProtocolSupportError.invalidInteger
        }
        return self[offset..<(offset + 8)].reduce(UInt64.zero) {
            ($0 << 8) | UInt64($1)
        }
    }

    var sha256: Data {
        Data(SHA256.hash(data: self))
    }
}

extension SymmetricKey {
    var dataRepresentation: Data {
        withUnsafeBytes { Data($0) }
    }
}

struct CanonicalJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder = JSONDecoder()
}

struct TranscriptBuilder {
    private(set) var data = Data()
    private var lastTag: UInt8 = 0

    mutating func append(tag: UInt8, value: Data) throws {
        guard tag > lastTag, value.count <= Int(UInt32.max) else {
            throw ProtocolSupportError.invalidTranscript
        }
        lastTag = tag
        data.append(tag)
        data.appendUInt32(UInt32(value.count))
        data.append(value)
    }
}

extension URL {
    var canonicalRelayOrigin: String? {
        guard
            let scheme = scheme?.lowercased(),
            scheme == "ws" || scheme == "wss",
            let host = host?.lowercased(),
            user == nil,
            password == nil
        else {
            return nil
        }

        let resolvedPort = port ?? (scheme == "wss" ? 443 : 80)
        return "\(scheme)://\(host):\(resolvedPort)"
    }
}
