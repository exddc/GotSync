import CryptoKit
import Foundation

enum MnemonicError: Error, Equatable {
    case invalidSecretLength
    case invalidWordCount
    case unknownWord(String)
    case invalidChecksum
    case invalidInviteURL
    case unsupportedVersion
}

struct Invitation: Equatable, Sendable {
    let secret: Data

    init(secret: Data) throws {
        guard secret.count == 16 else {
            throw MnemonicError.invalidSecretLength
        }
        self.secret = secret
    }

    static func generate() throws -> Invitation {
        try Invitation(secret: .secureRandom(count: 16))
    }

    var phrase: String {
        MnemonicCodec.encode(secret)
    }

    var pairRoute: Data {
        SyncKeyDerivation.derive(
            input: secret,
            label: "com.gotdone.sync/pair-route/v1",
            count: 32
        )
    }

    var pairPSK: Data {
        SyncKeyDerivation.derive(
            input: secret,
            label: "com.gotdone.sync/pair-psk/v1",
            count: 32
        )
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = "gotdone"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "secret", value: secret.base64URLString),
        ]
        return components.url!
    }

    static func from(phrase: String) throws -> Invitation {
        try Invitation(secret: MnemonicCodec.decode(phrase))
    }

    static func from(url: URL) throws -> Invitation {
        guard
            url.scheme?.lowercased() == "gotdone",
            url.host?.lowercased() == "pair",
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            throw MnemonicError.invalidInviteURL
        }

        let items = components.queryItems ?? []
        guard
            items.count == 2,
            Set(items.map(\.name)) == Set(["v", "secret"])
        else {
            throw MnemonicError.invalidInviteURL
        }
        var values: [String: String] = [:]
        for item in items {
            guard values.updateValue(item.value ?? "", forKey: item.name) == nil else {
                throw MnemonicError.invalidInviteURL
            }
        }
        guard values["v"] == "1" else {
            throw MnemonicError.unsupportedVersion
        }
        guard let encoded = values["secret"] else {
            throw MnemonicError.invalidInviteURL
        }
        return try Invitation(secret: Data(base64URL: encoded))
    }
}

enum MnemonicCodec {
    private static let prefixes = [
        "amber", "aspen", "autumn", "azure",
        "bright", "calm", "cedar", "coral",
        "dawn", "ember", "fern", "golden",
        "lunar", "misty", "quiet", "silver",
    ]

    private static let suffixes = [
        "acorn", "badger", "brook", "cloud",
        "comet", "dune", "field", "fox",
        "grove", "harbor", "iris", "maple",
        "otter", "pine", "river", "willow",
    ]

    static let words: [String] = prefixes.flatMap { prefix in
        suffixes.map { "\(prefix)-\($0)" }
    }

    private static let indices: [String: UInt8] = Dictionary(
        uniqueKeysWithValues: words.enumerated().map { ($0.element, UInt8($0.offset)) }
    )

    static func encode(_ secret: Data) -> String {
        precondition(secret.count == 16)
        var bytes = Array(secret)
        bytes.append(secret.sha256[0])
        return bytes.map { words[Int($0)] }.joined(separator: " ")
    }

    static func decode(_ phrase: String) throws -> Data {
        let tokens = phrase
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard tokens.count == 17 else {
            throw MnemonicError.invalidWordCount
        }

        let bytes = try tokens.map { token in
            guard let value = indices[token] else {
                throw MnemonicError.unknownWord(token)
            }
            return value
        }
        let secret = Data(bytes.prefix(16))
        guard bytes[16] == secret.sha256[0] else {
            throw MnemonicError.invalidChecksum
        }
        return secret
    }
}
