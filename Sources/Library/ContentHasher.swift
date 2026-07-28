import CryptoKit
import Foundation

struct ContentDigest: Codable, Equatable, Sendable {
    let sha256: String
    let byteCount: Int64
}

enum ContentHasher {
    private static let chunkSize = 256 * 1_024

    static func sha256(of data: Data) -> ContentDigest {
        let digest = SHA256.hash(data: data)
        return ContentDigest(
            sha256: digest.map { String(format: "%02x", $0) }.joined(),
            byteCount: Int64(data.count)
        )
    }

    static func sha256(ofFileAt url: URL, maximumBytes: Int64? = nil) throws -> ContentDigest {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ContentHashError.notARegularFile(url)
        }

        if let size = values.fileSize.map(Int64.init), let maximumBytes, size > maximumBytes {
            throw ContentHashError.tooLarge(actual: size, limit: maximumBytes)
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        var total: Int64 = 0
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            total += Int64(chunk.count)
            if let maximumBytes, total > maximumBytes {
                throw ContentHashError.tooLarge(actual: total, limit: maximumBytes)
            }
            hasher.update(data: chunk)
        }

        let digest = hasher.finalize()
        return ContentDigest(
            sha256: digest.map { String(format: "%02x", $0) }.joined(),
            byteCount: total
        )
    }
}

enum ContentHashError: Error, Equatable, LocalizedError, Sendable {
    case notARegularFile(URL)
    case tooLarge(actual: Int64, limit: Int64)

    var errorDescription: String? {
        switch self {
        case let .notARegularFile(url):
            "\(url.lastPathComponent) is not a regular file."
        case let .tooLarge(actual, limit):
            "File is \(actual) bytes, above the \(limit)-byte limit."
        }
    }
}
