import CryptoKit
import Foundation

enum NotoOfflineCatalogError: Error, Equatable, LocalizedError, Sendable {
    case manifestMissing
    case manifestUnreadable
    case invalidManifest
    case unsupportedSchema(Int)
    case duplicateAsset(String)
    case assetMissing(String)
    case assetUnreadable(String)
    case assetCorrupt(String)

    var errorDescription: String? {
        switch self {
        case .manifestMissing:
            "The bundled animated emoji catalog is missing."
        case .manifestUnreadable:
            "The bundled animated emoji catalog could not be read."
        case .invalidManifest:
            "The bundled animated emoji catalog is invalid."
        case let .unsupportedSchema(version):
            "Animated emoji catalog schema \(version) is unsupported."
        case let .duplicateAsset(identifier):
            "The animated emoji catalog contains duplicate asset \(identifier)."
        case let .assetMissing(filename):
            "Bundled animated emoji asset \(filename) is missing."
        case let .assetUnreadable(filename):
            "Bundled animated emoji asset \(filename) could not be read."
        case let .assetCorrupt(filename):
            "Bundled animated emoji asset \(filename) failed its integrity check."
        }
    }
}

protocol NotoOfflineResourceProviding: Sendable {
    func manifestData() throws -> Data
    func assetURL(for relativePath: String) throws -> URL
}

struct BundleNotoOfflineResourceProvider: NotoOfflineResourceProviding, @unchecked Sendable {
    let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    func manifestData() throws -> Data {
        guard let url = manifestURL else {
            throw NotoOfflineCatalogError.manifestMissing
        }
        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw NotoOfflineCatalogError.manifestUnreadable
        }
    }

    func assetURL(for relativePath: String) throws -> URL {
        guard Self.isSafe(relativePath: relativePath) else {
            throw NotoOfflineCatalogError.invalidManifest
        }
        let relativeURL = URL(fileURLWithPath: relativePath)
        let basename = relativeURL.deletingPathExtension().lastPathComponent
        let fileExtension = relativeURL.pathExtension

        let candidates = [
            bundle.url(
                forResource: basename,
                withExtension: fileExtension,
                subdirectory: "Data/NotoOffline/gifs"
            ),
            bundle.url(
                forResource: basename,
                withExtension: fileExtension
            ),
            bundle.resourceURL?
                .appendingPathComponent("Data/NotoOffline", isDirectory: true)
                .appendingPathComponent(relativePath, isDirectory: false)
        ]
        if let url = candidates.compactMap({ $0 }).first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) {
            return url
        }
        throw NotoOfflineCatalogError.assetMissing(relativePath)
    }

    private var manifestURL: URL? {
        let candidates = [
            bundle.url(
                forResource: "noto-offline-manifest",
                withExtension: "json",
                subdirectory: "Data/NotoOffline"
            ),
            bundle.url(
                forResource: "noto-offline-manifest",
                withExtension: "json"
            ),
            bundle.resourceURL?
                .appendingPathComponent("Data/NotoOffline", isDirectory: true)
                .appendingPathComponent(
                    "noto-offline-manifest.json",
                    isDirectory: false
                )
        ]
        return candidates.compactMap { $0 }.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        })
    }

    private static func isSafe(relativePath: String) -> Bool {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
            return false
        }
        return relativePath.split(separator: "/").allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}

struct NotoOfflineCatalog: Sendable {
    private let entries: [Entry]

    init(
        resourceProvider: any NotoOfflineResourceProviding =
            BundleNotoOfflineResourceProvider()
    ) throws {
        let data = try resourceProvider.manifestData()
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw NotoOfflineCatalogError.invalidManifest
        }

        guard manifest.schemaVersion == 1 else {
            throw NotoOfflineCatalogError.unsupportedSchema(
                manifest.schemaVersion
            )
        }
        guard
            manifest.sourceName == "Noto Animated Emoji",
            manifest.creator == "Google",
            manifest.sourceURL ==
                URL(
                    string: "https://googlefonts.github.io/noto-emoji-animation/"
                ),
            manifest.assetSourcePattern ==
                "https://fonts.gstatic.com/s/e/notoemoji/latest/{codepoint}/512.gif",
            manifest.licenseName ==
                "Creative Commons Attribution 4.0 International",
            manifest.sourceURL.scheme == "https",
            manifest.licenseURL ==
                URL(string: "https://creativecommons.org/licenses/by/4.0/"),
            manifest.attribution == "Noto Animated Emoji by Google",
            !manifest.retrievedAt.isEmpty,
            !manifest.assets.isEmpty
        else {
            throw NotoOfflineCatalogError.invalidManifest
        }

        var seenIDs = Set<String>()
        var loadedEntries: [Entry] = []
        loadedEntries.reserveCapacity(manifest.assets.count)

