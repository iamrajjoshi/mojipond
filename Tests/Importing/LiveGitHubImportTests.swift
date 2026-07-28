import Foundation
import XCTest
@testable import MojiPond

final class LiveGitHubImportTests: XCTestCase {
    func testBufoRepositoryPreparesAndInstallsEndToEnd() async throws {
#if !LIVE_IMPORT_TESTS
        throw XCTSkip(
            "Add LIVE_IMPORT_TESTS to Swift compilation conditions to run."
        )
#else

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MojiPondLiveBufo-\(UUID().uuidString)",
                isDirectory: true
            )
        let temporaryRoot = root.appendingPathComponent(
            "Temporary",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let orchestrator = ImportOrchestrator(
            temporaryRootURL: temporaryRoot
        )
        let preparation = try await orchestrator.prepare(
            .github(
                try XCTUnwrap(
                    URL(
                        string:
                            "https://github.com/knobiknows/all-the-bufo"
                    )
                )
            ),
            against: MojiPondLibrary()
        )
        XCTAssertGreaterThan(preparation.preview.items.count, 1_000)
        XCTAssertEqual(
            preparation.preview.preparedPack.source.kind,
            .github
        )
        XCTAssertNotNil(
            preparation.preview.preparedPack.updateMetadata.sourceRevision
        )

        let decisions = Dictionary(
            uniqueKeysWithValues: preparation.preview.collisions.map {
                collision in
                let decision: CollisionDecision
                switch collision.incomingClaim {
                case .primary:
                    decision = .skipIncomingItem
                case .alias:
                    decision = .dropIncomingAlias
                }
                return (collision.id, decision)
            }
        )
        let store = LibraryStore(
            rootURL: root.appendingPathComponent(
                "Library",
                isDirectory: true
            )
        )
        let installed = try await preparation.install(
            into: store,
            decisions: decisions
        )
        XCTAssertGreaterThan(installed.items.count, 1_000)
        XCTAssertEqual(installed.source.kind, .github)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: preparation.workingDirectoryURL.path
            )
        )
#endif
    }
}
