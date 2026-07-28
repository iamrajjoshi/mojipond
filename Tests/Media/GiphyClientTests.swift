import Foundation
import XCTest
@testable import MojiPond

final class GiphyClientTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    func testMissingKeyStopsBeforeNetwork() async {
        let client = GiphyClient(
            session: URLProtocolStub.session(),
            keyProvider: TestKeyProvider(value: nil)
        )

        do {
            _ = try await client.search("frog")
            XCTFail("Expected a missing-key error.")
        } catch let error as RemoteMediaError {
            XCTAssertEqual(error, .missingAPIKey)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSearchMapsSecureRenditionsAndRequiredParameters() async throws {
        URLProtocolStub.install { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            let query = Dictionary(
                uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) }
            )
            XCTAssertEqual(components.path, "/v1/gifs/search")
            XCTAssertEqual(query["q"] ?? nil, "concerned frog")
            XCTAssertEqual(query["api_key"] ?? nil, "test-key")
            XCTAssertEqual(query["bundle"] ?? nil, "messaging_non_clips")
            XCTAssertNil(query["customer_id"] ?? nil)

            let data = Data(
                """
                {
                  "data": [{
                    "id": "frog-1",
                    "title": "Concerned frog",
                    "username": "pond_artist",
                    "source": "https://artist.example/original-post",
                    "user": {"username": "verified_pond"},
                    "images": {
                      "fixed_width": {
                        "url": "https://media.giphy.com/preview.gif",
                        "width": "200",
                        "height": "120"
                      },
                      "original": {
                        "url": "https://media.giphy.com/original.gif",
                        "width": "640",
                        "height": "384"
                      }
                    },
                    "analytics": {
                      "onload": {"url": "https://pingback.giphy.com/load"},
                      "onclick": {"url": "https://pingback.giphy.com/click"},
                      "onsent": {"url": "https://pingback.giphy.com/sent"}
                    }
                  }]
                }
                """.utf8
            )
            return (
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )),
                data
            )
        }

        let client = GiphyClient(
            session: URLProtocolStub.session(),
            keyProvider: TestKeyProvider(value: "test-key")
        )
        let results = try await client.search("concerned frog")

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, "frog-1")
        XCTAssertEqual(results[0].provider, .giphy)
        XCTAssertEqual(results[0].dimensions, .init(width: 640, height: 384))
        XCTAssertEqual(results[0].attribution, "Powered by GIPHY")
        XCTAssertEqual(results[0].creatorAttribution, "@verified_pond")
        XCTAssertEqual(results[0].sourceAttribution, "artist.example")
    }

    func testSearchLocallyCapsProviderOverReturn() async throws {
        URLProtocolStub.install { request in
            let item = """
                {
                  "id": "frog-ID",
                  "title": "Frog",
                  "images": {
                    "fixed_width": {
                      "url": "https://media.giphy.com/preview-ID.gif"
                    },
                    "original": {
                      "url": "https://media.giphy.com/original-ID.gif"
                    }
                  }
                }
                """
            let data = Data(
                """
                {"data": [
                  \(item.replacingOccurrences(of: "ID", with: "1")),
                  \(item.replacingOccurrences(of: "ID", with: "2"))
                ]}
                """.utf8
            )
            return (
                try XCTUnwrap(
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )
                ),
                data
            )
        }
        let client = GiphyClient(
            session: URLProtocolStub.session(),
            keyProvider: TestKeyProvider(value: "test-key")
        )

        let results = try await client.search("frog", limit: 1)

        XCTAssertEqual(results.map(\.id), ["frog-1"])
    }

    func testSearchRejectsOverlongQuery() async {
        let client = GiphyClient(
            session: URLProtocolStub.session(),
            keyProvider: TestKeyProvider(value: "test-key")
        )

        do {
            _ = try await client.search(String(repeating: "x", count: 51))
            XCTFail("Expected a query-length error.")
        } catch let error as RemoteMediaError {
            XCTAssertEqual(error, .queryTooLong(limit: 50))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testProviderURLPolicyRejectsUnrelatedAndLocalHosts() {
        XCTAssertTrue(
            RemoteMediaURLPolicy.allows(
                URL(string: "https://media2.giphy.com/media/frog.gif")!,
                for: .giphy
            )
        )
        XCTAssertTrue(
            RemoteMediaURLPolicy.allows(
                URL(string: "https://fonts.gstatic.com/frog.gif")!,
                for: .notoAnimatedEmoji
            )
        )
        XCTAssertFalse(
            RemoteMediaURLPolicy.allows(
                URL(string: "https://example.com/frog.gif")!,
                for: .giphy
            )
        )
        XCTAssertFalse(
            RemoteMediaURLPolicy.allows(
                URL(string: "https://127.0.0.1/frog.gif")!,
                for: .giphy
            )
        )
        XCTAssertFalse(
            RemoteMediaURLPolicy.allows(
                URL(string: "https://fonts.gstatic.com:444/frog.gif")!,
                for: .notoAnimatedEmoji
            )
        )
    }
}

private struct TestKeyProvider: GiphyAPIKeyProviding {
    let value: String?

    func apiKey() throws -> String {
        guard let value else {
            throw RemoteMediaError.missingAPIKey
        }
        return value
    }
}
