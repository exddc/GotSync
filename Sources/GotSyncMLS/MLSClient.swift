import CryptoKit
import Foundation
import GotSyncMLSBindings

public enum MLSClientError: Error {
    case invalidState
    case invalidDelivery
    case storageUnavailable
    case capacityReached
    /// The group's profile differs from the expected one or is malformed.
    case unsupportedGroupProfile
}

public struct MLSJoiningIdentity: Sendable {
    public let keyPackage: Data
    public let fingerprint: Data
}

public struct MLSDelivery: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case commit, application, proposal }
    public let group: Data
    public let epoch: UInt64
    public let kind: Kind
    public let payload: Data
    public let welcome: Data?
    public let keyPackageReference: Data?
    public let addWriter: Data?
    public let removeWriter: Data?

    public init(group: Data, epoch: UInt64, kind: Kind, payload: Data, welcome: Data? = nil, keyPackageReference: Data? = nil, addWriter: Data? = nil, removeWriter: Data? = nil) {
        self.group = group
        self.epoch = epoch
        self.kind = kind
        self.payload = payload
        self.welcome = welcome
        self.keyPackageReference = keyPackageReference
        self.addWriter = addWriter
        self.removeWriter = removeWriter
    }
}

public struct MLSInboxMessage: Codable, Equatable, Sendable {
    public let cursor: UInt64
    public let sender: Data
    public let plaintext: Data
}

/// A tracked application message of this member as it landed in the log.
/// The log never returns a member's own messages to its inbox, so this is
/// how the member learns where they landed.
public struct MLSSentMessage: Codable, Equatable, Sendable {
    public static let retained = 64

    public let cursor: UInt64
    public let digest: Data
}

public struct MLSMember: Equatable, Sendable {
    public let deviceID: Data
    public let fingerprint: Data
    public let writerHash: Data
}

struct ClientRecord: Codable {
    var state: Data
    var deviceID: Data
    var identity: IdentityRecord
    var writerToken: Data
    var removalAuthorization: Data?
    var group: Data?
    var epoch: UInt64 = 0
    var cursor: UInt64 = 0
    var pending: MLSDelivery?
    var pendingPlaintext: Data?
    var rejectedCommit: MLSDelivery?
    var rejectedApplicationCursors: [UInt64] = []
    var inbox: [MLSInboxMessage] = []
    var removed = false
    var departures: [Data]?
    var pendingTracked: Bool?
    var sent: [MLSSentMessage]?
    var withdrawnWriter: Data?
    /// Current members that sent this member an authenticated application
    /// message, kept after the message leaves the inbox.
    var spoke: [Data]?
}

struct IdentityRecord: Codable {
    var fingerprint: Data
}

