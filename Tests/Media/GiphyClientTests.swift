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
            XCTAssertEqual(query["customer_id"] ?? nil, "customer")

            let data = Data(
                """
                {
                  "data": [{
                    "id": "frog-1",
                    "title": "Concerned frog",
                    "images": {
                      "fixed_width": {
                        "url": "https://media.example/preview.gif",
                        "width": "200",
                        "height": "120"
                      },
                      "original": {
                        "url": "https://media.example/original.gif",
                        "width": "640",
                        "height": "384"
                      }
                    },
                    "analytics": {
                      "onload": {"url": "https://analytics.example/load"},
                      "onclick": {"url": "https://analytics.example/click"},
                      "onsent": {"url": "https://analytics.example/sent"}
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
            keyProvider: TestKeyProvider(value: "test-key"),
            customerID: { "customer" }
        )
        let results = try await client.search("concerned frog")

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, "frog-1")
        XCTAssertEqual(results[0].provider, .giphy)
        XCTAssertEqual(results[0].dimensions, .init(width: 640, height: 384))
        XCTAssertEqual(results[0].attribution, "Powered by GIPHY")
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
