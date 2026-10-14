import CryptoKit
import Foundation

enum MailboxCryptoError: Error, Equatable {
    case invalidCredentials
    case invalidEnvelope
    case invalidMessageID
    case envelopeTooLarge
    case messageIDMismatch
    case incompleteEnvelopeSet
}

public struct StoredMailboxEnvelope: Equatable, Sendable {
    public let messageID: Data
    public let ciphertext: Data

    public init(messageID: Data, ciphertext: Data) throws {
        guard messageID.count == 32 else {
            throw MailboxCryptoError.invalidMessageID
        }
        guard
            ciphertext.count >= 16,
            ciphertext.count <= ProtocolLimits.mailboxEnvelopeBytes
        else {
            throw MailboxCryptoError.envelopeTooLarge
        }
        self.messageID = messageID
        self.ciphertext = ciphertext
    }
}

private protocol PairingControlRecord: Codable, Equatable {
    var version: UInt8 { get }
    var pairID: Data { get }

    func validate() throws
}

private extension PairingControlRecord {
    func canonicalData() throws -> Data {
        try validate()
        return try CanonicalJSON.encoder.encode(self)
    }

    static func decodeCanonical(from data: Data) throws -> Self {
        let record: Self
        do {
            record = try CanonicalJSON.decoder.decode(Self.self, from: data)
        } catch {
            throw MailboxCryptoError.invalidEnvelope
        }
        try record.validate()
        guard try record.canonicalData() == data else {
            throw MailboxCryptoError.invalidEnvelope
        }
        return record
    }
}

private enum PairingControlStage: String, Sendable {
    case provision
    case ready
    case commit
    case abort

    var data: Data {
        Data(rawValue.utf8)
    }
}

private enum PairingControlRoute {
    static let label = Data(
        "\(ProtocolDomains.namespace)/pairing-control-route/v2".utf8
    )
}

private struct PairingControlCipher: Sendable {
    private static let aadLabel = Data(
        "\(ProtocolDomains.namespace)/pairing-control-aad/v2".utf8
    )

    let route: Data
    let authorization: Data
    private let pairID: Data
    private let senderRole: DeviceRole
    private let stage: PairingControlStage
    private let encryptionRoot: Data
    private let messageIDKey: SymmetricKey

    init(
        pairRoot: Data,
        pairID: Data,
        stage: PairingControlStage,
        senderRole: DeviceRole
    ) throws {
        guard pairRoot.count == 32, pairID.count == 16 else {
            throw MailboxCryptoError.invalidCredentials
        }
        let direction = Self.directionLabel(senderRole)
        let domain = "\(stage.rawValue)/\(direction)/v2"
        let authorization = SyncKeyDerivation.derive(
            input: pairRoot,
            label: "\(ProtocolDomains.namespace)/pairing-control-auth/\(domain)",
            context: pairID,
            count: 32
        )
        self.pairID = pairID
        self.senderRole = senderRole
        self.stage = stage
        self.authorization = authorization
        route = (PairingControlRoute.label + authorization).sha256
        encryptionRoot = SyncKeyDerivation.derive(
            input: pairRoot,
            label: "\(ProtocolDomains.namespace)/pairing-control-encryption/\(domain)",
            context: pairID,
            count: 32
        )
        messageIDKey = SymmetricKey(
            data: SyncKeyDerivation.derive(
                input: pairRoot,
                label: "\(ProtocolDomains.namespace)/pairing-control-message-id/\(domain)",
                context: pairID,
                count: 32
            )
        )
    }

    func seal(_ plaintext: Data) throws -> StoredMailboxEnvelope {
        guard plaintext.count <= ProtocolLimits.mailboxEnvelopeBytes - 16 else {
            throw MailboxCryptoError.envelopeTooLarge
        }
        let messageID = messageID(for: plaintext)
        let sealed = try ChaChaPoly.seal(
            plaintext,
            using: messageKey(for: messageID),
            nonce: try Self.zeroNonce(),
            authenticating: try associatedData(messageID: messageID)
        )
        return try StoredMailboxEnvelope(
            messageID: messageID,
            ciphertext: sealed.ciphertext + sealed.tag
        )
    }

