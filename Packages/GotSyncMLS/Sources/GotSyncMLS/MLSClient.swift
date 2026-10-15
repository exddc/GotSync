import CryptoKit
import Foundation
import GotSyncMLSBindings

public enum MLSClientError: Error {
    case invalidState
    case invalidDelivery
    case storageUnavailable
    case capacityReached
}

public struct MLSJoiningIdentity: Sendable {
    public let keyPackage: Data
    public let fingerprint: Data
}

public struct MLSDelivery: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case commit, application }
    public let group: Data
    public let epoch: UInt64
    public let kind: Kind
    public let payload: Data
    public let welcome: Data?
    public let keyPackageReference: Data?

    public init(group: Data, epoch: UInt64, kind: Kind, payload: Data, welcome: Data? = nil, keyPackageReference: Data? = nil) {
        self.group = group
        self.epoch = epoch
        self.kind = kind
        self.payload = payload
        self.welcome = welcome
        self.keyPackageReference = keyPackageReference
    }
}

public struct MLSInboxMessage: Codable, Equatable, Sendable {
    public let cursor: UInt64
    public let sender: Data
    public let plaintext: Data
}

struct ClientRecord: Codable {
    var state: Data
    var deviceID: Data
    var identity: IdentityRecord
    var group: Data?
    var epoch: UInt64 = 0
    var cursor: UInt64 = 0
    var pending: MLSDelivery?
    var pendingPlaintext: Data?
    var rejectedCommit: MLSDelivery?
    var rejectedApplicationCursors: [UInt64] = []
    var inbox: [MLSInboxMessage] = []
    var removed = false
}

struct IdentityRecord: Codable {
    var keyPackage: Data
    var fingerprint: Data
}

public actor MLSClient {
    private let store: MLSStore

    public init(directory: URL, deviceID: Data) throws {
        store = try MLSStore(directory: directory)
        try store.update { record in
            if let record {
                guard record.deviceID == deviceID else { throw MLSClientError.invalidState }
            } else {
                let identity = try createIdentity(deviceId: deviceID)
                record = ClientRecord(
                    state: Data(identity.state), deviceID: deviceID,
                    identity: IdentityRecord(keyPackage: Data(identity.keyPackage), fingerprint: Data(identity.fingerprint))
                )
            }
        }
    }

    public func joiningIdentity() throws -> MLSJoiningIdentity {
        let record = try store.read()
        guard record.group == nil else { throw MLSClientError.invalidState }
        return MLSJoiningIdentity(keyPackage: record.identity.keyPackage, fingerprint: record.identity.fingerprint)
    }

    public func fingerprint() throws -> Data { try store.read().identity.fingerprint }
    public func cursor() throws -> UInt64 { try store.read().cursor }
    public func epoch() throws -> UInt64 { try store.read().epoch }
    public func pendingDelivery() throws -> MLSDelivery? { try store.read().pending }
    public func inbox() throws -> [MLSInboxMessage] { try store.read().inbox }
    public func isRemoved() throws -> Bool { try store.read().removed }
    public func rejectedCommit() throws -> MLSDelivery? { try store.read().rejectedCommit }
    public func rejectedApplicationCursors() throws -> [UInt64] { try store.read().rejectedApplicationCursors }

    public func createGroup(id: Data) throws {
        try mutate { record in
            guard record.group == nil else { throw MLSClientError.invalidState }
            let transition = try GotSyncMLSBindings.createGroup(state: record.state, groupId: id)
            Self.apply(transition, to: &record)
            record.identity.keyPackage = Data()
        }
    }

    public func prepareAdd(keyPackage: Data, verifiedFingerprint: Data, reference: Data) throws -> MLSDelivery {
        try mutate { record in
            guard record.pending == nil, reference == Data(SHA256.hash(data: keyPackage)) else { throw MLSClientError.invalidState }
            let transition = try GotSyncMLSBindings.prepareAdd(state: record.state, keyPackage: keyPackage, verifiedFingerprint: verifiedFingerprint)
            Self.apply(transition, to: &record)
            let delivery = MLSDelivery(group: Data(transition.groupId), epoch: transition.epoch, kind: .commit, payload: Data(transition.output), welcome: transition.welcome, keyPackageReference: reference)
            record.pending = delivery
            return delivery
        }
    }

    public func prepareRemove(fingerprint: Data) throws -> MLSDelivery {
        try mutate { record in
            guard record.pending == nil else { throw MLSClientError.invalidState }
            let transition = try GotSyncMLSBindings.prepareRemove(state: record.state, memberFingerprint: fingerprint)
            Self.apply(transition, to: &record)
            let delivery = MLSDelivery(group: Data(transition.groupId), epoch: transition.epoch, kind: .commit, payload: Data(transition.output), welcome: nil, keyPackageReference: nil)
            record.pending = delivery
            return delivery
        }
    }

    public func prepareMessage(_ plaintext: Data) throws -> MLSDelivery {
        try mutate { record in
            guard record.pending == nil else { throw MLSClientError.invalidState }
            return try Self.seal(plaintext, in: &record)
        }
    }

    public func join(welcome: Data, group: Data, verifiedInviterFingerprint: Data, cursor: UInt64) throws {
        try mutate { record in
            guard record.group == nil else { throw MLSClientError.invalidState }
            let transition = try joinGroup(state: record.state, welcome: welcome, expectedGroupId: group, inviterFingerprint: verifiedInviterFingerprint)
            Self.apply(transition, to: &record)
            record.cursor = cursor
            record.identity.keyPackage = Data()
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
                    guard delivery.kind == .application, error != .InvalidState else { throw error }
                    record.rejectedApplicationCursors.append(cursor)
                    record.rejectedApplicationCursors = Array(record.rejectedApplicationCursors.suffix(64))
                    record.cursor = cursor
                    return
                }
                let expectedEpoch = delivery.epoch + (delivery.kind == .commit ? 1 : 0)
                guard transition.epoch == expectedEpoch,
                      (transition.sender == nil) == (delivery.kind == .commit)
                else { throw MLSClientError.invalidDelivery }
                Self.apply(transition, to: &record)
                if let sender = transition.sender {
                    guard record.inbox.count < 1000 else { throw MLSClientError.capacityReached }
                    record.inbox.append(MLSInboxMessage(cursor: cursor, sender: sender, plaintext: transition.output))
                }
                if transition.removed {
                    record.removed = true
                    record.state = Data()
                    record.pending = nil
                    record.pendingPlaintext = nil
                } else if let retryPlaintext {
                    _ = try Self.seal(retryPlaintext, in: &record)
                }
            }
            record.cursor = cursor
        }
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

    private static func apply(_ transition: MlsTransition, to record: inout ClientRecord) {
        record.state = Data(transition.state)
        record.group = Data(transition.groupId)
        record.epoch = transition.epoch
    }
}
