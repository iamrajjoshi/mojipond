import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct LibraryThumbnailLimits: Equatable, Sendable {
    var maximumSourceBytes: Int64 = 25 * 1_024 * 1_024
    var maximumPixelWidth = 4_096
    var maximumPixelHeight = 4_096
    var maximumPixelsPerFrame: Int64 = 16_777_216
    var maximumFrameCount = 256
    var maximumTotalAnimationPixels: Int64 = 200_000_000
    var thumbnailPixelSize = 256
    var maximumThumbnailBytes: Int64 = 2 * 1_024 * 1_024

    static let `default` = Self()
}

enum LibraryThumbnailError: Error, Equatable, LocalizedError, Sendable {
    case notRegularFile
    case emptyFile
    case sourceTooLarge(actual: Int64, limit: Int64)
    case notImage
    case incompleteImage
    case unsupportedType(String)
    case invalidFrameCount(actual: Int, limit: Int)
    case missingDimensions(frame: Int)
    case dimensionsTooLarge(
        width: Int,
        height: Int,
        maximumWidth: Int,
        maximumHeight: Int
    )
    case tooManyPixels(actual: Int64, limit: Int64)
    case animationPixelBudgetExceeded(limit: Int64)
    case cannotDecodeThumbnail
    case cannotEncodeThumbnail
    case thumbnailTooLarge(actual: Int64, limit: Int64)
    case unsafeCacheDirectory

    var errorDescription: String? {
        switch self {
        case .notRegularFile:
            "The thumbnail source is not a regular file."
        case .emptyFile:
            "The thumbnail source is empty."
        case let .sourceTooLarge(actual, limit):
            "The thumbnail source is \(actual) bytes; the limit is \(limit) bytes."
        case .notImage:
            "The thumbnail source is not a supported image."
        case .incompleteImage:
            "The thumbnail source is incomplete."
        case let .unsupportedType(type):
            "The thumbnail source type \(type) is unsupported."
        case let .invalidFrameCount(actual, limit):
            "The thumbnail source has \(actual) frames; the limit is \(limit)."
        case let .missingDimensions(frame):
            "Thumbnail frame \(frame) has no valid dimensions."
        case let .dimensionsTooLarge(width, height, maximumWidth, maximumHeight):
            "Thumbnail frame dimensions \(width)×\(height) exceed \(maximumWidth)×\(maximumHeight)."
        case let .tooManyPixels(actual, limit):
            "A thumbnail frame has \(actual) pixels; the limit is \(limit)."
        case let .animationPixelBudgetExceeded(limit):
            "The thumbnail source exceeds the \(limit)-pixel animation budget."
        case .cannotDecodeThumbnail:
            "MojiPond could not decode a static thumbnail."
        case .cannotEncodeThumbnail:
            "MojiPond could not encode the static thumbnail."
        case let .thumbnailTooLarge(actual, limit):
            "The generated thumbnail is \(actual) bytes; the limit is \(limit) bytes."
        case .unsafeCacheDirectory:
            "The thumbnail cache directory is unsafe."
        }
    }
}

/// An immutable, fully-decoded image that can safely cross from the thumbnail
/// worker to SwiftUI. `CGImage` instances are immutable after creation.
struct LibraryThumbnail: @unchecked Sendable {
    let cgImage: CGImage

    var pixelWidth: Int {
        cgImage.width
    }

    var pixelHeight: Int {
        cgImage.height
    }
}

protocol LibraryThumbnailLoading: Sendable {
    func thumbnail(for sourceURL: URL) async throws -> LibraryThumbnail
}

protocol LibraryThumbnailServing:
    LibraryThumbnailLoading,
    Sendable
{
    func invalidate(sourceURL: URL) async throws
    func reconcile(retaining sourceURLs: Set<URL>) async throws
}

protocol LibraryThumbnailRendering: Sendable {
    func render(
        sourceURL: URL,
        limits: LibraryThumbnailLimits
    ) throws -> LibraryThumbnail
}

