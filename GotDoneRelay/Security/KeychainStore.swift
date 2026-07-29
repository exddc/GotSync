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
    let pairingArchiveHash: Data?

    init(
        pairRoot: Data,
        pairID: Data,
        role: DeviceRole,
        localDeviceID: Data,
        remoteDeviceID: Data,
        pairingArchiveHash: Data? = nil
    ) {
        version = SyncProtocol.version
        self.pairRoot = pairRoot
        self.pairID = pairID
        self.role = role
        self.localDeviceID = localDeviceID
        self.remoteDeviceID = remoteDeviceID
        self.pairingArchiveHash = pairingArchiveHash
    }
}

enum PairingFinalizationState: String, Codable, Equatable, Sendable {
    case waitingForProvision
    case provisionStagedAwaitingMergeApproval
    case provisionMayHaveBeenStored
    case readyMayHaveBeenStored
    case commitMarkerMayHaveBeenStored
    case abortMayHaveBeenStored
    case abortAcknowledgementMayHaveBeenStored

    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct PendingPair: Codable, Equatable, Sendable {
    let version: UInt8
    let pairRoot: Data
    let pairID: Data
    let role: DeviceRole
    let localDeviceID: Data
    let pairingVersion: UInt8?
    var remoteDeviceID: Data?
    var archiveHash: Data
    let expiresAt: Date
    var finalizationState: PairingFinalizationState?
    let pairingArtifactID: Data?
    var abortAcknowledgementCursor: UInt64?

    init(
        version: UInt8,
        pairRoot: Data,
        pairID: Data,
        role: DeviceRole,
        localDeviceID: Data,
        pairingVersion: UInt8? = SyncProtocol.pairingVersion,
        remoteDeviceID: Data?,
        archiveHash: Data,
        expiresAt: Date,
        finalizationState: PairingFinalizationState? = nil,
        pairingArtifactID: Data? = nil,
        abortAcknowledgementCursor: UInt64? = nil
    ) {
        self.version = version
        self.pairRoot = pairRoot
        self.pairID = pairID
        self.role = role
        self.localDeviceID = localDeviceID
        self.pairingVersion = pairingVersion
        self.remoteDeviceID = remoteDeviceID
        self.archiveHash = archiveHash
        self.expiresAt = expiresAt
        self.finalizationState = finalizationState
        self.pairingArtifactID = pairingArtifactID
        self.abortAcknowledgementCursor = abortAcknowledgementCursor
    }
}

enum TerminalPairingActionKind:
    String,
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    case abort
    case receipt
}

struct TerminalPairingActionKey: Hashable, Sendable {
    let pairID: Data
    let kind: TerminalPairingActionKind
}

enum TerminalPairingJournalError: Error, Equatable {
    case invalidAction
    case conflictingAction
    case duplicateAction
    case actionLimitExceeded(Int)
    case unsupportedVersion(UInt8)
    case missingInstallIdentity
    case localIdentityMismatch
    case pendingActionMismatch
}

extension TerminalPairingJournalError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidAction:
            "The saved terminal pairing action is invalid."
        case .conflictingAction:
            "The terminal pairing action conflicts with an existing action."
        case .duplicateAction:
            "The terminal pairing journal contains duplicate actions."
        case .actionLimitExceeded(let limit):
            "The terminal pairing journal is limited to \(limit) actions."
        case .unsupportedVersion(let version):
            "Terminal pairing journal version \(version) is unsupported."
        case .missingInstallIdentity:
            "The install identity required by the pairing journal is missing."
        case .localIdentityMismatch:
            "The terminal pairing action belongs to another install identity."
        case .pendingActionMismatch:
            "The terminal pairing action does not match the pending pair."
        }
    }
}

struct TerminalPairingAction: Codable, Equatable, Sendable {
    static let maximumCiphertextBytes = 4 * 1_024
    private static let routeLabel = Data(
        "com.gotdone.sync/pairing-control-route/v2".utf8
    )

    let version: UInt8
    let pairingVersion: UInt8
    let pairID: Data
    let kind: TerminalPairingActionKind
    let role: DeviceRole
    let localDeviceID: Data
    let remoteDeviceID: Data?
    let route: Data
    let authorization: Data
    let messageID: Data
    let ciphertext: Data

    var key: TerminalPairingActionKey {
        TerminalPairingActionKey(pairID: pairID, kind: kind)
    }

    var envelope: StoredMailboxEnvelope {
        get throws {
            try StoredMailboxEnvelope(
                messageID: messageID,
                ciphertext: ciphertext
            )
        }
    }

