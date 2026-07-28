import Foundation

struct ZipExtractionLimits: Equatable, Sendable {
    var maximumArchiveBytes: Int64 = 100 * 1_024 * 1_024
    var maximumEntryCount = 5_000
    var maximumEntryBytes: Int64 = 25 * 1_024 * 1_024
    var maximumTotalUncompressedBytes: Int64 = 250 * 1_024 * 1_024
    var maximumCompressionRatio: Int64 = 200
    var maximumPathBytes = 1_024
    var maximumPathComponentBytes = 255

    static let `default` = Self()
}

struct ZipArchiveEntry: Equatable, Sendable {
    let path: String
    let compressedBytes: Int64
    let uncompressedBytes: Int64
    let isDirectory: Bool
}

struct ZipArchiveInspection: Equatable, Sendable {
    let entries: [ZipArchiveEntry]

    var totalUncompressedBytes: Int64 {
        entries.reduce(0) { $0 + $1.uncompressedBytes }
    }
}

struct ZipArchiveExtractor: Sendable {
    let limits: ZipExtractionLimits
    let unzipExecutableURL: URL

    init(
        limits: ZipExtractionLimits = .default,
        unzipExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/unzip")
    ) {
        self.limits = limits
        self.unzipExecutableURL = unzipExecutableURL
    }

    func inspect(archiveAt archiveURL: URL) throws -> ZipArchiveInspection {
        let values = try archiveURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ZipArchiveError.notARegularFile
        }
        let fileSize = Int64(values.fileSize ?? 0)
        guard fileSize > 0, fileSize <= limits.maximumArchiveBytes else {
            throw ZipArchiveError.archiveTooLarge(actual: fileSize, limit: limits.maximumArchiveBytes)
        }

        let data = try Data(contentsOf: archiveURL, options: [.mappedIfSafe, .uncached])
        guard let endOffset = findEndOfCentralDirectory(in: data) else {
            throw ZipArchiveError.missingEndOfCentralDirectory
        }
        guard data.uint32(at: endOffset) == 0x0605_4B50 else {
            throw ZipArchiveError.missingEndOfCentralDirectory
        }

        let diskNumber = try data.requiredUInt16(at: endOffset + 4)
        let centralDirectoryDisk = try data.requiredUInt16(at: endOffset + 6)
        let entriesOnDisk = try data.requiredUInt16(at: endOffset + 8)
        let entryCount = try data.requiredUInt16(at: endOffset + 10)
        let centralDirectorySize = try data.requiredUInt32(at: endOffset + 12)
        let centralDirectoryOffset = try data.requiredUInt32(at: endOffset + 16)
        let commentLength = try data.requiredUInt16(at: endOffset + 20)

        guard diskNumber == 0, centralDirectoryDisk == 0, entriesOnDisk == entryCount else {
            throw ZipArchiveError.multiDiskArchive
        }
        guard entryCount != UInt16.max,
              centralDirectorySize != UInt32.max,
              centralDirectoryOffset != UInt32.max else {
            throw ZipArchiveError.zip64NotSupported
        }
        guard Int(entryCount) <= limits.maximumEntryCount else {
            throw ZipArchiveError.tooManyEntries(
                actual: Int(entryCount),
                limit: limits.maximumEntryCount
            )
        }
        guard endOffset + 22 + Int(commentLength) == data.count else {
            throw ZipArchiveError.trailingData
        }

        let centralStart = Int(centralDirectoryOffset)
        let centralSize = Int(centralDirectorySize)
        guard centralStart >= 0,
              centralSize >= 0,
              centralStart <= endOffset,
              centralSize <= endOffset - centralStart,
              centralStart + centralSize == endOffset else {
            throw ZipArchiveError.invalidCentralDirectory
        }

        var entries: [ZipArchiveEntry] = []
        var entryRanges: [Range<Int>] = []
        var seenPaths = Set<String>()
        var totalUncompressed: Int64 = 0
        var cursor = centralStart

