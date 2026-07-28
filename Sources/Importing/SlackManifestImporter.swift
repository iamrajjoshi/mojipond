import Foundation

enum SlackImportAssetLocation: Equatable, Sendable {
    case local(relativePath: String)
    case remote(URL)
}

struct SlackImportManifestEntry: Equatable, Sendable {
    let shortcode: Shortcode
    let aliases: [Shortcode]
    let location: SlackImportAssetLocation
}

struct SlackImportManifest: Equatable, Sendable {
    let entries: [SlackImportManifestEntry]
}

enum SlackImportManifestParser {
    static func parse(_ data: Data) throws -> SlackImportManifest {
        let root: SlackJSONValue
        do {
            root = try JSONDecoder().decode(SlackJSONValue.self, from: data)
        } catch {
            throw SlackImportManifestError.invalidJSON
        }

        let records = try rawRecords(from: root)
        var definitions: [Shortcode: Definition] = [:]
        for record in records {
            let shortcode: Shortcode
            do {
                shortcode = try Shortcode(normalizing: record.name)
            } catch {
                throw SlackImportManifestError.invalidName(record.name)
            }
            guard definitions[shortcode] == nil else {
                throw SlackImportManifestError.duplicateName(shortcode)
            }

            if let aliasTarget = record.aliasTarget {
                let target: Shortcode
                do {
                    target = try Shortcode(normalizing: aliasTarget)
                } catch {
                    throw SlackImportManifestError.invalidName(aliasTarget)
                }
                definitions[shortcode] = .alias(target)
            } else if let rawLocation = record.assetLocation {
                definitions[shortcode] = .asset(
                    try parsedLocation(rawLocation)
                )
            } else {
                throw SlackImportManifestError.missingLocationOrAlias(record.name)
            }
        }

        var states: [Shortcode: VisitState] = [:]
        var resolved: [Shortcode: Shortcode] = [:]
        var stack: [Shortcode] = []

        func resolve(_ shortcode: Shortcode) throws -> Shortcode {
            if let target = resolved[shortcode] {
                return target
            }
            guard let definition = definitions[shortcode] else {
                throw SlackImportManifestError.missingAliasTarget(shortcode)
            }
            if states[shortcode] == .visiting {
                let start = stack.firstIndex(of: shortcode) ?? 0
                throw SlackImportManifestError.aliasCycle(
                    Array(stack[start...]) + [shortcode]
                )
            }

            states[shortcode] = .visiting
            stack.append(shortcode)
            let target: Shortcode
            switch definition {
            case .asset:
                target = shortcode
            case let .alias(aliasTarget):
                target = try resolve(aliasTarget)
            }
            _ = stack.popLast()
            states[shortcode] = .visited
            resolved[shortcode] = target
            return target
        }

        for shortcode in definitions.keys.sorted() {
            _ = try resolve(shortcode)
        }

        var aliases: [Shortcode: [Shortcode]] = [:]
        for (shortcode, target) in resolved where shortcode != target {
            aliases[target, default: []].append(shortcode)
        }
        let entries = definitions.keys.sorted().compactMap {
            shortcode -> SlackImportManifestEntry? in
            guard case let .asset(location) = definitions[shortcode] else {
                return nil
            }
            return SlackImportManifestEntry(
                shortcode: shortcode,
                aliases: aliases[shortcode, default: []].sorted(),
                location: location
            )
        }
        return SlackImportManifest(entries: entries)
    }

    private static func rawRecords(
        from root: SlackJSONValue
    ) throws -> [RawRecord] {
        switch root {
        case let .array(values):
            return try values.map(rawRecord(from:))
        case let .object(object):
            if let emoji = object["emoji"] {
                switch emoji {
                case let .array(values):
                    return try values.map(rawRecord(from:))
                case let .object(map):
                    return try rawRecords(from: map)
                default:
                    throw SlackImportManifestError.unsupportedShape
                }
            }
            return try rawRecords(from: object)
        default:
            throw SlackImportManifestError.unsupportedShape
        }
    }

    private static func rawRecords(
        from map: [String: SlackJSONValue]
    ) throws -> [RawRecord] {
        var records: [RawRecord] = []
        for name in map.keys.sorted() {
            if ["ok", "cache_ts", "response_metadata"].contains(name) {
                continue
            }
            guard case let .string(value)? = map[name] else {
                throw SlackImportManifestError.unsupportedShape
            }
            if value.hasPrefix("alias:") {
                records.append(
                    RawRecord(
                        name: name,
                        assetLocation: nil,
                        aliasTarget: String(value.dropFirst("alias:".count))
                    )
                )
            } else {
                records.append(
                    RawRecord(
                        name: name,
                        assetLocation: value,
                        aliasTarget: nil
                    )
                )
            }
        }
        return records
    }

