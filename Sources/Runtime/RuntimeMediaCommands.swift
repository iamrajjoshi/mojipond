import AppKit
import Foundation
import UniformTypeIdentifiers

enum RuntimeMediaNetworkPolicy {
    static func nonCachingSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }

    static func nonCachingRequest(for url: URL) -> URLRequest {
        URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    static func liveCoordinator(
        bundle: Bundle = .main
    ) throws -> MediaCommandCoordinator {
        let session = nonCachingSession()
        return try MediaCommandCoordinator(
            offlineCatalog: NotoOfflineCatalog(
                resourceProvider: BundleNotoOfflineResourceProvider(
                    bundle: bundle
                )
            ),
            stickerSearcher: NotoStickerClient(session: session),
            gifSearcher: GiphyClient(session: session),
            assetResolver: MediaCommandAssetResolver(
                remoteDownloader: RemoteMediaDownloader(session: session)
            )
        )
    }
}

protocol RuntimeFrontmostApplicationProviding: Sendable {
    func bundleIdentifier() -> String?
}

struct MacRuntimeFrontmostApplicationProvider:
    RuntimeFrontmostApplicationProviding,
    @unchecked Sendable
{
    func bundleIdentifier() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}

protocol RuntimeMediaCommandCoordinating: Sendable {
    func search(
        command: MediaCommandKind,
        query: String,
        bundleIdentifier: String?,
        networkOptions: MediaCommandNetworkOptions,
        limit: Int
    ) async -> MediaCommandSearchState

    func cancel() async -> MediaCommandSearchState
    func resolve(
        _ result: MediaCommandResult
    ) async throws -> MediaCommandDownload
}

extension MediaCommandCoordinator: RuntimeMediaCommandCoordinating {}

enum RuntimeMediaInsertionSource: Equatable, Sendable {
    case customEmoji(shortcode: String)
    case sticker
    case gif
}

enum RuntimeMediaCopyFallbackReason: Equatable, Sendable {
    case notMessages
    case managedLibraryUnavailable
    case invalidManagedAsset
    case downloadFailed
    case unsupportedDownloadedMedia
    case insertionFailed(InsertionFailureReason)
}

struct RuntimeMediaCopyFallbackDiagnostic: Equatable, Sendable {
    let source: RuntimeMediaInsertionSource
    let reason: RuntimeMediaCopyFallbackReason
}

enum RuntimeMediaDownloadError: Error, Equatable, Sendable {
    case empty
    case tooLarge(limit: Int)
    case unsupportedContentType
    case contentTypeMismatch
}

enum RuntimeMediaPayloadBuilder {
    static let maximumBytes = 25 * 1_024 * 1_024

    static func payload(
        for download: MediaCommandDownload,
        maximumBytes: Int = maximumBytes
    ) throws -> PasteboardItemPayload {
        let uniformType = try validatedUniformType(
            for: download,
            maximumBytes: maximumBytes
        )
        return .image(
            originalData: download.data,
            type: uniformType,
            includeCompatibilityFallbacks: true
        )
    }

    static func validatedUniformType(
        for download: MediaCommandDownload,
        maximumBytes: Int = maximumBytes
    ) throws -> UTType {
        guard !download.data.isEmpty else {
            throw RuntimeMediaDownloadError.empty
        }
        guard download.data.count <= maximumBytes else {
            throw RuntimeMediaDownloadError.tooLarge(limit: maximumBytes)
        }

        let normalizedType = download.contentType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        let uniformType: UTType
        let matchesMagic: Bool
        switch normalizedType {
        case "image/png":
            uniformType = .png
            matchesMagic = download.data.starts(with: [
                0x89, 0x50, 0x4E, 0x47,
                0x0D, 0x0A, 0x1A, 0x0A
            ])
        case "image/jpeg", "image/jpg":
            uniformType = .jpeg
            matchesMagic = download.data.count >= 3
                && download.data[download.data.startIndex] == 0xFF
                && download.data[
                    download.data.index(after: download.data.startIndex)
                ] == 0xD8
                && download.data[
                    download.data.index(
                        download.data.startIndex,
                        offsetBy: 2
                    )
                ] == 0xFF
        case "image/gif":
            uniformType = .gif
            matchesMagic =
                download.data.starts(with: Data("GIF87a".utf8))
                || download.data.starts(with: Data("GIF89a".utf8))
        case "image/webp":
            uniformType = .webP
            matchesMagic = download.data.count >= 12
                && download.data.prefix(4) == Data("RIFF".utf8)
                && download.data.dropFirst(8).prefix(4)
                    == Data("WEBP".utf8)
        default:
            throw RuntimeMediaDownloadError.unsupportedContentType
        }
        guard matchesMagic else {
            throw RuntimeMediaDownloadError.contentTypeMismatch
        }
        return uniformType
    }
}

extension MediaCommandNetworkOptions {
    init(preferences: NetworkPreferences) {
        self.init(
            allowsNotoNetwork: preferences.allowsStickerSearch,
            allowsGIPHYNetwork: preferences.allowsGIFSearch
        )
    }
}

extension MediaCommandParser {
    var renderedToken: String? {
        switch state {
        case .idle:
            nil
        case let .commandPrefix(prefix):
            "/\(prefix)"
        case let .awaitingQuery(command):
            "\(command.invocation) "
        case let .query(command, query):
            "\(command.invocation) \(query)"
        }
    }
}

extension MediaCommandSearchState {
    var runtimePanelState: RuntimeMediaPanelState {
        switch self {
        case .idle:
            .idle
        case .loading:
            .loading
        case .results:
            .results
        case .offline:
            .offline
        case .empty:
            .empty
        case .cancelled:
            .cancelled
        case .networkDisabled:
            .networkDisabled
        case .rateLimited:
            .rateLimited
        case let .failed(_, failure):
            .failed(failure)
        }
    }

    var runtimeResults: MediaCommandResults? {
        switch self {
        case let .results(results), let .offline(results):
            results
        default:
            nil
        }
    }
}
