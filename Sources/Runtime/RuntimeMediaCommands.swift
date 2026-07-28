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
    case animatedWebPExperimental
    case downloadFailed
    case unsupportedDownloadedMedia
    case insertionFailed(InsertionFailureReason)
}

struct RuntimeMediaCopyFallbackDiagnostic: Equatable, Sendable {
    let source: RuntimeMediaInsertionSource
    let reason: RuntimeMediaCopyFallbackReason
    let payload: PasteboardItemPayload?

    init(
        source: RuntimeMediaInsertionSource,
        reason: RuntimeMediaCopyFallbackReason,
        payload: PasteboardItemPayload? = nil
    ) {
        self.source = source
        self.reason = reason
        self.payload = payload
    }
}

enum RuntimeMediaDownloadError: Error, Equatable, Sendable {
    case empty
    case tooLarge(limit: Int)
    case unsupportedContentType
    case contentTypeMismatch
    case unsafeImage
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
        let expectedFormat: AssetFormat
        switch normalizedType {
        case "image/png":
            uniformType = .png
            expectedFormat = .png
        case "image/jpeg", "image/jpg":
            uniformType = .jpeg
            expectedFormat = .jpeg
        case "image/gif":
            uniformType = .gif
            expectedFormat = .gif
        case "image/webp":
            uniformType = .webP
            expectedFormat = .webP
        default:
            throw RuntimeMediaDownloadError.unsupportedContentType
        }
        var limits = AssetValidationLimits.default
        limits.maximumFileBytes = Int64(maximumBytes)
        do {
            _ = try AssetValidator(limits: limits).validate(
                data: download.data,
                expectedFormat: expectedFormat
            )
        } catch let error as AssetValidationError {
            if case .dataTypeMismatch = error {
                throw RuntimeMediaDownloadError.contentTypeMismatch
            }
            throw RuntimeMediaDownloadError.unsafeImage
        } catch {
            throw RuntimeMediaDownloadError.unsafeImage
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