        for _ in 0..<Int(entryCount) {
            guard try data.requiredUInt32(at: cursor) == 0x0201_4B50 else {
                throw ZipArchiveError.invalidCentralDirectory
            }
            let versionMadeBy = try data.requiredUInt16(at: cursor + 4)
            let flags = try data.requiredUInt16(at: cursor + 8)
            let method = try data.requiredUInt16(at: cursor + 10)
            let compressedSize = try data.requiredUInt32(at: cursor + 20)
            let uncompressedSize = try data.requiredUInt32(at: cursor + 24)
            let filenameLength = Int(try data.requiredUInt16(at: cursor + 28))
            let extraLength = Int(try data.requiredUInt16(at: cursor + 30))
            let fileCommentLength = Int(try data.requiredUInt16(at: cursor + 32))
            let startingDisk = try data.requiredUInt16(at: cursor + 34)
            let externalAttributes = try data.requiredUInt32(at: cursor + 38)
            let localHeaderOffset = try data.requiredUInt32(at: cursor + 42)

            guard compressedSize != UInt32.max,
                  uncompressedSize != UInt32.max,
                  localHeaderOffset != UInt32.max else {
                throw ZipArchiveError.zip64NotSupported
            }
            guard startingDisk == 0 else {
                throw ZipArchiveError.multiDiskArchive
            }
            guard filenameLength > 0, filenameLength <= limits.maximumPathBytes else {
                throw ZipArchiveError.unsafePath("oversized filename")
            }
            let variableLength = filenameLength + extraLength + fileCommentLength
            guard cursor <= endOffset - 46, variableLength <= endOffset - (cursor + 46) else {
                throw ZipArchiveError.invalidCentralDirectory
            }

            let filenameData = data.subdata(in: (cursor + 46)..<(cursor + 46 + filenameLength))
            guard let filename = String(data: filenameData, encoding: .utf8) else {
                throw ZipArchiveError.nonUTF8Filename
            }
            let extraData = data.subdata(
                in: (cursor + 46 + filenameLength)..<(cursor + 46 + filenameLength + extraLength)
            )
            try validateExtraFields(extraData)
            let safePath = try validatedArchivePath(filename)

            guard flags & 0x0001 == 0, flags & 0x0040 == 0 else {
                throw ZipArchiveError.encryptedEntry(safePath)
            }
            // Bits 1–2 tune deflate, bit 3 enables a data descriptor, and bit 11
            // marks UTF-8 names. Other features can alter extraction semantics.
            guard flags & ~UInt16(0x080E) == 0 else {
                throw ZipArchiveError.unsupportedFlags(path: safePath, flags: flags)
            }
            guard method == 0 || method == 8 else {
                throw ZipArchiveError.unsupportedCompression(path: safePath, method: method)
            }

            let isDirectory = filename.hasSuffix("/")
            try validateUnixFileType(
                versionMadeBy: versionMadeBy,
                externalAttributes: externalAttributes,
                path: safePath,
                isDirectory: isDirectory
            )

            let compressed = Int64(compressedSize)
            let uncompressed = Int64(uncompressedSize)
            guard uncompressed <= limits.maximumEntryBytes else {
                throw ZipArchiveError.entryTooLarge(
                    path: safePath,
                    actual: uncompressed,
                    limit: limits.maximumEntryBytes
                )
            }
            if uncompressed > 0 {
                guard compressed > 0,
                      uncompressed <= compressed * limits.maximumCompressionRatio else {
                    throw ZipArchiveError.compressionRatioExceeded(safePath)
                }
            }
            let (newTotal, overflow) = totalUncompressed.addingReportingOverflow(uncompressed)
            guard !overflow, newTotal <= limits.maximumTotalUncompressedBytes else {
                throw ZipArchiveError.totalSizeExceeded(limit: limits.maximumTotalUncompressedBytes)
            }
            totalUncompressed = newTotal

            let collisionKey = safePath
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .precomposedStringWithCanonicalMapping
                .lowercased()
            guard seenPaths.insert(collisionKey).inserted else {
                throw ZipArchiveError.duplicatePath(safePath)
            }

            let localRange = try validateLocalHeader(
                in: data,
                at: Int(localHeaderOffset),
                expectedFilenameData: filenameData,
                expectedFlags: flags,
                expectedMethod: method,
                expectedCompressedSize: compressedSize,
                expectedUncompressedSize: uncompressedSize,
                centralDirectoryOffset: centralStart
            )
            entryRanges.append(localRange)
            entries.append(
                ZipArchiveEntry(
                    path: safePath,
                    compressedBytes: compressed,
                    uncompressedBytes: uncompressed,
                    isDirectory: isDirectory
                )
            )
            cursor += 46 + variableLength
        }

