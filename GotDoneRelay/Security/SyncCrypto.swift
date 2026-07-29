import CryptoKit
import Foundation

enum SyncCryptoError: Error, Equatable {
    case invalidKeyLength
    case invalidHandshakeFrame
    case invalidPublicKey
    case invalidSharedSecret
    case invalidConfirmation
    case invalidFrame
    case invalidFrameVersion
    case invalidFrameSequence(expected: UInt64, actual: UInt64)
    case invalidNoncePrefix
    case plaintextTooLarge
    case ciphertextTooLarge
    case sequenceExhausted
}

enum HandshakeMode: UInt8, Sendable {
    case pairing = 0x50
    case sync = 0x53
}

struct HandshakeContext: Sendable {
    let mode: HandshakeMode
    let relayOrigin: String
    let route: Data
    let pairID: Data?
    let roleADeviceID: Data?
    let roleBDeviceID: Data?
    let pairingProtocolVersion: UInt8?

    static func pairing(
        relayOrigin: String,
        route: Data,
        pairingProtocolVersion: UInt8? = SyncProtocol.pairingVersion
    ) -> HandshakeContext {
        HandshakeContext(
            mode: .pairing,
            relayOrigin: relayOrigin,
            route: route,
            pairID: nil,
            roleADeviceID: nil,
            roleBDeviceID: nil,
            pairingProtocolVersion: pairingProtocolVersion
        )
    }

    static func sync(
        relayOrigin: String,
        route: Data,
        pairID: Data,
        roleADeviceID: Data,
        roleBDeviceID: Data
    ) -> HandshakeContext {
        HandshakeContext(
            mode: .sync,
            relayOrigin: relayOrigin,
            route: route,
            pairID: pairID,
            roleADeviceID: roleADeviceID,
            roleBDeviceID: roleBDeviceID,
            pairingProtocolVersion: nil
        )
    }

    func transcriptHash(
        connectionID: Data,
        roleAPublicKey: Data,
        nonceA: Data,
        roleBPublicKey: Data,
        nonceB: Data
    ) throws -> Data {
        guard
            route.count == 32,
            connectionID.count == 16,
            roleAPublicKey.count == 32,
            nonceA.count == 16,
            roleBPublicKey.count == 32,
            nonceB.count == 16
        else {
            throw SyncCryptoError.invalidHandshakeFrame
        }

        var builder = TranscriptBuilder()
        try builder.append(tag: 1, value: SyncProtocol.appID)
        try builder.append(tag: 2, value: Data([SyncProtocol.version]))
        try builder.append(tag: 3, value: Data(relayOrigin.utf8))
        try builder.append(tag: 4, value: route)

        if mode == .pairing {
            guard let pairingProtocolVersion else {
                try builder.append(tag: 8, value: connectionID)
                try builder.append(tag: 9, value: roleAPublicKey)
                try builder.append(tag: 10, value: nonceA)
                try builder.append(tag: 11, value: roleBPublicKey)
                try builder.append(tag: 12, value: nonceB)
                return builder.data.sha256
            }
            try builder.append(
                tag: 5,
                value: Data([pairingProtocolVersion])
            )
        } else {
            guard
                let pairID,
                pairID.count == 16,
                let roleADeviceID,
                roleADeviceID.count == 16,
                let roleBDeviceID,
                roleBDeviceID.count == 16
            else {
                throw SyncCryptoError.invalidHandshakeFrame
            }
            try builder.append(tag: 5, value: pairID)
            try builder.append(tag: 6, value: roleADeviceID)
            try builder.append(tag: 7, value: roleBDeviceID)
        }

        try builder.append(tag: 8, value: connectionID)
        try builder.append(tag: 9, value: roleAPublicKey)
        try builder.append(tag: 10, value: nonceA)
        try builder.append(tag: 11, value: roleBPublicKey)
        try builder.append(tag: 12, value: nonceB)
        return builder.data.sha256
    }
}

