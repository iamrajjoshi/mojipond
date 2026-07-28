import Foundation

enum RemoteMediaProvider: String, Codable, Sendable {
    case giphy
    case notoAnimatedEmoji
}

struct RemoteMediaDimensions: Codable, Equatable, Sendable {
    let width: Int
    let height: Int
}

struct RemoteMediaAnalytics: Codable, Equatable, Sendable {
    let onLoadURL: URL?
    let onClickURL: URL?
    let onSentURL: URL?
}

struct RemoteMediaItem: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let provider: RemoteMediaProvider
    let title: String
    let previewURL: URL
    let originalURL: URL
    let dimensions: RemoteMediaDimensions?
    let attribution: String
    let analytics: RemoteMediaAnalytics?
}

enum RemoteMediaError: Error, Equatable, LocalizedError, Sendable {
    case missingAPIKey
    case emptyQuery
    case queryTooLong(limit: Int)
    case invalidRequest
    case invalidResponse
    case statusCode(Int)
    case insecureURL
    case responseTooLarge(limit: Int)
    case unsupportedContentType(String?)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Add a GIPHY API key in MojiPond settings to enable GIF search."
        case .emptyQuery:
            "Enter a search term."
        case let .queryTooLong(limit):
            "Search terms must be \(limit) characters or fewer."
        case .invalidRequest:
            "MojiPond could not create a valid media request."
        case .invalidResponse:
            "The media provider returned an invalid response."
        case let .statusCode(code):
            "The media provider returned HTTP \(code)."
        case .insecureURL:
            "MojiPond only loads media over HTTPS."
        case let .responseTooLarge(limit):
            "The selected media is larger than the \(limit)-byte safety limit."
        case let .unsupportedContentType(type):
            "The media provider returned an unsupported content type: \(type ?? "unknown")."
        }
    }
}

