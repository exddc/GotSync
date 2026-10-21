import CryptoKit
import Foundation

/// A single-use admission capability for one MLS group.
///
/// The phrase encodes only `secret`. The URL also carries the group ID and the
/// inviter's MLS fingerprint. A joiner that starts from the phrase learns both
/// from an offer sealed under a key derived from `secret`.
public struct Invitation: Equatable, Sendable {
    static let urlVersion = "2"

    public let secret: Data
    public let groupID: Data?
    public let inviterFingerprint: Data?

    public init(secret: Data, groupID: Data? = nil, inviterFingerprint: Data? = nil) throws {
        guard secret.count == 16 else { throw MnemonicError.invalidSecretLength }
        guard (groupID == nil) == (inviterFingerprint == nil),
              groupID.map({ $0.count == 32 }) ?? true,
              inviterFingerprint.map({ $0.count == 32 }) ?? true
        else {
            throw MnemonicError.invalidInviteURL
        }
        self.secret = secret
        self.groupID = groupID
        self.inviterFingerprint = inviterFingerprint
    }

    static func generate(groupID: Data, inviterFingerprint: Data) throws -> Invitation {
        try Invitation(secret: .secureRandom(count: 16), groupID: groupID, inviterFingerprint: inviterFingerprint)
    }

    public var phrase: String {
        MnemonicCodec.encode(secret)
    }

    var pairingToken: Data { derive("mls-pairing-token/v2") }
    var route: Data { derive("mls-pairing-route/v2") }
    var offerKey: SymmetricKey { SymmetricKey(data: derive("mls-pairing-offer/v2")) }
    var responseKey: SymmetricKey { SymmetricKey(data: derive("mls-pairing-response/v2")) }

    private func derive(_ label: String) -> Data {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            info: Data("\(ProtocolDomains.namespace)/\(label)".utf8),
            outputByteCount: 32
        ).dataRepresentation
    }

    public func url(scheme: String) throws -> URL {
        try Self.validateURLScheme(scheme)
        guard let groupID, let inviterFingerprint else { throw MnemonicError.invalidInviteURL }
        var components = URLComponents()
        components.scheme = scheme.lowercased()
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: Self.urlVersion),
            URLQueryItem(name: "secret", value: secret.base64URLString),
            URLQueryItem(name: "group", value: groupID.base64URLString),
            URLQueryItem(name: "fingerprint", value: inviterFingerprint.base64URLString),
        ]
        guard let url = components.url else { throw MnemonicError.invalidInviteURL }
        return url
    }

    static func validateURLScheme(_ scheme: String) throws {
        guard scheme.range(of: "\\A[A-Za-z][A-Za-z0-9+.-]*\\z", options: .regularExpression) != nil,
              !["http", "https", "ws", "wss", "file"].contains(scheme.lowercased())
        else { throw MnemonicError.invalidInviteURL }
    }

    public static func from(phrase: String) throws -> Invitation {
        try Invitation(secret: MnemonicCodec.decode(phrase))
    }

    public static func from(url: URL, scheme: String) throws -> Invitation {
        try validateURLScheme(scheme)
        guard
            url.scheme?.lowercased() == scheme.lowercased(),
            url.host?.lowercased() == "pair",
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            throw MnemonicError.invalidInviteURL
        }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard values.updateValue(item.value ?? "", forKey: item.name) == nil else {
                throw MnemonicError.invalidInviteURL
            }
        }
        guard let version = values["v"] else { throw MnemonicError.invalidInviteURL }
        guard version == urlVersion else { throw MnemonicError.unsupportedVersion }
        guard
            Set(values.keys) == ["v", "secret", "group", "fingerprint"],
            let secret = values["secret"].flatMap(canonical),
            let group = values["group"].flatMap(canonical),
            let fingerprint = values["fingerprint"].flatMap(canonical)
        else {
            throw MnemonicError.invalidInviteURL
        }
        return try Invitation(secret: secret, groupID: group, inviterFingerprint: fingerprint)
    }

    private static func canonical(_ value: String) -> Data? {
        guard let data = try? Data(base64URL: value), data.base64URLString == value else { return nil }
        return data
    }
}