enum SyncKeyDerivation {
    static func derive(
        input: Data,
        salt: Data = Data(),
        label: String,
        context: Data = Data(),
        count: Int
    ) -> Data {
        let info = Data(label.utf8) + context
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: input),
            salt: salt,
            info: info,
            outputByteCount: count
        )
        return key.dataRepresentation
    }

    static func syncRoute(pairRoot: Data) -> Data {
        derive(
            input: pairRoot,
            label: "com.gotdone.sync/route/v1",
            count: 32
        )
    }

    static func syncPSK(pairRoot: Data) -> Data {
        derive(
            input: pairRoot,
            label: "com.gotdone.sync/connection-psk/v1",
            count: 32
        )
    }
}

struct AHello: Equatable, Sendable {
    static let type: UInt8 = 1
    static let encodedSize = 2 + 16 + 32 + 16

    let connectionID: Data
    let publicKey: Data
    let nonce: Data

    var encoded: Data {
        Data([SyncProtocol.version, Self.type]) + connectionID + publicKey + nonce
    }

    init(connectionID: Data, publicKey: Data, nonce: Data) throws {
        guard connectionID.count == 16, publicKey.count == 32, nonce.count == 16 else {
            throw SyncCryptoError.invalidHandshakeFrame
        }
        self.connectionID = connectionID
        self.publicKey = publicKey
        self.nonce = nonce
    }

    init(encoded: Data) throws {
        guard
            encoded.count == Self.encodedSize,
            encoded[0] == SyncProtocol.version,
            encoded[1] == Self.type
        else {
            throw SyncCryptoError.invalidHandshakeFrame
        }
        try self.init(
            connectionID: encoded.subdata(in: 2..<18),
            publicKey: encoded.subdata(in: 18..<50),
            nonce: encoded.subdata(in: 50..<66)
        )
    }
}

struct BHello: Equatable, Sendable {
    static let type: UInt8 = 2
    static let encodedSize = 2 + 32 + 16 + 32

    let publicKey: Data
    let nonce: Data
    let confirmation: Data

    var encoded: Data {
        Data([SyncProtocol.version, Self.type]) + publicKey + nonce + confirmation
    }

    init(publicKey: Data, nonce: Data, confirmation: Data) throws {
        guard publicKey.count == 32, nonce.count == 16, confirmation.count == 32 else {
            throw SyncCryptoError.invalidHandshakeFrame
        }
        self.publicKey = publicKey
        self.nonce = nonce
        self.confirmation = confirmation
    }

    init(encoded: Data) throws {
        guard
            encoded.count == Self.encodedSize,
            encoded[0] == SyncProtocol.version,
            encoded[1] == Self.type
        else {
            throw SyncCryptoError.invalidHandshakeFrame
        }
        try self.init(
            publicKey: encoded.subdata(in: 2..<34),
            nonce: encoded.subdata(in: 34..<50),
            confirmation: encoded.subdata(in: 50..<82)
        )
    }
}

struct AConfirm: Equatable, Sendable {
    static let type: UInt8 = 3
    static let encodedSize = 2 + 32

    let confirmation: Data

    var encoded: Data {
        Data([SyncProtocol.version, Self.type]) + confirmation
    }

    init(confirmation: Data) throws {
        guard confirmation.count == 32 else {
            throw SyncCryptoError.invalidHandshakeFrame
        }
        self.confirmation = confirmation
    }

    init(encoded: Data) throws {
        guard
            encoded.count == Self.encodedSize,
            encoded[0] == SyncProtocol.version,
            encoded[1] == Self.type
        else {
            throw SyncCryptoError.invalidHandshakeFrame
        }
        try self.init(confirmation: encoded.subdata(in: 2..<34))
    }
}

struct HandshakeMaterial: Sendable {
    let mode: HandshakeMode
    let transcriptHash: Data
    let sessionSecret: Data
    let roleAToBKey: Data
    let roleBToAKey: Data
    let roleAToBNoncePrefix: Data
    let roleBToANoncePrefix: Data

    var safetyCode: String {
        let codeBytes = HMAC<SHA256>.authenticationCode(
            for: Data("com.gotdone.sync/safety-code/v1".utf8) + transcriptHash,
            using: SymmetricKey(data: sessionSecret)
        )
        let value = Data(codeBytes).prefix(4).reduce(UInt32.zero) {
            ($0 << 8) | UInt32($1)
        } % 1_000_000
        return String(format: "%06u", value)
    }

