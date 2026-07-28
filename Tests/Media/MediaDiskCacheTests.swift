import Foundation
import XCTest
@testable import MojiPond

final class MediaDiskCacheTests: XCTestCase {
    func testStoreLookupAndRemove() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MojiPondMediaCacheTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let cache = MediaDiskCache(rootURL: root, maximumBytes: 1_024)
        let item = RemoteMediaItem(
            id: "one",
            provider: .giphy,
            title: "One",
            previewURL: URL(string: "https://example.com/one.gif")!,
            originalURL: URL(string: "https://example.com/one.gif")!,
            dimensions: nil,
            attribution: "Powered by GIPHY",
            analytics: nil
        )
        let download = RemoteMediaDownloader.Download(
            data: Data([0x47, 0x49, 0x46]),
            contentType: "image/gif",
            suggestedFilename: "source.gif"
        )

        let stored = try await cache.store(download, for: item)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.path))
        let lookup = try await cache.cachedFile(for: item.originalURL)
        XCTAssertEqual(lookup, stored)

        try await cache.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testCachePrunesOldestFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MojiPondMediaCacheTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let cache = MediaDiskCache(rootURL: root, maximumBytes: 5)
        let first = item(id: "first")
        let second = item(id: "second")
        _ = try await cache.store(download(bytes: 4), for: first)
        try await Task.sleep(for: .milliseconds(20))
        _ = try await cache.store(download(bytes: 4), for: second)

        let firstFile = try await cache.cachedFile(for: first.originalURL)
        let secondFile = try await cache.cachedFile(for: second.originalURL)
        XCTAssertNil(firstFile)
        XCTAssertNotNil(secondFile)
    }

    private func item(id: String) -> RemoteMediaItem {
        let url = URL(string: "https://example.com/\(id).gif")!
        return RemoteMediaItem(
            id: id,
            provider: .giphy,
            title: id,
            previewURL: url,
            originalURL: url,
            dimensions: nil,
            attribution: "Powered by GIPHY",
            analytics: nil
        )
    }

    private func download(bytes: Int) -> RemoteMediaDownloader.Download {
        .init(
            data: Data(repeating: 1, count: bytes),
            contentType: "image/gif",
            suggestedFilename: "source.gif"
        )
    }
}

