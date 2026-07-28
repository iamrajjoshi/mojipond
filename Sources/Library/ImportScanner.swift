import Foundation

struct ImportScanLimits: Equatable, Sendable {
    var maximumFileCount = 2_000
    var maximumDirectoryDepth = 12
    var maximumTotalInputBytes: Int64 = 250 * 1_024 * 1_024

    static let `default` = Self()
}

struct ImportScanner: Sendable {
    private static let maximumPortableManifestBytes: Int64 = 1 * 1_024 * 1_024
    private static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "jpe", "gif", "webp"
    ]

    let validator: AssetValidator
    let limits: ImportScanLimits

    init(
        validator: AssetValidator = .init(),
        limits: ImportScanLimits = .default
    ) {
        self.validator = validator
        self.limits = limits
    }

    func scanFiles(
        _ urls: [URL],
        packName: String
    ) throws -> ImportScanResult {
        guard urls.count <= limits.maximumFileCount else {
            throw ImportScanError.tooManyFiles(actual: urls.count, limit: limits.maximumFileCount)
        }

        let source = PackSource(kind: .individualFiles)
        return try scan(
            urls: urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending },
            packName: packName,
            source: source,
            ignoreUnsupportedExtensions: false
        )
    }

    func scanFolder(
        at folderURL: URL,
        packName: String? = nil
    ) throws -> ImportScanResult {
        let rootValues = try folderURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey
        ])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw ImportScanError.notADirectory(folderURL)
        }

        let root = folderURL.standardizedFileURL
        let portableManifestURL = root.appendingPathComponent(
            MojiPondLibrary.manifestFilename,
            isDirectory: false
        )
        if FileManager.default.fileExists(atPath: portableManifestURL.path) {
            return try scanPortablePack(manifestAt: portableManifestURL)
        }

        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            throw ImportScanError.cannotEnumerate(root)
        }

        var candidateURLs: [URL] = []
        var rejectionURLs: [URL] = []
        var encounteredCount = 0
        var ignoredRegularFileCount = 0
        let rootDepth = root.pathComponents.count

        for case let childURL as URL in enumerator {
            encounteredCount += 1
            guard encounteredCount <= limits.maximumFileCount else {
                throw ImportScanError.tooManyFiles(
                    actual: encounteredCount,
                    limit: limits.maximumFileCount
                )
            }

            let child = childURL.standardizedFileURL
            guard Self.isDescendant(child, of: root) else {
                throw ImportScanError.pathEscapedRoot(child)
            }
            let values = try child.resourceValues(forKeys: Set(keys))
            let depth = child.pathComponents.count - rootDepth
            if depth > limits.maximumDirectoryDepth {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                rejectionURLs.append(child)
                continue
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                rejectionURLs.append(child)
                continue
            }
            guard values.isRegularFile == true else {
                continue
            }
            if Self.supportedExtensions.contains(child.pathExtension.lowercased()) {
                candidateURLs.append(child)
            } else {
                ignoredRegularFileCount += 1
            }
        }

        var result = try scan(
            urls: candidateURLs.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending },
            packName: packName ?? folderURL.lastPathComponent,
            source: PackSource(kind: .folder, displayLocation: folderURL.lastPathComponent),
            ignoreUnsupportedExtensions: true
        )
        if !rejectionURLs.isEmpty {
            let extra = rejectionURLs.map { url in
                ImportRejection(
                    source: url.lastPathComponent,
                    reason: "Symlinks and paths deeper than \(limits.maximumDirectoryDepth) levels are not imported."
                )
            }
            result = ImportScanResult(
                preparedPack: result.preparedPack,
                rejections: result.rejections + extra,
                ignoredFileCount: result.ignoredFileCount + ignoredRegularFileCount
            )
        } else if ignoredRegularFileCount > 0 {
            result = ImportScanResult(
                preparedPack: result.preparedPack,
                rejections: result.rejections,
                ignoredFileCount: result.ignoredFileCount + ignoredRegularFileCount
            )
        }
        return result
    }

    func scanPortablePack(manifestAt manifestURL: URL) throws -> ImportScanResult {
        let values = try manifestURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw PortablePackManifestError.unsafeManifestFile
        }
        let manifestBytes = Int64(values.fileSize ?? 0)
        guard manifestBytes > 0,
              manifestBytes <= Self.maximumPortableManifestBytes else {
            throw PortablePackManifestError.manifestTooLarge(
                actual: manifestBytes,
                limit: Self.maximumPortableManifestBytes
            )
        }

        let root = manifestURL.deletingLastPathComponent().standardizedFileURL
        let manifest = try PortablePackManifest.decode(
            Data(contentsOf: manifestURL, options: [.mappedIfSafe])
        )
        guard manifest.emoji.count <= limits.maximumFileCount else {
            throw ImportScanError.tooManyFiles(
                actual: manifest.emoji.count,
                limit: limits.maximumFileCount
            )
        }

        var preparedItems: [PreparedEmoji] = []
        var totalBytes: Int64 = 0
        for (index, entry) in manifest.emoji.enumerated() {
            let assetURL = root.appendingPathComponent(entry.file).standardizedFileURL
            guard Self.isDescendant(assetURL, of: root) else {
                throw PortablePackManifestError.assetOutsidePack(entry.file)
            }
            guard FileManager.default.fileExists(atPath: assetURL.path) else {
                throw PortablePackManifestError.missingAsset(entry.file)
            }

            let asset: ValidatedAsset
            do {
                asset = try validator.validate(fileAt: assetURL)
            } catch {
                throw PortablePackManifestError.assetRejected(
                    entry.file,
                    error.localizedDescription
                )
            }
            let (newTotal, overflow) = totalBytes.addingReportingOverflow(asset.digest.byteCount)
            guard !overflow, newTotal <= limits.maximumTotalInputBytes else {
                throw PortablePackManifestError.totalBytesExceeded(
                    limits.maximumTotalInputBytes
                )
            }
            totalBytes = newTotal
            preparedItems.append(
                PreparedEmoji(
                    shortcode: entry.shortcode,
                    aliases: entry.aliases,
                    displayName: entry.displayName,
                    tags: entry.tags,
                    category: entry.category,
                    order: entry.order ?? index,
                    sourceURL: assetURL,
                    sourceFilename: entry.file,
                    asset: asset
                )
            )
        }

        return ImportScanResult(
            preparedPack: PreparedPackImport(
                name: manifest.name,
                manifest: manifest.metadata,
                source: PackSource(
                    kind: .folder,
                    displayLocation: root.lastPathComponent
                ),
                updateMetadata: PackUpdateMetadata(
                    sourceRevision: manifest.version
                ),
                items: preparedItems
            ),
            rejections: [],
            ignoredFileCount: 0
        )
    }

    /// Safely expands a ZIP into a caller-owned fresh directory, then runs the same
    /// bounded folder scanner. The caller must keep `destinationURL` alive until the
    /// resulting prepared import is installed.
    func scanZIPArchive(
        at archiveURL: URL,
        extractingTo destinationURL: URL,
        packName: String? = nil,
        extractor: ZipArchiveExtractor = .init()
    ) throws -> ImportScanResult {
        _ = try extractor.extract(archiveAt: archiveURL, to: destinationURL)

        var scanRoot = destinationURL
        let children = try FileManager.default.contentsOfDirectory(
            at: destinationURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        if children.count == 1,
           let child = children.first {
            let values = try child.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ])
            if values.isDirectory == true, values.isSymbolicLink != true {
                scanRoot = child
            }
        }

        let scanned = try scanFolder(
            at: scanRoot,
            packName: packName ?? archiveURL.deletingPathExtension().lastPathComponent
        )
        var preparedPack = scanned.preparedPack
        preparedPack.source = PackSource(
            kind: .zipArchive,
            displayLocation: archiveURL.lastPathComponent
        )
        return ImportScanResult(
            preparedPack: preparedPack,
            rejections: scanned.rejections,
            ignoredFileCount: scanned.ignoredFileCount
        )
    }

    private func scan(
        urls: [URL],
        packName: String,
        source: PackSource,
        ignoreUnsupportedExtensions: Bool
    ) throws -> ImportScanResult {
        var items: [PreparedEmoji] = []
        var rejections: [ImportRejection] = []
        var ignoredCount = 0
        var totalBytes: Int64 = 0

        for url in urls {
            if !Self.supportedExtensions.contains(url.pathExtension.lowercased()) {
                if ignoreUnsupportedExtensions {
                    ignoredCount += 1
                } else {
                    rejections.append(
                        ImportRejection(
                            source: url.lastPathComponent,
                            reason: "Only PNG, JPEG, GIF, and WebP files are supported."
                        )
                    )
                }
                continue
            }

            do {
                let asset = try validator.validate(fileAt: url)
                let (newTotal, overflow) = totalBytes.addingReportingOverflow(asset.digest.byteCount)
                guard !overflow, newTotal <= limits.maximumTotalInputBytes else {
                    throw ImportScanError.totalBytesExceeded(limit: limits.maximumTotalInputBytes)
                }
                totalBytes = newTotal

                let shortcode = try Shortcode(
                    normalizing: url.deletingPathExtension().lastPathComponent
                )
                items.append(
                    PreparedEmoji(
                        shortcode: shortcode,
                        displayName: Self.displayName(for: shortcode),
                        order: items.count,
                        sourceURL: url,
                        asset: asset
                    )
                )
            } catch let error as ImportScanError {
                throw error
            } catch {
                rejections.append(
                    ImportRejection(
                        source: url.lastPathComponent,
                        reason: error.localizedDescription
                    )
                )
            }
        }

        let cleanedName = packName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty else {
            throw ImportScanError.emptyPackName
        }
        return ImportScanResult(
            preparedPack: PreparedPackImport(
                name: cleanedName,
                source: source,
                items: items
            ),
            rejections: rejections,
            ignoredFileCount: ignoredCount
        )
    }

    private static func displayName(for shortcode: Shortcode) -> String {
        shortcode.rawValue.replacingOccurrences(of: "_", with: " ")
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath.hasPrefix(rootPath + "/")
    }
}

enum ImportScanError: Error, Equatable, LocalizedError, Sendable {
    case notADirectory(URL)
    case cannotEnumerate(URL)
    case tooManyFiles(actual: Int, limit: Int)
    case totalBytesExceeded(limit: Int64)
    case pathEscapedRoot(URL)
    case emptyPackName

    var errorDescription: String? {
        switch self {
        case let .notADirectory(url):
            "\(url.lastPathComponent) is not an importable directory."
        case let .cannotEnumerate(url):
            "Could not enumerate \(url.lastPathComponent)."
        case let .tooManyFiles(actual, limit):
            "Import contains \(actual) entries, above the \(limit)-entry limit."
        case let .totalBytesExceeded(limit):
            "Import exceeds the \(limit)-byte total limit."
        case let .pathEscapedRoot(url):
            "Import path escaped its selected folder: \(url.path)."
        case .emptyPackName:
            "Pack name cannot be empty."
        }
    }
}
