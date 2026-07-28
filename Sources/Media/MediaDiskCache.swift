import CryptoKit
import Foundation

actor MediaDiskCache {
    private let rootURL: URL
    private let maximumBytes: Int64
    private let fileManager: FileManager

    init(
        rootURL: URL,
        maximumBytes: Int64 = 250 * 1_024 * 1_024,
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.maximumBytes = maximumBytes
        self.fileManager = fileManager
    }

    func cachedFile(for remoteURL: URL) throws -> URL? {
        let baseURL = try preparedRoot()
        let prefix = cacheKey(for: remoteURL)
        let entries = try fileManager.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        guard let match = entries.first(where: { $0.lastPathComponent.hasPrefix("\(prefix).") }) else {
            return nil
        }
        try fileManager.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: match.path
        )
        // Directory enumeration may canonicalize `/var` to `/private/var`.
        // Return a URL in the caller's cache-root namespace so repeated cache
        // operations have stable URL identity.
        return baseURL.appendingPathComponent(
            match.lastPathComponent,
            isDirectory: false
        )
    }

    @discardableResult
    func store(
        _ download: RemoteMediaDownloader.Download,
        for item: RemoteMediaItem
    ) throws -> URL {
        let baseURL = try preparedRoot()
        let safeExtension = (download.suggestedFilename as NSString).pathExtension.lowercased()
        guard ["gif", "png", "jpg", "webp"].contains(safeExtension) else {
            throw RemoteMediaError.unsupportedContentType(download.contentType)
        }

        let destination = baseURL
            .appending(path: "\(cacheKey(for: item.originalURL)).\(safeExtension)")
        let temporary = baseURL.appending(
            path: ".\(UUID().uuidString.lowercased()).partial"
        )
        try download.data.write(to: temporary, options: [.atomic])
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporary, to: destination)
        try pruneIfNeeded()
        return destination
    }

    func removeAll() throws {
        guard fileManager.fileExists(atPath: rootURL.path) else {
            return
        }
        let values = try rootURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try fileManager.removeItem(at: rootURL)
    }

    private func preparedRoot() throws -> URL {
        if fileManager.fileExists(atPath: rootURL.path) {
            let values = try rootURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
        } else {
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        return rootURL.resolvingSymlinksInPath()
    }

    private func pruneIfNeeded() throws {
        let entries = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey
            ],
            options: [.skipsHiddenFiles]
        )
        var files: [(url: URL, size: Int64, date: Date)] = []
        var total: Int64 = 0

        for entry in entries {
            let values = try entry.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey
            ])
            guard values.isRegularFile == true else {
                continue
            }
            let size = Int64(values.fileSize ?? 0)
            total += size
            files.append((entry, size, values.contentModificationDate ?? .distantPast))
        }

        for file in files.sorted(by: { $0.date < $1.date }) where total > maximumBytes {
            try fileManager.removeItem(at: file.url)
            total -= file.size
        }
    }

    private func cacheKey(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
