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

/// `profile` in an offer or response is the sender's group profile
/// descriptor. A `nil` profile uses the legacy frame kinds that earlier
/// builds understand; a descriptor uses kinds they reject.
enum PairingFrame: Equatable, Sendable {
    case offer(groupID: Data, inviterFingerprint: Data, profile: Data?)
    case commitment(Data)
    case nonce(Data)
    /// `origins` lists every origin in the joiner's replica, so the inviter
    /// can check the merged task history before it admits the joiner.
    case response(keyPackageReference: Data, joinerFingerprint: Data, joinerNonce: Data, origins: [ReplicaDeviceID], profile: Data?)
    case decision(approved: Bool)
    case historyFull
    /// The sender runs a different group profile.
    case profileMismatch

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
        case profiledOffer = 6
        case profiledResponse = 7
    }

    private var kind: Kind {
        switch self {
        case .offer(_, _, let profile): profile == nil ? .offer : .profiledOffer
        case .commitment: .commitment
        case .nonce: .nonce
        case .response(_, _, _, _, let profile): profile == nil ? .response : .profiledResponse
        case .decision, .historyFull, .profileMismatch: .decision
        }
    }

    private var direction: Direction? {
        switch self {
        case .offer, .nonce, .historyFull: .fromInviter
        case .commitment, .response: .fromJoiner
        case .decision, .profileMismatch: nil
        }
    }

    private var body: Data {
        switch self {
        case .offer(let group, let fingerprint, let profile): group + fingerprint + (profile ?? Data())
        case .commitment(let value), .nonce(let value): value
        case .response(let reference, let fingerprint, let nonce, let origins, let profile):
            origins.sorted().reduce(reference + fingerprint + nonce + Data([UInt8(origins.count)])) { $0 + $1.bytes }
                + (profile ?? Data())
        case .decision(let approved): Data([approved ? 1 : 0])
        case .historyFull: Data([2])
        case .profileMismatch: Data([3])
        }
    }

    private static let responseFixedBytes = 97
    private static let maximumFrameBytes = 1 + 12 + 16 + responseFixedBytes + 16 * ReplicaLimits.maxOrigins
        + SyncGroupProfile.maximumDescriptorBytes

    private static func isDescriptorSized(_ profile: Data?) -> Bool {
        profile.map { (1...SyncGroupProfile.maximumDescriptorBytes).contains($0.count) } ?? true
    }

    func seal(for invitation: Invitation, from direction: Direction) throws -> Data {
        guard self.direction == nil || self.direction == direction else { throw SyncError.invalidPairMessage }
        switch self {
        case .offer(_, _, let profile):
            guard Self.isDescriptorSized(profile) else { throw SyncError.invalidPairMessage }
        case .response(_, _, _, let origins, let profile):
            guard origins.count <= ReplicaLimits.maxOrigins, Set(origins).count == origins.count,
                  Self.isDescriptorSized(profile)
            else {
                throw SyncError.invalidPairMessage
            }
        default:
            break
        }
        let sealed = try ChaChaPoly.seal(
            body,
            using: Self.key(for: invitation, direction: direction),
            authenticating: Self.associatedData(kind)
        )
        return Data([kind.rawValue]) + sealed.combined
    }

    static func open(_ frame: Data, for invitation: Invitation, from direction: Direction) throws -> PairingFrame {
        guard frame.count <= maximumFrameBytes, let first = frame.first, let kind = Kind(rawValue: first) else {
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
            decoded = .offer(groupID: Data(body.prefix(32)), inviterFingerprint: Data(body.suffix(32)), profile: nil)
        case .profiledOffer:
            let bytes = Data(body)
            let profile = bytes.subdata(in: min(64, bytes.count)..<bytes.count)
            guard bytes.count > 64, isDescriptorSized(profile) else { throw SyncError.invalidPairMessage }
            decoded = .offer(groupID: bytes.subdata(in: 0..<32), inviterFingerprint: bytes.subdata(in: 32..<64), profile: profile)
        case .commitment:
            guard body.count == 32 else { throw SyncError.invalidPairMessage }
            decoded = .commitment(Data(body))
        case .nonce:
            guard body.count == 32 else { throw SyncError.invalidPairMessage }
            decoded = .nonce(Data(body))
        case .response, .profiledResponse:
            let bytes = Data(body)
            guard bytes.count >= responseFixedBytes else { throw SyncError.invalidPairMessage }
            let count = Int(bytes[responseFixedBytes - 1])
            let originsEnd = responseFixedBytes + 16 * count
            guard count <= ReplicaLimits.maxOrigins, bytes.count >= originsEnd else {
                throw SyncError.invalidPairMessage
            }
            let profile: Data? = kind == .profiledResponse ? bytes.subdata(in: originsEnd..<bytes.count) : nil
            guard kind == .profiledResponse ? (profile?.isEmpty == false && isDescriptorSized(profile)) : bytes.count == originsEnd else {
                throw SyncError.invalidPairMessage
            }
            let origins = try (0..<count).map { index in
                let start = responseFixedBytes + 16 * index
                guard let origin = try? ReplicaDeviceID(bytes: bytes.subdata(in: start..<start + 16)) else {
                    throw SyncError.invalidPairMessage
                }
                return origin
            }
            guard zip(origins, origins.dropFirst()).allSatisfy({ $0 < $1 }) else { throw SyncError.invalidPairMessage }
            decoded = .response(
                keyPackageReference: bytes.subdata(in: 0..<32),
                joinerFingerprint: bytes.subdata(in: 32..<64),
                joinerNonce: bytes.subdata(in: 64..<96),
                origins: origins,
                profile: profile
            )
        case .decision:
            guard body.count == 1, body[body.startIndex] <= 3 else { throw SyncError.invalidPairMessage }
            switch body[body.startIndex] {
            case 2: decoded = .historyFull
            case 3: decoded = .profileMismatch
            case let value: decoded = .decision(approved: value == 1)
            }
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
///
/// With a group profile, both values use their own labels and cover the
/// length-prefixed descriptor, so devices that disagree on the profile can
/// neither open each other's commitment nor show the same code. Without one
/// the inputs are those of earlier builds.
enum PairingSafetyCode {
    static func commitment(
        groupID: Data,
        inviterFingerprint: Data,
        keyPackageReference: Data,
        joinerFingerprint: Data,
        joinerNonce: Data,
        profile: Data?
    ) -> Data {
        var input = transcript(label: "mls-pairing-commitment", profile: profile)
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
        joinerNonce: Data,
        profile: Data?
    ) -> String {
        var input = transcript(label: "mls-safety-code", profile: profile)
        for part in [groupID, inviterFingerprint, joinerFingerprint, inviterNonce, joinerNonce] {
            input.append(part)
        }
        let value = Data(SHA256.hash(data: input)).prefix(4).reduce(UInt32.zero) { ($0 << 8) | UInt32($1) } % 1_000_000
        return String(format: "%06u", value)
    }

    private static func transcript(label: String, profile: Data?) -> Data {
        guard let profile else {
            return Data("\(ProtocolDomains.namespace)/\(label)/v2".utf8)
        }
        return Data("\(ProtocolDomains.namespace)/\(label)/profiled/v2".utf8) + Data([UInt8(profile.count)]) + profile
    }
}
