import Foundation

enum MediaCommandKind: String, CaseIterable, Equatable, Sendable {
    case sticker
    case gif

    var invocation: String {
        "/\(rawValue)"
    }

    var maximumQueryLength: Int {
        switch self {
        case .sticker:
            64
        case .gif:
            50
        }
    }
}

struct MediaCommandRequest: Equatable, Sendable {
    let id: UInt64
    let command: MediaCommandKind
}

struct MediaCommandNetworkOptions: Equatable, Sendable {
    var allowsNotoNetwork: Bool
    var allowsGIPHYNetwork: Bool

    static let offlineOnly = MediaCommandNetworkOptions(
        allowsNotoNetwork: false,
        allowsGIPHYNetwork: false
    )
}

struct MediaCommandAttribution: Equatable, Sendable {
    let text: String
    let destinationURL: URL

    static let notoAnimatedEmoji = MediaCommandAttribution(
        text: "Noto Animated Emoji by Google · CC BY 4.0",
        destinationURL: URL(
            string: "https://googlefonts.github.io/noto-emoji-animation/"
        )!
    )

    static let giphy = MediaCommandAttribution(
        text: "Powered by GIPHY",
        destinationURL: URL(string: "https://giphy.com/")!
    )
}

struct BundledMediaAsset: Equatable, Sendable {
    let fileURL: URL
    let expectedSHA256: String
    let expectedByteCount: Int
}

enum MediaCommandResultOrigin: Equatable, Sendable {
    case bundled(BundledMediaAsset)
    case remote
}

struct MediaCommandResult: Identifiable, Equatable, Sendable {
    let media: RemoteMediaItem
    let origin: MediaCommandResultOrigin

    var id: String {
        media.id
    }

    var attribution: MediaCommandAttribution {
        switch media.provider {
        case .giphy:
            .giphy
        case .notoAnimatedEmoji:
            .notoAnimatedEmoji
        }
    }
}

struct MediaCommandResults: Equatable, Sendable {
    let request: MediaCommandRequest
    let items: [MediaCommandResult]
    let attributions: [MediaCommandAttribution]
}

enum MediaCommandFailure: Equatable, Sendable {
    case invalidQuery
    case missingGIPHYAPIKey
    case providerUnavailable
    case invalidProviderResponse
    case unsupportedMedia
}

enum MediaCommandSearchState: Equatable, Sendable {
    case idle
    case loading(MediaCommandRequest)
    case results(MediaCommandResults)
    case offline(MediaCommandResults)
    case empty(MediaCommandRequest)
    case cancelled(MediaCommandRequest)
    case networkDisabled(MediaCommandRequest)
    case rateLimited(MediaCommandRequest)
    case failed(MediaCommandRequest, MediaCommandFailure)

    var request: MediaCommandRequest? {
        switch self {
        case .idle:
            nil
        case let .loading(request),
             let .empty(request),
             let .cancelled(request),
             let .networkDisabled(request),
             let .rateLimited(request):
            request
        case let .results(results), let .offline(results):
            results.request
        case let .failed(request, _):
            request
        }
    }
}

struct MediaCommandDownload: Equatable, Sendable {
    let data: Data
    let contentType: String
    let suggestedFilename: String
}
