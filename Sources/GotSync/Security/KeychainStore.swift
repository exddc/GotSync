import Foundation
import Security

public protocol SecretStore: Sendable {
    func read(account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
    func delete(account: String) throws
}

public enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
}

public struct KeychainStore: SecretStore {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    public func read(account: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain: true,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        return item as? Data
    }

    public func write(_ data: Data, account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable: false,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var insert = query
        attributes.forEach { insert[$0.key] = $0.value }
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(insertStatus)
        }
    }

    public func delete(account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

struct InstallIdentity: Equatable, Sendable {
    static let account = "install-device-id-v1"

    let deviceID: Data

    static func loadOrCreate(store: any SecretStore) throws -> InstallIdentity {
        if let existing = try store.read(account: account), existing.count == 16 {
            return InstallIdentity(deviceID: existing)
        }

        let generated = try Data.secureRandom(count: 16)
        try store.write(generated, account: account)
        return InstallIdentity(deviceID: generated)
    }
}

public enum PairingFinalizationState: String, Codable, Equatable, Sendable {
    case waitingForProvision
    case provisionStagedAwaitingMergeApproval
    case provisionMayHaveBeenStored
    case readyMayHaveBeenStored
    case commitMarkerMayHaveBeenStored
    case abortMayHaveBeenStored
    case abortAcknowledgementMayHaveBeenStored

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        if value == "readyMayHaveBeenSent" {
            self = .readyMayHaveBeenStored
            return
        }
        guard let state = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unknown pairing finalization state"
            )
        }
        self = state
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
