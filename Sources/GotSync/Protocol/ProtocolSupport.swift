import CryptoKit
import Foundation
import Security

enum SyncProtocol {
    static let version: UInt8 = 2
}

enum ProtocolLimits {
    static let registrationBytes = 512
    static let webSocketMessageBytes = 512 * 1_024
    static let plaintextBytes = 384 * 1_024
}

public enum DeviceRole: String, Codable, Sendable {
    case host
    case joiner
}

enum ProtocolSupportError: Error, Equatable {
    case invalidRandomLength
    case randomGenerationFailed(Int32)
    case invalidBase64URL
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
