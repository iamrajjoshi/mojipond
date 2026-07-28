import Foundation
import ImageIO
import UniformTypeIdentifiers

struct AssetValidationLimits: Equatable, Sendable {
    var maximumFileBytes: Int64 = 25 * 1_024 * 1_024
    var maximumPixelWidth = 4_096
    var maximumPixelHeight = 4_096
    var maximumPixelsPerFrame: Int64 = 16_777_216
    var maximumFrameCount = 256
    var maximumTotalAnimationPixels: Int64 = 200_000_000
    var maximumFrameDurationSeconds = 10.0
    var maximumAnimationDurationSeconds = 120.0
    var allowedFormats: Set<AssetFormat> = Set(AssetFormat.allCases)

    static let `default` = Self()
}

struct ValidatedAsset: Equatable, Sendable {
    let format: AssetFormat
    let digest: ContentDigest
    let pixelWidth: Int
    let pixelHeight: Int
    let frameCount: Int

    var isAnimated: Bool {
        frameCount > 1
    }
}

struct AssetValidator: Sendable {
    private struct Inspection {
        let format: AssetFormat
        let pixelWidth: Int
        let pixelHeight: Int
        let frameCount: Int
    }

    let limits: AssetValidationLimits

    init(limits: AssetValidationLimits = .default) {
        self.limits = limits
    }