    init(
        kind: TerminalPairingActionKind,
        proof: PendingPair,
        route: Data,
        authorization: Data,
        envelope: StoredMailboxEnvelope
    ) throws {
        version = proof.version
        pairingVersion = proof.pairingVersion ?? 0
        pairID = proof.pairID
        self.kind = kind
        role = proof.role
        localDeviceID = proof.localDeviceID
        remoteDeviceID = proof.remoteDeviceID
        self.route = route
        self.authorization = authorization
        messageID = envelope.messageID
        ciphertext = envelope.ciphertext
        try validate(proof: proof)
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case pairingVersion
        case pairID
        case kind
        case role
        case localDeviceID
        case remoteDeviceID
        case route
        case authorization
        case messageID
        case ciphertext
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(
            UInt8.self,
            forKey: .version
        ) ?? SyncProtocol.version
        pairingVersion = try container.decodeIfPresent(
            UInt8.self,
            forKey: .pairingVersion
        ) ?? SyncProtocol.pairingVersion
        pairID = try container.decode(Data.self, forKey: .pairID)
        kind = try container.decode(
            TerminalPairingActionKind.self,
            forKey: .kind
        )
        role = try container.decode(DeviceRole.self, forKey: .role)
        localDeviceID = try container.decode(
            Data.self,
            forKey: .localDeviceID
        )
        remoteDeviceID = try container.decodeIfPresent(
            Data.self,
            forKey: .remoteDeviceID
        )
        route = try container.decode(Data.self, forKey: .route)
        authorization = try container.decode(
            Data.self,
            forKey: .authorization
        )
        messageID = try container.decode(Data.self, forKey: .messageID)
        ciphertext = try container.decode(Data.self, forKey: .ciphertext)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(pairingVersion, forKey: .pairingVersion)
        try container.encode(pairID, forKey: .pairID)
        try container.encode(kind, forKey: .kind)
        try container.encode(role, forKey: .role)
        try container.encode(localDeviceID, forKey: .localDeviceID)
        try container.encodeIfPresent(
            remoteDeviceID,
            forKey: .remoteDeviceID
        )
        try container.encode(route, forKey: .route)
        try container.encode(authorization, forKey: .authorization)
        try container.encode(messageID, forKey: .messageID)
        try container.encode(ciphertext, forKey: .ciphertext)
    }

    func validate() throws {
        guard
            version == SyncProtocol.version,
            pairingVersion == SyncProtocol.pairingVersion,
            pairID.count == 16,
            localDeviceID.count == 16,
            authorization.count == 32,
            route == (Self.routeLabel + authorization).sha256,
            messageID.count == 32,
            16...Self.maximumCiphertextBytes ~= ciphertext.count
        else {
            throw TerminalPairingJournalError.invalidAction
        }
        switch kind {
        case .abort:
            guard remoteDeviceID == nil else {
                throw TerminalPairingJournalError.invalidAction
            }
        case .receipt:
            guard
                role == .joiner,
                let remoteDeviceID,
                remoteDeviceID.count == 16,
                remoteDeviceID != localDeviceID
            else {
                throw TerminalPairingJournalError.invalidAction
            }
        }
        _ = try envelope
    }

    private func validate(proof: PendingPair) throws {
        try validate()
        guard
            proof.version == SyncProtocol.version,
            proof.pairingVersion == SyncProtocol.pairingVersion,
            proof.pairRoot.count == 32,
            proof.pairID == pairID,
            proof.localDeviceID == localDeviceID
        else {
            throw TerminalPairingJournalError.invalidAction
        }
        switch kind {
        case .abort:
            let isJoinerCancellation =
                proof.role == .joiner
                    && proof.finalizationState == .waitingForProvision
                    && proof.remoteDeviceID == nil
                    && proof.archiveHash.isEmpty
            let isHostCancellation =
                proof.role == .host
                    && proof.finalizationState == .provisionMayHaveBeenStored
                    && proof.remoteDeviceID == nil
                    && proof.archiveHash.count == 32
            let isNormalizedAbort =
                proof.finalizationState == .abortMayHaveBeenStored
                    && proof.remoteDeviceID == nil
                    && proof.archiveHash.isEmpty
            guard
                isJoinerCancellation
                    || isHostCancellation
                    || isNormalizedAbort
            else {
                throw TerminalPairingJournalError.invalidAction
            }
        case .receipt:
            guard
                proof.role == .joiner,
                proof.finalizationState == .readyMayHaveBeenStored,
                proof.remoteDeviceID?.count == 16,
                proof.archiveHash.count == 32
            else {
                throw TerminalPairingJournalError.invalidAction
            }
        }
    }
}

struct TerminalPairingActionJournal: Codable, Equatable, Sendable {
    static let formatVersion: UInt8 = 1
    static let maximumActionCount = 32

    let version: UInt8
    private(set) var actions: [TerminalPairingAction]

    init(actions: [TerminalPairingAction] = []) throws {
        version = Self.formatVersion
        self.actions = actions
        try validate()
        sortActions()
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case actions
        case records
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(
            UInt8.self,
            forKey: .version
        ) ?? Self.formatVersion
        let hasActions = container.contains(.actions)
        let hasRecords = container.contains(.records)
        guard hasActions != hasRecords else {
            throw TerminalPairingJournalError.invalidAction
        }
        actions = hasActions
            ? try container.decode(
                [TerminalPairingAction].self,
                forKey: .actions
            )
            : try container.decode(
                [TerminalPairingAction].self,
                forKey: .records
            )
        try validate()
        sortActions()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(actions, forKey: .actions)
    }

