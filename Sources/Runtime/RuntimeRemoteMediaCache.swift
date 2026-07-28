import Foundation

protocol RuntimeRemoteMediaCaching: Sendable {
    func cachedDownload(
        for result: MediaCommandResult
    ) async throws -> MediaCommandDownload?

    func store(
        _ download: MediaCommandDownload,
        for result: MediaCommandResult
    ) async throws
}

/// A bounded, best-effort cache for remote Noto assets selected by the user.
/// GIPHY results are rejected before the underlying disk cache is touched.
actor RuntimeNotoMediaDiskCache: RuntimeRemoteMediaCaching {
    private let diskCache: MediaDiskCache

    init(
        rootURL: URL,
        maximumBytes: Int64 = 250 * 1_024 * 1_024
    ) {
        diskCache = MediaDiskCache(
            rootURL: rootURL,
            maximumBytes: maximumBytes
        )
    }

    func cachedDownload(
        for result: MediaCommandResult
    ) async throws -> MediaCommandDownload? {
        guard Self.isCacheable(result) else {
            return nil
        }
        guard
            let fileURL = try await diskCache.cachedFile(
                for: result.media.originalURL
            )
        else {
            return nil
        }

        let contentType = try Self.contentType(
            forFileExtension: fileURL.pathExtension
        )
        let download = MediaCommandDownload(
            data: try Data(contentsOf: fileURL, options: [.mappedIfSafe]),
            contentType: contentType,
            suggestedFilename: fileURL.lastPathComponent
        )
        _ = try RuntimeMediaPayloadBuilder.validatedUniformType(
            for: download
        )
        return download
    }

    func store(
        _ download: MediaCommandDownload,
        for result: MediaCommandResult
    ) async throws {
        guard Self.isCacheable(result) else {
            return
        }

        _ = try RuntimeMediaPayloadBuilder.validatedUniformType(
            for: download
        )
        let fileExtension = try Self.fileExtension(
            forContentType: download.contentType
        )
        _ = try await diskCache.store(
            RemoteMediaDownloader.Download(
                data: download.data,
                contentType: download.contentType,
                suggestedFilename: "noto.\(fileExtension)"
            ),
            for: result.media
        )
    }

    private static func isCacheable(
        _ result: MediaCommandResult
    ) -> Bool {
        guard result.media.provider == .notoAnimatedEmoji else {
            return false
        }
        if case .remote = result.origin {
            return true
        }
        return false
    }

    private static func fileExtension(
        forContentType rawContentType: String
    ) throws -> String {
        switch normalizedContentType(rawContentType) {
        case "image/gif":
            return "gif"
        case "image/png":
            return "png"
        case "image/jpeg", "image/jpg":
            return "jpg"
        case "image/webp":
            return "webp"
        default:
            throw RuntimeMediaDownloadError.unsupportedContentType
        }
    }

    private static func contentType(
        forFileExtension rawExtension: String
    ) throws -> String {
        switch rawExtension.lowercased(
            with: Locale(identifier: "en_US_POSIX")
        ) {
        case "gif":
            return "image/gif"
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "webp":
            return "image/webp"
        default:
            throw RuntimeMediaDownloadError.unsupportedContentType
        }
    }

    private static func normalizedContentType(
        _ contentType: String
    ) -> String {
        contentType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            ?? ""
    }
}

struct RuntimeMediaDownloadResolver: Sendable {
    let coordinator: any RuntimeMediaCommandCoordinating
    let cache: (any RuntimeRemoteMediaCaching)?

    func resolve(
        _ result: MediaCommandResult
    ) async throws -> MediaCommandDownload {
        guard Self.shouldUseCache(result), let cache else {
            return try await coordinator.resolve(result)
        }

        if let cached = try? await cache.cachedDownload(for: result) {
            return cached
        }
        let download = try await coordinator.resolve(result)
        try? await cache.store(download, for: result)
        return download
    }

    private static func shouldUseCache(
        _ result: MediaCommandResult
    ) -> Bool {
        guard result.media.provider == .notoAnimatedEmoji else {
            return false
        }
        if case .remote = result.origin {
            return true
        }
        return false
    }
}
