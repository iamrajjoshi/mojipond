import Foundation
import XCTest
@testable import MojiPond

final class BoundedHTTPSResponseLoaderTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    func testRejectsDeclaredOversizeBeforeReadingBody() async {
        URLProtocolStub.install { request in
            (
                try XCTUnwrap(
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Length": "9"]
                    )
                ),
                Data()
            )
        }
        let loader = BoundedHTTPSResponseLoader(
            session: URLProtocolStub.session()
        )

        await assertLoadError(.responseTooLarge(limit: 8)) {
            _ = try await loader.load(
                URLRequest(url: URL(string: "https://example.com/feed")!),
                maximumBytes: 8
            )
        }
    }

    func testCancelsUnknownLengthBodyAtLimit() async {
        URLProtocolStub.install { request in
            (
                try XCTUnwrap(
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )
                ),
                Data(repeating: 0x61, count: 9)
            )
        }
        let loader = BoundedHTTPSResponseLoader(
            session: URLProtocolStub.session()
        )

        await assertLoadError(.responseTooLarge(limit: 8)) {
            _ = try await loader.load(
                URLRequest(url: URL(string: "https://example.com/feed")!),
                maximumBytes: 8
            )
        }
    }

    func testRejectsInsecureInitialURL() async {
        let loader = BoundedHTTPSResponseLoader(
            session: URLProtocolStub.session()
        )

        await assertLoadError(.insecureRequestURL) {
            _ = try await loader.load(
                URLRequest(url: URL(string: "http://example.com/feed")!),
                maximumBytes: 8
            )
        }
    }

    private func assertLoadError(
        _ expected: BoundedHTTPSLoadError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected).")
        } catch let error as BoundedHTTPSLoadError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
