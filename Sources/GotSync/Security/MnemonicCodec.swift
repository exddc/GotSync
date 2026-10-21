import CryptoKit
import Foundation

public enum MnemonicError: Error, Equatable {
    case invalidSecretLength
    case invalidWordCount
    case unknownWord(String)
    case invalidChecksum
    case invalidInviteURL
    case unsupportedVersion
}

struct LegacyInvitation: Equatable, Sendable {
    let secret: Data

    init(secret: Data) throws {
        guard secret.count == 16 else {
            throw MnemonicError.invalidSecretLength
        }
        self.secret = secret
    }

    var phrase: String {
        MnemonicCodec.encode(secret)
    }

    var pairRoute: Data {
        SyncKeyDerivation.derive(
            input: secret,
            label: "\(ProtocolDomains.namespace)/pair-route/v1",
            count: 32
        )
    }

    var pairPSK: Data {
        SyncKeyDerivation.derive(
            input: secret,
            label: "\(ProtocolDomains.namespace)/pair-psk/v1",
            count: 32
        )
    }
}

enum MnemonicCodec {
    /// 256 single words (one per byte). No hyphens or compound tokens.
    static let words: [String] = [
        "able", "acid", "acre", "aged", "ahead", "aid", "aim", "air",
        "ale", "all", "aloe", "also", "amber", "angel", "anger", "angle",
        "ant", "any", "apple", "april", "arch", "area", "arm", "army",
        "art", "ash", "ask", "atom", "aunt", "auto", "awake", "away",
        "axis", "baby", "back", "badge", "bag", "bake", "ball", "band",
        "bank", "bar", "bark", "barn", "base", "basin", "bath", "beach",
        "bead", "beam", "bean", "bear", "beat", "bed", "bee", "beef",
        "been", "bell", "belt", "bench", "berry", "best", "bike", "bind",
        "bird", "bite", "black", "blade", "blame", "blank", "blast", "blaze",
        "blend", "bless", "blind", "block", "blood", "bloom", "blue", "bluff",
        "blur", "board", "boat", "body", "boil", "bold", "bolt", "bomb",
        "bond", "bone", "book", "boom", "boot", "born", "boss", "both",
        "bowl", "box", "boy", "brand", "brass", "brave", "bread", "break",
        "brick", "bride", "bridge", "brief", "bright", "bring", "broad", "brook",
        "broom", "brown", "brush", "bubble", "buck", "budget", "buff", "build",
        "bulb", "bulk", "bull", "bump", "bunch", "bunny", "burn", "burst",
        "bus", "bush", "busy", "butter", "button", "buyer", "cabin", "cable",
        "cactus", "cage", "cake", "calm", "camel", "camp", "canal", "candy",
        "cane", "cannon", "canoe", "canvas", "canyon", "cape", "card", "care",
        "cargo", "carol", "carry", "cart", "case", "cash", "cast", "cat",
        "catch", "cause", "cave", "cedar", "cell", "cement", "census", "cereal",
        "chair", "chalk", "champ", "chance", "change", "chaos", "charge", "charm",
        "chart", "chase", "cheap", "check", "cheek", "cheer", "cheese", "chef",
        "cherry", "chest", "chick", "chief", "child", "chili", "chill", "chip",
        "choice", "choir", "choke", "chord", "chore", "chose", "chunk", "cider",
        "cigar", "circle", "city", "civic", "civil", "claim", "clamp", "clap",
        "claw", "clay", "clean", "clerk", "clever", "click", "client", "cliff",
        "climb", "cling", "clinic", "clip", "clock", "close", "cloth", "cloud",
        "clown", "club", "clump", "clutch", "coach", "coast", "code", "coffee",
        "coil", "coin", "cold", "color", "column", "combat", "combo", "come",
        "comic", "comma", "common", "cook", "cool", "copper", "copy", "coral",
        "core", "corn", "cost", "cotton", "couch", "couple", "course", "cousin",
    ]

    private static let indices: [String: UInt8] = {
        precondition(words.count == 256)
        precondition(Set(words).count == 256)
        precondition(words.allSatisfy { !$0.contains("-") && !$0.contains(" ") })
        return Dictionary(
            uniqueKeysWithValues: words.enumerated().map { ($0.element, UInt8($0.offset)) }
        )
    }()

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