    func open(_ envelope: StoredMailboxEnvelope) throws -> Data {
        guard envelope.ciphertext.count >= 16 else {
            throw MailboxCryptoError.invalidEnvelope
        }
        let tagStart = envelope.ciphertext.count - 16
        let sealed = try ChaChaPoly.SealedBox(
            nonce: try Self.zeroNonce(),
            ciphertext: Data(envelope.ciphertext.prefix(tagStart)),
            tag: Data(envelope.ciphertext.suffix(16))
        )
        let plaintext = try ChaChaPoly.open(
            sealed,
            using: messageKey(for: envelope.messageID),
            authenticating: try associatedData(messageID: envelope.messageID)
        )
        guard Self.constantTimeEqual(
            messageID(for: plaintext),
            envelope.messageID
        ) else {
            throw MailboxCryptoError.messageIDMismatch
        }
        return plaintext
    }

    private func messageID(for plaintext: Data) -> Data {
        Data(
            HMAC<SHA256>.authenticationCode(
                for: plaintext,
                using: messageIDKey
            )
        )
    }

    private func messageKey(for messageID: Data) -> SymmetricKey {
        let direction = Self.directionLabel(senderRole)
        return SymmetricKey(
            data: SyncKeyDerivation.derive(
                input: encryptionRoot,
                label:
                    "\(ProtocolDomains.namespace)/pairing-control-message-key/"
                    + "\(stage.rawValue)/\(direction)/v2",
                context: pairID + messageID,
                count: 32
            )
        )
    }

    private func associatedData(messageID: Data) throws -> Data {
        guard messageID.count == 32, route.count == 32 else {
            throw MailboxCryptoError.invalidEnvelope
        }
        var builder = TranscriptBuilder()
        try builder.append(tag: 1, value: Self.aadLabel)
        try builder.append(tag: 2, value: SyncProtocol.appID)
        try builder.append(
            tag: 3,
            value: Data([SyncProtocol.pairingVersion])
        )
        try builder.append(tag: 4, value: stage.data)
        try builder.append(tag: 5, value: Data([senderRole.wireByte]))
        try builder.append(tag: 6, value: pairID)
        try builder.append(tag: 7, value: route)
        try builder.append(tag: 8, value: messageID)
        return builder.data
    }

    private static func directionLabel(_ role: DeviceRole) -> String {
        role == .host ? "A-to-B" : "B-to-A"
    }

    private static func zeroNonce() throws -> ChaChaPoly.Nonce {
        try ChaChaPoly.Nonce(data: Data(repeating: 0, count: 12))
    }

    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }
}

struct PairingProvisionPayload: Equatable, Sendable {
    let archive: Data
    let archiveHash: Data
    let hostDeviceID: Data
    /// Present when the issuer is admitting a joiner into an existing group.
    let groupID: Data?
    let epoch: UInt64?
    let groupRoot: Data?
    let membershipGeneration: UInt64?
    /// Full post-join active roster (device IDs), including the joiner.
    let memberDeviceIDs: [Data]?

    init(
        archive: Data,
        archiveHash: Data,
        hostDeviceID: Data,
        groupID: Data? = nil,
        epoch: UInt64? = nil,
        groupRoot: Data? = nil,
        membershipGeneration: UInt64? = nil,
        memberDeviceIDs: [Data]? = nil
    ) {
        self.archive = archive
        self.archiveHash = archiveHash
        self.hostDeviceID = hostDeviceID
        self.groupID = groupID
        self.epoch = epoch
        self.groupRoot = groupRoot
        self.membershipGeneration = membershipGeneration
        self.memberDeviceIDs = memberDeviceIDs
    }