    var pairRoot: Data? {
        guard mode == .pairing else {
            return nil
        }
        return SyncKeyDerivation.derive(
            input: sessionSecret,
            label: "com.gotdone.sync/pair-root/v1",
            count: 32
        )
    }

    var pairID: Data? {
        guard mode == .pairing else {
            return nil
        }
        return SyncKeyDerivation.derive(
            input: sessionSecret,
            label: "com.gotdone.sync/pair-id/v1",
            count: 16
        )
    }

    func makeSecureSession(role: DeviceRole) throws -> SecureSession {
        let outboundKey = role == .host ? roleAToBKey : roleBToAKey
        let inboundKey = role == .host ? roleBToAKey : roleAToBKey
        let outboundPrefix = role == .host ? roleAToBNoncePrefix : roleBToANoncePrefix
        let inboundPrefix = role == .host ? roleBToANoncePrefix : roleAToBNoncePrefix

        return try SecureSession(
            outbound: FrameCipher(
                key: outboundKey,
                noncePrefix: outboundPrefix,
                transcriptHash: transcriptHash,
                mode: mode,
                direction: role.wireByte
            ),
            inbound: FrameCipher(
                key: inboundKey,
                noncePrefix: inboundPrefix,
                transcriptHash: transcriptHash,
                mode: mode,
                direction: role.opposite.wireByte
            )
        )
    }
}

struct InitiatorHandshake {
    let context: HandshakeContext
    let psk: Data
    private let privateKey: Curve25519.KeyAgreement.PrivateKey
    private let connectionID: Data
    private let nonceA: Data

    init(context: HandshakeContext, psk: Data) throws {
        try self.init(
            context: context,
            psk: psk,
            privateKey: Curve25519.KeyAgreement.PrivateKey(),
            connectionID: .secureRandom(count: 16),
            nonceA: .secureRandom(count: 16)
        )
    }

    init(
        context: HandshakeContext,
        psk: Data,
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        connectionID: Data,
        nonceA: Data
    ) throws {
        guard psk.count == 32, connectionID.count == 16, nonceA.count == 16 else {
            throw SyncCryptoError.invalidKeyLength
        }
        self.context = context
        self.psk = psk
        self.privateKey = privateKey
        self.connectionID = connectionID
        self.nonceA = nonceA
    }

    var hello: Data {
        try! AHello(
            connectionID: connectionID,
            publicKey: privateKey.publicKey.rawRepresentation,
            nonce: nonceA
        ).encoded
    }

    func receive(_ encodedBHello: Data) throws -> (material: HandshakeMaterial, confirm: Data) {
        let message = try BHello(encoded: encodedBHello)
        let publicKey: Curve25519.KeyAgreement.PublicKey
        do {
            publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: message.publicKey)
        } catch {
            throw SyncCryptoError.invalidPublicKey
        }