        for asset in manifest.assets {
            guard seenIDs.insert(asset.id).inserted else {
                throw NotoOfflineCatalogError.duplicateAsset(asset.id)
            }
            guard
                !asset.id.isEmpty,
                asset.codepoint.allSatisfy({ $0.isHexDigit || $0 == "_" }),
                asset.filename.hasPrefix("gifs/"),
                asset.filename.hasSuffix(".gif"),
                Self.isSafe(relativePath: asset.filename),
                asset.sha256.count == 64,
                asset.sha256.allSatisfy({ $0.isHexDigit }),
                asset.byteCount > 0,
                !asset.title.isEmpty,
                !asset.tags.isEmpty
            else {
                throw NotoOfflineCatalogError.invalidManifest
            }

            let fileURL = try resourceProvider.assetURL(for: asset.filename)
            let gifData: Data
            do {
                gifData = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            } catch {
                throw NotoOfflineCatalogError.assetUnreadable(asset.filename)
            }
            guard
                gifData.count == asset.byteCount,
                Self.isGIF(gifData),
                Self.sha256(gifData) == asset.sha256.lowercased()
            else {
                throw NotoOfflineCatalogError.assetCorrupt(asset.filename)
            }

            loadedEntries.append(
                Entry(
                    asset: asset,
                    fileURL: fileURL,
                    searchTerms: Self.searchTerms(for: asset)
                )
            )
        }
        entries = loadedEntries
    }

    var count: Int {
        entries.count
    }

    func search(_ query: String, limit: Int = 24) throws -> [MediaCommandResult] {
        let normalizedQuery = Self.normalize(query)
        guard !normalizedQuery.isEmpty else {
            throw RemoteMediaError.emptyQuery
        }
        guard normalizedQuery.count <= MediaCommandKind.sticker.maximumQueryLength else {
            throw RemoteMediaError.queryTooLong(
                limit: MediaCommandKind.sticker.maximumQueryLength
            )
        }

        return entries
            .compactMap { entry -> (Entry, Int)? in
                guard let score = Self.score(
                    query: normalizedQuery,
                    terms: entry.searchTerms
                ) else {
                    return nil
                }
                return (entry, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 {
                    return lhs.1 < rhs.1
                }
                if lhs.0.asset.popularity != rhs.0.asset.popularity {
                    return lhs.0.asset.popularity > rhs.0.asset.popularity
                }
                return lhs.0.asset.codepoint < rhs.0.asset.codepoint
            }
            .prefix(min(max(limit, 1), 60))
            .map(Self.makeResult)
    }

    private static func makeResult(_ ranked: (Entry, Int)) -> MediaCommandResult {
        let entry = ranked.0
        let media = RemoteMediaItem(
            id: entry.asset.id,
            provider: .notoAnimatedEmoji,
            title: entry.asset.title,
            previewURL: entry.fileURL,
            originalURL: entry.fileURL,
            dimensions: RemoteMediaDimensions(width: 512, height: 512),
            attribution: "Noto Animated Emoji by Google"
        )
        return MediaCommandResult(
            media: media,
            origin: .bundled(
                BundledMediaAsset(
                    fileURL: entry.fileURL,
                    expectedSHA256: entry.asset.sha256.lowercased(),
                    expectedByteCount: entry.asset.byteCount
                )
            )
        )
    }

    private static func score(query: String, terms: [String]) -> Int? {
        if terms.contains(query) {
            return 0
        }
        if terms.contains(where: { $0.hasPrefix(query) }) {
            return 1
        }
        if terms.contains(where: {
            $0.split(separator: " ").contains(where: { $0.hasPrefix(query) })
        }) {
            return 2
        }
        if terms.contains(where: { $0.contains(query) }) {
            return 3
        }
        return nil
    }

    private static func searchTerms(for asset: Asset) -> [String] {
        let rawTerms = [asset.title, asset.codepoint] + asset.tags
        var seen = Set<String>()
        return rawTerms.compactMap { rawTerm in
            let normalized = normalize(rawTerm)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else {
                return nil
            }
            return normalized
        }
    }

    private static func normalize(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        var normalized = ""
        var previousWasSpace = true
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "+" {
                normalized.unicodeScalars.append(scalar)
                previousWasSpace = false
            } else if !previousWasSpace {
                normalized.append(" ")
                previousWasSpace = true
            }
        }
        return normalized.trimmingCharacters(in: .whitespaces)
    }

    private static func isGIF(_ data: Data) -> Bool {
        guard data.count >= 6 else {
            return false
        }
        return data.prefix(6) == Data("GIF87a".utf8) ||
            data.prefix(6) == Data("GIF89a".utf8)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isSafe(relativePath: String) -> Bool {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
            return false
        }
        return relativePath.split(separator: "/").allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}

private extension NotoOfflineCatalog {
    struct Entry: Sendable {
        let asset: Asset
        let fileURL: URL
        let searchTerms: [String]
    }

    struct Manifest: Decodable {
        let schemaVersion: Int
        let sourceName: String
        let creator: String
        let sourceURL: URL
        let assetSourcePattern: String
        let licenseName: String
        let licenseURL: URL
        let attribution: String
        let retrievedAt: String
        let assets: [Asset]
    }

    struct Asset: Decodable, Sendable {
        let id: String
        let codepoint: String
        let title: String
        let tags: [String]
        let popularity: Int
        let filename: String
        let byteCount: Int
        let sha256: String
    }
}