    var isGroupJoin: Bool {
        groupRoot != nil && groupID != nil && memberDeviceIDs != nil
    }
}

private struct PairingProvisionChunkRecord:
    PairingControlRecord,
    Sendable
{
    let version: UInt8
    let pairID: Data
    let hostDeviceID: Data
    let archiveHash: Data
    let archiveBytes: Int
    let chunkIndex: Int
    let chunkCount: Int
    let chunk: Data
    let groupID: Data?
    let epoch: UInt64?
    let groupRoot: Data?
    let membershipGeneration: UInt64?
    let memberDeviceIDs: [Data]?

    func validate() throws {
        guard
            version == SyncProtocol.pairingVersion,
            pairID.count == 16,
            hostDeviceID.count == 16,
            archiveHash.count == 32,
            0...ProtocolLimits.provisioningArchiveBytes ~= archiveBytes,
            1...PairingProvisionMailbox.maximumChunkCount ~= chunkCount,
            0..<chunkCount ~= chunkIndex,
            chunk.count <= PairingProvisionMailbox.chunkBytes
        else {
            throw MailboxCryptoError.invalidEnvelope
        }
        let groupFields = [
            groupID != nil,
            epoch != nil,
            groupRoot != nil,
            membershipGeneration != nil,
            memberDeviceIDs != nil,
        ]
        let groupPresent = groupFields.contains(true)
        if groupPresent {
            guard
                groupFields.allSatisfy({ $0 }),
                let groupID,
                groupID.count == 16,
                let groupRoot,
                groupRoot.count == 32,
                let epoch,
                epoch >= 1,
                let membershipGeneration,
                membershipGeneration >= 1,
                let memberDeviceIDs,
                memberDeviceIDs.count >= 2,
                memberDeviceIDs.count <= ReplicaLimits.maxOrigins,
                memberDeviceIDs.allSatisfy({ $0.count == 16 }),
                Set(memberDeviceIDs).count == memberDeviceIDs.count,
                memberDeviceIDs.contains(hostDeviceID)
            else {
                throw MailboxCryptoError.invalidEnvelope
            }
        }
    }
}

struct PairingProvisionMailbox: Sendable {
    static let routeLabel = PairingControlRoute.label
    fileprivate static let chunkBytes =
        ProtocolLimits.mailboxEnvelopeBytes * 3 / 4 - 2_048
    fileprivate static let maximumChunkCount =
        max(
            1,
            (
                ProtocolLimits.provisioningArchiveBytes
                    + chunkBytes - 1
            ) / chunkBytes
        )

    let senderRole: DeviceRole
    let route: Data
    let authorization: Data
    private let pairID: Data
    private let cipher: PairingControlCipher

    init(
        pairRoot: Data,
        pairID: Data,
        senderRole: DeviceRole = .host
    ) throws {
        guard senderRole == .host else {
            throw MailboxCryptoError.invalidCredentials
        }
        let cipher = try PairingControlCipher(
            pairRoot: pairRoot,
            pairID: pairID,
            stage: .provision,
            senderRole: senderRole
        )
        self.pairID = pairID
        self.senderRole = senderRole
        self.cipher = cipher
        route = cipher.route
        authorization = cipher.authorization
    }

    func seal(
        archive: Data,
        hostDeviceID: Data,
        groupID: Data? = nil,
        epoch: UInt64? = nil,
        groupRoot: Data? = nil,
        membershipGeneration: UInt64? = nil,
        memberDeviceIDs: [Data]? = nil
    ) throws -> [StoredMailboxEnvelope] {
        guard
            archive.count <= ProtocolLimits.provisioningArchiveBytes,
            hostDeviceID.count == 16
        else {
            throw MailboxCryptoError.invalidEnvelope
        }
        let archiveHash = archive.sha256
        let chunkCount = Self.chunkCount(forArchiveBytes: archive.count)
        return try (0..<chunkCount).map { chunkIndex in
            let start = chunkIndex * Self.chunkBytes
            let end = min(start + Self.chunkBytes, archive.count)
            let chunk = archive.subdata(in: start..<end)
            let record = PairingProvisionChunkRecord(
                version: SyncProtocol.pairingVersion,
                pairID: pairID,
                hostDeviceID: hostDeviceID,
                archiveHash: archiveHash,
                archiveBytes: archive.count,
                chunkIndex: chunkIndex,
                chunkCount: chunkCount,
                chunk: chunk,
                groupID: groupID,
                epoch: epoch,
                groupRoot: groupRoot,
                membershipGeneration: membershipGeneration,
                memberDeviceIDs: memberDeviceIDs
            )
            return try cipher.seal(record.canonicalData())
        }
    }

