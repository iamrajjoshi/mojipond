import Foundation
import XCTest
@testable import MojiPond

final class RemoteMediaDownloaderTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    func testDownloaderPreservesGIFBytes() async throws {
        let expected = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])
        URLProtocolStub.install { request in
            (
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "image/gif"]
                )),
                expected
            )
        }

        let item = RemoteMediaItem(
            id: "gif",
            provider: .giphy,
            title: "GIF",
            previewURL: URL(string: "https://example.com/preview.gif")!,
            originalURL: URL(string: "https://example.com/original.gif")!,
            dimensions: nil,
            attribution: "Powered by GIPHY",
            analytics: nil
        )
        let downloader = RemoteMediaDownloader(session: URLProtocolStub.session())
        let result = try await downloader.download(item)

        XCTAssertEqual(result.data, expected)
        XCTAssertEqual(result.contentType, "image/gif")
        XCTAssertTrue(result.suggestedFilename.hasSuffix(".gif"))
    }

    func testDownloaderRejectsOversizedBody() async {
        URLProtocolStub.install { request in
            (
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "image/png"]
                )),
                Data(repeating: 0, count: 9)
            )
        }

        let item = RemoteMediaItem(
            id: "image",
            provider: .notoAnimatedEmoji,
            title: "Image",
            previewURL: URL(string: "https://example.com/image.png")!,
            originalURL: URL(string: "https://example.com/image.png")!,
            dimensions: nil,
            attribution: "Noto Animated Emoji by Google",
            analytics: nil
        )
        let downloader = RemoteMediaDownloader(
            session: URLProtocolStub.session(),
            maximumBytes: 8
        )

        do {
            _ = try await downloader.download(item)
            XCTFail("Expected an oversized-response error.")
        } catch let error as RemoteMediaError {
            XCTAssertEqual(error, .responseTooLarge(limit: 8))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