    func validate(fileAt url: URL) throws -> ValidatedAsset {
        let resourceValues = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentTypeKey
        ])
        guard resourceValues.isRegularFile == true, resourceValues.isSymbolicLink != true else {
            throw AssetValidationError.notARegularFile(url)
        }

        let reportedSize = Int64(resourceValues.fileSize ?? 0)
        guard reportedSize > 0 else {
            throw AssetValidationError.emptyFile
        }
        guard reportedSize <= limits.maximumFileBytes else {
            throw AssetValidationError.fileTooLarge(actual: reportedSize, limit: limits.maximumFileBytes)
        }

        guard let imageSource = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            throw AssetValidationError.notAnImage
        }
        let inspection = try inspect(imageSource)
        try validateFilenameType(
            url: url,
            resourceType: resourceValues.contentType,
            actualFormat: inspection.format
        )

        let digest = try ContentHasher.sha256(
            ofFileAt: url,
            maximumBytes: limits.maximumFileBytes
        )
        return ValidatedAsset(
            format: inspection.format,
            digest: digest,
            pixelWidth: inspection.pixelWidth,
            pixelHeight: inspection.pixelHeight,
            frameCount: inspection.frameCount
        )
    }

    func validate(
        data: Data,
        expectedFormat: AssetFormat? = nil
    ) throws -> ValidatedAsset {
        guard !data.isEmpty else {
            throw AssetValidationError.emptyFile
        }
        let byteCount = Int64(data.count)
        guard byteCount <= limits.maximumFileBytes else {
            throw AssetValidationError.fileTooLarge(
                actual: byteCount,
                limit: limits.maximumFileBytes
            )
        }
        guard let imageSource = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            throw AssetValidationError.notAnImage
        }
        let inspection = try inspect(imageSource)
        if let expectedFormat, inspection.format != expectedFormat {
            throw AssetValidationError.dataTypeMismatch(
                expected: expectedFormat,
                detected: inspection.format
            )
        }
        return ValidatedAsset(
            format: inspection.format,
            digest: ContentHasher.sha256(of: data),
            pixelWidth: inspection.pixelWidth,
            pixelHeight: inspection.pixelHeight,
            frameCount: inspection.frameCount
        )
    }

    private func inspect(_ imageSource: CGImageSource) throws -> Inspection {
        guard CGImageSourceGetStatus(imageSource) == .statusComplete else {
            throw AssetValidationError.incompleteImage
        }
        guard let sourceTypeIdentifier = CGImageSourceGetType(imageSource),
              let sourceType = UTType(sourceTypeIdentifier as String) else {
            throw AssetValidationError.unknownImageType
        }
        guard
            let format = Self.format(for: sourceType),
            limits.allowedFormats.contains(format)
        else {
            throw AssetValidationError.unsupportedType(
                sourceType.identifier
            )
        }

        let frameCount = CGImageSourceGetCount(imageSource)
        guard frameCount > 0 else {
            throw AssetValidationError.noFrames
        }
        guard frameCount <= limits.maximumFrameCount else {
            throw AssetValidationError.tooManyFrames(
                actual: frameCount,
                limit: limits.maximumFrameCount
            )
        }

        var firstWidth: Int?
        var firstHeight: Int?
        var totalPixels: Int64 = 0
        var totalDuration = 0.0
        for index in 0..<frameCount {
            guard
                CGImageSourceGetStatusAtIndex(imageSource, index)
                    == .statusComplete
            else {
                throw AssetValidationError.incompleteFrame(index)
            }
            guard
                let properties = CGImageSourceCopyPropertiesAtIndex(
                    imageSource,
                    index,
                    nil
                ) as? [CFString: Any],
                let width = Self.integerProperty(
                    kCGImagePropertyPixelWidth,
                    in: properties
                ),
                let height = Self.integerProperty(
                    kCGImagePropertyPixelHeight,
                    in: properties
                ),
                width > 0,
                height > 0
            else {
                throw AssetValidationError.missingDimensions(frame: index)
            }

            guard
                width <= limits.maximumPixelWidth,
                height <= limits.maximumPixelHeight
            else {
                throw AssetValidationError.dimensionsTooLarge(
                    width: width,
                    height: height,
                    maximumWidth: limits.maximumPixelWidth,
                    maximumHeight: limits.maximumPixelHeight
                )
            }

            let pixels = Int64(width) * Int64(height)
            guard pixels <= limits.maximumPixelsPerFrame else {
                throw AssetValidationError.tooManyPixels(
                    actual: pixels,
                    limit: limits.maximumPixelsPerFrame
                )
            }
            let (newTotal, overflow) =
                totalPixels.addingReportingOverflow(pixels)
            guard
                !overflow,
                newTotal <= limits.maximumTotalAnimationPixels
            else {
                throw AssetValidationError.animationPixelBudgetExceeded(
                    limit: limits.maximumTotalAnimationPixels
                )
            }
            totalPixels = newTotal
            if firstWidth == nil {
                firstWidth = width
                firstHeight = height
            }

            if frameCount > 1 {
                let duration = Self.frameDuration(
                    format: format,
                    properties: properties
                )
                guard
                    duration.isFinite,
                    duration >= 0,
                    duration <= limits.maximumFrameDurationSeconds
                else {
                    throw AssetValidationError.invalidFrameDuration(
                        frame: index,
                        maximum: limits.maximumFrameDurationSeconds
                    )
                }
                totalDuration += duration
                guard
                    totalDuration.isFinite,
                    totalDuration
                        <= limits.maximumAnimationDurationSeconds
                else {
                    throw AssetValidationError
                        .animationDurationExceeded(
                            limit:
                                limits.maximumAnimationDurationSeconds
                        )
                }
            }

            // Metadata-only parsing can accept truncated frame data. Decode a
            // tiny thumbnail for every frame without full-size allocation.
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard
                CGImageSourceCreateThumbnailAtIndex(
                    imageSource,
                    index,
                    thumbnailOptions as CFDictionary
                ) != nil
            else {
                throw AssetValidationError.cannotDecodeFrame(index)
            }
        }

        return Inspection(
            format: format,
            pixelWidth: firstWidth ?? 0,
            pixelHeight: firstHeight ?? 0,
            frameCount: frameCount
        )
    }

    private func validateFilenameType(
        url: URL,
        resourceType: UTType?,
        actualFormat: AssetFormat
    ) throws {
        let filenameExtension = url.pathExtension
        guard !filenameExtension.isEmpty else {
            return
        }

        guard let declaredType = resourceType ?? UTType(filenameExtension: filenameExtension),
              let declaredFormat = Self.format(for: declaredType),
              limits.allowedFormats.contains(declaredFormat) else {
            throw AssetValidationError.unsupportedFilenameExtension(filenameExtension)
        }
        guard declaredFormat == actualFormat else {
            throw AssetValidationError.typeMismatch(
                filenameExtension: filenameExtension,
                detected: actualFormat
            )
        }
    }

    private static func integerProperty(
        _ key: CFString,
        in properties: [CFString: Any]
    ) -> Int? {
        (properties[key] as? NSNumber)?.intValue
    }

    private static func frameDuration(
        format: AssetFormat,
        properties: [CFString: Any]
    ) -> Double {
        let dictionaryKey: CFString
        let unclampedKey: CFString
        let delayKey: CFString
        switch format {
        case .gif:
            dictionaryKey = kCGImagePropertyGIFDictionary
            unclampedKey = kCGImagePropertyGIFUnclampedDelayTime
            delayKey = kCGImagePropertyGIFDelayTime
        case .png:
            dictionaryKey = kCGImagePropertyPNGDictionary
            unclampedKey = kCGImagePropertyAPNGUnclampedDelayTime
            delayKey = kCGImagePropertyAPNGDelayTime
        case .webP:
            dictionaryKey = kCGImagePropertyWebPDictionary
            unclampedKey = kCGImagePropertyWebPUnclampedDelayTime
            delayKey = kCGImagePropertyWebPDelayTime
        case .jpeg:
            return 0.1
        }
        guard
            let dictionary = properties[dictionaryKey]
                as? [CFString: Any]
        else {
            return 0.1
        }
        return (dictionary[unclampedKey] as? NSNumber)?.doubleValue
            ?? (dictionary[delayKey] as? NSNumber)?.doubleValue
            ?? 0.1
    }

    private static func format(for type: UTType) -> AssetFormat? {
        if type.conforms(to: .png) {
            return .png
        }
        if type.conforms(to: .jpeg) {
            return .jpeg
        }
        if type.conforms(to: .gif) {
            return .gif
        }
        if type.conforms(to: .webP) {
            return .webP
        }
        return nil
    }
}