        guard cursor == endOffset else {
            throw ZipArchiveError.invalidCentralDirectory
        }
        let sortedRanges = entryRanges.sorted { $0.lowerBound < $1.lowerBound }
        for pair in zip(sortedRanges, sortedRanges.dropFirst()) where pair.0.overlaps(pair.1) {
            throw ZipArchiveError.overlappingEntries
        }
        let normalizedPaths = entries.map {
            $0.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .precomposedStringWithCanonicalMapping
                .lowercased()
        }
        for (index, entry) in entries.enumerated() where !entry.isDirectory {
            let filePath = normalizedPaths[index]
            if normalizedPaths.enumerated().contains(where: { pair in
                pair.offset != index && pair.element.hasPrefix(filePath + "/")
            }) {
                throw ZipArchiveError.pathTypeConflict(entry.path)
            }
        }
        return ZipArchiveInspection(entries: entries)
    }

    @discardableResult
    func extract(
        archiveAt archiveURL: URL,
        to destinationURL: URL
    ) throws -> ZipArchiveInspection {
        let inspection = try inspect(archiveAt: archiveURL)
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw ZipArchiveError.destinationAlreadyExists
        }
        guard fileManager.isExecutableFile(atPath: unzipExecutableURL.path) else {
            throw ZipArchiveError.unzipUnavailable
        }

        try fileManager.createDirectory(
            at: destinationURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var shouldCleanUp = true
        defer {
            if shouldCleanUp {
                try? fileManager.removeItem(at: destinationURL)
            }
        }

        let process = Process()
        process.executableURL = unzipExecutableURL
        process.arguments = ["-qq", archiveURL.path, "-d", destinationURL.path]
        process.standardOutput = FileHandle.nullDevice
        let standardError = Pipe()
        process.standardError = standardError
        do {
            try process.run()
        } catch {
            throw ZipArchiveError.extractionFailed(error.localizedDescription)
        }
        process.waitUntilExit()

        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let message = String(data: errorData.prefix(4_096), encoding: .utf8)
                ?? "unzip exited with status \(process.terminationStatus)"
            throw ZipArchiveError.extractionFailed(message)
        }

        try verifyExtractedTree(
            at: destinationURL,
            inspection: inspection,
            fileManager: fileManager
        )
        shouldCleanUp = false
        return inspection
    }

    private func findEndOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else {
            return nil
        }
        let earliest = max(0, data.count - 22 - 65_535)
        var cursor = data.count - 22
        while cursor >= earliest {
            if data.uint32(at: cursor) == 0x0605_4B50 {
                return cursor
            }
            cursor -= 1
        }
        return nil
    }

    private func validatedArchivePath(_ path: String) throws -> String {
        guard !path.isEmpty,
              path.utf8.count <= limits.maximumPathBytes,
              !path.hasPrefix("/"),
              !path.hasPrefix("\\"),
              !path.contains("\\"),
              !path.contains(":"),
              !path.unicodeScalars.contains(where: { $0.value == 0 || $0.value < 0x20 })
        else {
            throw ZipArchiveError.unsafePath(path)
        }

        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({
                  !$0.isEmpty
                      && $0 != "."
                      && $0 != ".."
                      && $0.utf8.count <= limits.maximumPathComponentBytes
              }) else {
            throw ZipArchiveError.unsafePath(path)
        }
        return components.joined(separator: "/") + (path.hasSuffix("/") ? "/" : "")
    }

    private func validateExtraFields(_ data: Data) throws {
        var cursor = 0
        while cursor < data.count {
            guard cursor <= data.count - 4 else {
                throw ZipArchiveError.malformedExtraField
            }
            let identifier = try data.requiredUInt16(at: cursor)
            let length = Int(try data.requiredUInt16(at: cursor + 2))
            guard length <= data.count - (cursor + 4) else {
                throw ZipArchiveError.malformedExtraField
            }
            // ZIP64 changes size/offset interpretation. Info-ZIP’s Unicode path
            // field can make the extractor use a path other than the central name.
            if identifier == 0x0001 {
                throw ZipArchiveError.zip64NotSupported
            }
            if identifier == 0x7075 {
                throw ZipArchiveError.unicodePathOverride
            }
            cursor += 4 + length
        }
    }

    private func validateUnixFileType(
        versionMadeBy: UInt16,
        externalAttributes: UInt32,
        path: String,
        isDirectory: Bool
    ) throws {
        let creatorSystem = versionMadeBy >> 8
        guard creatorSystem == 3 else {
            return
        }
        let mode = UInt16((externalAttributes >> 16) & 0xFFFF)
        let fileType = mode & 0o170000
        if fileType == 0 {
            return
        }
        let expected: UInt16 = isDirectory ? 0o040000 : 0o100000
        guard fileType == expected else {
            throw ZipArchiveError.nonRegularEntry(path)
        }
    }

    private func validateLocalHeader(
        in data: Data,
        at offset: Int,
        expectedFilenameData: Data,
        expectedFlags: UInt16,
        expectedMethod: UInt16,
        expectedCompressedSize: UInt32,
        expectedUncompressedSize: UInt32,
        centralDirectoryOffset: Int
    ) throws -> Range<Int> {
        guard offset >= 0, offset <= centralDirectoryOffset - 30,
              try data.requiredUInt32(at: offset) == 0x0403_4B50 else {
            throw ZipArchiveError.invalidLocalHeader
        }
        let flags = try data.requiredUInt16(at: offset + 6)
        let method = try data.requiredUInt16(at: offset + 8)
        let compressedSize = try data.requiredUInt32(at: offset + 18)
        let uncompressedSize = try data.requiredUInt32(at: offset + 22)
        let filenameLength = Int(try data.requiredUInt16(at: offset + 26))
        let extraLength = Int(try data.requiredUInt16(at: offset + 28))
        guard flags == expectedFlags, method == expectedMethod,
              filenameLength == expectedFilenameData.count,
              offset + 30 + filenameLength + extraLength <= centralDirectoryOffset else {
            throw ZipArchiveError.invalidLocalHeader
        }
        let localFilename = data.subdata(in: (offset + 30)..<(offset + 30 + filenameLength))
        guard localFilename == expectedFilenameData else {
            throw ZipArchiveError.localFilenameMismatch
        }
        let localExtra = data.subdata(
            in: (offset + 30 + filenameLength)..<(offset + 30 + filenameLength + extraLength)
        )
        try validateExtraFields(localExtra)

        if flags & 0x0008 == 0 {
            guard compressedSize == expectedCompressedSize,
                  uncompressedSize == expectedUncompressedSize else {
                throw ZipArchiveError.localSizeMismatch
            }
        } else {
            guard (compressedSize == 0 || compressedSize == expectedCompressedSize),
                  (uncompressedSize == 0 || uncompressedSize == expectedUncompressedSize) else {
                throw ZipArchiveError.localSizeMismatch
            }
        }

        let dataStart = offset + 30 + filenameLength + extraLength
        let compressedCount = Int(expectedCompressedSize)
        guard compressedCount <= centralDirectoryOffset - dataStart else {
            throw ZipArchiveError.invalidLocalHeader
        }
        return offset..<(dataStart + compressedCount)
    }

    private func verifyExtractedTree(
        at root: URL,
        inspection: ZipArchiveInspection,
        fileManager: FileManager
    ) throws {
        let rootPath = root.standardizedFileURL.path
        let expectedFiles = Dictionary(
            uniqueKeysWithValues: inspection.entries.compactMap { entry in
                entry.isDirectory ? nil : (String(entry.path.drop(while: { $0 == "/" })), entry)
            }
        )
        var actualFiles = Set<String>()
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw ZipArchiveError.extractedTreeInvalid
        }

        for case let url as URL in enumerator {
            let standardized = url.standardizedFileURL
            guard standardized.path.hasPrefix(rootPath + "/") else {
                throw ZipArchiveError.extractedPathEscapedRoot
            }
            let values = try standardized.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else {
                throw ZipArchiveError.nonRegularEntry(url.lastPathComponent)
            }
            let relativePath = String(standardized.path.dropFirst(rootPath.count + 1))
            if values.isDirectory == true {
                try fileManager.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: standardized.path
                )
                continue
            }
            guard values.isRegularFile == true,
                  let expected = expectedFiles[relativePath],
                  Int64(values.fileSize ?? -1) == expected.uncompressedBytes else {
                throw ZipArchiveError.extractedTreeInvalid
            }
            guard actualFiles.insert(relativePath).inserted else {
                throw ZipArchiveError.duplicatePath(relativePath)
            }
            // Imported content is data. Strip executable and special permission bits.
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: standardized.path
            )
        }
        guard actualFiles == Set(expectedFiles.keys) else {
            throw ZipArchiveError.extractedTreeInvalid
        }
    }
}

