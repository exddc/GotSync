import Foundation

public enum EndpointSecurityPolicy: Equatable, Sendable {
    case localDevelopment
    case production

}

public enum SyncEndpointConfigurationError: Error, Equatable, LocalizedError {
    case missing(String)
    case invalidRelay
    case invalidMailbox

    public var errorDescription: String? {
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

public struct SyncEndpointConfiguration: Equatable, Sendable {
    public let relayURL: URL
    public let mailboxURL: URL

    public init(
        relayURL: URL,
        mailboxURL: URL,
        policy: EndpointSecurityPolicy
    ) throws {
        try Self.validateRelayURL(relayURL, policy: policy)
        try Self.validateMailboxURL(mailboxURL, policy: policy)
        self.relayURL = relayURL
        self.mailboxURL = mailboxURL
    }

    public static func validateRelayURL(
        _ url: URL,
        policy: EndpointSecurityPolicy
    ) throws {
        guard
            let scheme = url.scheme?.lowercased(),
            scheme == "ws" || scheme == "wss",
            let host = url.host?.lowercased(),
            !host.isEmpty,
            url.path == "/v2/pairing",
            url.user == nil,
            url.password == nil,
            url.query == nil,
            url.fragment == nil
        else {
            throw SyncEndpointConfigurationError.invalidRelay
        }
        switch policy {
        case .localDevelopment:
            // Plaintext is allowed only on loopback or RFC1918 LAN hosts so a
            // phone on the same Wi‑Fi can reach a Mac-hosted demo relay.
            guard scheme == "wss" || isLoopback(host) || isPrivateLANHost(host) else {
                throw SyncEndpointConfigurationError.invalidRelay
            }
        case .production:
            guard scheme == "wss", !isLocalOnly(host) else {
                throw SyncEndpointConfigurationError.invalidRelay
            }
        }
    }

    public static func validateMailboxURL(
        _ url: URL,
        policy: EndpointSecurityPolicy
    ) throws {
        guard isValidHTTPEndpoint(url, path: "/v2/mls", policy: policy) else {
            throw SyncEndpointConfigurationError.invalidMailbox
        }
    }

    private static func isValidHTTPEndpoint(
        _ url: URL,
        path: String,
        policy: EndpointSecurityPolicy
    ) -> Bool {
        guard
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = url.host?.lowercased(),
            !host.isEmpty,
            url.path == path,
            url.user == nil,
            url.password == nil,
            url.query == nil,
            url.fragment == nil
        else {
            return false
        }
        switch policy {
        case .localDevelopment:
            return scheme == "https" || isLoopback(host) || isPrivateLANHost(host)
        case .production:
            return scheme == "https" && !isLocalOnly(host)
        }
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost"
            || host == "127.0.0.1"
            || host == "::1"
    }

    private static func isLocalOnly(_ host: String) -> Bool {
        isLoopback(host) || host == "0.0.0.0" || host == "::"
    }

    /// RFC1918 private IPv4 ranges for same-network device demos.
    private static func isPrivateLANHost(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count == 4,
              let a = UInt8(parts[0]),
              let b = UInt8(parts[1]),
              UInt8(parts[2]) != nil,
              UInt8(parts[3]) != nil
        else {
            return false
        }
        if a == 10 { return true }
        if a == 192 && b == 168 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        return false
    }
}
