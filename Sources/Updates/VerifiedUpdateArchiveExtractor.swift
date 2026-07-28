import Foundation

enum VerifiedUpdateArchiveError: Error, Equatable, Sendable {
    case invalidArchive
    case expectedSingleApplication
    case unexpectedPayload
    case extractionUnavailable
    case extractionFailed
    case extractedTreeMismatch
}

protocol VerifiedUpdateArchiveExtracting: Sendable {
    func extractApplication(
        from archiveURL: URL,
        to destinationURL: URL
    ) throws -> URL
}

/// Extracts an already authenticated update archive. The archive is still
/// treated as hostile: every ZIP entry is preflighted, symbolic links and
/// special files are rejected, and the extracted tree must exactly match the
/// central-directory manifest.
struct VerifiedUpdateArchiveExtractor: VerifiedUpdateArchiveExtracting {
    static let applicationBundleName = "MojiPond.app"

    private let limits: ZipExtractionLimits
    private let unzipExecutableURL: URL
    private let processTimeout: TimeInterval

    init(
        limits: ZipExtractionLimits = .init(
            maximumArchiveBytes: 512 * 1_024 * 1_024,
            maximumEntryCount: 20_000,
            maximumEntryBytes: 256 * 1_024 * 1_024,
            maximumTotalUncompressedBytes: 1_024 * 1_024 * 1_024,
            maximumCompressionRatio: 200,
            maximumPathBytes: 1_024,
            maximumPathComponentBytes: 255
        ),
        unzipExecutableURL: URL = URL(
            fileURLWithPath: "/usr/bin/unzip",
            isDirectory: false
        ),
        processTimeout: TimeInterval = 120
    ) {
        self.limits = limits
        self.unzipExecutableURL = unzipExecutableURL
        self.processTimeout = processTimeout
    }

    func extractApplication(
        from archiveURL: URL,
        to destinationURL: URL
    ) throws -> URL {
        let inspection: ZipArchiveInspection
        do {
            inspection = try ZipArchiveExtractor(limits: limits).inspect(
                archiveAt: archiveURL
            )
        } catch {
            throw VerifiedUpdateArchiveError.invalidArchive
        }

        let layout = try Self.validatedLayout(from: inspection)
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw VerifiedUpdateArchiveError.extractedTreeMismatch
        }
        guard fileManager.isExecutableFile(atPath: unzipExecutableURL.path) else {
            throw VerifiedUpdateArchiveError.extractionUnavailable
        }

