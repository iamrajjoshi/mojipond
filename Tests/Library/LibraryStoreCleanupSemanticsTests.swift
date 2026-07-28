import Foundation
import XCTest
@testable import MojiPond

@MainActor
final class LibraryStoreCleanupSemanticsTests: XCTestCase {
    func testCommittedRemovalSucceedsWhenAssetCleanupFailsAndCanBeRetried()
        async throws
    {
        let workspace = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let rootURL = workspace.appendingPathComponent(
            "Library",
            isDirectory: true
        )
        let strayURL = rootURL
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent("unreferenced.png")
        let fileManager = CleanupFailingFileManager()
        fileManager.blockedRemovalPath = strayURL.path
        let store = LibraryStore(
            rootURL: rootURL,
            fileManager: fileManager
        )
        let pack = try await store.createPack(name: "Temporary")
        _ = try await store.createUnicodeItem(
            in: pack.id,
            shortcode: Shortcode(validating: "temporary_frog"),
            unicode: "🐸"
        )
        try Data("unreferenced".utf8).write(to: strayURL)

        try await store.removePack(pack.id)

        let snapshot = try await store.snapshot()
        XCTAssertTrue(snapshot.packs.isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: strayURL.path)
        )
        do {
            try await store.cleanUpAssets()
            XCTFail("Expected explicit maintenance cleanup to fail")
        } catch {
            XCTAssertEqual(
                error as? CleanupFailingFileManager.Failure,
                .intentional
            )
        }

        let retryingStore = LibraryStore(rootURL: rootURL)
        try await retryingStore.cleanUpAssets()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: strayURL.path)
        )
    }
}

private final class CleanupFailingFileManager:
    FileManager,
    @unchecked Sendable
{
    enum Failure: Error, Equatable {
        case intentional
    }

    private let stateLock = NSLock()
    private var storedBlockedRemovalPath: String?

    var blockedRemovalPath: String? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return storedBlockedRemovalPath
        }
        set {
            stateLock.lock()
            storedBlockedRemovalPath = newValue
            stateLock.unlock()
        }
    }

    override func removeItem(at URL: URL) throws {
        if URL.standardizedFileURL.path == blockedRemovalPath {
            throw Failure.intentional
        }
        try super.removeItem(at: URL)
    }
}
