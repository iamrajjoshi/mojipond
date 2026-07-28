import Foundation
import Security

protocol GiphyAPIKeyProviding: Sendable {
    func apiKey() throws -> String
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

final class KeychainGiphyAPIKeyStore: GiphyAPIKeyProviding, @unchecked Sendable {
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
    enum AnalyticsEvent: Sendable {
        case load
        case click
        case sent
    }

    private let session: URLSession
    private let keyProvider: any GiphyAPIKeyProviding
    private let baseURL: URL
    private let customerID: @Sendable () -> String
    private let now: @Sendable () -> Date

    init(
        session: URLSession = .shared,
        keyProvider: any GiphyAPIKeyProviding = KeychainGiphyAPIKeyStore(),
        baseURL: URL = URL(string: "https://api.giphy.com")!,
        customerID: @escaping @Sendable () -> String = {
            GiphyCustomerIdentifier.value
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.keyProvider = keyProvider
        self.baseURL = baseURL
        self.customerID = customerID
        self.now = now
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
            URLQueryItem(name: "bundle", value: "messaging_non_clips"),
            URLQueryItem(name: "customer_id", value: customerID())
        ]
        guard let url = components?.url else {
            throw RemoteMediaError.invalidRequest
        }

        let (data, response) = try await session.data(from: url)
        try Self.validate(response)
        let payload = try JSONDecoder().decode(SearchResponse.self, from: data)
        return payload.data.compactMap(Self.map)
    }

    func register(_ event: AnalyticsEvent, for item: RemoteMediaItem) async throws {
        guard item.provider == .giphy, let analytics = item.analytics else {
            return
        }

        let sourceURL: URL?
        switch event {
        case .load:
            sourceURL = analytics.onLoadURL
        case .click:
            sourceURL = analytics.onClickURL
        case .sent:
            sourceURL = analytics.onSentURL
        }
        guard let sourceURL else {
            return
        }
        guard sourceURL.scheme == "https" else {
            throw RemoteMediaError.insecureURL
        }

        var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.append(URLQueryItem(name: "customer_id", value: customerID()))
        queryItems.append(
            URLQueryItem(
                name: "ts",
                value: String(Int(now().timeIntervalSince1970 * 1_000))
            )
        )
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw RemoteMediaError.invalidRequest
        }
        let (_, response) = try await session.data(from: url)
        try Self.validate(response)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else {
            throw RemoteMediaError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw RemoteMediaError.statusCode(response.statusCode)
        }
    }

    private static func map(_ source: GIF) -> RemoteMediaItem? {
        guard
            let preview = source.images.fixedWidth?.url ?? source.images.preview?.url,
            let original = source.images.original.url,
            preview.scheme == "https",
            original.scheme == "https"
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
            )
        )
    }
}

private enum GiphyCustomerIdentifier {
    static var value: String {
        let key = "com.rajjoshi.MojiPond.giphyCustomerIdentifier"
        if let value = UserDefaults.standard.string(forKey: key) {
            return value
        }
        let value = UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: key)
        return value
    }
}

private struct SearchResponse: Decodable {
    let data: [GIF]
}

private struct GIF: Decodable {
    let id: String
    let title: String
    let images: GIFImages
    let analytics: GIFAnalytics?
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