        let transcript = try context.transcriptHash(
            connectionID: connectionID,
            roleAPublicKey: privateKey.publicKey.rawRepresentation,
            nonceA: nonceA,
            roleBPublicKey: message.publicKey,
            nonceB: message.nonce
        )
        let material = try Self.deriveMaterial(
            context: context,
            psk: psk,
            privateKey: privateKey,
            peerPublicKey: publicKey,
            transcriptHash: transcript
        )
        let confirmKey = Self.confirmKey(material: material)
        let expectedB = Self.confirmation(
            role: .joiner,
            transcriptHash: transcript,
            key: confirmKey
        )
        guard Self.constantTimeEqual(expectedB, message.confirmation) else {
            throw SyncCryptoError.invalidConfirmation
        }
        let confirmA = Self.confirmation(
            role: .host,
            transcriptHash: transcript,
            key: confirmKey
        )
        return (material, try AConfirm(confirmation: confirmA).encoded)
    }

    fileprivate static func deriveMaterial(
        context: HandshakeContext,
        psk: Data,
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKey: Curve25519.KeyAgreement.PublicKey,
        transcriptHash: Data
    ) throws -> HandshakeMaterial {
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
        let sharedData = shared.withUnsafeBytes { Data($0) }
        guard sharedData.contains(where: { $0 != 0 }) else {
            throw SyncCryptoError.invalidSharedSecret
        }

        let sessionSecret = SyncKeyDerivation.derive(
            input: sharedData,
            salt: psk,
            label: "com.gotdone.sync/handshake/v1",
            context: transcriptHash,
            count: 32
        )
        let pairMode = context.mode == .pairing
        let trafficPrefix = pairMode ? "com.gotdone.sync/pair-traffic" : "com.gotdone.sync/traffic"
        let noncePrefix = pairMode ? "com.gotdone.sync/pair-nonce" : "com.gotdone.sync/nonce"

        return HandshakeMaterial(
            mode: context.mode,
            transcriptHash: transcriptHash,
            sessionSecret: sessionSecret,
            roleAToBKey: SyncKeyDerivation.derive(
                input: sessionSecret,
                label: "\(trafficPrefix)/A-to-B/v1",
                count: 32
            ),
            roleBToAKey: SyncKeyDerivation.derive(
                input: sessionSecret,
                label: "\(trafficPrefix)/B-to-A/v1",
                count: 32
            ),
            roleAToBNoncePrefix: SyncKeyDerivation.derive(
                input: sessionSecret,
                label: "\(noncePrefix)/A-to-B/v1",
                count: 4
            ),
            roleBToANoncePrefix: SyncKeyDerivation.derive(
                input: sessionSecret,
                label: "\(noncePrefix)/B-to-A/v1",
                count: 4
            )
        )
    }

    fileprivate static func confirmKey(material: HandshakeMaterial) -> Data {
        SyncKeyDerivation.derive(
            input: material.sessionSecret,
            label: "com.gotdone.sync/confirm/v1",
            count: 32
        )
    }

    fileprivate static func confirmation(
        role: DeviceRole,
        transcriptHash: Data,
        key: Data
    ) -> Data {
        let input = Data([role.wireByte]) + transcriptHash
        return Data(HMAC<SHA256>.authenticationCode(
            for: input,
            using: SymmetricKey(data: key)
        ))
    }

    fileprivate static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
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

struct ResponderHandshake {
    private let material: HandshakeMaterial
    private let expectedAConfirmation: Data

    static func respond(
        to encodedAHello: Data,
        context: HandshakeContext,
        psk: Data
    ) throws -> (state: ResponderHandshake, response: Data) {
        try respond(
            to: encodedAHello,
            context: context,
            psk: psk,
            privateKey: Curve25519.KeyAgreement.PrivateKey(),
            nonceB: .secureRandom(count: 16)
        )
    }

    static func respond(
        to encodedAHello: Data,
        context: HandshakeContext,
        psk: Data,
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        nonceB: Data
    ) throws -> (state: ResponderHandshake, response: Data) {
        guard psk.count == 32, nonceB.count == 16 else {
            throw SyncCryptoError.invalidKeyLength
        }
        let message = try AHello(encoded: encodedAHello)
        let publicKey: Curve25519.KeyAgreement.PublicKey
        do {
            publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: message.publicKey)
        } catch {
            throw SyncCryptoError.invalidPublicKey
        }

        let localPublicKey = privateKey.publicKey.rawRepresentation
        let transcript = try context.transcriptHash(
            connectionID: message.connectionID,
            roleAPublicKey: message.publicKey,
            nonceA: message.nonce,
            roleBPublicKey: localPublicKey,
            nonceB: nonceB
        )
        let material = try InitiatorHandshake.deriveMaterial(
            context: context,
            psk: psk,
            privateKey: privateKey,
            peerPublicKey: publicKey,
            transcriptHash: transcript
        )
        let confirmKey = InitiatorHandshake.confirmKey(material: material)
        let confirmationB = InitiatorHandshake.confirmation(
            role: .joiner,
            transcriptHash: transcript,
            key: confirmKey
        )
        let expectedA = InitiatorHandshake.confirmation(
            role: .host,
            transcriptHash: transcript,
            key: confirmKey
        )
        let response = try BHello(
            publicKey: localPublicKey,
            nonce: nonceB,
            confirmation: confirmationB
        ).encoded
        return (
            ResponderHandshake(material: material, expectedAConfirmation: expectedA),
            response
        )
    }

    func receive(_ encodedAConfirm: Data) throws -> HandshakeMaterial {
        let confirmation = try AConfirm(encoded: encodedAConfirm).confirmation
        guard InitiatorHandshake.constantTimeEqual(
            confirmation,
            expectedAConfirmation
        ) else {
            throw SyncCryptoError.invalidConfirmation
        }
        return material
    }
}

