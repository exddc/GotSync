import CryptoKit
import Foundation
import Security

public enum MLSStoreError: Error, Equatable {
    case unreadable
}

public protocol MLSStateKeyProvider: Sendable {
    func key() throws -> SymmetricKey
}

public struct InMemoryStateKeyProvider: MLSStateKeyProvider {
    private let value: SymmetricKey

    public init(key: SymmetricKey = SymmetricKey(size: .bits256)) {
        value = key
    }

    public func key() throws -> SymmetricKey { value }
}

public struct KeychainStateKeyProvider: MLSStateKeyProvider {
    private let service: String
    private let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    public func key() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
        ]
        func read() throws -> SymmetricKey? {
            var lookup = query
            lookup[kSecReturnData as String] = true
            lookup[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(lookup as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw MLSClientError.storageUnavailable }
            guard let bytes = result as? Data, bytes.count == 32 else { throw MLSStoreError.unreadable }
            return SymmetricKey(data: bytes)
        }
        if let existing = try read() { return existing }
        let generated = SymmetricKey(size: .bits256)
        var item = query
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecValueData as String] = generated.withUnsafeBytes { Data($0) }
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem, let existing = try read() { return existing }
        guard status == errSecSuccess else { throw MLSClientError.storageUnavailable }
        return generated
    }
}