    private static func rawRecord(
        from value: SlackJSONValue
    ) throws -> RawRecord {
        guard case let .object(object) = value,
              case let .string(name)? = object["name"] else {
            throw SlackImportManifestError.unsupportedShape
        }
        let alias = firstString(
            in: object,
            keys: ["alias_for", "aliasFor", "alias"]
        ).map {
            $0.hasPrefix("alias:")
                ? String($0.dropFirst("alias:".count))
                : $0
        }
        let location = firstString(
            in: object,
            keys: ["url", "image_url", "imageUrl", "path", "file"]
        )
        return RawRecord(
            name: name,
            assetLocation: alias == nil ? location : nil,
            aliasTarget: alias
        )
    }

    private static func firstString(
        in object: [String: SlackJSONValue],
        keys: [String]
    ) -> String? {
        keys.lazy.compactMap { key -> String? in
            guard case let .string(value)? = object[key], !value.isEmpty else {
                return nil
            }
            return value
        }.first
    }

    private static func parsedLocation(
        _ value: String
    ) throws -> SlackImportAssetLocation {
        if let components = URLComponents(string: value),
           components.scheme != nil {
            guard let url = components.url else {
                throw SlackImportManifestError.unsafeAssetLocation(value)
            }
            do {
                try ImportURLPolicy.slackAsset.validate(url)
            } catch {
                throw SlackImportManifestError.unsafeAssetLocation(value)
            }
            return .remote(url)
        }
        guard isSafeRelativePath(value) else {
            throw SlackImportManifestError.unsafeAssetLocation(value)
        }
        return .local(relativePath: value)
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 1_024,
              !value.hasPrefix("/"),
              !value.contains("\\"),
              !value.contains(":"),
              !value.unicodeScalars.contains(where: {
                  $0.value == 0 || $0.value < 0x20 || $0.value == 0x7F
              }) else {
            return false
        }
        let components = value.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        return components.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255
        }
    }

    private struct RawRecord {
        let name: String
        let assetLocation: String?
        let aliasTarget: String?
    }

    private enum Definition {
        case asset(SlackImportAssetLocation)
        case alias(Shortcode)
    }

    private enum VisitState {
        case visiting
        case visited
    }
}

struct SlackManifestImportLimits: Equatable, Sendable {
    var maximumManifestBytes: Int64 = 1 * 1_024 * 1_024
    var maximumRemoteAssetBytes: Int64 = 25 * 1_024 * 1_024
    var maximumAssetCount = 2_000
    var maximumTotalAssetBytes: Int64 = 250 * 1_024 * 1_024

    static let `default` = Self()
}

struct SlackManifestImporter: Sendable {
    let transport: any ImportHTTPTransport
    let validator: AssetValidator
    let limits: SlackManifestImportLimits

    init(
        transport: any ImportHTTPTransport = URLSessionImportHTTPTransport(),
        validator: AssetValidator = .init(),
        limits: SlackManifestImportLimits = .default
    ) {
        self.transport = transport
        self.validator = validator
        self.limits = limits
    }