struct ImageIOLibraryThumbnailRenderer: LibraryThumbnailRendering {
    func render(
        sourceURL: URL,
        limits: LibraryThumbnailLimits
    ) throws -> LibraryThumbnail {
        let values = try sourceURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard
            values.isRegularFile == true,
            values.isSymbolicLink != true
        else {
            throw LibraryThumbnailError.notRegularFile
        }

        let byteCount = Int64(values.fileSize ?? 0)
        guard byteCount > 0 else {
            throw LibraryThumbnailError.emptyFile
        }
        guard byteCount <= limits.maximumSourceBytes else {
            throw LibraryThumbnailError.sourceTooLarge(
                actual: byteCount,
                limit: limits.maximumSourceBytes
            )
        }
        guard
            let source = CGImageSourceCreateWithURL(
                sourceURL as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary
            )
        else {
            throw LibraryThumbnailError.notImage
        }
        guard CGImageSourceGetStatus(source) == .statusComplete else {
            throw LibraryThumbnailError.incompleteImage
        }
        guard let sourceTypeIdentifier = CGImageSourceGetType(source) else {
            throw LibraryThumbnailError.notImage
        }
        let typeIdentifier = sourceTypeIdentifier as String
        let allowedTypes = [
            UTType.png.identifier,
            UTType.jpeg.identifier,
            UTType.gif.identifier,
            UTType.webP.identifier
        ]
        guard allowedTypes.contains(typeIdentifier) else {
            throw LibraryThumbnailError.unsupportedType(typeIdentifier)
        }

        let frameCount = CGImageSourceGetCount(source)
        guard
            frameCount > 0,
            frameCount <= limits.maximumFrameCount
        else {
            throw LibraryThumbnailError.invalidFrameCount(
                actual: frameCount,
                limit: limits.maximumFrameCount
            )
        }

        var totalPixels: Int64 = 0
        for frame in 0..<frameCount {
            guard
                let properties = CGImageSourceCopyPropertiesAtIndex(
                    source,
                    frame,
                    nil
                ) as? [CFString: Any],
                let width = (
                    properties[kCGImagePropertyPixelWidth] as? NSNumber
                )?.intValue,
                let height = (
                    properties[kCGImagePropertyPixelHeight] as? NSNumber
                )?.intValue,
                width > 0,
                height > 0
            else {
                throw LibraryThumbnailError.missingDimensions(frame: frame)
            }
            guard
                width <= limits.maximumPixelWidth,
                height <= limits.maximumPixelHeight
            else {
                throw LibraryThumbnailError.dimensionsTooLarge(
                    width: width,
                    height: height,
                    maximumWidth: limits.maximumPixelWidth,
                    maximumHeight: limits.maximumPixelHeight
                )
            }

            let pixels = Int64(width) * Int64(height)
            guard pixels <= limits.maximumPixelsPerFrame else {
                throw LibraryThumbnailError.tooManyPixels(
                    actual: pixels,
                    limit: limits.maximumPixelsPerFrame
                )
            }
            let (newTotal, overflow) =
                totalPixels.addingReportingOverflow(pixels)
            guard
                !overflow,
                newTotal <= limits.maximumTotalAnimationPixels
            else {
                throw LibraryThumbnailError.animationPixelBudgetExceeded(
                    limit: limits.maximumTotalAnimationPixels
                )
            }
            totalPixels = newTotal
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: limits.thumbnailPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard
            let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            )
        else {
            throw LibraryThumbnailError.cannotDecodeThumbnail
        }
        return LibraryThumbnail(cgImage: cgImage)
    }
}

struct LibraryThumbnailCacheMetrics: Equatable, Sendable {
    var memoryHits = 0
    var diskHits = 0
    var renders = 0
}

struct LibraryThumbnailCacheEntryCounts: Equatable, Sendable {
    let memory: Int
    let disk: Int
}

