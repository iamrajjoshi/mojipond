import Foundation

enum RemoteMediaProvider: String, Codable, Sendable {
    case notoAnimatedEmoji
}

enum RemoteMediaURLPolicy {
    static func allows(_ url: URL, for provider: RemoteMediaProvider) -> Bool {
        guard
            url.scheme?.lowercased(
                with: Locale(identifier: "en_US_POSIX")
            ) == "https",
            let host = url.host?.lowercased(
                with: Locale(identifier: "en_US_POSIX")
            ),
            !host.isEmpty,
            url.user == nil,
            url.password == nil,
            url.port == nil,
            url.fragment == nil
        else {
            return false
        }

        return provider == .notoAnimatedEmoji && host == "fonts.gstatic.com"
    }
}

struct RemoteMediaDimensions: Codable, Equatable, Sendable {
    let width: Int
    let height: Int
}

struct RemoteMediaItem: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let provider: RemoteMediaProvider
    let title: String
    let previewURL: URL
    let originalURL: URL
    let dimensions: RemoteMediaDimensions?
    let attribution: String
}

enum RemoteMediaError: Error, Equatable, LocalizedError, Sendable {
    case emptyQuery
    case queryTooLong(limit: Int)
    case invalidResponse
    case statusCode(Int)
    case insecureURL
    case responseTooLarge(limit: Int)
    case unsupportedContentType(String?)
    case unsafeImage

    var errorDescription: String? {
        switch self {
        case .emptyQuery:
            "Enter a search term."
        case let .queryTooLong(limit):
            "Search terms must be \(limit) characters or fewer."
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
        case .unsafeImage:
            "The media provider returned an unsafe or malformed image."
        }
    }
}
