import CryptoKit
import Foundation

enum MailboxCryptoError: Error, Equatable {
    case invalidCredentials
    case invalidEnvelope
    case invalidMessageID
    case envelopeTooLarge
    case messageIDMismatch
}

struct StoredMailboxEnvelope: Equatable, Sendable {
    let messageID: Data
    let ciphertext: Data

    init(messageID: Data, ciphertext: Data) throws {
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

struct MailboxKeyMaterial: Sendable {
    static let modeByte: UInt8 = 0x4d
    static let routeLabel = Data(
        "com.gotdone.sync/mailbox-route/v1".utf8
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
            label: "com.gotdone.sync/mailbox-auth/\(direction)/v1",
            count: 32
        )
        self.pairID = pairID
        self.senderRole = senderRole
        self.authorization = authorization
        route = (Self.routeLabel + authorization).sha256
        encryptionRoot = SyncKeyDerivation.derive(
            input: pairRoot,
            label: "com.gotdone.sync/mailbox-encryption/\(direction)/v1",
            count: 32
        )
        messageIDKey = SymmetricKey(
            data: SyncKeyDerivation.derive(
                input: pairRoot,
                label: "com.gotdone.sync/mailbox-message-id/\(direction)/v1",
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
                label: "com.gotdone.sync/mailbox-message-key/v1",
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