    func scan(
        manifestAt manifestURL: URL,
        packName: String? = nil,
        allowRemoteAssets: Bool,
        workingDirectory: URL
    ) async throws -> ImportScanResult {
        try Task.checkCancellation()
        let manifestValues = try manifestURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard manifestValues.isRegularFile == true,
              manifestValues.isSymbolicLink != true else {
            throw SlackImportManifestError.unsafeManifestFile
        }
        let manifestBytes = Int64(manifestValues.fileSize ?? 0)
        guard manifestBytes > 0, manifestBytes <= limits.maximumManifestBytes else {
            throw SlackImportManifestError.manifestTooLarge(
                actual: manifestBytes,
                limit: limits.maximumManifestBytes
            )
        }
        let manifest = try SlackImportManifestParser.parse(
            Data(contentsOf: manifestURL, options: [.mappedIfSafe])
        )
        guard manifest.entries.count <= limits.maximumAssetCount else {
            throw SlackImportManifestError.tooManyAssets(
                actual: manifest.entries.count,
                limit: limits.maximumAssetCount
            )
        }

        let rootURL = manifestURL.deletingLastPathComponent().standardizedFileURL
        try Self.requireSafeDirectory(rootURL)
        try Self.requireSafeDirectory(workingDirectory)
        let downloadDirectory = workingDirectory.appendingPathComponent(
            "slack-assets",
            isDirectory: true
        )
        if !FileManager.default.fileExists(atPath: downloadDirectory.path) {
            try FileManager.default.createDirectory(
                at: downloadDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }

        var preparedItems: [PreparedEmoji] = []
        var rejections: [ImportRejection] = []
        var totalBytes: Int64 = 0
        for entry in manifest.entries {
            try Task.checkCancellation()
            do {
                let source = try await sourceFile(
                    for: entry,
                    rootURL: rootURL,
                    allowRemoteAssets: allowRemoteAssets,
                    downloadDirectory: downloadDirectory
                )
                let asset = try validator.validate(fileAt: source.url)
                let (nextTotal, overflow) = totalBytes.addingReportingOverflow(
                    asset.digest.byteCount
                )
                guard !overflow, nextTotal <= limits.maximumTotalAssetBytes else {
                    throw ImportScanError.totalBytesExceeded(
                        limit: limits.maximumTotalAssetBytes
                    )
                }
                totalBytes = nextTotal
                preparedItems.append(
                    PreparedEmoji(
                        shortcode: entry.shortcode,
                        aliases: entry.aliases,
                        displayName: Self.displayName(for: entry.shortcode),
                        order: preparedItems.count,
                        sourceURL: source.url,
                        sourceFilename: source.sourceName,
                        asset: asset
                    )
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ImportScanError {
                throw error
            } catch {
                rejections.append(
                    ImportRejection(
                        source: entry.shortcode.rawValue,
                        reason: error.localizedDescription
                    )
                )
            }
        }

        let resolvedPackName = (
            packName ?? rootURL.lastPathComponent
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedPackName.isEmpty else {
            throw ImportScanError.emptyPackName
        }
        return ImportScanResult(
            preparedPack: PreparedPackImport(
                name: resolvedPackName,
                source: PackSource(
                    kind: .slackManifest,
                    displayLocation: manifestURL.lastPathComponent
                ),
                items: preparedItems
            ),
            rejections: rejections,
            ignoredFileCount: 0
        )
    }

    private func sourceFile(
        for entry: SlackImportManifestEntry,
        rootURL: URL,
        allowRemoteAssets: Bool,
        downloadDirectory: URL
    ) async throws -> (url: URL, sourceName: String) {
        switch entry.location {
        case let .local(relativePath):
            let url = try Self.localAssetURL(
                relativePath: relativePath,
                rootURL: rootURL
            )
            return (url, relativePath)
        case let .remote(url):
            guard allowRemoteAssets else {
                throw SlackImportManifestError.remoteDownloadsDisabled(
                    entry.shortcode
                )
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            request.setValue("MojiPond/0.1", forHTTPHeaderField: "User-Agent")
            let response = try await transport.fetch(
                request,
                policy: .slackAsset,
                maximumBytes: limits.maximumRemoteAssetBytes
            )
            try ImportURLPolicy.slackAsset.validate(response.finalURL)
            guard Int64(response.data.count) <= limits.maximumRemoteAssetBytes else {
                throw ImportHTTPError.responseTooLarge(
                    limit: limits.maximumRemoteAssetBytes
                )
            }
            guard response.statusCode == 200 else {
                throw SlackImportManifestError.assetHTTPStatus(
                    entry.shortcode,
                    response.statusCode
                )
            }
            guard !response.data.isEmpty else {
                throw SlackImportManifestError.emptyRemoteAsset(entry.shortcode)
            }

            let filenameExtension = try Self.filenameExtension(
                response: response
            )
            let filename = [
                entry.shortcode.rawValue,
                UUID().uuidString.lowercased()
            ].joined(separator: "-") + ".\(filenameExtension)"
            let destination = downloadDirectory.appendingPathComponent(
                filename,
                isDirectory: false
            )
            try response.data.write(to: destination, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
            return (destination, url.lastPathComponent)
        }
    }

    private static func localAssetURL(
        relativePath: String,
        rootURL: URL
    ) throws -> URL {
        let components = relativePath.split(separator: "/").map(String.init)
        var current = rootURL
        for (index, component) in components.enumerated() {
            current.appendPathComponent(
                component,
                isDirectory: index < components.count - 1
            )
            let values: URLResourceValues
            do {
                values = try current.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ])
            } catch {
                throw SlackImportManifestError.missingLocalAsset(relativePath)
            }
            guard values.isSymbolicLink != true else {
                throw SlackImportManifestError.unsafeLocalAsset(relativePath)
            }
            if index < components.count - 1, values.isDirectory != true {
                throw SlackImportManifestError.missingLocalAsset(relativePath)
            }
        }
        let candidate = current.standardizedFileURL
        guard candidate.path.hasPrefix(rootURL.path + "/") else {
            throw SlackImportManifestError.unsafeLocalAsset(relativePath)
        }
        return candidate
    }

    private static func filenameExtension(
        response: ImportHTTPResponse
    ) throws -> String {
        let pathExtension = response.finalURL.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "jpe", "gif", "webp"].contains(
            pathExtension
        ) {
            return pathExtension == "jpeg" || pathExtension == "jpe"
                ? "jpg"
                : pathExtension
        }

        let mediaType = response.header("content-type")?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch mediaType {
        case "image/png":
            return "png"
        case "image/jpeg", "image/jpg":
            return "jpg"
        case "image/gif":
            return "gif"
        case "image/webp":
            return "webp"
        default:
            break
        }

        let data = response.data
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return "png"
        }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "jpg"
        }
        if data.starts(with: Data("GIF87a".utf8))
            || data.starts(with: Data("GIF89a".utf8)) {
            return "gif"
        }
        if data.count >= 12,
           data.prefix(4) == Data("RIFF".utf8),
           data.dropFirst(8).prefix(4) == Data("WEBP".utf8) {
            return "webp"
        }
        throw SlackImportManifestError.unknownRemoteAssetType
    }

    private static func requireSafeDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw SlackImportManifestError.unsafeDirectory(url)
        }
    }

    private static func displayName(for shortcode: Shortcode) -> String {
        shortcode.rawValue
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }
}