enum ZipArchiveError: Error, Equatable, LocalizedError, Sendable {
    case notARegularFile
    case archiveTooLarge(actual: Int64, limit: Int64)
    case missingEndOfCentralDirectory
    case multiDiskArchive
    case zip64NotSupported
    case tooManyEntries(actual: Int, limit: Int)
    case trailingData
    case invalidCentralDirectory
    case unsafePath(String)
    case nonUTF8Filename
    case malformedExtraField
    case unicodePathOverride
    case encryptedEntry(String)
    case unsupportedFlags(path: String, flags: UInt16)
    case unsupportedCompression(path: String, method: UInt16)
    case nonRegularEntry(String)
    case entryTooLarge(path: String, actual: Int64, limit: Int64)
    case compressionRatioExceeded(String)
    case totalSizeExceeded(limit: Int64)
    case duplicatePath(String)
    case pathTypeConflict(String)
    case invalidLocalHeader
    case localFilenameMismatch
    case localSizeMismatch
    case overlappingEntries
    case destinationAlreadyExists
    case unzipUnavailable
    case extractionFailed(String)
    case extractedTreeInvalid
    case extractedPathEscapedRoot

    var errorDescription: String? {
        switch self {
        case .notARegularFile:
            "ZIP archive is not a regular file."
        case let .archiveTooLarge(actual, limit):
            "ZIP archive is \(actual) bytes, above the \(limit)-byte limit."
        case .missingEndOfCentralDirectory:
            "ZIP archive has no valid end-of-central-directory record."
        case .multiDiskArchive:
            "Multi-disk ZIP archives are not supported."
        case .zip64NotSupported:
            "ZIP64 archives are rejected by the safe importer."
        case let .tooManyEntries(actual, limit):
            "ZIP has \(actual) entries, above the \(limit)-entry limit."
        case .trailingData:
            "ZIP archive contains unaccounted trailing data."
        case .invalidCentralDirectory:
            "ZIP central directory is malformed."
        case let .unsafePath(path):
            "ZIP contains unsafe path \(path)."
        case .nonUTF8Filename:
            "ZIP filenames must be UTF-8."
        case .malformedExtraField:
            "ZIP contains a malformed extra field."
        case .unicodePathOverride:
            "ZIP Unicode path overrides are not accepted."
        case let .encryptedEntry(path):
            "ZIP entry \(path) is encrypted."
        case let .unsupportedFlags(path, flags):
            "ZIP entry \(path) uses unsupported flags \(flags)."
        case let .unsupportedCompression(path, method):
            "ZIP entry \(path) uses unsupported compression method \(method)."
        case let .nonRegularEntry(path):
            "ZIP entry \(path) is not a regular file or directory."
        case let .entryTooLarge(path, actual, limit):
            "ZIP entry \(path) is \(actual) bytes, above the \(limit)-byte limit."
        case let .compressionRatioExceeded(path):
            "ZIP entry \(path) exceeds the compression-ratio limit."
        case let .totalSizeExceeded(limit):
            "ZIP expands beyond the \(limit)-byte total limit."
        case let .duplicatePath(path):
            "ZIP contains a duplicate or case-colliding path \(path)."
        case let .pathTypeConflict(path):
            "ZIP path \(path) is both a file and a parent directory."
        case .invalidLocalHeader:
            "ZIP contains an invalid local file header."
        case .localFilenameMismatch:
            "ZIP local and central filenames do not match."
        case .localSizeMismatch:
            "ZIP local and central sizes do not match."
        case .overlappingEntries:
            "ZIP entries overlap."
        case .destinationAlreadyExists:
            "ZIP extraction destination already exists."
        case .unzipUnavailable:
            "The system unzip utility is unavailable."
        case let .extractionFailed(message):
            "ZIP extraction failed: \(message)"
        case .extractedTreeInvalid:
            "Extracted ZIP contents do not match the preflight manifest."
        case .extractedPathEscapedRoot:
            "An extracted ZIP path escaped the destination."
        }
    }
}

private extension Data {
    func uint32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= count - 4 else {
            return nil
        }
        return UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }

    func requiredUInt16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset <= count - 2 else {
            throw ZipArchiveError.invalidCentralDirectory
        }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func requiredUInt32(at offset: Int) throws -> UInt32 {
        guard let value = uint32(at: offset) else {
            throw ZipArchiveError.invalidCentralDirectory
        }
        return value
    }
}
