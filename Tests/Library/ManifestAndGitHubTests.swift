import Foundation
import XCTest
@testable import MojiPond

final class ManifestAndGitHubTests: XCTestCase {
    func testParsesSlackDictionaryAndFlattensAliasChains() throws {
        let manifest = try SlackEmojiManifestParser.parse(
            data: TestSupport.fixture(named: "slack-map.json")
        )
        XCTAssertEqual(manifest.entries.count, 1)
        XCTAssertEqual(manifest.entries[0].shortcode.rawValue, "party_parrot")
        XCTAssertEqual(
            manifest.entries[0].aliases.map(\.rawValue),
            ["celebrate", "party"]
        )
        XCTAssertEqual(
            manifest.entries[0].assetURL.absoluteString,
            "https://emoji.slack-edge.com/T/party_parrot.gif"
        )
    }

    func testParsesSlackArrayFormatAndNormalizesNames() throws {
        let manifest = try SlackEmojiManifestParser.parse(
            data: TestSupport.fixture(named: "slack-array.json")
        )
        XCTAssertEqual(manifest.entries.count, 1)
        XCTAssertEqual(manifest.entries[0].shortcode.rawValue, "bufo_wave")
        XCTAssertEqual(manifest.entries[0].aliases.map(\.rawValue), ["hello_bufo"])
    }

    func testRejectsSlackAliasCyclesAndMissingTargets() throws {
        XCTAssertThrowsError(
            try SlackEmojiManifestParser.parse(
                data: TestSupport.fixture(named: "slack-cycle.json")
            )
        ) {
            guard case .aliasCycle = $0 as? SlackManifestError else {
                return XCTFail("Expected aliasCycle, got \($0)")
            }
        }
        XCTAssertThrowsError(
            try SlackEmojiManifestParser.parse(
                data: TestSupport.fixture(named: "slack-missing-alias.json")
            )
        ) {
            XCTAssertEqual(
                $0 as? SlackManifestError,
                .missingAliasTarget(try! Shortcode(validating: "not_here"))
            )
        }
    }

    func testRejectsSlackDuplicateNormalizedNamesAndUnsafeURLs() throws {
        let duplicate = Data(
            """
            [
              {"name":"Party Frog","url":"https://example.com/a.png"},
              {"name":"party_frog","url":"https://example.com/b.png"}
            ]
            """.utf8
        )
        XCTAssertThrowsError(try SlackEmojiManifestParser.parse(data: duplicate)) {
            XCTAssertEqual(
                $0 as? SlackManifestError,
                .duplicateName(try! Shortcode(validating: "party_frog"))
            )
        }

        let insecure = Data(#"{"frog":"http://example.com/frog.png"}"#.utf8)
        XCTAssertThrowsError(try SlackEmojiManifestParser.parse(data: insecure)) {
            XCTAssertEqual(
                $0 as? SlackManifestError,
                .invalidAssetURL("http://example.com/frog.png")
            )
        }
    }

    func testParsesStrictGitHubRepositoryAndTreeURLs() throws {
        let repository = try GitHubRepositoryReference.parse(
            XCTUnwrap(URL(string: "https://github.com/knobiknows/all-the-bufo"))
        )
        XCTAssertEqual(repository.owner, "knobiknows")
        XCTAssertEqual(repository.repository, "all-the-bufo")
        XCTAssertEqual(repository.ref, "HEAD")
        XCTAssertNil(repository.subdirectory)
        XCTAssertEqual(
            repository.archiveURL.absoluteString,
            "https://codeload.github.com/knobiknows/all-the-bufo/zip/HEAD"
        )

        let tree = try GitHubRepositoryReference.parse(
            XCTUnwrap(
                URL(string: "https://github.com/owner/repo/tree/main/packs/frogs")
            )
        )
        XCTAssertEqual(tree.ref, "main")
        XCTAssertEqual(tree.subdirectory, "packs/frogs")
    }

    func testExplicitGitHubRefSupportsSlashAndIsEncodedAsOneArchiveComponent() throws {
        let reference = try GitHubRepositoryReference.parse(
            XCTUnwrap(URL(string: "https://github.com/owner/repo")),
            ref: "feature/frogs",
            subdirectory: "packs/bufo"
        )
        XCTAssertEqual(reference.ref, "feature/frogs")
        XCTAssertEqual(reference.subdirectory, "packs/bufo")
        XCTAssertEqual(
            reference.archiveURL.absoluteString,
            "https://codeload.github.com/owner/repo/zip/feature%2Ffrogs"
        )
    }

    func testRejectsNonPublicOrAmbiguousGitHubURLsAndTraversal() throws {
        let invalidURLs = [
            "http://github.com/owner/repo",
            "https://evil.example/owner/repo",
            "https://user@github.com/owner/repo",
            "https://github.com/owner/repo/issues",
            "https://github.com/owner/repo?tab=readme",
            "https://github.com/owner/repo/tree/main/%2e%2e/secrets"
        ]
        for rawURL in invalidURLs {
            XCTAssertThrowsError(
                try GitHubRepositoryReference.parse(XCTUnwrap(URL(string: rawURL))),
                "Expected rejection for \(rawURL)"
            )
        }

        XCTAssertThrowsError(
            try GitHubRepositoryReference(
                owner: "owner",
                repository: "repo",
                ref: "../main"
            )
        )
        XCTAssertThrowsError(
            try GitHubRepositoryReference(
                owner: "owner",
                repository: "repo",
                subdirectory: "../outside"
            )
        )
    }
}
