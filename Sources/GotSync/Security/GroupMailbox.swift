import CryptoKit
import Foundation

/// Per-recipient mailbox material for group sync (Option C).
///
/// Routes are ordered pairs (sender → recipient) under the current group root
/// epoch so each recipient can ACK independently.
struct GroupMailboxKeyMaterial: Sendable {
    static let modeByte: UInt8 = 0x47
    static let routeLabel = Data(
        "\(ProtocolDomains.namespace)/mailbox-route/v1".utf8
    )

    let groupID: Data
    let epoch: UInt64
    let senderDeviceID: Data
    let recipientDeviceID: Data
    let route: Data
    let authorization: Data
    private let encryptionRoot: Data
    private let messageIDKey: SymmetricKey

    init(
        groupRoot: Data,
        groupID: Data,
        epoch: UInt64,
        senderDeviceID: Data,
        recipientDeviceID: Data
    ) throws {
        guard
            groupRoot.count == 32,
            groupID.count == 16,
            epoch >= 1,
            senderDeviceID.count == 16,
            recipientDeviceID.count == 16,
            senderDeviceID != recipientDeviceID
        else {
            throw MailboxCryptoError.invalidCredentials
        }

        var info = Data("\(ProtocolDomains.namespace)/mailbox-auth/".utf8)
        info.append(senderDeviceID)
        info.append(recipientDeviceID)
        info.append(contentsOf: "/v1".utf8)
        // Domain-separated from pair A-to-B labels via group-root + device IDs.
        let authorization = SyncKeyDerivation.derive(
            input: groupRoot,
            label: "\(ProtocolDomains.namespace)/mailbox-auth/group-pair/v1",
            context: senderDeviceID + recipientDeviceID + epochBytes(epoch),
            count: 32
        )
        self.groupID = groupID
        self.epoch = epoch
        self.senderDeviceID = senderDeviceID
        self.recipientDeviceID = recipientDeviceID
        self.authorization = authorization
        route = (Self.routeLabel + authorization).sha256
        encryptionRoot = SyncKeyDerivation.derive(
            input: groupRoot,
            label: "\(ProtocolDomains.namespace)/mailbox-encryption/group-pair/v1",
            context: senderDeviceID + recipientDeviceID + epochBytes(epoch),
            count: 32
        )
        messageIDKey = SymmetricKey(
            data: SyncKeyDerivation.derive(
                input: groupRoot,
                label: "\(ProtocolDomains.namespace)/mailbox-message-id/group-pair/v1",
                context: senderDeviceID + recipientDeviceID + epochBytes(epoch),
                count: 32
            )
        )
        _ = info // reserved for future exact-doc label alignment tests
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
                label: "\(ProtocolDomains.namespace)/mailbox-message-key/group/v1",
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
        try builder.append(tag: 4, value: groupID)
        try builder.append(tag: 5, value: epochBytes(epoch))
        try builder.append(tag: 6, value: senderDeviceID)
        try builder.append(tag: 7, value: recipientDeviceID)
        try builder.append(tag: 8, value: route)
        try builder.append(tag: 9, value: messageID)
        return builder.data
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

private func epochBytes(_ epoch: UInt64) -> Data {
    var data = Data(count: 8)
    for index in 0..<8 {
        data[index] = UInt8((epoch >> (8 * (7 - index))) & 0xff)
    }
    return data
}

/// Multi-recipient task mailbox for a linked group member.
struct GroupMailbox: Sendable {
    let credentials: GroupCredentials
    let localDeviceID: ReplicaDeviceID
    let outboundByRecipient: [Data: GroupMailboxKeyMaterial]
    let inboundBySender: [Data: GroupMailboxKeyMaterial]

    init(credentials: GroupCredentials) throws {
        try credentials.validate(deviceID: try ReplicaDeviceID(bytes: credentials.localDeviceID))
        localDeviceID = try ReplicaDeviceID(bytes: credentials.localDeviceID)
        self.credentials = credentials

        var outbound: [Data: GroupMailboxKeyMaterial] = [:]
        var inbound: [Data: GroupMailboxKeyMaterial] = [:]
        for remote in credentials.remoteActiveDeviceIDs {
            outbound[remote] = try GroupMailboxKeyMaterial(
                groupRoot: credentials.groupRoot,
                groupID: credentials.groupID,
                epoch: credentials.epoch,
                senderDeviceID: credentials.localDeviceID,
                recipientDeviceID: remote
            )
            inbound[remote] = try GroupMailboxKeyMaterial(
                groupRoot: credentials.groupRoot,
                groupID: credentials.groupID,
                epoch: credentials.epoch,
                senderDeviceID: remote,
                recipientDeviceID: credentials.localDeviceID
            )
        }
        outboundByRecipient = outbound
        inboundBySender = inbound
    }

    func seal(
        _ operation: TaskOperation,
        for recipientDeviceID: Data
    ) throws -> StoredMailboxEnvelope {
        guard operation.originDeviceID == localDeviceID else {
            throw MailboxCryptoError.invalidEnvelope
        }
        guard let material = outboundByRecipient[recipientDeviceID] else {
            throw MailboxCryptoError.invalidCredentials
        }
        return try material.seal(operation)
    }

    func open(
        _ envelope: StoredMailboxEnvelope,
        from senderDeviceID: Data
    ) throws -> TaskOperation {
        guard let material = inboundBySender[senderDeviceID] else {
            throw MailboxCryptoError.invalidCredentials
        }
        let operation = try material.open(envelope)
        guard operation.originDeviceID.bytes == senderDeviceID else {
            throw MailboxCryptoError.invalidEnvelope
        }
        return operation
    }
}

// MARK: - Membership control (side log)

/// One roster entry in a signed membership snapshot (device ID + optional pubkey).
struct GroupMembershipRosterEntry: Codable, Equatable, Sendable, Hashable {
    let deviceID: Data
    let signingPublicKey: Data

    init(deviceID: Data, signingPublicKey: Data = Data()) {
        self.deviceID = deviceID
        self.signingPublicKey = signingPublicKey
    }

    init(member: GroupMember) {
        deviceID = member.deviceID
        signingPublicKey = member.signingPublicKey
    }

    var asGroupMember: GroupMember {
        GroupMember(
            deviceID: deviceID,
            signingPublicKey: signingPublicKey
        )
    }
}

/// Signed membership snapshot (C2). Optional rekeySeed advances epoch (C3).
struct GroupMembershipSnapshot: Codable, Equatable, Sendable {
    static let currentVersion: UInt8 = 2

    let version: UInt8
    let groupID: Data
    let epoch: UInt64
    let membershipGeneration: UInt64
    let roster: [GroupMembershipRosterEntry]
    let issuerDeviceID: Data
    let rekeySeed: Data?
    let signature: Data

    var members: [Data] {
        roster.map(\.deviceID)
    }

    init(
        groupID: Data,
        epoch: UInt64,
        membershipGeneration: UInt64,
        members: [Data],
        issuerDeviceID: Data,
        rekeySeed: Data? = nil,
        signature: Data = Data()
    ) {
        let roster = members
            .sorted { $0.lexicographicallyPrecedes($1) }
            .map { GroupMembershipRosterEntry(deviceID: $0) }
        self.init(
            groupID: groupID,
            epoch: epoch,
            membershipGeneration: membershipGeneration,
            roster: roster,
            issuerDeviceID: issuerDeviceID,
            rekeySeed: rekeySeed,
            signature: signature
        )
    }

    init(
        groupID: Data,
        epoch: UInt64,
        membershipGeneration: UInt64,
        roster: [GroupMembershipRosterEntry],
        issuerDeviceID: Data,
        rekeySeed: Data? = nil,
        signature: Data = Data()
    ) {
        version = Self.currentVersion
        self.groupID = groupID
        self.epoch = epoch
        self.membershipGeneration = membershipGeneration
        self.roster = roster.sorted {
            $0.deviceID.lexicographicallyPrecedes($1.deviceID)
        }
        self.issuerDeviceID = issuerDeviceID
        self.rekeySeed = rekeySeed
        self.signature = signature
    }

    static func signed(
        groupID: Data,
        epoch: UInt64,
        membershipGeneration: UInt64,
        roster: [GroupMembershipRosterEntry],
        issuerDeviceID: Data,
        rekeySeed: Data? = nil,
        signingKey: Curve25519.Signing.PrivateKey
    ) throws -> GroupMembershipSnapshot {
        let unsigned = GroupMembershipSnapshot(
            groupID: groupID,
            epoch: epoch,
            membershipGeneration: membershipGeneration,
            roster: roster,
            issuerDeviceID: issuerDeviceID,
            rekeySeed: rekeySeed,
            signature: Data()
        )
        let body = try unsigned.unsignedCanonicalData()
        let signature = try signingKey.signature(for: body)
        return GroupMembershipSnapshot(
            groupID: groupID,
            epoch: epoch,
            membershipGeneration: membershipGeneration,
            roster: unsigned.roster,
            issuerDeviceID: issuerDeviceID,
            rekeySeed: rekeySeed,
            signature: Data(signature)
        )
    }

    func validate() throws {
        let issuerInRoster = roster.contains(where: { $0.deviceID == issuerDeviceID })
        let leaveAllowed = rekeySeed != nil && !issuerInRoster
        guard
            version == 1 || version == Self.currentVersion,
            groupID.count == 16,
            epoch >= 1,
            membershipGeneration >= 1,
            issuerDeviceID.count == 16,
            roster.count >= 2,
            roster.count <= ReplicaLimits.maxOrigins,
            roster.allSatisfy({ $0.deviceID.count == 16 }),
            roster.allSatisfy({
                $0.signingPublicKey.isEmpty || $0.signingPublicKey.count == 32
            }),
            Set(roster.map(\.deviceID)).count == roster.count,
            issuerInRoster || leaveAllowed
        else {
            throw MailboxCryptoError.invalidEnvelope
        }
        if let rekeySeed {
            guard rekeySeed.count == 32 else {
                throw MailboxCryptoError.invalidEnvelope
            }
        }
        if version >= Self.currentVersion {
            guard signature.count == 64 else {
                throw MailboxCryptoError.invalidEnvelope
            }
        }
    }

    func unsignedCanonicalData() throws -> Data {
        try validateStructureOnly()
        let body = GroupMembershipSnapshot(
            groupID: groupID,
            epoch: epoch,
            membershipGeneration: membershipGeneration,
            roster: roster,
            issuerDeviceID: issuerDeviceID,
            rekeySeed: rekeySeed,
            signature: Data()
        )
        return try CanonicalJSON.encoder.encode(UnsignedMembershipBody(from: body))
    }

    func canonicalData() throws -> Data {
        try validate()
        return try CanonicalJSON.encoder.encode(self)
    }

    func verifySignature(publicKey: Data) throws {
        guard publicKey.count == 32, signature.count == 64 else {
            throw MailboxCryptoError.invalidEnvelope
        }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        let body = try unsignedCanonicalData()
        guard key.isValidSignature(signature, for: body) else {
            throw MailboxCryptoError.invalidEnvelope
        }
    }

    static func decodeCanonical(from data: Data) throws -> GroupMembershipSnapshot {
        if let v2 = try? CanonicalJSON.decoder.decode(
            GroupMembershipSnapshot.self,
            from: data
        ), v2.version >= Self.currentVersion, !v2.roster.isEmpty {
            try v2.validate()
            guard try v2.canonicalData() == data else {
                throw MailboxCryptoError.invalidEnvelope
            }
            return v2
        }
        let legacy: LegacyMembershipSnapshot
        do {
            legacy = try CanonicalJSON.decoder.decode(
                LegacyMembershipSnapshot.self,
                from: data
            )
        } catch {
            throw MailboxCryptoError.invalidEnvelope
        }
        try legacy.validate()
        return GroupMembershipSnapshot(
            version: 1,
            groupID: legacy.groupID,
            epoch: legacy.epoch,
            membershipGeneration: legacy.membershipGeneration,
            roster: legacy.members
                .sorted { $0.lexicographicallyPrecedes($1) }
                .map { GroupMembershipRosterEntry(deviceID: $0) },
            issuerDeviceID: legacy.issuerDeviceID,
            rekeySeed: nil,
            signature: Data()
        )
    }

    /// Apply rules relative to current credentials (C2 + C3).
    func acceptedUpdate(
        against credentials: GroupCredentials
    ) throws -> GroupCredentials? {
        guard groupID == credentials.groupID else {
            return nil
        }
        guard membershipGeneration > credentials.membershipGeneration else {
            return nil
        }
        guard version >= Self.currentVersion else {
            throw MailboxCryptoError.invalidEnvelope
        }
        guard credentials.activeMemberDeviceIDs.contains(issuerDeviceID) else {
            throw MailboxCryptoError.invalidEnvelope
        }

        let knownIssuerKey = credentials.activeMembers
            .first(where: { $0.deviceID == issuerDeviceID })?
            .signingPublicKey
        let claimedIssuerKey = roster
            .first(where: { $0.deviceID == issuerDeviceID })?
            .signingPublicKey ?? Data()

        if let knownIssuerKey, knownIssuerKey.count == 32 {
            try verifySignature(publicKey: knownIssuerKey)
        } else if claimedIssuerKey.count == 32 {
            try verifySignature(publicKey: claimedIssuerKey)
        } else {
            throw MailboxCryptoError.invalidEnvelope
        }

        let previousIDs = Set(credentials.activeMemberDeviceIDs)
        let nextIDs = Set(members)
        let removed = previousIDs.subtracting(nextIDs)
        let isLeave = rekeySeed != nil && !nextIDs.contains(issuerDeviceID)

        // Local device removed by someone else → unlink (nil signals caller).
        if !nextIDs.contains(credentials.localDeviceID) {
            return nil
        }

        var nextRoot = credentials.groupRoot
        var nextEpoch = credentials.epoch

        if !removed.isEmpty || isLeave {
            guard let rekeySeed, rekeySeed.count == 32 else {
                throw MailboxCryptoError.invalidEnvelope
            }
            guard epoch == credentials.epoch &+ 1 else {
                throw MailboxCryptoError.invalidEnvelope
            }
            nextRoot = SyncKeyDerivation.groupRootRekey(
                groupRoot: credentials.groupRoot,
                rekeySeed: rekeySeed
            )
            nextEpoch = epoch
        } else {
            guard epoch == credentials.epoch else {
                throw MailboxCryptoError.invalidEnvelope
            }
            guard rekeySeed == nil else {
                throw MailboxCryptoError.invalidEnvelope
            }
        }

        let nextMembers = roster.map(\.asGroupMember)
        return try credentials.replacingRoster(
            members: nextMembers,
            membershipGeneration: membershipGeneration,
            epoch: nextEpoch,
            groupRoot: nextRoot
        )
    }

    private init(
        version: UInt8,
        groupID: Data,
        epoch: UInt64,
        membershipGeneration: UInt64,
        roster: [GroupMembershipRosterEntry],
        issuerDeviceID: Data,
        rekeySeed: Data?,
        signature: Data
    ) {
        self.version = version
        self.groupID = groupID
        self.epoch = epoch
        self.membershipGeneration = membershipGeneration
        self.roster = roster.sorted {
            $0.deviceID.lexicographicallyPrecedes($1.deviceID)
        }
        self.issuerDeviceID = issuerDeviceID
        self.rekeySeed = rekeySeed
        self.signature = signature
    }

    private func validateStructureOnly() throws {
        let issuerInRoster = roster.contains(where: { $0.deviceID == issuerDeviceID })
        let leaveAllowed = rekeySeed != nil && !issuerInRoster
        guard
            groupID.count == 16,
            epoch >= 1,
            membershipGeneration >= 1,
            issuerDeviceID.count == 16,
            roster.count >= 2,
            roster.count <= ReplicaLimits.maxOrigins,
            roster.allSatisfy({ $0.deviceID.count == 16 }),
            Set(roster.map(\.deviceID)).count == roster.count,
            issuerInRoster || leaveAllowed
        else {
            throw MailboxCryptoError.invalidEnvelope
        }
    }
}

private struct UnsignedMembershipBody: Codable {
    let version: UInt8
    let groupID: Data
    let epoch: UInt64
    let membershipGeneration: UInt64
    let roster: [GroupMembershipRosterEntry]
    let issuerDeviceID: Data
    let rekeySeed: Data?
    let signature: Data

    init(from snapshot: GroupMembershipSnapshot) {
        version = GroupMembershipSnapshot.currentVersion
        groupID = snapshot.groupID
        epoch = snapshot.epoch
        membershipGeneration = snapshot.membershipGeneration
        roster = snapshot.roster
        issuerDeviceID = snapshot.issuerDeviceID
        rekeySeed = snapshot.rekeySeed
        signature = Data()
    }
}

private struct LegacyMembershipSnapshot: Codable {
    let version: UInt8
    let groupID: Data
    let epoch: UInt64
    let membershipGeneration: UInt64
    let members: [Data]
    let issuerDeviceID: Data

    func validate() throws {
        guard
            version == 1,
            groupID.count == 16,
            epoch >= 1,
            membershipGeneration >= 1,
            issuerDeviceID.count == 16,
            members.count >= 2,
            members.count <= ReplicaLimits.maxOrigins,
            members.allSatisfy({ $0.count == 16 }),
            Set(members).count == members.count,
            members.contains(issuerDeviceID)
        else {
            throw MailboxCryptoError.invalidEnvelope
        }
    }
}

/// Membership gossip channel from issuer S to peer M.
///
/// Uses the shared mailbox route label so the relay authorization check
/// (route = SHA256(mailbox-route-label || auth)) accepts membership traffic
/// without a separate control-plane path.
struct GroupMembershipMailbox: Sendable {
    static let routeLabel = Data(
        "\(ProtocolDomains.namespace)/mailbox-route/v1".utf8
    )

    let route: Data
    let authorization: Data
    private let groupID: Data
    private let cipherRoot: Data
    private let messageIDKey: SymmetricKey
    private let senderDeviceID: Data
    private let recipientDeviceID: Data

    init(
        groupRoot: Data,
        groupID: Data,
        epoch: UInt64,
        senderDeviceID: Data,
        recipientDeviceID: Data
    ) throws {
        guard
            groupRoot.count == 32,
            groupID.count == 16,
            epoch >= 1,
            senderDeviceID.count == 16,
            recipientDeviceID.count == 16,
            senderDeviceID != recipientDeviceID
        else {
            throw MailboxCryptoError.invalidCredentials
        }
        self.groupID = groupID
        self.senderDeviceID = senderDeviceID
        self.recipientDeviceID = recipientDeviceID
        authorization = SyncKeyDerivation.derive(
            input: groupRoot,
            label: "\(ProtocolDomains.namespace)/membership-auth/v1",
            context: senderDeviceID + recipientDeviceID + epochBytes(epoch),
            count: 32
        )
        route = (Self.routeLabel + authorization).sha256
        cipherRoot = SyncKeyDerivation.derive(
            input: groupRoot,
            label: "\(ProtocolDomains.namespace)/membership-encryption/v1",
            context: senderDeviceID + recipientDeviceID + epochBytes(epoch),
            count: 32
        )
        messageIDKey = SymmetricKey(
            data: SyncKeyDerivation.derive(
                input: groupRoot,
                label: "\(ProtocolDomains.namespace)/membership-message-id/v1",
                context: senderDeviceID + recipientDeviceID + epochBytes(epoch),
                count: 32
            )
        )
    }

    func seal(_ snapshot: GroupMembershipSnapshot) throws -> StoredMailboxEnvelope {
        let plaintext = try snapshot.canonicalData()
        guard plaintext.count <= ProtocolLimits.mailboxEnvelopeBytes - 16 else {
            throw MailboxCryptoError.envelopeTooLarge
        }
        let messageID = Data(
            HMAC<SHA256>.authenticationCode(
                for: plaintext,
                using: messageIDKey
            )
        )
        let key = SymmetricKey(
            data: SyncKeyDerivation.derive(
                input: cipherRoot,
                label: "\(ProtocolDomains.namespace)/membership-message-key/v1",
                context: messageID,
                count: 32
            )
        )
        let sealed = try ChaChaPoly.seal(
            plaintext,
            using: key,
            nonce: try ChaChaPoly.Nonce(data: Data(repeating: 0, count: 12)),
            authenticating: groupID + senderDeviceID + recipientDeviceID + messageID
        )
        return try StoredMailboxEnvelope(
            messageID: messageID,
            ciphertext: sealed.ciphertext + sealed.tag
        )
    }

    func open(_ envelope: StoredMailboxEnvelope) throws -> GroupMembershipSnapshot {
        guard envelope.ciphertext.count >= 16 else {
            throw MailboxCryptoError.invalidEnvelope
        }
        let tagStart = envelope.ciphertext.count - 16
        let key = SymmetricKey(
            data: SyncKeyDerivation.derive(
                input: cipherRoot,
                label: "\(ProtocolDomains.namespace)/membership-message-key/v1",
                context: envelope.messageID,
                count: 32
            )
        )
        let sealed = try ChaChaPoly.SealedBox(
            nonce: try ChaChaPoly.Nonce(data: Data(repeating: 0, count: 12)),
            ciphertext: Data(envelope.ciphertext.prefix(tagStart)),
            tag: Data(envelope.ciphertext.suffix(16))
        )
        let plaintext = try ChaChaPoly.open(
            sealed,
            using: key,
            authenticating: groupID + senderDeviceID + recipientDeviceID
                + envelope.messageID
        )
        let expectedID = Data(
            HMAC<SHA256>.authenticationCode(
                for: plaintext,
                using: messageIDKey
            )
        )
        guard expectedID == envelope.messageID else {
            throw MailboxCryptoError.messageIDMismatch
        }
        let snapshot = try GroupMembershipSnapshot.decodeCanonical(from: plaintext)
        guard
            snapshot.groupID == groupID,
            snapshot.issuerDeviceID == senderDeviceID
        else {
            throw MailboxCryptoError.invalidEnvelope
        }
        return snapshot
    }
}
