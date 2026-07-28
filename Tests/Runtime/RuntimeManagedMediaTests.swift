import CryptoKit
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import MojiPond

final class RuntimeManagedMediaTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots = []
    }

    func testResolvesPNGAndPreservesOriginalBytes() throws {
        let png = Data([
            0x89, 0x50, 0x4E, 0x47,
            0x0D, 0x0A, 0x1A, 0x0A,
            0xAA, 0xBB, 0xCC
        ])
        let fixture = try makeFixture(data: png, filename: "pond.png")

        let resolved = try RuntimeManagedMediaResolver().resolve(
            media(
                type: .png,
                path: fixture.relativePath,
                data: png
            ),
            beneath: fixture.root
        )

        XCTAssertEqual(resolved.originalData, png)
        XCTAssertEqual(resolved.uniformType, .png)
        XCTAssertEqual(resolved.suggestedFilename, "pond.png")
    }

    func testResolvesGIFAndPayloadKeepsOriginalGIFRepresentation() throws {
        let gif = validGIFData
        let fixture = try makeFixture(data: gif, filename: "bufo.gif")
        let resolved = try RuntimeManagedMediaResolver().resolve(
            media(
                type: .gif,
                path: fixture.relativePath,
                data: gif,
                isAnimated: true
            ),
            beneath: fixture.root
        )

        let original = resolved.pasteboardPayload.representations.first {
            $0.typeIdentifier == UTType.gif.identifier
        }
        XCTAssertEqual(original?.data, gif)
    }

    func testRejectsTraversalSymlinkDigestMismatchAndOversize() throws {
        let gif = Data("GIF89a-safe".utf8)
        let fixture = try makeFixture(data: gif, filename: "safe.gif")
        let resolver = RuntimeManagedMediaResolver(maximumBytes: gif.count)

        XCTAssertThrowsError(
            try resolver.resolve(
                media(
                    type: .gif,
                    path: "../safe.gif",
                    data: gif
                ),
                beneath: fixture.root
            )
        ) {
            XCTAssertEqual(
                $0 as? RuntimeManagedMediaError,
                .unsafeRelativePath
            )
        }

        var changedDigest = String(repeating: "0", count: 64)
        if changedDigest == digest(gif) {
            changedDigest = String(repeating: "1", count: 64)
        }
        XCTAssertThrowsError(
            try resolver.resolve(
                MediaEmojiContent(
                    mediaType: .gif,
                    relativePath: fixture.relativePath,
                    contentHash: changedDigest,
                    isAnimated: true
                ),
                beneath: fixture.root
            )
        ) {
            XCTAssertEqual(
                $0 as? RuntimeManagedMediaError,
                .digestMismatch
            )
        }

        let oversized = Data("GIF89a-too-large".utf8)
        let oversizedFixture = try makeFixture(
            data: oversized,
            filename: "large.gif"
        )
        XCTAssertThrowsError(
            try resolver.resolve(
                media(
                    type: .gif,
                    path: oversizedFixture.relativePath,
                    data: oversized
                ),
                beneath: oversizedFixture.root
            )
        ) {
            XCTAssertEqual(
                $0 as? RuntimeManagedMediaError,
                .fileTooLarge(limit: gif.count)
            )
        }

        let externalRoot = try makeTemporaryRoot()
        let externalFile = externalRoot.appendingPathComponent("outside.gif")
        try gif.write(to: externalFile)
        let link = fixture.root.appendingPathComponent("linked.gif")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: externalFile
        )
        XCTAssertThrowsError(
            try resolver.resolve(
                media(type: .gif, path: "linked.gif", data: gif),
                beneath: fixture.root
            )
        ) {
            XCTAssertEqual(
                $0 as? RuntimeManagedMediaError,
                .escapedManagedRoot
            )
        }
    }

    func testRejectsDeclaredTypeThatDoesNotMatchBytes() throws {
        let gif = Data("GIF89a-not-a-png".utf8)
        let fixture = try makeFixture(data: gif, filename: "lying.png")

        XCTAssertThrowsError(
            try RuntimeManagedMediaResolver().resolve(
                media(
                    type: .png,
                    path: fixture.relativePath,
                    data: gif
                ),
                beneath: fixture.root
            )
        ) {
            XCTAssertEqual(
                $0 as? RuntimeManagedMediaError,
                .contentTypeMismatch
            )
        }
    }

    func testDownloadedGIFAndPNGPayloadsRetainOriginalBytes() throws {
        let downloads: [(Data, String, String)] = [
            (
                validGIFData,
                "image/gif",
                UTType.gif.identifier
            ),
            (
                Data([
                    0x89, 0x50, 0x4E, 0x47,
                    0x0D, 0x0A, 0x1A, 0x0A,
                    0x01
                ]),
                "image/png",
                UTType.png.identifier
            )
        ]

        for (data, contentType, typeIdentifier) in downloads {
            let payload = try RuntimeMediaPayloadBuilder.payload(
                for: MediaCommandDownload(
                    data: data,
                    contentType: contentType,
                    suggestedFilename: "asset"
                )
            )
            XCTAssertEqual(
                payload.representations.first {
                    $0.typeIdentifier == typeIdentifier
                }?.data,
                data
            )
        }
    }

    private func makeFixture(
        data: Data,
        filename: String
    ) throws -> (root: URL, relativePath: String) {
        let root = try makeTemporaryRoot()
        let relativePath = "assets/\(filename)"
        let directory = root.appendingPathComponent(
            "assets",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try data.write(to: root.appendingPathComponent(relativePath))
        return (root, relativePath)
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MojiPondRuntimeMediaTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        temporaryRoots.append(root)
        return root
    }

    private func media(
        type: EmojiMediaType,
        path: String,
        data: Data,
        isAnimated: Bool = false
    ) -> MediaEmojiContent {
        MediaEmojiContent(
            mediaType: type,
            relativePath: path,
            originalFilename: URL(
                fileURLWithPath: path
            ).lastPathComponent,
            contentHash: digest(data),
            isAnimated: isAnimated
        )
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private var validGIFData: Data {
        Data(
            base64Encoded:
                "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=="
        )!
    }
}
