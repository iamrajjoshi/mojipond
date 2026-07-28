import Foundation
import XCTest
@testable import MojiPond

final class NotoStickerClientTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    func testSearchUsesTagsAndPopularity() async throws {
        URLProtocolStub.install { request in
            let data = Data(
                """
                {
                  "host": "",
                  "asset_url_pattern": "",
                  "families": ["Animated Emoji"],
                  "icons": [
                    {
                      "name": "emoji_u1f44b",
                      "version": 1,
                      "popularity": 100,
                      "codepoint": "1f44b",
                      "unsupported_families": [],
                      "categories": ["People"],
                      "tags": [":wave:"],
                      "sizes_px": []
                    },
                    {
                      "name": "emoji_u1f30a",
                      "version": 1,
                      "popularity": 20,
                      "codepoint": "1f30a",
                      "unsupported_families": [],
                      "categories": ["Nature"],
                      "tags": [":water-wave:"],
                      "sizes_px": []
                    }
                  ]
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

        let client = NotoStickerClient(session: URLProtocolStub.session())
        let results = try await client.search("wave")

        XCTAssertEqual(results.map(\.id), ["noto-1f44b", "noto-1f30a"])
        XCTAssertEqual(results[0].title, "Wave")
        XCTAssertEqual(
            results[0].originalURL.absoluteString,
            "https://fonts.gstatic.com/s/e/notoemoji/latest/1f44b/512.gif"
        )
    }
}
