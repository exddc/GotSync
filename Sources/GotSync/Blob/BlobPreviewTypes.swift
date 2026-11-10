import Foundation

/// A host-chosen, persisted 16-byte identity for one outgoing or incoming transfer.
@_spi(BlobPreview) public struct BlobTransferID: Hashable, Sendable {
    public let bytes: Data

    public init(bytes: Data) throws {
        guard bytes.count == 16 else {
            throw BlobError.invalidIdentifier
        }
        self.bytes = Data(bytes)
    }
}

/// The ledger class that refused new work. Accepted rows and files are never
/// evicted to make room; the host keeps its durable intent and retries.
@_spi(BlobPreview) public enum BlobCapacity: Equatable, Sendable {
    /// Library bytes would exceed the 64 MiB ledger.
    case libraryBytes
    /// 16 outgoing rows exist, in any state.
    case outgoingRows
    /// 8 incoming rows already hold or reserve bytes.
    case incomingRows
    /// 1,024 incoming descriptors are queued.
    case queuedDescriptors
    /// 4,000 objects are registered as available.
    case availableRegistry
    /// The volume would keep less than 512 MiB free.
    case diskFloor
}

@_spi(BlobPreview) public enum BlobError: Error, Equatable, Sendable {
    /// No active group session is bound.
    case notBound
    /// The route is not the bound group's route.
    case routeMismatch
    /// The binding changed while the work ran; nothing was committed.
    case staleBinding
    /// The same transfer ID was used with a different route, hash or descriptor.
    case transferMismatch
    /// The digest differs from the frozen descriptor; nothing was deleted.
    case staleConfirmation
    case capacity(BlobCapacity)
    case malformedDescriptor
    case unsupportedDescriptor(version: UInt8, flags: UInt8)
    /// The source no longer has the expected content hash.
    case sourceChanged
    case sourceUnreadable
    /// The image is empty, larger than 10 MiB or outside the validator's limits.
    case exceedsSyncLimits
    /// The validator could not read the image.
    case imageRejected
    /// An offered transfer is handed off or retired, never cancelled.
    case alreadyOffered
    case invalidIdentifier
    /// The library's storage could not be read or written.
    case storageUnavailable
    /// The relay does not offer blob storage.
    case relayUnsupported
}

/// Why an outgoing transfer stopped before it was ever offered.
@_spi(BlobPreview) public enum BlobOutgoingFailure: Equatable, Sendable {
    case sourceChanged
    case sourceUnreadable
    case exceedsSyncLimits
    case imageRejected
}

@_spi(BlobPreview) public struct BlobOutgoingStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Sealed and not yet complete on the relay.
        case uploading
        /// The descriptor is frozen. The host stores it with its record in one
        /// transaction and then calls `confirmHandoff` with `digest`.
        case readyForHandoff(descriptor: Data, digest: Data)
        /// The relay lost the object and it could not be rebuilt from the source.
        /// The descriptor is kept and never replaced.
        case repairRequired(descriptor: Data, digest: Data)
        case failed(BlobOutgoingFailure)
        /// The session that sealed it ended. An offered descriptor is still
        /// handed off with `confirmHandoff`; otherwise the host cancels it.
        case retired(descriptor: Data?, digest: Data?)
    }

    public let id: BlobTransferID
    public let route: BlobRoute
    public let contentHash: Data
    public let state: State
}

/// Why an incoming variant was rejected. Only this descriptor is affected.
@_spi(BlobPreview) public enum BlobRejection: Equatable, Sendable {
    case relayIntegrity
    case descriptorMismatch
    case imageRejected
}

@_spi(BlobPreview) public struct BlobIncomingStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case queued
        case fetching
        /// The relay does not hold the object now; the library asked for it and retries.
        case unavailable
        case rejected(BlobRejection)
        /// Verified content the host publishes, then confirms with `confirmPublished`.
        /// The file belongs to the library until then; the host copies or clones it.
        case awaitingPublish(file: URL, contentHash: Data, digest: Data)
        /// The session ended before the content was verified; nothing is kept.
        case retired
    }

    public let id: BlobTransferID
    public let route: BlobRoute
    public let objectID: Data
    public let digest: Data
    /// Whether the row belongs to a session that has ended.
    public let isRetired: Bool
    public let state: State
}

@_spi(BlobPreview) public struct BlobSummary: Equatable, Sendable {
    public var outgoingUploading = 0
    /// Distinct transfers refused for capacity since they last made progress.
    public var outgoingWaitingCapacity = 0
    public var outgoingOffered = 0
    public var outgoingRepairRequired = 0
    public var outgoingFailed = 0
    public var outgoingRetired = 0
    public var incomingQueued = 0
    public var incomingFetching = 0
    public var incomingUnavailable = 0
    public var incomingRejected = 0
    public var incomingVerified = 0
    public var incomingRetiredVerified = 0
    public var availableObjects = 0
    public var libraryBytes: Int64 = 0
    /// The relay answered that it offers no blob storage.
    public var relayUnsupported = false
    /// Unconfirmed rows keep the ledger at a cap, so new work is refused.
    public var hostBackpressure = false

    public init() {}
}

/// What the image validator read from an image's headers.
@_spi(BlobPreview) public struct BlobImageInfo: Equatable, Sendable {
    /// A uniform type identifier, such as `public.jpeg`.
    public let mediaType: String
    public let pixelWidth: UInt32
    public let pixelHeight: UInt32
}

/// The public fields of a v1 descriptor, for keying host variants by
/// `(route, objectID)`. The key is not exposed.
@_spi(BlobPreview) public struct BlobDescriptorInfo: Equatable, Sendable {
    public let objectID: Data
    public let contentHash: Data
    public let plaintextLength: UInt64
    public let image: BlobImageInfo
    public let digest: Data

    public init(descriptor: Data) throws {
        let decoded = try BlobDescriptor.decodeForService(descriptor)
        objectID = decoded.objectID
        contentHash = decoded.contentHash
        plaintextLength = decoded.plaintextLength
        image = BlobImageInfo(mediaType: decoded.mediaType, pixelWidth: decoded.pixelWidth, pixelHeight: decoded.pixelHeight)
        digest = BlobDescriptor.digest(of: descriptor)
    }
}

/// Host callbacks. They may be called from any task.
@_spi(BlobPreview) public struct BlobHostHooks: Sendable {
    /// A host-owned file whose content has `contentHash`, for re-uploading an
    /// object other members want. Return nil when none is held.
    public var verifiedContentURL: @Sendable (_ contentHash: Data) async -> URL?
    /// The host's own acceptance check on a received image, after the library's
    /// validator. Rejecting marks only this variant rejected.
    public var acceptsImage: @Sendable (_ file: URL, _ image: BlobImageInfo) async -> Bool

    public init(
        verifiedContentURL: @escaping @Sendable (_ contentHash: Data) async -> URL?,
        acceptsImage: @escaping @Sendable (_ file: URL, _ image: BlobImageInfo) async -> Bool = { _, _ in true }
    ) {
        self.verifiedContentURL = verifiedContentURL
        self.acceptsImage = acceptsImage
    }
}

extension BlobDescriptor {
    /// Decodes with the errors the service reports to the host.
    static func decodeForService(_ encoded: Data) throws -> BlobDescriptor {
        do {
            return try BlobDescriptor(decoding: encoded)
        } catch BlobCodecError.unsupportedDescriptor(let version, let flags) {
            throw BlobError.unsupportedDescriptor(version: version, flags: flags)
        } catch {
            throw BlobError.malformedDescriptor
        }
    }
}