    func open(
        _ envelopes: [StoredMailboxEnvelope]
    ) throws -> PairingProvisionPayload {
        guard !envelopes.isEmpty else {
            throw MailboxCryptoError.invalidEnvelope
        }
        var records: [Int: PairingProvisionChunkRecord] = [:]
        var expected: PairingProvisionChunkRecord?
        for envelope in envelopes {
            let plaintext = try cipher.open(envelope)
            let record = try PairingProvisionChunkRecord.decodeCanonical(
                from: plaintext
            )
            guard record.pairID == pairID else {
                throw MailboxCryptoError.invalidEnvelope
            }
            if let expected {
                guard
                    record.hostDeviceID == expected.hostDeviceID,
                    record.archiveHash == expected.archiveHash,
                    record.archiveBytes == expected.archiveBytes,
                    record.chunkCount == expected.chunkCount,
                    record.groupID == expected.groupID,
                    record.epoch == expected.epoch,
                    record.groupRoot == expected.groupRoot,
                    record.membershipGeneration
                        == expected.membershipGeneration,
                    record.memberDeviceIDs == expected.memberDeviceIDs
                else {
                    throw MailboxCryptoError.invalidEnvelope
                }
            } else {
                expected = record
            }
            if let existing = records[record.chunkIndex] {
                guard existing == record else {
                    throw MailboxCryptoError.invalidEnvelope
                }
            } else {
                records[record.chunkIndex] = record
            }
        }
        guard
            let expected,
            expected.chunkCount
                == Self.chunkCount(forArchiveBytes: expected.archiveBytes)
        else {
            throw MailboxCryptoError.invalidEnvelope
        }
        guard records.count == expected.chunkCount else {
            throw MailboxCryptoError.incompleteEnvelopeSet
        }
        var archive = Data()
        archive.reserveCapacity(expected.archiveBytes)
        for chunkIndex in 0..<expected.chunkCount {
            guard let record = records[chunkIndex] else {
                throw MailboxCryptoError.invalidEnvelope
            }
            let expectedBytes = Self.expectedChunkBytes(
                archiveBytes: expected.archiveBytes,
                chunkIndex: chunkIndex
            )
            guard record.chunk.count == expectedBytes else {
                throw MailboxCryptoError.invalidEnvelope
            }
            archive.append(record.chunk)
        }
        guard
            archive.count == expected.archiveBytes,
            PairingControlCipher.constantTimeEqual(
                archive.sha256,
                expected.archiveHash
            )
        else {
            throw MailboxCryptoError.invalidEnvelope
        }
        return PairingProvisionPayload(
            archive: archive,
            archiveHash: expected.archiveHash,
            hostDeviceID: expected.hostDeviceID,
            groupID: expected.groupID,
            epoch: expected.epoch,
            groupRoot: expected.groupRoot,
            membershipGeneration: expected.membershipGeneration,
            memberDeviceIDs: expected.memberDeviceIDs
        )
    }

    private static func chunkCount(forArchiveBytes bytes: Int) -> Int {
        max(1, (bytes + chunkBytes - 1) / chunkBytes)
    }

