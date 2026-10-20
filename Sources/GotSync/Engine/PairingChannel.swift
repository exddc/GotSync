import CryptoKit
import Foundation

protocol PairingConnection: AnyObject, Sendable {
    func receive() async throws -> RelayEvent
    func send(_ data: Data) async throws
    func cancel() async
}

protocol PairingRendezvous: Sendable {
    func connect(route: Data) async throws -> any PairingConnection
}

extension RelaySocket: PairingConnection {}

struct RelayPairingRendezvous: PairingRendezvous {
    let url: URL
    let policy: EndpointSecurityPolicy

    func connect(route: Data) async throws -> any PairingConnection {
        let socket = RelaySocket(url: url, policy: policy)
        try await socket.connect(route: route)
        return socket
    }
}

enum PairingFrame: Equatable, Sendable {
    case offer(groupID: Data, inviterFingerprint: Data)
    case commitment(Data)
    case nonce(Data)
    case response(keyPackageReference: Data, joinerFingerprint: Data, joinerNonce: Data)
    case decision(approved: Bool)

    enum Direction {
        case fromInviter
        case fromJoiner
    }

    private enum Kind: UInt8 {
        case offer = 1
        case response = 2
        case decision = 3
        case commitment = 4
        case nonce = 5
    }

    private var kind: Kind {
        switch self {
        case .offer: .offer
        case .commitment: .commitment
        case .nonce: .nonce
        case .response: .response
        case .decision: .decision
        }
    }

    private var direction: Direction? {
        switch self {
        case .offer, .nonce: .fromInviter
        case .commitment, .response: .fromJoiner
        case .decision: nil
        }
    }

    private var body: Data {
        switch self {
        case .offer(let group, let fingerprint): group + fingerprint
        case .commitment(let value), .nonce(let value): value
        case .response(let reference, let fingerprint, let nonce): reference + fingerprint + nonce
        case .decision(let approved): Data([approved ? 1 : 0])
        }
    }

    func seal(for invitation: Invitation, from direction: Direction) throws -> Data {
        guard self.direction == nil || self.direction == direction else { throw SyncError.invalidPairMessage }
        let sealed = try ChaChaPoly.seal(
            body,
            using: Self.key(for: invitation, direction: direction),
            authenticating: Self.associatedData(kind)
        )
        return Data([kind.rawValue]) + sealed.combined
    }

    static func open(_ frame: Data, for invitation: Invitation, from direction: Direction) throws -> PairingFrame {
        guard frame.count <= 512, let first = frame.first, let kind = Kind(rawValue: first) else {
            throw SyncError.invalidPairMessage
        }
        let body: Data
        do {
            let box = try ChaChaPoly.SealedBox(combined: frame.dropFirst())
            body = try ChaChaPoly.open(box, using: key(for: invitation, direction: direction), authenticating: associatedData(kind))
        } catch {
            throw SyncError.invalidPairMessage
        }
        let decoded: PairingFrame
        switch kind {
        case .offer:
            guard body.count == 64 else { throw SyncError.invalidPairMessage }
            decoded = .offer(groupID: Data(body.prefix(32)), inviterFingerprint: Data(body.suffix(32)))
        case .commitment:
            guard body.count == 32 else { throw SyncError.invalidPairMessage }
            decoded = .commitment(Data(body))
        case .nonce:
            guard body.count == 32 else { throw SyncError.invalidPairMessage }
            decoded = .nonce(Data(body))
        case .response:
            guard body.count == 96 else { throw SyncError.invalidPairMessage }
            let bytes = Data(body)
            decoded = .response(
                keyPackageReference: bytes.prefix(32),
                joinerFingerprint: bytes.dropFirst(32).prefix(32),
                joinerNonce: bytes.suffix(32)
            )
        case .decision:
            guard body.count == 1, body[body.startIndex] <= 1 else { throw SyncError.invalidPairMessage }
            decoded = .decision(approved: body[body.startIndex] == 1)
        }
        guard decoded.direction == nil || decoded.direction == direction else { throw SyncError.invalidPairMessage }
        return decoded
    }

    private static func key(for invitation: Invitation, direction: Direction) -> SymmetricKey {
        switch direction {
        case .fromInviter: invitation.offerKey
        case .fromJoiner: invitation.responseKey
        }
    }

    private static func associatedData(_ kind: Kind) -> Data {
        Data("\(ProtocolDomains.namespace)/mls-pairing-frame/v2".utf8) + Data([kind.rawValue])
    }
}

/// The joiner commits to its KeyPackage, fingerprint and nonce before it
/// learns the inviter's nonce, and the code depends on both nonces. A party
/// holding the invitation therefore cannot search for a KeyPackage whose code
/// matches another device's code.
enum PairingSafetyCode {
    static func commitment(
        groupID: Data,
        inviterFingerprint: Data,
        keyPackageReference: Data,
        joinerFingerprint: Data,
        joinerNonce: Data
    ) -> Data {
        var input = Data("\(ProtocolDomains.namespace)/mls-pairing-commitment/v2".utf8)
        for part in [groupID, inviterFingerprint, keyPackageReference, joinerFingerprint, joinerNonce] {
            input.append(part)
        }
        return Data(SHA256.hash(data: input))
    }

    static func code(
        groupID: Data,
        inviterFingerprint: Data,
        joinerFingerprint: Data,
        inviterNonce: Data,
        joinerNonce: Data
    ) -> String {
        var input = Data("\(ProtocolDomains.namespace)/mls-safety-code/v2".utf8)
        for part in [groupID, inviterFingerprint, joinerFingerprint, inviterNonce, joinerNonce] {
            input.append(part)
        }
        let value = Data(SHA256.hash(data: input)).prefix(4).reduce(UInt32.zero) { ($0 << 8) | UInt32($1) } % 1_000_000
        return String(format: "%06u", value)
    }
}
