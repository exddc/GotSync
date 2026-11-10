import Foundation
import ImageIO

/// The provisional image policy: header limits plus a frame-0 thumbnail decode.
/// These are policy inputs, not a measured memory ceiling.
enum BlobImageValidator {
    static let maxBytes: UInt64 = BlobFormat.maxPlaintextLength
    static let allowedTypes: Set<String> = [
        "public.jpeg", "public.png", "public.heic", "public.heif",
        "com.compuserve.gif", "public.tiff", "org.webmproject.webp",
    ]
    static let maxFrames = 64
    static let maxSide = 8_192
    static let maxFramePixels = 40_000_000
    static let maxTotalPixels = 160_000_000
    static let thumbnailMaxPixelSize = 1_600

    enum Failure: Error, Equatable {
        case unreadable
        case exceedsLimits
    }

    static func validate(_ url: URL) throws -> BlobImageInfo {
        let size = try fileSize(url)
        guard size >= 1, size <= maxBytes else {
            throw Failure.exceedsLimits
        }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else {
            throw Failure.unreadable
        }
        guard let type = CGImageSourceGetType(source) as String? else {
            throw Failure.unreadable
        }
        guard allowedTypes.contains(type) else {
            throw Failure.exceedsLimits
        }
        let frames = CGImageSourceGetCount(source)
        guard frames >= 1 else {
            throw Failure.unreadable
        }
        guard frames <= maxFrames else {
            throw Failure.exceedsLimits
        }
        var total = 0
        var first: (width: Int, height: Int)?
        for index in 0..<frames {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, options) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width >= 1, height >= 1
            else {
                throw Failure.unreadable
            }
            guard width <= maxSide, height <= maxSide, width * height <= maxFramePixels else {
                throw Failure.exceedsLimits
            }
            total += width * height
            guard total <= maxTotalPixels else {
                throw Failure.exceedsLimits
            }
            first = first ?? (width, height)
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize,
            kCGImageSourceShouldCache: false,
        ] as CFDictionary
        guard let first, CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) != nil else {
            throw Failure.unreadable
        }
        return BlobImageInfo(mediaType: type, pixelWidth: UInt32(first.width), pixelHeight: UInt32(first.height))
    }

    static func fileSize(_ url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size >= 0 else {
            throw Failure.unreadable
        }
        return UInt64(size)
    }
}

/// A process-wide FIFO gate admitting one holder at a time.
actor BlobWorkGate {
    /// Concurrent off-actor workers per process: seal 1, open 1, validation 1.
    static let seal = BlobWorkGate()
    static let open = BlobWorkGate()
    static let validation = BlobWorkGate()

    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        guard held else {
            held = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            held = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