    mutating func upsert(_ action: TerminalPairingAction) throws {
        try action.validate()
        if let index = actions.firstIndex(where: { $0.key == action.key }) {
            guard actions[index] == action else {
                throw TerminalPairingJournalError.conflictingAction
            }
            return
        }
        guard actions.count < Self.maximumActionCount else {
            throw TerminalPairingJournalError.actionLimitExceeded(
                Self.maximumActionCount
            )
        }
        actions.append(action)
        sortActions()
    }

    mutating func remove(_ key: TerminalPairingActionKey) {
        actions.removeAll { $0.key == key }
    }

    private func validate() throws {
        guard version == Self.formatVersion else {
            throw TerminalPairingJournalError.unsupportedVersion(version)
        }
        guard actions.count <= Self.maximumActionCount else {
            throw TerminalPairingJournalError.actionLimitExceeded(
                Self.maximumActionCount
            )
        }
        var keys: Set<TerminalPairingActionKey> = []
        for action in actions {
            try action.validate()
            guard keys.insert(action.key).inserted else {
                throw TerminalPairingJournalError.duplicateAction
            }
        }
    }

    private mutating func sortActions() {
        actions.sort {
            if $0.pairID != $1.pairID {
                return $0.pairID.lexicographicallyPrecedes($1.pairID)
            }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }
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
    static let terminalPairingActionsAccount =
        "terminal-pairing-actions-v1"
    static let damagedTerminalPairingActionsAccount =
        "terminal-pairing-actions-damaged-v1"

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

    func terminalPairingActions() throws -> [TerminalPairingAction] {
        try loadTerminalPairingJournal().actions
    }

    func upsertTerminalPairingAction(
        _ action: TerminalPairingAction
    ) throws {
        try validateLocalIdentity(action)
        var journal = try loadTerminalPairingJournal()
        try journal.upsert(action)
        try saveTerminalPairingJournal(journal)
    }

    func upsertTerminalPairingActionThenClearPending(
        _ action: TerminalPairingAction
    ) throws {
        guard
            let pending = try pending(),
            pending.pairID == action.pairID,
            pending.role == action.role,
            pending.localDeviceID == action.localDeviceID,
            pending.remoteDeviceID == action.remoteDeviceID
        else {
            throw TerminalPairingJournalError.pendingActionMismatch
        }
        try upsertTerminalPairingAction(action)
        try clearPending()
    }

    func removeTerminalPairingAction(
        _ key: TerminalPairingActionKey
    ) throws {
        var journal = try loadTerminalPairingJournal()
        journal.remove(key)
        if journal.actions.isEmpty {
            try keychain.delete(
                account: Self.terminalPairingActionsAccount
            )
        } else {
            try saveTerminalPairingJournal(journal)
        }
    }

    func clearTerminalPairingActions() throws {
        try keychain.delete(account: Self.terminalPairingActionsAccount)
    }

    func replaceDamagedTerminalPairingActions(
        with action: TerminalPairingAction
    ) throws {
        try validateLocalIdentity(action)
        guard let data = try keychain.read(
            account: Self.terminalPairingActionsAccount
        ) else {
            throw TerminalPairingJournalError.invalidAction
        }
        if let existing = try keychain.read(
            account: Self.damagedTerminalPairingActionsAccount
        ), existing != data {
            throw TerminalPairingJournalError.conflictingAction
        }
        try keychain.write(
            data,
            account: Self.damagedTerminalPairingActionsAccount
        )
        try saveTerminalPairingJournal(
            TerminalPairingActionJournal(actions: [action])
        )
    }

    func clearCurrentPair() throws {
        try keychain.delete(account: mailboxCheckpointAccount)
        try keychain.delete(account: pendingAccount)
        try keychain.delete(account: activeAccount)
    }

    func clearAllPairingData() throws {
        try clearCurrentPair()
        try clearTerminalPairingActions()
        try keychain.delete(
            account: Self.damagedTerminalPairingActionsAccount
        )
    }

    func clearPair() throws {
        try clearAllPairingData()
    }

    private func loadTerminalPairingJournal()
        throws -> TerminalPairingActionJournal
    {
        guard let data = try keychain.read(
            account: Self.terminalPairingActionsAccount
        ) else {
            return try TerminalPairingActionJournal()
        }
        let journal = try CanonicalJSON.decoder.decode(
            TerminalPairingActionJournal.self,
            from: data
        )
        for action in journal.actions {
            try validateLocalIdentity(action)
        }
        return journal
    }

    private func saveTerminalPairingJournal(
        _ journal: TerminalPairingActionJournal
    ) throws {
        let data = try CanonicalJSON.encoder.encode(journal)
        try keychain.write(
            data,
            account: Self.terminalPairingActionsAccount
        )
    }

    private func validateLocalIdentity(
        _ action: TerminalPairingAction
    ) throws {
        guard
            let localDeviceID = try keychain.read(
                account: InstallIdentity.account
            ),
            localDeviceID.count == 16
        else {
            throw TerminalPairingJournalError.missingInstallIdentity
        }
        guard action.localDeviceID == localDeviceID else {
            throw TerminalPairingJournalError.localIdentityMismatch
        }
    }
}
