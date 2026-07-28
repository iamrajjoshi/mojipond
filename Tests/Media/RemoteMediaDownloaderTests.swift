import Foundation
import XCTest
@testable import MojiPond

final class RemoteMediaDownloaderTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    func testDownloaderPreservesGIFBytes() async throws {
        let expected = try XCTUnwrap(
            Data(
                base64Encoded:
                    "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=="
            )
        )
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
            previewURL: URL(string: "https://media.giphy.com/preview.gif")!,
            originalURL: URL(string: "https://media.giphy.com/original.gif")!,
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

    func testDownloaderRejectsMalformedImageWithAllowedContentType()
        async
    {
        URLProtocolStub.install { request in
            (
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "image/gif"]
                )),
                Data("GIF89a-malformed".utf8)
            )
        }
        let item = RemoteMediaItem(
            id: "gif",
            provider: .giphy,
            title: "GIF",
            previewURL: URL(
                string: "https://media.giphy.com/preview.gif"
            )!,
            originalURL: URL(
                string: "https://media.giphy.com/original.gif"
            )!,
            dimensions: nil,
            attribution: "Powered by GIPHY",
            analytics: nil
        )

        do {
            _ = try await RemoteMediaDownloader(
                session: URLProtocolStub.session()
            ).download(item)
            XCTFail("Expected malformed media rejection")
        } catch let error as RemoteMediaError {
            XCTAssertEqual(error, .unsafeImage)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
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
            previewURL: URL(string: "https://fonts.gstatic.com/image.png")!,
            originalURL: URL(string: "https://fonts.gstatic.com/image.png")!,
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

    func testDownloaderRejectsProviderHostSubstitutionBeforeNetwork() async {
        let item = RemoteMediaItem(
            id: "hostile",
            provider: .giphy,
            title: "Hostile",
            previewURL: URL(string: "https://127.0.0.1/preview.gif")!,
            originalURL: URL(string: "https://127.0.0.1/original.gif")!,
            dimensions: nil,
            attribution: "Powered by GIPHY",
            analytics: nil
        )
        let downloader = RemoteMediaDownloader(
            session: URLProtocolStub.session()
        )

        do {
            _ = try await downloader.download(item)
            XCTFail("Expected a provider-host error.")
        } catch let error as RemoteMediaError {
            XCTAssertEqual(error, .insecureURL)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
