import CryptoKit
import Foundation
import UniformTypeIdentifiers

enum RuntimeManagedMediaError: Error, Equatable, LocalizedError, Sendable {
    case rootUnavailable
    case unsafeRelativePath
    case escapedManagedRoot
    case missingFile
    case notRegularFile
    case emptyFile
    case fileTooLarge(limit: Int)
    case digestMismatch
    case contentTypeMismatch

    var errorDescription: String? {
        switch self {
        case .rootUnavailable:
            "The managed media library is unavailable."
        case .unsafeRelativePath:
            "The media item contains an unsafe path."
        case .escapedManagedRoot:
            "The media item resolves outside the managed library."
        case .missingFile:
            "The original media file is missing."
        case .notRegularFile:
            "The media item is not a regular file."
        case .emptyFile:
            "The media file is empty."
        case let .fileTooLarge(limit):
            "The media file is larger than the \(limit)-byte safety limit."
        case .digestMismatch:
            "The media file no longer matches its imported integrity digest."
        case .contentTypeMismatch:
            "The media file does not match its declared image type."
        }
    }
}

struct RuntimeResolvedManagedMedia: Equatable, Sendable {
    let originalData: Data
    let uniformType: UTType
    let suggestedFilename: String

    var pasteboardPayload: PasteboardItemPayload {
        .image(
            originalData: originalData,
            type: uniformType,
            includeCompatibilityFallbacks: true
        )
    }
}

protocol RuntimeManagedMediaResolving: Sendable {
    func resolve(
        _ media: MediaEmojiContent,
        beneath managedRoot: URL
    ) throws -> RuntimeResolvedManagedMedia
}

/// Opens only immutable imported assets below MojiPond's managed Library root.
/// The canonical path check is deliberately repeated at insertion time so a
/// post-import symlink swap or file modification fails closed.
struct RuntimeManagedMediaResolver:
    RuntimeManagedMediaResolving,
    @unchecked Sendable
{
    static let defaultMaximumBytes = 25 * 1_024 * 1_024

    let maximumBytes: Int
    private let fileManager: FileManager

    init(
        maximumBytes: Int = defaultMaximumBytes,
        fileManager: FileManager = .default
    ) {
        self.maximumBytes = max(0, maximumBytes)
        self.fileManager = fileManager
    }

    func resolve(
        _ media: MediaEmojiContent,
        beneath managedRoot: URL
    ) throws -> RuntimeResolvedManagedMedia {
        guard Self.isSafe(relativePath: media.relativePath) else {
            throw RuntimeManagedMediaError.unsafeRelativePath
        }

        let canonicalRoot = managedRoot
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var rootIsDirectory: ObjCBool = false
        guard
            fileManager.fileExists(
                atPath: canonicalRoot.path,
                isDirectory: &rootIsDirectory
            ),
            rootIsDirectory.boolValue
        else {
            throw RuntimeManagedMediaError.rootUnavailable
        }

        let candidate = canonicalRoot
            .appendingPathComponent(media.relativePath, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard Self.isDescendant(candidate, of: canonicalRoot) else {
            throw RuntimeManagedMediaError.escapedManagedRoot
        }

        var isDirectory: ObjCBool = false
        guard
            fileManager.fileExists(
                atPath: candidate.path,
                isDirectory: &isDirectory
            )
        else {
            throw RuntimeManagedMediaError.missingFile
        }
        guard !isDirectory.boolValue else {
            throw RuntimeManagedMediaError.notRegularFile
        }

        let resourceValues = try? candidate.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ]
        )
        guard
            resourceValues?.isRegularFile == true,
            resourceValues?.isSymbolicLink != true
        else {
            throw RuntimeManagedMediaError.notRegularFile
        }
        guard let fileSize = resourceValues?.fileSize, fileSize > 0 else {
            throw RuntimeManagedMediaError.emptyFile
        }
        guard fileSize <= maximumBytes else {
            throw RuntimeManagedMediaError.fileTooLarge(limit: maximumBytes)
        }

        let data: Data
        do {
            data = try Data(contentsOf: candidate, options: [.mappedIfSafe])
        } catch {
            throw RuntimeManagedMediaError.missingFile
        }
        guard !data.isEmpty else {
            throw RuntimeManagedMediaError.emptyFile
        }
        guard data.count <= maximumBytes else {
            throw RuntimeManagedMediaError.fileTooLarge(limit: maximumBytes)
        }
        guard
            Self.sha256(data)
                == media.contentHash.lowercased(
                    with: Locale(identifier: "en_US_POSIX")
                )
        else {
            throw RuntimeManagedMediaError.digestMismatch
        }

        let uniformType = Self.uniformType(for: media.mediaType)
        guard Self.matchesMagic(data, mediaType: media.mediaType) else {
            throw RuntimeManagedMediaError.contentTypeMismatch
        }

        return RuntimeResolvedManagedMedia(
            originalData: data,
            uniformType: uniformType,
            suggestedFilename: Self.safeFilename(
                media.originalFilename,
                fallbackPath: media.relativePath,
                mediaType: media.mediaType
            )
        )
    }

    private static func isSafe(relativePath: String) -> Bool {
        guard
            !relativePath.isEmpty,
            !relativePath.hasPrefix("/"),
            !relativePath.contains("\\"),
            !relativePath.unicodeScalars.contains(where: {
                $0.value == 0 || $0.value < 0x20
            })
        else {
            return false
        }
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        return !components.isEmpty && components.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.path
        let candidatePath = candidate.path
        return candidatePath.hasPrefix(
            rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func uniformType(for mediaType: EmojiMediaType) -> UTType {
        switch mediaType {
        case .png:
            .png
        case .jpeg:
            .jpeg
        case .gif:
            .gif
        case .webP:
            .webP
        }
    }

    private static func matchesMagic(
        _ data: Data,
        mediaType: EmojiMediaType
    ) -> Bool {
        switch mediaType {
        case .png:
            data.starts(with: [
                0x89, 0x50, 0x4E, 0x47,
                0x0D, 0x0A, 0x1A, 0x0A
            ])
        case .jpeg:
            data.count >= 3
                && data[data.startIndex] == 0xFF
                && data[data.index(after: data.startIndex)] == 0xD8
                && data[data.index(data.startIndex, offsetBy: 2)] == 0xFF
        case .gif:
            data.starts(with: Data("GIF87a".utf8))
                || data.starts(with: Data("GIF89a".utf8))
        case .webP:
            data.count >= 12
                && data.prefix(4) == Data("RIFF".utf8)
                && data.dropFirst(8).prefix(4) == Data("WEBP".utf8)
        }
    }

    private static func safeFilename(
        _ originalFilename: String?,
        fallbackPath: String,
        mediaType: EmojiMediaType
    ) -> String {
        let candidate = originalFilename?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let basename = candidate.flatMap {
            URL(fileURLWithPath: $0).lastPathComponent
        }
        guard
            let basename,
            !basename.isEmpty,
            basename != ".",
            basename != "..",
            basename.utf8.count <= 255
        else {
            let fallback = URL(
                fileURLWithPath: fallbackPath
            ).deletingPathExtension().lastPathComponent
            return "\(fallback).\(fileExtension(for: mediaType))"
        }
        return basename
    }

    private static func fileExtension(
        for mediaType: EmojiMediaType
    ) -> String {
        switch mediaType {
        case .png:
            "png"
        case .jpeg:
            "jpg"
        case .gif:
            "gif"
        case .webP:
            "webp"
        }
    }
}