    private static func expectedChunkBytes(
        archiveBytes: Int,
        chunkIndex: Int
    ) -> Int {
        if archiveBytes == 0 {
            return 0
        }
        return min(chunkBytes, archiveBytes - chunkIndex * chunkBytes)
    }
}

struct PairingReadyRecord: PairingControlRecord, Sendable {
    let version: UInt8
    let pairID: Data
    let hostDeviceID: Data
    let joinerDeviceID: Data
    let archiveHash: Data

    init(
        version: UInt8 = SyncProtocol.pairingVersion,
        pairID: Data,
        hostDeviceID: Data,
        joinerDeviceID: Data,
        archiveHash: Data
    ) throws {
        self.version = version
        self.pairID = pairID
        self.hostDeviceID = hostDeviceID
        self.joinerDeviceID = joinerDeviceID
        self.archiveHash = archiveHash
        try validate()
    }

    fileprivate func validate() throws {
        guard
            version == SyncProtocol.pairingVersion,
            pairID.count == 16,
            hostDeviceID.count == 16,
            joinerDeviceID.count == 16,
            hostDeviceID != joinerDeviceID,
            archiveHash.count == 32
        else {
            throw MailboxCryptoError.invalidEnvelope
        }
    }
}

struct PairingReadyMailbox: Sendable {
    static let routeLabel = PairingControlRoute.label

    let senderRole = DeviceRole.joiner
    let route: Data
    let authorization: Data
    private let pairID: Data
    private let hostDeviceID: Data
    private let archiveHash: Data
    private let cipher: PairingControlCipher

    init(
        pairRoot: Data,
        pairID: Data,
        hostDeviceID: Data,
        archiveHash: Data
    ) throws {
        guard
            pairID.count == 16,
            hostDeviceID.count == 16,
            archiveHash.count == 32
        else {
            throw MailboxCryptoError.invalidCredentials
        }
        let cipher = try PairingControlCipher(
            pairRoot: pairRoot,
            pairID: pairID,
            stage: .ready,
            senderRole: .joiner
        )
        self.pairID = pairID
        self.hostDeviceID = hostDeviceID
        self.archiveHash = archiveHash
        self.cipher = cipher
        route = cipher.route
        authorization = cipher.authorization
    }

    func seal(joinerDeviceID: Data) throws -> StoredMailboxEnvelope {
        let record = try PairingReadyRecord(
            pairID: pairID,
            hostDeviceID: hostDeviceID,
            joinerDeviceID: joinerDeviceID,
            archiveHash: archiveHash
        )
        return try cipher.seal(record.canonicalData())
    }

    func open(_ envelope: StoredMailboxEnvelope) throws -> PairingReadyRecord {
        let record = try PairingReadyRecord.decodeCanonical(
            from: cipher.open(envelope)
        )
        guard
            record.pairID == pairID,
            record.hostDeviceID == hostDeviceID,
            record.archiveHash == archiveHash
        else {
            throw MailboxCryptoError.invalidEnvelope
        }
        return record
    }
}

struct PairingCommitRecord: PairingControlRecord, Sendable {
    let version: UInt8
    let pairID: Data
    let hostDeviceID: Data
    let joinerDeviceID: Data
    let archiveHash: Data

    init(
        version: UInt8 = SyncProtocol.pairingVersion,
        pairID: Data,
        hostDeviceID: Data,
        joinerDeviceID: Data,
        archiveHash: Data
    ) throws {
        self.version = version
        self.pairID = pairID
        self.hostDeviceID = hostDeviceID
        self.joinerDeviceID = joinerDeviceID
        self.archiveHash = archiveHash
        try validate()
    }

    fileprivate func validate() throws {
        guard
            version == SyncProtocol.pairingVersion,
            pairID.count == 16,
            hostDeviceID.count == 16,
            joinerDeviceID.count == 16,
            hostDeviceID != joinerDeviceID,
            archiveHash.count == 32
        else {
            throw MailboxCryptoError.invalidEnvelope
        }
    }
}

