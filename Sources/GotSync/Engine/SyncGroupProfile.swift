import Foundation
import GotSyncMLS

/// The payload format a group's application messages carry.
///
/// Only formats that `SyncEngine` actually replicates can be selected, so a
/// profile never claims data compatibility the engine does not provide.
public struct SyncPayloadSchema: Equatable, Hashable, Sendable {
    public let identifier: String
    public let version: UInt16

    /// The title and completion task operations of `ReplicatedTask`.
    public static let taskReplica = SyncPayloadSchema(identifier: "gotsync.task-replica", version: 2)

    init(identifier: String, version: UInt16) {
        self.identifier = identifier
        self.version = version
    }
}

public enum SyncGroupProfileError: Error, Equatable, Sendable {
    case invalidApplication
    case invalidMemberLimit
    case invalidDescriptor
}

/// What a group is for and how many devices it admits at once.
///
/// A profiled group stores its descriptor in an MLS GroupContext extension,
/// and pairing binds the descriptor into the commitment and safety code, so
/// devices with different applications, schemas, or member limits refuse to
/// pair. `legacyTaskDemo` describes groups without a descriptor, which
/// earlier builds create, with eight members.
public struct SyncGroupProfile: Equatable, Hashable, Sendable {
    public static let legacyMemberLimit = 8
    /// The most members any group can have, enforced by the MLS library and
    /// the relay.
    public static let supportedMemberCeiling = MLSClient.memberCeiling
    static let maximumLabelBytes = 64
    static let maximumDescriptorBytes = 1 + 2 * (1 + maximumLabelBytes) + 2 + 1
    private static let descriptorFormat: UInt8 = 1

    public static let legacyTaskDemo = SyncGroupProfile(
        unchecked: nil, schema: .taskReplica, memberLimit: legacyMemberLimit
    )

    /// `nil` for the legacy profile.
    public let application: String?
    public let schema: SyncPayloadSchema
    public let memberLimit: Int

    public var isLegacy: Bool { application == nil }

    /// A profile for new groups of `application`, a lowercase identifier such
    /// as a reverse-DNS name. `memberLimit` must be between 2 and
    /// `supportedMemberCeiling`.
    public init(application: String, schema: SyncPayloadSchema, memberLimit: Int) throws {
        guard Self.isLabel(application) else { throw SyncGroupProfileError.invalidApplication }
        guard (2...Self.supportedMemberCeiling).contains(memberLimit) else {
            throw SyncGroupProfileError.invalidMemberLimit
        }
        self.init(unchecked: application, schema: schema, memberLimit: memberLimit)
    }

    private init(unchecked application: String?, schema: SyncPayloadSchema, memberLimit: Int) {
        self.application = application
        self.schema = schema
        self.memberLimit = memberLimit
    }

    /// The canonical bytes stored in the group and bound into pairing, or
    /// `nil` for the legacy profile.
    var descriptor: Data? {
        guard let application else { return nil }
        var bytes = Data([Self.descriptorFormat, UInt8(application.utf8.count)])
        bytes.append(contentsOf: application.utf8)
        bytes.append(UInt8(schema.identifier.utf8.count))
        bytes.append(contentsOf: schema.identifier.utf8)
        bytes.append(contentsOf: [UInt8(schema.version >> 8), UInt8(schema.version & 0xff), UInt8(memberLimit)])
        return bytes
    }

    /// Decodes a canonical descriptor; the legacy profile has none.
    init(descriptor: Data) throws {
        let bytes = [UInt8](descriptor)
        var index = 1
        func label() throws -> String {
            guard index < bytes.count else { throw SyncGroupProfileError.invalidDescriptor }
            let end = index + 1 + Int(bytes[index])
            guard end <= bytes.count, let text = String(bytes: bytes[(index + 1)..<end], encoding: .ascii),
                  Self.isLabel(text)
            else { throw SyncGroupProfileError.invalidDescriptor }
            index = end
            return text
        }
        guard bytes.first == Self.descriptorFormat else { throw SyncGroupProfileError.invalidDescriptor }
        let application = try label()
        let schema = try label()
        guard bytes.count == index + 3 else { throw SyncGroupProfileError.invalidDescriptor }
        let version = UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
        let limit = Int(bytes[index + 2])
        guard version > 0, (2...Self.supportedMemberCeiling).contains(limit) else {
            throw SyncGroupProfileError.invalidDescriptor
        }
        self.init(
            unchecked: application,
            schema: SyncPayloadSchema(identifier: schema, version: version),
            memberLimit: limit
        )
    }

    private static func isLabel(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard let first = bytes.first, bytes.count <= maximumLabelBytes,
              isLowercaseAlphanumeric(first)
        else { return false }
        return bytes.allSatisfy { isLowercaseAlphanumeric($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "-") }
    }

    private static func isLowercaseAlphanumeric(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }
}