actor LibraryThumbnailPipeline: LibraryThumbnailServing {
    static let shared = LibraryThumbnailPipeline(
        rootURL: defaultCacheRoot()
    )

    private struct SourceFingerprint: Sendable {
        let sourceIdentifier: String
        let cacheKey: String
    }

    private struct InFlightRender: Sendable {
        let id: UUID
        let task: Task<LibraryThumbnail, any Error>
    }

    private let rootURL: URL
    private let maximumCacheBytes: Int64
    private let maximumMemoryEntries: Int
    private let limits: LibraryThumbnailLimits
    private let renderer: any LibraryThumbnailRendering
    private let fileManager: FileManager

    private var memoryCache: [String: LibraryThumbnail] = [:]
    private var memoryOrder: [String] = []
    private var inFlight: [String: InFlightRender] = [:]
    private var cacheMetrics = LibraryThumbnailCacheMetrics()

    init(
        rootURL: URL,
        maximumCacheBytes: Int64 = 32 * 1_024 * 1_024,
        maximumMemoryEntries: Int = 128,
        limits: LibraryThumbnailLimits = .default,
        renderer: any LibraryThumbnailRendering =
            ImageIOLibraryThumbnailRenderer(),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.maximumCacheBytes = maximumCacheBytes
        self.maximumMemoryEntries = maximumMemoryEntries
        self.limits = limits
        self.renderer = renderer
        self.fileManager = fileManager
    }

    func thumbnail(for sourceURL: URL) async throws -> LibraryThumbnail {
        let fingerprint = try makeFingerprint(for: sourceURL)
        if let cached = memoryCache[fingerprint.cacheKey] {
            cacheMetrics.memoryHits += 1
            touchMemoryKey(fingerprint.cacheKey)
            return cached
        }

        if let cached = try loadDiskThumbnail(
            forKey: fingerprint.cacheKey
        ) {
            cacheMetrics.diskHits += 1
            insertIntoMemory(cached, forKey: fingerprint.cacheKey)
            return cached
        }

        let operation: InFlightRender
        if let existing = inFlight[fingerprint.cacheKey] {
            operation = existing
        } else {
            let renderer = self.renderer
            let limits = self.limits
            let sourceURL = sourceURL.standardizedFileURL
            let created = Task.detached(priority: .userInitiated) {
                try renderer.render(
                    sourceURL: sourceURL,
                    limits: limits
                )
            }
            let createdOperation = InFlightRender(
                id: UUID(),
                task: created
            )
            inFlight[fingerprint.cacheKey] = createdOperation
            operation = createdOperation
        }

        do {
            let thumbnail = try await operation.task.value
            if inFlight[fingerprint.cacheKey]?.id == operation.id {
                inFlight[fingerprint.cacheKey] = nil
                cacheMetrics.renders += 1
                try store(
                    thumbnail,
                    forKey: fingerprint.cacheKey,
                    sourceIdentifier: fingerprint.sourceIdentifier
                )
                removeOldMemoryEntries(
                    for: fingerprint.sourceIdentifier,
                    keeping: fingerprint.cacheKey
                )
            } else if let cached = memoryCache[fingerprint.cacheKey] {
                return cached
            } else {
                throw CancellationError()
            }
            insertIntoMemory(
                thumbnail,
                forKey: fingerprint.cacheKey
            )
            return thumbnail
        } catch {
            if inFlight[fingerprint.cacheKey]?.id == operation.id {
                inFlight[fingerprint.cacheKey] = nil
            }
            throw error
        }
    }

    func metrics() -> LibraryThumbnailCacheMetrics {
        cacheMetrics
    }

    func entryCounts() throws -> LibraryThumbnailCacheEntryCounts {
        let diskCount: Int
        if fileManager.fileExists(atPath: rootURL.path) {
            diskCount = try cacheEntries(in: preparedRoot()).count
        } else {
            diskCount = 0
        }
        return LibraryThumbnailCacheEntryCounts(
            memory: memoryCache.count,
            disk: diskCount
        )
    }

    func invalidate(sourceURL: URL) throws {
        let sourceIdentifier = Self.sourceIdentifier(for: sourceURL)
        cancelInFlightRenders(notRetainedBy: [sourceIdentifier])
        memoryCache = memoryCache.filter {
            !$0.key.hasPrefix("\(sourceIdentifier)-")
        }
        memoryOrder.removeAll {
            $0.hasPrefix("\(sourceIdentifier)-")
        }

        guard fileManager.fileExists(atPath: rootURL.path) else {
            return
        }
        let baseURL = try preparedRoot()
        for url in try cacheEntries(in: baseURL)
        where url.lastPathComponent.hasPrefix(
            "\(sourceIdentifier)-"
        ) {
            try fileManager.removeItem(at: url)
        }
    }

    func reconcile(retaining sourceURLs: Set<URL>) throws {
        let retainedIdentifiers = Set(
            sourceURLs.map(Self.sourceIdentifier(for:))
        )
        cancelInFlightRenders(retaining: retainedIdentifiers)
        memoryCache = memoryCache.filter {
            retainedIdentifiers.contains(
                Self.sourceIdentifier(fromCacheKey: $0.key)
            )
        }
        memoryOrder.removeAll {
            !retainedIdentifiers.contains(
                Self.sourceIdentifier(fromCacheKey: $0)
            )
        }

        guard fileManager.fileExists(atPath: rootURL.path) else {
            return
        }
        let baseURL = try preparedRoot()
        for url in try cacheEntries(in: baseURL)
        where !retainedIdentifiers.contains(
            Self.sourceIdentifier(
                fromCacheKey: url.deletingPathExtension()
                    .lastPathComponent
            )
        ) {
            try fileManager.removeItem(at: url)
        }
    }

    private func makeFingerprint(
        for sourceURL: URL
    ) throws -> SourceFingerprint {
        let standardized = sourceURL.standardizedFileURL
        let values = try standardized.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey
        ])
        guard
            values.isRegularFile == true,
            values.isSymbolicLink != true
        else {
            throw LibraryThumbnailError.notRegularFile
        }
        let size = Int64(values.fileSize ?? 0)
        guard size > 0 else {
            throw LibraryThumbnailError.emptyFile
        }
        guard size <= limits.maximumSourceBytes else {
            throw LibraryThumbnailError.sourceTooLarge(
                actual: size,
                limit: limits.maximumSourceBytes
            )
        }

        let sourceIdentifier = Self.sourceIdentifier(for: standardized)
        let modificationBits = (
            values.contentModificationDate ?? .distantPast
        ).timeIntervalSinceReferenceDate.bitPattern
        let versionedIdentity = [
            "v1",
            standardized.path,
            String(size),
            String(modificationBits),
            String(limits.thumbnailPixelSize)
        ].joined(separator: "\u{0}")
        let fingerprint = ContentHasher.sha256(
            of: Data(versionedIdentity.utf8)
        ).sha256
        return SourceFingerprint(
            sourceIdentifier: sourceIdentifier,
            cacheKey: "\(sourceIdentifier)-\(fingerprint)"
        )
    }

    private func loadDiskThumbnail(
        forKey key: String
    ) throws -> LibraryThumbnail? {
        guard fileManager.fileExists(atPath: rootURL.path) else {
            return nil
        }
        let baseURL = try preparedRoot()
        let url = baseURL.appendingPathComponent(
            "\(key).png",
            isDirectory: false
        )
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let thumbnail = try Self.decodeCachedThumbnail(
                at: url,
                limits: limits
            )
            try fileManager.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: url.path
            )
            return thumbnail
        } catch {
            try? fileManager.removeItem(at: url)
            return nil
        }
    }

    private func store(
        _ thumbnail: LibraryThumbnail,
        forKey key: String,
        sourceIdentifier: String
    ) throws {
        let data = try Self.pngData(
            for: thumbnail,
            limits: limits
        )
        let baseURL = try preparedRoot()
        let destination = baseURL.appendingPathComponent(
            "\(key).png",
            isDirectory: false
        )
        try data.write(to: destination, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )

        for url in try cacheEntries(in: baseURL)
        where
            url.lastPathComponent.hasPrefix(
                "\(sourceIdentifier)-"
            )
                && url.lastPathComponent != destination.lastPathComponent
        {
            try? fileManager.removeItem(at: url)
        }
        try pruneDiskCache(in: baseURL)
    }

    private func preparedRoot() throws -> URL {
        if (try? fileManager.destinationOfSymbolicLink(
            atPath: rootURL.path
        )) != nil {
            throw LibraryThumbnailError.unsafeCacheDirectory
        }
        if fileManager.fileExists(atPath: rootURL.path) {
            let values = try rootURL.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ])
            guard
                values.isDirectory == true,
                values.isSymbolicLink != true
            else {
                throw LibraryThumbnailError.unsafeCacheDirectory
            }
        } else {
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        return rootURL
    }

    private func cacheEntries(in baseURL: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey
            ],
            options: [.skipsHiddenFiles]
        ).filter {
            $0.pathExtension == "png"
        }
    }

    private func pruneDiskCache(in baseURL: URL) throws {
        var files: [(url: URL, size: Int64, date: Date)] = []
        var totalBytes: Int64 = 0
        for url in try cacheEntries(in: baseURL) {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey
            ])
            guard
                values.isRegularFile == true,
                values.isSymbolicLink != true
            else {
                try? fileManager.removeItem(at: url)
                continue
            }
            let size = Int64(values.fileSize ?? 0)
            totalBytes += size
            files.append(
                (
                    url,
                    size,
                    values.contentModificationDate ?? .distantPast
                )
            )
        }
        for file in files.sorted(by: { $0.date < $1.date })
        where totalBytes > maximumCacheBytes {
            try fileManager.removeItem(at: file.url)
            totalBytes -= file.size
        }
    }

    private func insertIntoMemory(
        _ thumbnail: LibraryThumbnail,
        forKey key: String
    ) {
        guard maximumMemoryEntries > 0 else {
            return
        }
        memoryCache[key] = thumbnail
        touchMemoryKey(key)
        while memoryOrder.count > maximumMemoryEntries {
            memoryCache[memoryOrder.removeFirst()] = nil
        }
    }

    private func cancelInFlightRenders(
        retaining retainedIdentifiers: Set<String>
    ) {
        for (key, operation) in inFlight
        where !retainedIdentifiers.contains(
            Self.sourceIdentifier(fromCacheKey: key)
        ) {
            inFlight[key] = nil
            operation.task.cancel()
        }
    }

    private func cancelInFlightRenders(
        notRetainedBy invalidatedIdentifiers: Set<String>
    ) {
        for (key, operation) in inFlight
        where invalidatedIdentifiers.contains(
            Self.sourceIdentifier(fromCacheKey: key)
        ) {
            inFlight[key] = nil
            operation.task.cancel()
        }
    }

    private func removeOldMemoryEntries(
        for sourceIdentifier: String,
        keeping retainedKey: String
    ) {
        let prefix = "\(sourceIdentifier)-"
        let staleKeys = memoryOrder.filter {
            $0.hasPrefix(prefix) && $0 != retainedKey
        }
        for key in staleKeys {
            memoryCache[key] = nil
        }
        memoryOrder.removeAll {
            $0.hasPrefix(prefix) && $0 != retainedKey
        }
    }

    private func touchMemoryKey(_ key: String) {
        memoryOrder.removeAll(where: { $0 == key })
        memoryOrder.append(key)
    }

    private static func decodeCachedThumbnail(
        at url: URL,
        limits: LibraryThumbnailLimits
    ) throws -> LibraryThumbnail {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard
            values.isRegularFile == true,
            values.isSymbolicLink != true
        else {
            throw LibraryThumbnailError.cannotDecodeThumbnail
        }
        let byteCount = Int64(values.fileSize ?? 0)
        guard
            byteCount > 0,
            byteCount <= limits.maximumThumbnailBytes
        else {
            throw LibraryThumbnailError.thumbnailTooLarge(
                actual: byteCount,
                limit: limits.maximumThumbnailBytes
            )
        }
        guard
            let source = CGImageSourceCreateWithURL(
                url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ),
            CGImageSourceGetCount(source) == 1
        else {
            throw LibraryThumbnailError.cannotDecodeThumbnail
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: limits.thumbnailPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard
            let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            ),
            cgImage.width <= limits.thumbnailPixelSize,
            cgImage.height <= limits.thumbnailPixelSize
        else {
            throw LibraryThumbnailError.cannotDecodeThumbnail
        }
        return LibraryThumbnail(cgImage: cgImage)
    }

    private static func pngData(
        for thumbnail: LibraryThumbnail,
        limits: LibraryThumbnailLimits
    ) throws -> Data {
        let mutableData = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                mutableData,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            throw LibraryThumbnailError.cannotEncodeThumbnail
        }
        CGImageDestinationAddImage(
            destination,
            thumbnail.cgImage,
            nil
        )
        guard CGImageDestinationFinalize(destination) else {
            throw LibraryThumbnailError.cannotEncodeThumbnail
        }
        let data = mutableData as Data
        guard Int64(data.count) <= limits.maximumThumbnailBytes else {
            throw LibraryThumbnailError.thumbnailTooLarge(
                actual: Int64(data.count),
                limit: limits.maximumThumbnailBytes
            )
        }
        return data
    }

    private static func sourceIdentifier(for url: URL) -> String {
        ContentHasher.sha256(
            of: Data(url.standardizedFileURL.path.utf8)
        ).sha256
    }

    private static func sourceIdentifier(
        fromCacheKey key: String
    ) -> String {
        String(key.prefix(64))
    }

    private static func defaultCacheRoot() -> URL {
        let baseURL = (
            FileManager.default.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
        )
        return baseURL
            .appendingPathComponent("MojiPond", isDirectory: true)
            .appendingPathComponent(
                "Library Thumbnails",
                isDirectory: true
            )
    }
}
