import Foundation
import XCTest
@testable import MojiPond

@MainActor
final class GitHubImportClientTests: XCTestCase {
    func testRevisionCheckDoesNotDownloadArchive() async throws {
        let transport = MockImportHTTPTransport()
        let sha = String(repeating: "b", count: 40)
        await transport.enqueue(
            host: "api.github.com",
            outcome: .response(
                try ImportingTestSupport.response(
                    url:
                        "https://api.github.com/repos/knobiknows/all-the-bufo/commits/main",
                    data: Data(#"{"sha":"\#(sha)"}"#.utf8),
                    headers: ["ETag": "\"revision-etag\""]
                )
            )
        )

        let revision = try await GitHubImportClient(
            transport: transport
        ).resolveRevision(
            from: ImportingTestSupport.unwrappedURL(
                "https://github.com/knobiknows/all-the-bufo"
            ),
            ref: "main"
        )

        XCTAssertEqual(revision.commitSHA, sha)
        XCTAssertEqual(revision.sourceETag, "\"revision-etag\"")
        let calls = await transport.recordedCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].policy, .githubAPI)
    }

    func testResolvesCommitBeforeDownloadingPinnedArchive() async throws {
        let transport = MockImportHTTPTransport()
        let sha = String(repeating: "a", count: 40)
        await transport.enqueue(
            host: "api.github.com",
            outcome: .response(
                try ImportingTestSupport.response(
                    url: "https://api.github.com/repos/knobiknows/all-the-bufo/commits/feature%2Fpond",
                    data: Data(#"{"sha":"\#(sha)"}"#.utf8),
                    headers: ["ETag": "\"commit-etag\""]
                )
            )
        )
        await transport.enqueue(
            host: "codeload.github.com",
            outcome: .response(
                try ImportingTestSupport.response(
                    url: "https://codeload.github.com/knobiknows/all-the-bufo/zip/\(sha)",
                    data: Data("zip".utf8)
                )
            )
        )
        let client = GitHubImportClient(
            transport: transport,
            tokenProvider: StaticGitHubTokenProvider(token: "github_pat_test")
        )

        let archive = try await client.fetchArchive(
            from: ImportingTestSupport.unwrappedURL(
                "https://github.com/knobiknows/all-the-bufo"
            ),
            ref: "feature/pond"
        )

        XCTAssertEqual(archive.commitSHA, sha)
        XCTAssertEqual(archive.sourceETag, "\"commit-etag\"")
        XCTAssertEqual(archive.requestedReference.ref, "feature/pond")
        let calls = await transport.recordedCalls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].policy, .githubAPI)
        XCTAssertEqual(calls[0].url.host, "api.github.com")
        XCTAssertTrue(calls[0].url.absoluteString.contains("feature%2Fpond"))
        XCTAssertEqual(calls[0].authorization, "Bearer github_pat_test")
        XCTAssertEqual(calls[1].policy, .githubArchive)
        XCTAssertEqual(calls[1].url.host, "codeload.github.com")
        XCTAssertTrue(calls[1].url.absoluteString.hasSuffix("/zip/\(sha)"))
        XCTAssertNil(calls[1].authorization)
    }

    func testRejectsHostileGitHubRedirectsAndReportsOffline() async throws {
        let repositoryURL = try ImportingTestSupport.unwrappedURL(
            "https://github.com/knobiknows/all-the-bufo"
        )

        let hostileHostTransport = MockImportHTTPTransport()
        await hostileHostTransport.enqueue(
            host: "api.github.com",
            outcome: .redirect(
                try ImportingTestSupport.unwrappedURL(
                    "https://attacker.example/commit"
                )
            )
        )
        do {
            _ = try await GitHubImportClient(
                transport: hostileHostTransport
            ).fetchArchive(from: repositoryURL)
            XCTFail("Expected redirect host rejection")
        } catch {
            XCTAssertEqual(
                error as? ImportHTTPError,
                .disallowedHost("attacker.example")
            )
        }

        let downgradeTransport = MockImportHTTPTransport()
        await downgradeTransport.enqueue(
            host: "api.github.com",
            outcome: .redirect(
                try ImportingTestSupport.unwrappedURL(
                    "http://api.github.com/commit"
                )
            )
        )
        do {
            _ = try await GitHubImportClient(
                transport: downgradeTransport
            ).fetchArchive(from: repositoryURL)
            XCTFail("Expected redirect downgrade rejection")
        } catch {
            XCTAssertEqual(error as? ImportHTTPError, .insecureURL)
        }

        let offlineTransport = MockImportHTTPTransport()
        await offlineTransport.enqueue(
            host: "api.github.com",
            outcome: .networkError(.offline)
        )
        do {
            _ = try await GitHubImportClient(
                transport: offlineTransport
            ).fetchArchive(from: repositoryURL)
            XCTFail("Expected offline error")
        } catch {
            XCTAssertEqual(error as? ImportHTTPError, .offline)
        }
    }

    func testRejectsOversizedAndMalformedCommitResponses() async throws {
        let repositoryURL = try ImportingTestSupport.unwrappedURL(
            "https://github.com/knobiknows/all-the-bufo"
        )
        let oversizedTransport = MockImportHTTPTransport()
        await oversizedTransport.enqueue(
            host: "api.github.com",
            outcome: .response(
                try ImportingTestSupport.response(
                    url: "https://api.github.com/repos/knobiknows/all-the-bufo/commits/HEAD",
                    data: Data(repeating: 0x61, count: 65)
                )
            )
        )
        let limits = GitHubImportLimits(
            maximumAPIResponseBytes: 64,
            maximumArchiveBytes: 1_024
        )
        do {
            _ = try await GitHubImportClient(
                transport: oversizedTransport,
                limits: limits
            ).fetchArchive(from: repositoryURL)
            XCTFail("Expected size cap")
        } catch {
            XCTAssertEqual(
                error as? ImportHTTPError,
                .responseTooLarge(limit: 64)
            )
        }

        let malformedTransport = MockImportHTTPTransport()
        await malformedTransport.enqueue(
            host: "api.github.com",
            outcome: .response(
                try ImportingTestSupport.response(
                    url: "https://api.github.com/repos/knobiknows/all-the-bufo/commits/HEAD",
                    data: Data(#"{"sha":"not-a-sha"}"#.utf8)
                )
            )
        )
        do {
            _ = try await GitHubImportClient(
                transport: malformedTransport
            ).fetchArchive(from: repositoryURL)
            XCTFail("Expected invalid SHA")
        } catch {
            XCTAssertEqual(
                error as? GitHubImportError,
                .invalidCommitSHA
            )
        }
    }
}
