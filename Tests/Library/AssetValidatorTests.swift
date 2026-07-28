import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import MojiPond

final class AssetValidatorTests: XCTestCase {
    func testAcceptsPNGJPEGGIFAndWebP() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let png = try TestSupport.writeImage(
            to: root.appendingPathComponent("frog.png"),
            format: .png
        )
        let jpeg = try TestSupport.writeImage(
            to: root.appendingPathComponent("frog.jpg"),
            format: .jpeg
        )
        let gif = try TestSupport.writeImage(
            to: root.appendingPathComponent("frog.gif"),
            format: .gif,
            frameCount: 2
        )
        let webP = try TestSupport.writeTinyWebP(
            to: root.appendingPathComponent("frog.webp")
        )
        let validator = AssetValidator()

        XCTAssertEqual(try validator.validate(fileAt: png).format, .png)
        XCTAssertEqual(try validator.validate(fileAt: jpeg).format, .jpeg)
        let gifResult = try validator.validate(fileAt: gif)
        XCTAssertEqual(gifResult.format, .gif)
        XCTAssertEqual(gifResult.frameCount, 2)
        XCTAssertTrue(gifResult.isAnimated)
        XCTAssertEqual(try validator.validate(fileAt: webP).format, .webP)
    }

    func testRejectsSpoofedExtensionAndNonImage() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let realPNG = try TestSupport.writeImage(
            to: root.appendingPathComponent("real.png"),
            format: .png
        )
        let spoofed = root.appendingPathComponent("spoofed.jpg")
        try FileManager.default.copyItem(at: realPNG, to: spoofed)
        let text = root.appendingPathComponent("not-image.png")
        try Data("not an image".utf8).write(to: text)

        XCTAssertThrowsError(try AssetValidator().validate(fileAt: spoofed)) {
            XCTAssertEqual(
                $0 as? AssetValidationError,
                .typeMismatch(filenameExtension: "jpg", detected: .png)
            )
        }
        XCTAssertThrowsError(try AssetValidator().validate(fileAt: text))
    }

    func testRejectsSymlinkOversizeDimensionsAndFrameCount() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let png = try TestSupport.writeImage(
            to: root.appendingPathComponent("large.png"),
            format: .png,
            width: 4,
            height: 3
        )
        let symlink = root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: png)
        XCTAssertThrowsError(try AssetValidator().validate(fileAt: symlink))

        var dimensionLimits = AssetValidationLimits.default
        dimensionLimits.maximumPixelWidth = 3
        XCTAssertThrowsError(
            try AssetValidator(limits: dimensionLimits).validate(fileAt: png)
        ) {
            guard case .dimensionsTooLarge = $0 as? AssetValidationError else {
                return XCTFail("Expected dimensionsTooLarge, got \($0)")
            }
        }

        let gif = try TestSupport.writeImage(
            to: root.appendingPathComponent("animated.gif"),
            format: .gif,
            frameCount: 2
        )
        var frameLimits = AssetValidationLimits.default
        frameLimits.maximumFrameCount = 1
        XCTAssertThrowsError(
            try AssetValidator(limits: frameLimits).validate(fileAt: gif)
        ) {
            XCTAssertEqual(
                $0 as? AssetValidationError,
                .tooManyFrames(actual: 2, limit: 1)
            )
        }

        var byteLimits = AssetValidationLimits.default
        byteLimits.maximumFileBytes = 1
        XCTAssertThrowsError(
            try AssetValidator(limits: byteLimits).validate(fileAt: png)
        )
    }
}