        do {
            try fileManager.createDirectory(
                at: destinationURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw VerifiedUpdateArchiveError.extractionFailed
        }

        var shouldRemoveDestination = true
        defer {
            if shouldRemoveDestination {
                try? fileManager.removeItem(at: destinationURL)
            }
        }

        guard BoundedUpdateToolRunner.run(
            executableURL: unzipExecutableURL,
            arguments: [
                "-qq",
                archiveURL.path,
                "-d",
                destinationURL.path
            ],
            environment: [
                "LANG": "C",
                "LC_ALL": "C"
            ],
            timeout: processTimeout
        ) else {
            throw VerifiedUpdateArchiveError.extractionFailed
        }

        try Self.verifyExtractedTree(
            at: destinationURL,
            inspection: inspection
        )
        let applicationURL = destinationURL.appendingPathComponent(
            layout.applicationPath,
            isDirectory: true
        )
        let applicationValues = try? applicationURL.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ]
        )
        guard applicationValues?.isDirectory == true,
              applicationValues?.isSymbolicLink != true else {
            throw VerifiedUpdateArchiveError.extractedTreeMismatch
        }

        shouldRemoveDestination = false
        return applicationURL
    }

    private static func validatedLayout(
        from inspection: ZipArchiveInspection
    ) throws -> UpdateArchiveLayout {
        var applicationPaths = Set<String>()
        for entry in inspection.entries {
            let path = entry.path.hasSuffix("/")
                ? String(entry.path.dropLast())
                : entry.path
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            for index in components.indices
            where components[index].lowercased().hasSuffix(".app") {
                let applicationPath = components[...index].joined(separator: "/")
                applicationPaths.insert(applicationPath)
            }
        }

        guard applicationPaths.count == 1,
              let applicationPath = applicationPaths.first,
              applicationPath.split(separator: "/").last
                == Substring(applicationBundleName) else {
            throw VerifiedUpdateArchiveError.expectedSingleApplication
        }

        let applicationPrefix = applicationPath + "/"
        let ancestorPaths = ancestorPaths(of: applicationPath)
        for entry in inspection.entries {
            let path = entry.path.hasSuffix("/")
                ? String(entry.path.dropLast())
                : entry.path
            if path == applicationPath || path.hasPrefix(applicationPrefix) {
                continue
            }
            guard entry.isDirectory, ancestorPaths.contains(path) else {
                throw VerifiedUpdateArchiveError.unexpectedPayload
            }
        }
        guard inspection.entries.contains(where: {
            !$0.isDirectory
                && $0.path == applicationPrefix + "Contents/Info.plist"
        }) else {
            throw VerifiedUpdateArchiveError.unexpectedPayload
        }
        return UpdateArchiveLayout(applicationPath: applicationPath)
    }

    private static func ancestorPaths(of path: String) -> Set<String> {
        let components = path.split(separator: "/")
        guard components.count > 1 else {
            return []
        }
        return Set(
            (1..<components.count).map {
                components.prefix($0).joined(separator: "/")
            }
        )
    }

    private static func verifyExtractedTree(
        at rootURL: URL,
        inspection: ZipArchiveInspection
    ) throws {
        let fileManager = FileManager.default
        let root = rootURL.standardizedFileURL
        let rootPath = root.path
        let expectedFiles = Dictionary(
            uniqueKeysWithValues: inspection.entries.compactMap { entry in
                entry.isDirectory
                    ? nil
                    : (entry.path, entry.uncompressedBytes)
            }
        )
        let expectedDirectories = expectedDirectoryPaths(in: inspection)
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw VerifiedUpdateArchiveError.extractedTreeMismatch
        }

        var actualFiles = Set<String>()
        var actualDirectories = Set<String>()
        for case let url as URL in enumerator {
            let standardizedURL = url.standardizedFileURL
            let standardizedPath = standardizedURL.path
            guard standardizedPath.hasPrefix(rootPath + "/") else {
                throw VerifiedUpdateArchiveError.extractedTreeMismatch
            }
            let values = try standardizedURL.resourceValues(
                forKeys: resourceKeys
            )
            guard values.isSymbolicLink != true else {
                throw VerifiedUpdateArchiveError.extractedTreeMismatch
            }

            let resolvedPath = standardizedURL.resolvingSymlinksInPath().path
            guard resolvedPath.hasPrefix(rootPath + "/") else {
                throw VerifiedUpdateArchiveError.extractedTreeMismatch
            }
            let attributes = try fileManager.attributesOfItem(
                atPath: standardizedPath
            )
            let permissions = (
                attributes[.posixPermissions] as? NSNumber
            )?.intValue ?? -1
            // Update archives may preserve executable bits, but never special
            // bits or group/world writability.
            guard permissions >= 0,
                  permissions & 0o7022 == 0 else {
                throw VerifiedUpdateArchiveError.extractedTreeMismatch
            }
            let relativePath = String(
                standardizedPath.dropFirst(rootPath.count + 1)
            )

            if values.isDirectory == true {
                guard expectedDirectories.contains(relativePath) else {
                    throw VerifiedUpdateArchiveError.extractedTreeMismatch
                }
                actualDirectories.insert(relativePath)
                continue
            }
            guard values.isRegularFile == true,
                  let expectedByteCount = expectedFiles[relativePath],
                  Int64(values.fileSize ?? -1) == expectedByteCount,
                  (attributes[.referenceCount] as? NSNumber)?.intValue
                      == 1,
                  actualFiles.insert(relativePath).inserted else {
                throw VerifiedUpdateArchiveError.extractedTreeMismatch
            }
        }

        guard actualFiles == Set(expectedFiles.keys),
              actualDirectories == expectedDirectories else {
            throw VerifiedUpdateArchiveError.extractedTreeMismatch
        }
    }

    private static func expectedDirectoryPaths(
        in inspection: ZipArchiveInspection
    ) -> Set<String> {
        var directories = Set<String>()
        for entry in inspection.entries {
            let path = entry.path.hasSuffix("/")
                ? String(entry.path.dropLast())
                : entry.path
            let components = path.split(separator: "/")
            let parentCount = entry.isDirectory
                ? components.count
                : max(0, components.count - 1)
            guard parentCount > 0 else {
                continue
            }
            for count in 1...parentCount {
                directories.insert(
                    components.prefix(count).joined(separator: "/")
                )
            }
        }
        return directories
    }
}

private struct UpdateArchiveLayout {
    let applicationPath: String
}