struct PairingCommitMailbox: Sendable {
    static let modeByte: UInt8 = 0x43
    static let routeLabel = PairingControlRoute.label

    let senderRole: DeviceRole
    let route: Data
    let authorization: Data
    private let expectedRecord: PairingCommitRecord
    private let cipher: PairingControlCipher

    init(
        pairRoot: Data,
        record: PairingCommitRecord,
        senderRole: DeviceRole
    ) throws {
        try record.validate()
        let cipher = try PairingControlCipher(
            pairRoot: pairRoot,
            pairID: record.pairID,
            stage: .commit,
            senderRole: senderRole
        )
        self.senderRole = senderRole
        self.expectedRecord = record
        self.cipher = cipher
        route = cipher.route
        authorization = cipher.authorization
    }

    func seal() throws -> StoredMailboxEnvelope {
        try cipher.seal(expectedRecord.canonicalData())
    }

    func open(
        _ envelope: StoredMailboxEnvelope
    ) throws -> PairingCommitRecord {
        let record = try PairingCommitRecord.decodeCanonical(
            from: cipher.open(envelope)
        )
        guard record == expectedRecord else {
            throw MailboxCryptoError.invalidEnvelope
        }
        return record
    }
}

struct PairingAbortRecord: PairingControlRecord, Sendable {
    let version: UInt8
    let pairID: Data
    let senderDeviceID: Data
    let senderRole: DeviceRole

    init(
        version: UInt8 = SyncProtocol.pairingVersion,
        pairID: Data,
        senderDeviceID: Data,
        senderRole: DeviceRole
    ) throws {
        self.version = version
        self.pairID = pairID
        self.senderDeviceID = senderDeviceID
        self.senderRole = senderRole
        try validate()
    }

    fileprivate func validate() throws {
        guard
            version == SyncProtocol.pairingVersion,
            pairID.count == 16,
            senderDeviceID.count == 16
        else {
            throw MailboxCryptoError.invalidEnvelope
        }
    }
}

struct PairingAbortMailbox: Sendable {
    static let routeLabel = PairingControlRoute.label

    let senderRole: DeviceRole
    let route: Data
    let authorization: Data
    private let pairID: Data
    private let cipher: PairingControlCipher

    init(
        pairRoot: Data,
        pairID: Data,
        senderRole: DeviceRole
    ) throws {
        let cipher = try PairingControlCipher(
            pairRoot: pairRoot,
            pairID: pairID,
            stage: .abort,
            senderRole: senderRole
        )
        self.pairID = pairID
        self.senderRole = senderRole
        self.cipher = cipher
        route = cipher.route
        authorization = cipher.authorization
    }

    func seal(senderDeviceID: Data) throws -> StoredMailboxEnvelope {
        let record = try PairingAbortRecord(
            pairID: pairID,
            senderDeviceID: senderDeviceID,
            senderRole: senderRole
        )
        return try cipher.seal(record.canonicalData())
    }

    func open(_ envelope: StoredMailboxEnvelope) throws -> PairingAbortRecord {
        let record = try PairingAbortRecord.decodeCanonical(
            from: cipher.open(envelope)
        )
        guard
            record.pairID == pairID,
            record.senderRole == senderRole
        else {
            throw MailboxCryptoError.invalidEnvelope
        }
        return record
    }
}

struct MailboxKeyMaterial: Sendable {
    static let modeByte: UInt8 = 0x4d
    static let routeLabel = Data(
        "\(ProtocolDomains.namespace)/mailbox-route/v1".utf8
    )

    let pairID: Data
    let senderRole: DeviceRole
    let route: Data
    let authorization: Data
    private let encryptionRoot: Data
    private let messageIDKey: SymmetricKey