struct FrameCipher {
    private let key: SymmetricKey
    private let noncePrefix: Data
    private let transcriptHash: Data
    private let mode: HandshakeMode
    private let direction: UInt8
    private(set) var sequence: UInt64 = 0

    init(
        key: Data,
        noncePrefix: Data,
        transcriptHash: Data,
        mode: HandshakeMode,
        direction: UInt8
    ) throws {
        guard key.count == 32 else {
            throw SyncCryptoError.invalidKeyLength
        }
        guard noncePrefix.count == 4, transcriptHash.count == 32 else {
            throw SyncCryptoError.invalidNoncePrefix
        }
        self.key = SymmetricKey(data: key)
        self.noncePrefix = noncePrefix
        self.transcriptHash = transcriptHash
        self.mode = mode
        self.direction = direction
    }

    mutating func seal(_ plaintext: Data) throws -> Data {
        guard plaintext.count <= ProtocolLimits.plaintextBytes else {
            throw SyncCryptoError.plaintextTooLarge
        }
        guard sequence != UInt64.max else {
            throw SyncCryptoError.sequenceExhausted
        }

        let current = sequence
        let nonce = try ChaChaPoly.Nonce(data: nonceData(sequence: current))
        let sealed = try ChaChaPoly.seal(
            plaintext,
            using: key,
            nonce: nonce,
            authenticating: associatedData(sequence: current)
        )
        var frame = Data([SyncProtocol.version])
        frame.appendUInt64(current)
        frame.append(sealed.ciphertext)
        frame.append(sealed.tag)
        guard frame.count <= ProtocolLimits.webSocketMessageBytes else {
            throw SyncCryptoError.ciphertextTooLarge
        }
        sequence += 1
        return frame
    }

    mutating func open(_ frame: Data) throws -> Data {
        guard
            frame.count >= 25,
            frame.count <= ProtocolLimits.webSocketMessageBytes
        else {
            throw SyncCryptoError.invalidFrame
        }
        guard frame[0] == SyncProtocol.version else {
            throw SyncCryptoError.invalidFrameVersion
        }
        let receivedSequence = try frame.uint64(at: 1)
        guard receivedSequence == sequence else {
            throw SyncCryptoError.invalidFrameSequence(
                expected: sequence,
                actual: receivedSequence
            )
        }
        guard sequence != UInt64.max else {
            throw SyncCryptoError.sequenceExhausted
        }

        let ciphertextStart = 9
        let tagStart = frame.count - 16
        let ciphertext = frame.subdata(in: ciphertextStart..<tagStart)
        let tag = frame.subdata(in: tagStart..<frame.count)
        let nonce = try ChaChaPoly.Nonce(data: nonceData(sequence: receivedSequence))
        let box = try ChaChaPoly.SealedBox(
            nonce: nonce,
            ciphertext: ciphertext,
            tag: tag
        )
        let plaintext = try ChaChaPoly.open(
            box,
            using: key,
            authenticating: associatedData(sequence: receivedSequence)
        )
        guard plaintext.count <= ProtocolLimits.plaintextBytes else {
            throw SyncCryptoError.plaintextTooLarge
        }
        sequence += 1
        return plaintext
    }

    private func nonceData(sequence: UInt64) -> Data {
        var nonce = noncePrefix
        nonce.appendUInt64(sequence)
        return nonce
    }

    private func associatedData(sequence: UInt64) -> Data {
        var data = Data([SyncProtocol.version])
        data.append(transcriptHash)
        data.append(mode.rawValue)
        data.append(direction)
        data.appendUInt64(sequence)
        return data
    }
}

struct SecureSession {
    private var outbound: FrameCipher
    private var inbound: FrameCipher

    init(outbound: FrameCipher, inbound: FrameCipher) {
        self.outbound = outbound
        self.inbound = inbound
    }

    mutating func seal(_ plaintext: Data) throws -> Data {
        try outbound.seal(plaintext)
    }

    mutating func open(_ frame: Data) throws -> Data {
        try inbound.open(frame)
    }
}
