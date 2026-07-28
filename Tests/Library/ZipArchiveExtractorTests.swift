import Foundation
import XCTest
@testable import MojiPond

final class ZipArchiveExtractorTests: XCTestCase {
    func testAcceptsArchiveProducedBySystemZip() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("ribbit".utf8).write(to: root.appendingPathComponent("frog.txt"))
        let archiveURL = root.appendingPathComponent("system.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = root
        process.arguments = ["-q", archiveURL.path, "frog.txt"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let inspection = try ZipArchiveExtractor().inspect(archiveAt: archiveURL)
        XCTAssertEqual(inspection.entries.map(\.path), ["frog.txt"])
    }

    func testPreflightsAndExtractsARegularArchive() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("pack.zip")
        let archive = TestZipBuilder.archive(
            entries: [
                .init(path: "pack/", data: Data(), unixMode: 0o040700),
                .init(path: "pack/frog.txt", data: Data("ribbit".utf8))
            ]
        )
        try archive.write(to: archiveURL)

        let extractor = ZipArchiveExtractor()
        let inspection = try extractor.inspect(archiveAt: archiveURL)
        XCTAssertEqual(inspection.entries.count, 2)
        XCTAssertEqual(inspection.totalUncompressedBytes, 6)

        let destination = root.appendingPathComponent("expanded", isDirectory: true)
        let extractedInspection = try extractor.extract(
            archiveAt: archiveURL,
            to: destination
        )
        XCTAssertEqual(extractedInspection, inspection)
        let extractedFile = destination.appendingPathComponent("pack/frog.txt")
        XCTAssertEqual(try String(contentsOf: extractedFile, encoding: .utf8), "ribbit")
        let permissions = try FileManager.default.attributesOfItem(
            atPath: extractedFile.path
        )[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testRejectsTraversalAbsoluteBackslashAndColonPaths() throws {
        let unsafePaths = [
            "../outside.png",
            "/absolute.png",
            "folder\\outside.png",
            "C:drive.png",
            "folder/../../outside.png"
        ]
        for path in unsafePaths {
            let archiveURL = try writeArchive(
                TestZipBuilder.archive(
                    entries: [.init(path: path, data: Data("x".utf8))]
                )
            )
            defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
            XCTAssertThrowsError(
                try ZipArchiveExtractor().inspect(archiveAt: archiveURL),
                "Expected rejection for \(path)"
            ) {
                guard case .unsafePath = $0 as? ZipArchiveError else {
                    return XCTFail("Expected unsafePath for \(path), got \($0)")
                }
            }
        }
    }

    func testRejectsSymlinkDuplicateCaseAndFileDirectoryConflict() throws {
        let symlinkArchive = try writeArchive(
            TestZipBuilder.archive(
                entries: [
                    .init(
                        path: "link",
                        data: Data("target".utf8),
                        unixMode: 0o120777
                    )
                ]
            )
        )
        defer { try? FileManager.default.removeItem(at: symlinkArchive.deletingLastPathComponent()) }
        XCTAssertThrowsError(
            try ZipArchiveExtractor().inspect(archiveAt: symlinkArchive)
        ) {
            XCTAssertEqual($0 as? ZipArchiveError, .nonRegularEntry("link"))
        }

        let duplicateArchive = try writeArchive(
            TestZipBuilder.archive(
                entries: [
                    .init(path: "Frog.png", data: Data("a".utf8)),
                    .init(path: "frog.png", data: Data("b".utf8))
                ]
            )
        )
        defer { try? FileManager.default.removeItem(at: duplicateArchive.deletingLastPathComponent()) }
        XCTAssertThrowsError(
            try ZipArchiveExtractor().inspect(archiveAt: duplicateArchive)
        ) {
            XCTAssertEqual($0 as? ZipArchiveError, .duplicatePath("frog.png"))
        }

        let conflictArchive = try writeArchive(
            TestZipBuilder.archive(
                entries: [
                    .init(path: "frog", data: Data("a".utf8)),
                    .init(path: "frog/child.png", data: Data("b".utf8))
                ]
            )
        )
        defer { try? FileManager.default.removeItem(at: conflictArchive.deletingLastPathComponent()) }
        XCTAssertThrowsError(
            try ZipArchiveExtractor().inspect(archiveAt: conflictArchive)
        ) {
            XCTAssertEqual($0 as? ZipArchiveError, .pathTypeConflict("frog"))
        }
    }

    func testRejectsCompressionBombShapeOversizedEntryAndTrailingPayload() throws {
        let bomb = try writeArchive(
            TestZipBuilder.archive(
                entries: [
                    .init(
                        path: "bomb.gif",
                        data: Data([0]),
                        declaredCompressedSize: 1,
                        declaredUncompressedSize: 1_000
                    )
                ]
            )
        )
        defer { try? FileManager.default.removeItem(at: bomb.deletingLastPathComponent()) }
        var ratioLimits = ZipExtractionLimits.default
        ratioLimits.maximumCompressionRatio = 10
        XCTAssertThrowsError(
            try ZipArchiveExtractor(limits: ratioLimits).inspect(archiveAt: bomb)
        ) {
            XCTAssertEqual(
                $0 as? ZipArchiveError,
                .compressionRatioExceeded("bomb.gif")
            )
        }

        let oversized = try writeArchive(
            TestZipBuilder.archive(
                entries: [
                    .init(path: "large.png", data: Data(repeating: 1, count: 4))
                ]
            )
        )
        defer { try? FileManager.default.removeItem(at: oversized.deletingLastPathComponent()) }
        var sizeLimits = ZipExtractionLimits.default
        sizeLimits.maximumEntryBytes = 3
        XCTAssertThrowsError(
            try ZipArchiveExtractor(limits: sizeLimits).inspect(archiveAt: oversized)
        ) {
            XCTAssertEqual(
                $0 as? ZipArchiveError,
                .entryTooLarge(path: "large.png", actual: 4, limit: 3)
            )
        }

        let trailing = try writeArchive(
            TestZipBuilder.archive(
                entries: [.init(path: "frog.png", data: Data("x".utf8))],
                trailingData: Data("payload".utf8)
            )
        )
        defer { try? FileManager.default.removeItem(at: trailing.deletingLastPathComponent()) }
        XCTAssertThrowsError(
            try ZipArchiveExtractor().inspect(archiveAt: trailing)
        ) {
            XCTAssertEqual($0 as? ZipArchiveError, .trailingData)
        }
    }

    func testDoesNotOverwriteExistingDestination() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("pack.zip")
        try TestZipBuilder.archive(
            entries: [.init(path: "frog.txt", data: Data("frog".utf8))]
        ).write(to: archiveURL)
        let destination = root.appendingPathComponent("existing", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)

        XCTAssertThrowsError(
            try ZipArchiveExtractor().extract(
                archiveAt: archiveURL,
                to: destination
            )
        ) {
            XCTAssertEqual($0 as? ZipArchiveError, .destinationAlreadyExists)
        }
    }

    private func writeArchive(_ data: Data) throws -> URL {
        let root = try TestSupport.makeTemporaryDirectory()
        let archiveURL = root.appendingPathComponent("test.zip")
        try data.write(to: archiveURL)
        return archiveURL
    }
}
