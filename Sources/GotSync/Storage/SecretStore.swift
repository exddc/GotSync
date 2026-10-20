import Foundation
import Security

public enum SecretAccessibility: Sendable {
    case whenUnlockedThisDeviceOnly
    case afterFirstUnlockThisDeviceOnly
}

public protocol SecretStore: Sendable {
    func read(account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
    func write(_ data: Data, account: String, accessibility: SecretAccessibility) throws
    func delete(account: String) throws
}

extension SecretStore {
    public func write(_ data: Data, account: String, accessibility: SecretAccessibility) throws {
        try write(data, account: account)
    }
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
        try write(data, account: account, accessibility: .whenUnlockedThisDeviceOnly)
    }

    public func write(_ data: Data, account: String, accessibility: SecretAccessibility) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: accessibility == .afterFirstUnlockThisDeviceOnly
                ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                : kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
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

/// Keychain accounts written by the version 1 protocol. They are only read
/// to detect and erase a pre-MLS link.
enum LegacyLinkCredentials {
    static let accounts = [
        "active-pair-v1",
        "active-group-v1",
        "pending-pair-v1",
        "mailbox-checkpoint-v1",
        "terminal-pairing-actions-v1",
        "terminal-pairing-actions-damaged-v1",
    ]

    static func exist(in store: any SecretStore) throws -> Bool {
        try accounts.contains { try store.read(account: $0) != nil }
    }

    static func erase(from store: any SecretStore) throws {
        for account in accounts {
            try store.delete(account: account)
        }
    }
}