enum SlackImportManifestError: Error, Equatable, LocalizedError, Sendable {
    case invalidJSON
    case unsupportedShape
    case invalidName(String)
    case duplicateName(Shortcode)
    case missingLocationOrAlias(String)
    case unsafeAssetLocation(String)
    case missingAliasTarget(Shortcode)
    case aliasCycle([Shortcode])
    case unsafeManifestFile
    case manifestTooLarge(actual: Int64, limit: Int64)
    case tooManyAssets(actual: Int, limit: Int)
    case unsafeDirectory(URL)
    case missingLocalAsset(String)
    case unsafeLocalAsset(String)
    case remoteDownloadsDisabled(Shortcode)
    case assetHTTPStatus(Shortcode, Int)
    case emptyRemoteAsset(Shortcode)
    case unknownRemoteAssetType

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            "Slack emoji.json is not valid JSON."
        case .unsupportedShape:
            "Slack emoji.json uses an unsupported structure."
        case let .invalidName(name):
            "Slack emoji name \(name) cannot be normalized safely."
        case let .duplicateName(shortcode):
            "Slack emoji name \(shortcode.rawValue) appears more than once."
        case let .missingLocationOrAlias(name):
            "Slack emoji \(name) has neither an asset path nor an alias."
        case let .unsafeAssetLocation(value):
            "Slack emoji asset location \(value) is unsafe."
        case let .missingAliasTarget(shortcode):
            "Slack alias points to missing emoji \(shortcode.rawValue)."
        case let .aliasCycle(shortcodes):
            "Slack aliases contain a cycle: \(shortcodes.map(\.rawValue).joined(separator: " → "))."
        case .unsafeManifestFile:
            "Slack emoji.json is not a safe regular file."
        case let .manifestTooLarge(actual, limit):
            "Slack emoji.json is \(actual) bytes, above the \(limit)-byte limit."
        case let .tooManyAssets(actual, limit):
            "Slack emoji.json contains \(actual) assets, above the \(limit)-asset limit."
        case let .unsafeDirectory(url):
            "\(url.lastPathComponent) is not a safe directory."
        case let .missingLocalAsset(path):
            "Local Slack asset \(path) does not exist."
        case let .unsafeLocalAsset(path):
            "Local Slack asset \(path) traverses a symbolic link."
        case let .remoteDownloadsDisabled(shortcode):
            "Remote download for \(shortcode.rawValue) requires explicit opt-in."
        case let .assetHTTPStatus(shortcode, status):
            "Remote Slack asset \(shortcode.rawValue) returned HTTP \(status)."
        case let .emptyRemoteAsset(shortcode):
            "Remote Slack asset \(shortcode.rawValue) was empty."
        case .unknownRemoteAssetType:
            "The remote Slack asset type could not be identified."
        }
    }
}

private enum SlackJSONValue: Decodable {
    case string(String)
    case number(Double)
    case object([String: SlackJSONValue])
    case array([SlackJSONValue])
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(
            [String: SlackJSONValue].self
        ) {
            self = .object(value)
        } else if let value = try? container.decode([SlackJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported Slack emoji.json value."
            )
        }
    }
}
