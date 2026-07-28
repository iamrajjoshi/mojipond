import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum TestSupport {
    static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MojiPondTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        return url
    }

    static func fixture(named name: String) throws -> Data {
        let fixturesURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
        return try Data(contentsOf: fixturesURL)
    }

    @discardableResult
    static func writeImage(
        to url: URL,
        format: UTType = .png,
        width: Int = 2,
        height: Int = 2,
        frameCount: Int = 1
    ) throws -> URL {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestSupportError.cannotCreateImage
        }
        guard let destination = CGImageDestinationCreateWithURL(
                  url as CFURL,
                  format.identifier as CFString,
                  frameCount,
                  nil
              ) else {
            throw TestSupportError.cannotCreateImage
        }

        if format == .gif {
            CGImageDestinationSetProperties(
                destination,
                [
                    kCGImagePropertyGIFDictionary: [
                        kCGImagePropertyGIFLoopCount: 0
                    ]
                ] as CFDictionary
            )
        }
        for frameIndex in 0..<frameCount {
            let progress = CGFloat(frameIndex + 1) / CGFloat(frameCount + 1)
            context.setFillColor(
                CGColor(
                    red: 0.15 + progress * 0.5,
                    green: 0.65 - progress * 0.4,
                    blue: 0.35,
                    alpha: 1
                )
            )
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            guard let image = context.makeImage() else {
                throw TestSupportError.cannotCreateImage
            }
            let properties: [CFString: Any] = format == .gif
                ? [
                    kCGImagePropertyGIFDictionary: [
                        kCGImagePropertyGIFDelayTime: 0.1
                    ]
                ]
                : [:]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw TestSupportError.cannotCreateImage
        }
        return url
    }

    @discardableResult
    static func writeTinyWebP(to url: URL) throws -> URL {
        let base64 = "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADMDOJaQAA3AA/v89WAAAAA=="
        guard let data = Data(base64Encoded: base64) else {
            throw TestSupportError.cannotCreateImage
        }
        try data.write(to: url)
        return url
    }
}

enum TestSupportError: Error {
    case cannotCreateImage
}

struct TestZipBuilder {
    struct Entry {
        var path: String
        var data: Data
        var unixMode: UInt16 = 0o100600
        var declaredCompressedSize: UInt32?
        var declaredUncompressedSize: UInt32?
    }

    static func archive(entries: [Entry], trailingData: Data = Data()) -> Data {
        struct CentralRecord {
            let entry: Entry
            let nameData: Data
            let checksum: UInt32
            let localOffset: UInt32
            let compressedSize: UInt32
            let uncompressedSize: UInt32
        }

        var archive = Data()
        var centralRecords: [CentralRecord] = []
        for entry in entries {
            let nameData = Data(entry.path.utf8)
            let checksum = crc32(entry.data)
            let compressedSize = entry.declaredCompressedSize ?? UInt32(entry.data.count)
            let uncompressedSize = entry.declaredUncompressedSize ?? UInt32(entry.data.count)
            let localOffset = UInt32(archive.count)

            archive.appendLittleEndian(UInt32(0x0403_4B50))
            archive.appendLittleEndian(UInt16(20))
            archive.appendLittleEndian(UInt16(0x0800))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(checksum)
            archive.appendLittleEndian(compressedSize)
            archive.appendLittleEndian(uncompressedSize)
            archive.appendLittleEndian(UInt16(nameData.count))
            archive.appendLittleEndian(UInt16(0))
            archive.append(nameData)
            archive.append(contentsOf: entry.data.prefix(Int(compressedSize)))
            centralRecords.append(
                CentralRecord(
                    entry: entry,
                    nameData: nameData,
                    checksum: checksum,
                    localOffset: localOffset,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize
                )
            )
        }

        let centralOffset = UInt32(archive.count)
        for record in centralRecords {
            archive.appendLittleEndian(UInt32(0x0201_4B50))
            archive.appendLittleEndian(UInt16(0x0314))
            archive.appendLittleEndian(UInt16(20))
            archive.appendLittleEndian(UInt16(0x0800))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(record.checksum)
            archive.appendLittleEndian(record.compressedSize)
            archive.appendLittleEndian(record.uncompressedSize)
            archive.appendLittleEndian(UInt16(record.nameData.count))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt32(record.entry.unixMode) << 16)
            archive.appendLittleEndian(record.localOffset)
            archive.append(record.nameData)
        }
        let centralSize = UInt32(archive.count) - centralOffset

        archive.appendLittleEndian(UInt32(0x0605_4B50))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt16(entries.count))
        archive.appendLittleEndian(UInt16(entries.count))
        archive.appendLittleEndian(centralSize)
        archive.appendLittleEndian(centralOffset)
        archive.appendLittleEndian(UInt16(0))
        archive.append(trailingData)
        return archive
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = 0 &- (crc & 1)
                crc = (crc >> 1) ^ (0xEDB8_8320 & mask)
            }
        }
        return ~crc
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