    init(pairRoot: Data, pairID: Data, senderRole: DeviceRole) throws {
        guard pairRoot.count == 32, pairID.count == 16 else {
            throw MailboxCryptoError.invalidCredentials
        }
        let direction = Self.directionLabel(senderRole)
        let authorization = SyncKeyDerivation.derive(
            input: pairRoot,
            label: "\(ProtocolDomains.namespace)/mailbox-auth/\(direction)/v1",
            count: 32
        )
        self.pairID = pairID
        self.senderRole = senderRole
        self.authorization = authorization
        route = (Self.routeLabel + authorization).sha256
        encryptionRoot = SyncKeyDerivation.derive(
            input: pairRoot,
            label: "\(ProtocolDomains.namespace)/mailbox-encryption/\(direction)/v1",
            count: 32
        )
        messageIDKey = SymmetricKey(
            data: SyncKeyDerivation.derive(
                input: pairRoot,
                label: "\(ProtocolDomains.namespace)/mailbox-message-id/\(direction)/v1",
                count: 32
            )
        )
    }

    func seal(_ operation: TaskOperation) throws -> StoredMailboxEnvelope {
        let plaintext = try operation.canonicalData()
        guard plaintext.count <= ProtocolLimits.mailboxEnvelopeBytes - 16 else {
            throw MailboxCryptoError.envelopeTooLarge
        }
        let messageID = messageID(for: plaintext)
        let sealed = try ChaChaPoly.seal(
            plaintext,
            using: messageKey(for: messageID),
            nonce: try Self.zeroNonce(),
            authenticating: try associatedData(messageID: messageID)
        )
        return try StoredMailboxEnvelope(
            messageID: messageID,
            ciphertext: sealed.ciphertext + sealed.tag
        )
    }

    func open(_ envelope: StoredMailboxEnvelope) throws -> TaskOperation {
        guard envelope.ciphertext.count >= 16 else {
            throw MailboxCryptoError.invalidEnvelope
        }
        let tagStart = envelope.ciphertext.count - 16
        let sealed = try ChaChaPoly.SealedBox(
            nonce: try Self.zeroNonce(),
            ciphertext: Data(envelope.ciphertext.prefix(tagStart)),
            tag: Data(envelope.ciphertext.suffix(16))
        )
        let plaintext = try ChaChaPoly.open(
            sealed,
            using: messageKey(for: envelope.messageID),
            authenticating: try associatedData(messageID: envelope.messageID)
        )
        guard Self.constantTimeEqual(
            messageID(for: plaintext),
            envelope.messageID
        ) else {
            throw MailboxCryptoError.messageIDMismatch
        }
        return try TaskOperation.decodeCanonical(from: plaintext)
    }

    private func messageID(for plaintext: Data) -> Data {
        Data(
            HMAC<SHA256>.authenticationCode(
                for: plaintext,
                using: messageIDKey
            )
        )
    }

    private func messageKey(for messageID: Data) -> SymmetricKey {
        SymmetricKey(
            data: SyncKeyDerivation.derive(
                input: encryptionRoot,
                label: "\(ProtocolDomains.namespace)/mailbox-message-key/v1",
                context: messageID,
                count: 32
            )
        )
    }

    private func associatedData(messageID: Data) throws -> Data {
        guard messageID.count == 32, route.count == 32 else {
            throw MailboxCryptoError.invalidEnvelope
        }
        var builder = TranscriptBuilder()
        try builder.append(tag: 1, value: SyncProtocol.appID)
        try builder.append(tag: 2, value: Data([SyncProtocol.version]))
        try builder.append(tag: 3, value: Data([Self.modeByte]))
        try builder.append(tag: 4, value: pairID)
        try builder.append(tag: 5, value: Data([senderRole.wireByte]))
        try builder.append(tag: 6, value: route)
        try builder.append(tag: 7, value: messageID)
        return builder.data
    }

    private static func directionLabel(_ role: DeviceRole) -> String {
        role == .host ? "A-to-B" : "B-to-A"
    }

    private static func zeroNonce() throws -> ChaChaPoly.Nonce {
        try ChaChaPoly.Nonce(data: Data(repeating: 0, count: 12))
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }
}
