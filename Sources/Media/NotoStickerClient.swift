import Foundation

actor NotoStickerClient {
    private static let maximumManifestBytes = 5 * 1_024 * 1_024

    private let responseLoader: BoundedHTTPSResponseLoader
    private let manifestURL: URL
    private let assetRootURL: URL
    private var cachedIcons: [NotoIcon]?

    init(
        session: URLSession = .shared,
        manifestURL: URL = URL(
            string: "https://googlefonts.github.io/noto-emoji-animation/data/api.json"
        )!,
        assetRootURL: URL = URL(
            string: "https://fonts.gstatic.com/s/e/notoemoji/latest/"
        )!
    ) {
        responseLoader = BoundedHTTPSResponseLoader(session: session)
        self.manifestURL = manifestURL
        self.assetRootURL = assetRootURL
    }

    func search(_ query: String, limit: Int = 60) async throws -> [RemoteMediaItem] {
        let query = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !query.isEmpty else {
            throw RemoteMediaError.emptyQuery
        }
        guard query.count <= 64 else {
            throw RemoteMediaError.queryTooLong(limit: 64)
        }

        let icons = try await loadIcons()
        return icons
            .filter { icon in
                icon.searchTerms.contains { $0.contains(query) }
            }
            .sorted { lhs, rhs in
                let lhsPrefix = lhs.searchTerms.contains { $0.hasPrefix(query) }
                let rhsPrefix = rhs.searchTerms.contains { $0.hasPrefix(query) }
                if lhsPrefix != rhsPrefix {
                    return lhsPrefix
                }
                if lhs.popularity != rhs.popularity {
                    return lhs.popularity > rhs.popularity
                }
                return lhs.codepoint < rhs.codepoint
            }
            .prefix(min(max(limit, 1), 100))
            .compactMap(makeResult)
    }

    func all(limit: Int = 100) async throws -> [RemoteMediaItem] {
        let icons = try await loadIcons()
        return icons
            .sorted {
                if $0.popularity != $1.popularity {
                    return $0.popularity > $1.popularity
                }
                return $0.codepoint < $1.codepoint
            }
            .prefix(min(max(limit, 1), 200))
            .compactMap(makeResult)
    }

    func clearManifestCache() {
        cachedIcons = nil
    }

    private func loadIcons() async throws -> [NotoIcon] {
        if let cachedIcons {
            return cachedIcons
        }
        guard manifestURL.scheme == "https", assetRootURL.scheme == "https" else {
            throw RemoteMediaError.insecureURL
        }

        let loaded: BoundedHTTPResponse
        do {
            loaded = try await responseLoader.load(
                URLRequest(url: manifestURL),
                maximumBytes: Self.maximumManifestBytes,
                redirectPolicy: .sameHost
            )
        } catch let error as BoundedHTTPSLoadError {
            switch error {
            case .responseTooLarge:
                throw RemoteMediaError.responseTooLarge(
                    limit: Self.maximumManifestBytes
                )
            case .insecureRequestURL, .insecureRedirectURL, .disallowedRedirectHost:
                throw RemoteMediaError.insecureURL
            case .invalidResponse:
                throw RemoteMediaError.invalidResponse
            }
        }
        let response = loaded.response
        guard (200..<300).contains(response.statusCode) else {
            throw RemoteMediaError.statusCode(response.statusCode)
        }

        let payload = try JSONDecoder().decode(
            NotoManifest.self,
            from: loaded.data
        )
        cachedIcons = payload.icons
        return payload.icons
    }

    private func makeResult(_ icon: NotoIcon) -> RemoteMediaItem? {
        let codepoint = icon.codepoint.lowercased()
        guard codepoint.allSatisfy({ $0.isHexDigit || $0 == "_" }) else {
            return nil
        }
        let directory = assetRootURL.appending(path: codepoint, directoryHint: .isDirectory)
        let gifURL = directory.appending(path: "512.gif")
        guard gifURL.scheme == "https" else {
            return nil
        }

        return RemoteMediaItem(
            id: "noto-\(codepoint)",
            provider: .notoAnimatedEmoji,
            title: icon.displayName,
            previewURL: gifURL,
            originalURL: gifURL,
            dimensions: RemoteMediaDimensions(width: 512, height: 512),
            attribution: "Noto Animated Emoji by Google",
            analytics: nil
        )
    }
}

private struct NotoManifest: Decodable {
    let icons: [NotoIcon]
}

private struct NotoIcon: Decodable {
    let name: String
    let popularity: Int
    let codepoint: String
    let tags: [String]

    var searchTerms: [String] {
        let normalizedTags = tags.map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                .replacingOccurrences(of: "-", with: " ")
                .lowercased()
        }
        return normalizedTags + [
            name.replacingOccurrences(of: "emoji_u", with: "")
                .replacingOccurrences(of: "_", with: " ")
                .lowercased(),
            codepoint.lowercased()
        ]
    }

    var displayName: String {
        guard let first = searchTerms.first, !first.isEmpty else {
            return "Animated emoji"
        }
        return first.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