public actor MLSClient {
    /// The most members a group can have, whatever its profile allows.
    public static let memberCeiling = Int(supportedMemberCeiling())

    private let store: MLSStore

    public init(directory: URL, deviceID: Data, stateKey: MLSStateKeyProvider) throws {
        store = try MLSStore(directory: directory, stateKey: stateKey)
        try store.update { record in
            if var existing = record {
                guard existing.deviceID == deviceID else { throw MLSClientError.invalidState }
                if existing.group != nil, !existing.removed, !existing.inbox.isEmpty {
                    let current = try GotSyncMLSBindings.members(state: existing.state).map(\.fingerprint)
                    let speakers = Set(existing.spoke ?? []).union(existing.inbox.map(\.sender))
                    existing.spoke = current.filter(speakers.contains)
                    record = existing
                }
            } else {
                let identity = try createIdentity(deviceId: deviceID)
                record = ClientRecord(
                    state: Data(identity.state), deviceID: deviceID,
                    identity: IdentityRecord(fingerprint: Data(identity.fingerprint)),
                    writerToken: Data(identity.writerToken)
                )
            }
        }
    }

    /// A KeyPackage for joining a group with `profile`, or a legacy group
    /// when `profile` is `nil`.
    public func joiningIdentity(profile: Data? = nil) throws -> MLSJoiningIdentity {
        try mutate { record in
            guard record.group == nil else { throw MLSClientError.invalidState }
            let transition = try publishKeyPackage(state: record.state, profile: profile)
            record.state = Data(transition.state)
            return MLSJoiningIdentity(keyPackage: Data(transition.output), fingerprint: record.identity.fingerprint)
        }
    }

    public func fingerprint() throws -> Data { try store.read().identity.fingerprint }
    public func transportAuthorization() throws -> Data {
        let record = try store.read()
        guard !record.removed, record.writerToken.count == 32 else { throw MLSClientError.invalidState }
        return record.writerToken
    }
    public func removalAuthorization() throws -> Data? { try store.read().removalAuthorization }
    public func members() throws -> [MLSMember] {
        try GotSyncMLSBindings.members(state: store.read().state).map {
            MLSMember(deviceID: $0.deviceId, fingerprint: $0.fingerprint, writerHash: $0.writerHash)
        }
    }
    public func group() throws -> Data? { try store.read().group }
    public func cursor() throws -> UInt64 { try store.read().cursor }
    public func epoch() throws -> UInt64 { try store.read().epoch }
    public func pendingDelivery() throws -> MLSDelivery? { try store.read().pending }
    public func inbox() throws -> [MLSInboxMessage] { try store.read().inbox }
    public func isRemoved() throws -> Bool { try store.read().removed }
    public func rejectedCommit() throws -> MLSDelivery? { try store.read().rejectedCommit }
    public func departures() throws -> [Data] { try store.read().departures ?? [] }
    public func rejectedApplicationCursors() throws -> [UInt64] { try store.read().rejectedApplicationCursors }
    /// The last `MLSSentMessage.retained` tracked messages that landed,
    /// oldest first, each with the SHA-256 digest of its plaintext.
    public func sentMessages() throws -> [MLSSentMessage] { try store.read().sent ?? [] }

    /// The group's profile descriptor, or `nil` for a legacy group.
    public func groupProfile() throws -> Data? {
        let record = try store.read()
        guard record.group != nil, !record.removed else { throw MLSClientError.invalidState }
        do {
            return try GotSyncMLSBindings.groupProfile(state: record.state)
        } catch MlsError.InvalidInput {
            throw MLSClientError.unsupportedGroupProfile
        }
    }

    public func createGroup(id: Data, profile: Data? = nil) throws {
        try mutate { record in
            guard record.group == nil else { throw MLSClientError.invalidState }
            let transition = try GotSyncMLSBindings.createGroup(state: record.state, groupId: id, profile: profile)
            Self.apply(transition, to: &record)
        }
    }

    public func prepareAdd(keyPackage: Data, verifiedFingerprint: Data, reference: Data) throws -> MLSDelivery {
        try mutate { record in
            guard record.pending == nil, reference == Data(SHA256.hash(data: keyPackage)) else { throw MLSClientError.invalidState }
            let transition = try GotSyncMLSBindings.prepareAdd(state: record.state, keyPackage: keyPackage, verifiedFingerprint: verifiedFingerprint)
            Self.apply(transition, to: &record)
            let delivery = MLSDelivery(group: Data(transition.groupId), epoch: transition.epoch, kind: .commit, payload: Data(transition.output), welcome: transition.welcome, keyPackageReference: reference, addWriter: transition.addedWriter)
            record.pending = delivery
            return delivery
        }
    }

    public func prepareRemove(fingerprint: Data) throws -> MLSDelivery {
        try mutate { record in
            guard record.pending == nil else { throw MLSClientError.invalidState }
            let transition = try GotSyncMLSBindings.prepareRemove(state: record.state, memberFingerprint: fingerprint)
            Self.apply(transition, to: &record)
            let delivery = MLSDelivery(group: Data(transition.groupId), epoch: transition.epoch, kind: .commit, payload: Data(transition.output), removeWriter: transition.removedWriter)
            record.pending = delivery
            return delivery
        }
    }

    public func prepareLeave() throws -> MLSDelivery {
        try mutate { record in
            guard record.pending == nil else { throw MLSClientError.invalidState }
            let transition = try GotSyncMLSBindings.prepareLeave(state: record.state)
            Self.apply(transition, to: &record)
            let delivery = MLSDelivery(group: Data(transition.groupId), epoch: transition.epoch, kind: .proposal, payload: Data(transition.output))
            record.pending = delivery
            return delivery
        }
    }

    public func prepareMessage(_ plaintext: Data, tracked: Bool = false) throws -> MLSDelivery {
        try mutate { record in
            guard record.pending == nil else { throw MLSClientError.invalidState }
            record.pendingTracked = tracked ? true : nil
            return try Self.seal(plaintext, in: &record)
        }
    }

    /// Clears a pending application message after the relay accepted it at
    /// `cursor`, when the inbox is too full to process the log up to that
    /// message. A tracked message is listed in `sentMessages()` as if it had
    /// been processed. The log copy is later recorded as a rejected cursor,
    /// like any message this member cannot decrypt.
    public func confirmAcceptedApplication(_ delivery: MLSDelivery, cursor: UInt64) throws {
        try mutate { record in
            guard delivery.kind == .application else { throw MLSClientError.invalidState }
            guard record.pending == delivery else { return }
            Self.recordTrackedDelivery(at: cursor, in: &record)
            record.pending = nil
            record.pendingPlaintext = nil
        }
    }

    /// Joins only a group whose profile equals `expectedProfile`.
    public func join(welcome: Data, group: Data, verifiedInviterFingerprint: Data, cursor: UInt64, expectedProfile: Data? = nil) throws {
        try mutate { record in
            guard record.group == nil else { throw MLSClientError.invalidState }
            let transition: MlsTransition
            do {
                transition = try joinGroup(
                    state: record.state, welcome: welcome, expectedGroupId: group,
                    inviterFingerprint: verifiedInviterFingerprint, expectedProfile: expectedProfile
                )
            } catch MlsError.ProfileMismatch {
                throw MLSClientError.unsupportedGroupProfile
            }
            Self.apply(transition, to: &record)
            record.cursor = cursor
        }
    }

    public func process(_ delivery: MLSDelivery, cursor: UInt64) throws {
        try mutate { record in
            guard delivery.group == record.group, delivery.epoch < (1 << 53), cursor < (1 << 53) else {
                throw MLSClientError.invalidDelivery
            }
            if cursor <= record.cursor { return }
            guard delivery.epoch <= record.epoch else { throw MLSClientError.invalidDelivery }
            if let pending = record.pending, delivery.payload == pending.payload,
               delivery.kind == pending.kind, delivery.epoch == pending.epoch {
                if pending.kind == .commit {
                    Self.apply(try acceptCommit(state: record.state, acceptedCommit: delivery.payload), to: &record)
                    try Self.pruneMemberRecords(in: &record)
                } else if pending.kind == .application {
                    Self.recordTrackedDelivery(at: cursor, in: &record)
                }
                record.pending = nil
                record.pendingPlaintext = nil
            } else {
                let retryPlaintext = delivery.kind == .commit ? record.pendingPlaintext : nil
                if delivery.kind == .commit, let pending = record.pending {
                    if pending.kind == .commit {
                        Self.apply(try discardCommit(state: record.state), to: &record)
                        record.rejectedCommit = pending
                    }
                    record.pending = nil
                    record.pendingPlaintext = nil
                }
                let transition: MlsTransition
                do {
                    transition = try receiveMessage(state: record.state, message: delivery.payload)
                } catch let error as MlsError {
                    guard delivery.kind != .commit, error != .InvalidState else { throw error }
                    record.rejectedApplicationCursors.append(cursor)
                    record.rejectedApplicationCursors = Array(record.rejectedApplicationCursors.suffix(64))
                    record.cursor = cursor
                    return
                }
                let expectedEpoch = delivery.epoch + (delivery.kind == .commit ? 1 : 0)
                guard transition.epoch == expectedEpoch,
                      (transition.sender != nil) == (delivery.kind == .application),
                      (transition.departed != nil) == (delivery.kind == .proposal)
                else { throw MLSClientError.invalidDelivery }
                Self.apply(transition, to: &record)
                if let departed = transition.departed, !(record.departures ?? []).contains(departed) {
                    record.departures = Array(((record.departures ?? []) + [departed]).suffix(Self.memberCeiling))
                }
                if let sender = transition.sender {
                    guard record.inbox.count < 1000 else { throw MLSClientError.capacityReached }
                    record.inbox.append(MLSInboxMessage(cursor: cursor, sender: sender, plaintext: transition.output))
                    if !(record.spoke ?? []).contains(sender) {
                        record.spoke = Array(((record.spoke ?? []) + [sender]).suffix(Self.memberCeiling))
                    }
                }
                if transition.removed {
                    record.removed = true
                    record.removalAuthorization = record.writerToken
                    record.state = Data()
                    record.writerToken = Data()
                    record.pending = nil
                    record.pendingPlaintext = nil
                    record.departures = nil
                } else {
                    if delivery.kind == .commit {
                        try Self.pruneMemberRecords(in: &record)
                    }
                    if let retryPlaintext {
                        _ = try Self.seal(retryPlaintext, in: &record)
                    }
                }
            }
            record.cursor = cursor
        }
    }

    /// Marks the pending Add as withdrawn: if it lands, its member is to be
    /// removed. The mark is kept until `clearWithdrawnAdd()`.
    public func withdrawPendingAdd() throws {
        try mutate { record in
            guard let pending = record.pending, pending.kind == .commit, pending.welcome != nil,
                  let writer = pending.addWriter
            else { return }
            record.withdrawnWriter = writer
        }
    }

    /// Members that sent an authenticated application message, including
    /// senders of messages still in the inbox of state written before this
    /// record existed.
    public func spokenMembers() throws -> Set<Data> {
        let record = try store.read()
        return Set(record.spoke ?? []).union(record.inbox.map(\.sender))
    }

    /// The writer hash of a withdrawn Add, if one is marked.
    public func withdrawnAddWriter() throws -> Data? { try store.read().withdrawnWriter }

    public func clearWithdrawnAdd() throws {
        try mutate { record in record.withdrawnWriter = nil }
    }

    public func rejectAddForUnavailableKeyPackage(commit: Data, rejectedEpoch: UInt64) throws {
        try mutate { record in
            guard let pending = record.pending, pending.kind == .commit,
                  pending.welcome != nil, pending.payload == commit,
                  pending.epoch == rejectedEpoch, record.epoch == rejectedEpoch
            else { throw MLSClientError.invalidDelivery }
            Self.apply(try discardCommit(state: record.state), to: &record)
            record.rejectedCommit = pending
            record.pending = nil
        }
    }

    public func acknowledgeInbox(through cursor: UInt64) throws {
        try mutate(allowRemoved: true) { record in record.inbox.removeAll { $0.cursor <= cursor } }
    }

    public func confirmRemovalAcknowledged() throws {
        try mutate(allowRemoved: true) { record in record.removalAuthorization = nil }
    }

    private func mutate<T>(allowRemoved: Bool = false, _ body: (inout ClientRecord) throws -> T) throws -> T {
        try store.update { optional in
            guard var record = optional else { throw MLSClientError.invalidState }
            guard allowRemoved || !record.removed else { throw MLSClientError.invalidState }
            let result = try body(&record)
            optional = record
            return result
        }
    }

    private static func seal(_ plaintext: Data, in record: inout ClientRecord) throws -> MLSDelivery {
        let transition = try sealMessage(state: record.state, plaintext: plaintext)
        apply(transition, to: &record)
        let delivery = MLSDelivery(group: transition.groupId, epoch: transition.epoch, kind: .application, payload: transition.output, welcome: nil, keyPackageReference: nil)
        record.pending = delivery
        record.pendingPlaintext = plaintext
        return delivery
    }

    private static func recordTrackedDelivery(at cursor: UInt64, in record: inout ClientRecord) {
        guard record.pendingTracked == true, let plaintext = record.pendingPlaintext else { return }
        let sent = MLSSentMessage(cursor: cursor, digest: Data(SHA256.hash(data: plaintext)))
        record.sent = Array(((record.sent ?? []) + [sent]).suffix(MLSSentMessage.retained))
    }

    private static func pruneMemberRecords(in record: inout ClientRecord) throws {
        guard record.departures != nil || record.spoke != nil else { return }
        let current = try GotSyncMLSBindings.members(state: record.state).map(\.fingerprint)
        record.departures = record.departures?.filter(current.contains)
        record.spoke = record.spoke?.filter(current.contains)
    }

    private static func apply(_ transition: MlsTransition, to record: inout ClientRecord) {
        record.state = Data(transition.state)
        record.group = Data(transition.groupId)
        record.epoch = transition.epoch
    }
}