enum AssetValidationError: Error, Equatable, LocalizedError, Sendable {
    case notARegularFile(URL)
    case emptyFile
    case fileTooLarge(actual: Int64, limit: Int64)
    case notAnImage
    case incompleteImage
    case unknownImageType
    case unsupportedType(String)
    case unsupportedFilenameExtension(String)
    case typeMismatch(filenameExtension: String, detected: AssetFormat)
    case dataTypeMismatch(expected: AssetFormat, detected: AssetFormat)
    case noFrames
    case tooManyFrames(actual: Int, limit: Int)
    case incompleteFrame(Int)
    case missingDimensions(frame: Int)
    case dimensionsTooLarge(width: Int, height: Int, maximumWidth: Int, maximumHeight: Int)
    case tooManyPixels(actual: Int64, limit: Int64)
    case animationPixelBudgetExceeded(limit: Int64)
    case invalidFrameDuration(frame: Int, maximum: Double)
    case animationDurationExceeded(limit: Double)
    case cannotDecodeFrame(Int)

    var errorDescription: String? {
        switch self {
        case let .notARegularFile(url):
            "\(url.lastPathComponent) is not a regular file."
        case .emptyFile:
            "The image file is empty."
        case let .fileTooLarge(actual, limit):
            "The image is \(actual) bytes, above the \(limit)-byte limit."
        case .notAnImage:
            "ImageIO could not open the file."
        case .incompleteImage:
            "The image data is incomplete."
        case .unknownImageType:
            "ImageIO could not identify the image type."
        case let .unsupportedType(type):
            "Image type \(type) is not supported."
        case let .unsupportedFilenameExtension(filenameExtension):
            "Filename extension .\(filenameExtension) is not supported."
        case let .typeMismatch(filenameExtension, detected):
            "Filename extension .\(filenameExtension) does not match detected \(detected.rawValue) data."
        case let .dataTypeMismatch(expected, detected):
            "Declared \(expected.rawValue) data is actually \(detected.rawValue)."
        case .noFrames:
            "The image has no frames."
        case let .tooManyFrames(actual, limit):
            "The image has \(actual) frames, above the \(limit)-frame limit."
        case let .incompleteFrame(frame):
            "Image frame \(frame) is incomplete."
        case let .missingDimensions(frame):
            "Image frame \(frame) has no valid dimensions."
        case let .dimensionsTooLarge(width, height, maximumWidth, maximumHeight):
            "Image dimensions \(width)×\(height) exceed \(maximumWidth)×\(maximumHeight)."
        case let .tooManyPixels(actual, limit):
            "An image frame has \(actual) pixels, above the \(limit)-pixel limit."
        case let .animationPixelBudgetExceeded(limit):
            "The animation exceeds the \(limit)-pixel decoded-frame budget."
        case let .invalidFrameDuration(frame, maximum):
            "Image frame \(frame) has an invalid duration above the \(maximum)-second limit."
        case let .animationDurationExceeded(limit):
            "The animation exceeds the \(limit)-second duration limit."
        case let .cannotDecodeFrame(frame):
            "ImageIO could not decode frame \(frame)."
        }
    }
}
