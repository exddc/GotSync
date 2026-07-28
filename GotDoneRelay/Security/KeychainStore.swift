import Foundation
import Security

enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
}

struct KeychainStore: Sendable {
    let service: String

    init(service: String = "com.gotdone.relay.poc") {
        self.service = service
    }

    func read(account: String) throws -> Data? {
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

    func write(_ data: Data, account: String) throws {
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

    func delete(account: String) throws {
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

    static func loadOrCreate(store: KeychainStore) throws -> InstallIdentity {
        if let existing = try store.read(account: account), existing.count == 16 {
            return InstallIdentity(deviceID: existing)
        }

        let generated = try Data.secureRandom(count: 16)
        try store.write(generated, account: account)
        return InstallIdentity(deviceID: generated)
    }
}

struct PairCredentials: Codable, Equatable, Sendable {
    let version: UInt8
    let pairRoot: Data
    let pairID: Data
    let role: DeviceRole
    let localDeviceID: Data
    let remoteDeviceID: Data

    init(
        pairRoot: Data,
        pairID: Data,
        role: DeviceRole,
        localDeviceID: Data,
        remoteDeviceID: Data
    ) {
        version = SyncProtocol.version
        self.pairRoot = pairRoot
        self.pairID = pairID
        self.role = role
        self.localDeviceID = localDeviceID
        self.remoteDeviceID = remoteDeviceID
    }
}

struct PendingPair: Codable, Equatable, Sendable {
    let version: UInt8
    let pairRoot: Data
    let pairID: Data
    let role: DeviceRole
    let localDeviceID: Data
    var remoteDeviceID: Data?
    let archiveHash: Data
    let expiresAt: Date
}

struct MailboxCheckpoint: Codable, Equatable, Sendable {
    let version: UInt8
    let pairID: Data
    let uploadedLocalSequence: UInt64

    init(pairID: Data, uploadedLocalSequence: UInt64) {
        version = SyncProtocol.version
        self.pairID = pairID
        self.uploadedLocalSequence = uploadedLocalSequence
    }
}

struct CredentialStore: Sendable {
    private let keychain: KeychainStore
    private let activeAccount = "active-pair-v1"
    private let pendingAccount = "pending-pair-v1"
    private let mailboxCheckpointAccount = "mailbox-checkpoint-v1"

    init(keychain: KeychainStore) {
        self.keychain = keychain
    }

    func active() throws -> PairCredentials? {
        guard let data = try keychain.read(account: activeAccount) else {
            return nil
        }
        return try CanonicalJSON.decoder.decode(PairCredentials.self, from: data)
    }

    func pending() throws -> PendingPair? {
        guard let data = try keychain.read(account: pendingAccount) else {
            return nil
        }
        return try CanonicalJSON.decoder.decode(PendingPair.self, from: data)
    }

    func saveActive(_ credentials: PairCredentials) throws {
        let data = try CanonicalJSON.encoder.encode(credentials)
        try keychain.write(data, account: activeAccount)
    }

    func savePending(_ pending: PendingPair) throws {
        let data = try CanonicalJSON.encoder.encode(pending)
        try keychain.write(data, account: pendingAccount)
    }

    func clearPending() throws {
        try keychain.delete(account: pendingAccount)
    }

    func mailboxCheckpoint() throws -> MailboxCheckpoint? {
        guard let data = try keychain.read(account: mailboxCheckpointAccount) else {
            return nil
        }
        return try CanonicalJSON.decoder.decode(MailboxCheckpoint.self, from: data)
    }

    func saveMailboxCheckpoint(_ checkpoint: MailboxCheckpoint) throws {
        let data = try CanonicalJSON.encoder.encode(checkpoint)
        try keychain.write(data, account: mailboxCheckpointAccount)
    }

    func clearMailboxCheckpoint() throws {
        try keychain.delete(account: mailboxCheckpointAccount)
    }

    func clearPair() throws {
        try keychain.delete(account: activeAccount)
        try keychain.delete(account: pendingAccount)
        try keychain.delete(account: mailboxCheckpointAccount)
    }
}
