import Foundation
import Security

protocol GiphyAPIKeyProviding: Sendable {
    func apiKey() throws -> String
}

protocol GiphyAPIKeyStoring: GiphyAPIKeyProviding {
    func save(_ value: String) throws
    func delete() throws
}

struct EnvironmentGiphyAPIKeyProvider: GiphyAPIKeyProviding {
    private let environment: @Sendable () -> [String: String]

    init(environment: @escaping @Sendable () -> [String: String] = {
        ProcessInfo.processInfo.environment
    }) {
        self.environment = environment
    }

    func apiKey() throws -> String {
        let value = environment()["MOJIPOND_GIPHY_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else {
            throw RemoteMediaError.missingAPIKey
        }
        return value
    }
}

final class KeychainGiphyAPIKeyStore:
    GiphyAPIKeyStoring,
    @unchecked Sendable
{
    private let service: String
    private let account: String

    init(
        service: String = "com.rajjoshi.MojiPond",
        account: String = "giphy-api-key"
    ) {
        self.service = service
        self.account = account
    }

    func apiKey() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            throw RemoteMediaError.missingAPIKey
        }
        guard
            status == errSecSuccess,
            let data = result as? Data,
            let value = String(data: data, encoding: .utf8),
            !value.isEmpty
        else {
            throw KeychainError(status)
        }
        return value
    }

    func save(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try delete()
            return
        }

        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError(updateStatus)
        }

        var item = identity
        attributes.forEach { item[$0.key] = $0.value }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError(addStatus)
        }
    }

    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status)
        }
    }
}

struct KeychainError: Error, Equatable, LocalizedError, Sendable {
    let status: OSStatus

    init(_ status: OSStatus) {
        self.status = status
    }

    var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String?
    }
}

final class GiphyClient: @unchecked Sendable {
    private static let maximumSearchResponseBytes = 2 * 1_024 * 1_024
    private let responseLoader: BoundedHTTPSResponseLoader
    private let keyProvider: any GiphyAPIKeyProviding
    private let baseURL: URL

    init(
        session: URLSession = .shared,
        keyProvider: any GiphyAPIKeyProviding = KeychainGiphyAPIKeyStore(),
        baseURL: URL = URL(string: "https://api.giphy.com")!
    ) {
        responseLoader = BoundedHTTPSResponseLoader(session: session)
        self.keyProvider = keyProvider
        self.baseURL = baseURL
    }

    func search(_ query: String, limit: Int = 25) async throws -> [RemoteMediaItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            throw RemoteMediaError.emptyQuery
        }
        guard normalizedQuery.count <= 50 else {
            throw RemoteMediaError.queryTooLong(limit: 50)
        }
        guard baseURL.scheme == "https" else {
            throw RemoteMediaError.insecureURL
        }

        let key = try keyProvider.apiKey()
        var components = URLComponents(
            url: baseURL.appending(path: "v1/gifs/search"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: key),
            URLQueryItem(name: "q", value: normalizedQuery),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 50))),
            URLQueryItem(name: "rating", value: "pg"),
            URLQueryItem(name: "lang", value: "en"),
            URLQueryItem(name: "bundle", value: "messaging_non_clips")
        ]
        guard let url = components?.url else {
            throw RemoteMediaError.invalidRequest
        }

        let loaded = try await load(
            url,
            maximumBytes: Self.maximumSearchResponseBytes
        )
        try Self.validate(loaded.response)
        let payload = try JSONDecoder().decode(
            SearchResponse.self,
            from: loaded.data
        )
        let boundedLimit = min(max(limit, 1), 50)
        return payload.data.prefix(boundedLimit).compactMap(Self.map)
    }

    private func load(
        _ url: URL,
        maximumBytes: Int
    ) async throws -> BoundedHTTPResponse {
        do {
            return try await responseLoader.load(
                URLRequest(url: url),
                maximumBytes: maximumBytes,
                redirectPolicy: .sameHost
            )
        } catch let error as BoundedHTTPSLoadError {
            switch error {
            case .responseTooLarge:
                throw RemoteMediaError.responseTooLarge(limit: maximumBytes)
            case .insecureRequestURL, .insecureRedirectURL, .disallowedRedirectHost:
                throw RemoteMediaError.insecureURL
            case .invalidResponse:
                throw RemoteMediaError.invalidResponse
            }
        }
    }

    private static func validate(_ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw RemoteMediaError.statusCode(response.statusCode)
        }
    }

    private static func map(_ source: GIF) -> RemoteMediaItem? {
        guard
            let preview = source.images.fixedWidth?.url ?? source.images.preview?.url,
            let original = source.images.original.url,
            RemoteMediaURLPolicy.allows(preview, for: .giphy),
            RemoteMediaURLPolicy.allows(original, for: .giphy)
        else {
            return nil
        }

        let width = Int(source.images.original.width ?? "")
        let height = Int(source.images.original.height ?? "")
        let dimensions = width.flatMap { width in
            height.map { height in
                RemoteMediaDimensions(width: width, height: height)
            }
        }

        return RemoteMediaItem(
            id: source.id,
            provider: .giphy,
            title: source.title.isEmpty ? "GIF" : source.title,
            previewURL: preview,
            originalURL: original,
            dimensions: dimensions,
            attribution: "Powered by GIPHY",
            analytics: RemoteMediaAnalytics(
                onLoadURL: source.analytics?.onload?.url,
                onClickURL: source.analytics?.onclick?.url,
                onSentURL: source.analytics?.onsent?.url
            ),
            creatorAttribution: creatorAttribution(for: source),
            sourceAttribution: sourceAttribution(for: source.source)
        )
    }

    private static func creatorAttribution(for source: GIF) -> String? {
        let username = source.user?.username ?? source.username
        guard
            let username = username?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !username.isEmpty
        else {
            return nil
        }
        return username.hasPrefix("@") ? username : "@\(username)"
    }

    private static func sourceAttribution(for value: String?) -> String? {
        guard
            let value = value?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            !value.isEmpty,
            value.utf8.count <= 2_048,
            let components = URLComponents(string: value),
            ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
            components.user == nil,
            components.password == nil,
            let host = components.host,
            !host.isEmpty
        else {
            return nil
        }
        return host
    }
}

private struct SearchResponse: Decodable {
    let data: [GIF]
}

private struct GIF: Decodable {
    let id: String
    let title: String
    let username: String?
    let source: String?
    let user: GIFUser?
    let images: GIFImages
    let analytics: GIFAnalytics?
}

private struct GIFUser: Decodable {
    let username: String?
}

private struct GIFImages: Decodable {
    let fixedWidth: GIFImage?
    let preview: GIFImage?
    let original: GIFImage

    enum CodingKeys: String, CodingKey {
        case fixedWidth = "fixed_width"
        case preview = "preview_gif"
        case original
    }
}

private struct GIFImage: Decodable {
    let url: URL?
    let width: String?
    let height: String?
}

private struct GIFAnalytics: Decodable {
    let onload: GIFAnalyticsURL?
    let onclick: GIFAnalyticsURL?
    let onsent: GIFAnalyticsURL?
}

private struct GIFAnalyticsURL: Decodable {
    let url: URL?
}
