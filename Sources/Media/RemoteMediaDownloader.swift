import CryptoKit
import Foundation

actor RemoteMediaDownloader {
    struct Download: Sendable {
        let data: Data
        let contentType: String
        let suggestedFilename: String
    }

    private let session: URLSession
    private let maximumBytes: Int

    init(session: URLSession = .shared, maximumBytes: Int = 25 * 1_024 * 1_024) {
        self.session = session
        self.maximumBytes = maximumBytes
    }

    func download(_ item: RemoteMediaItem) async throws -> Download {
        guard item.originalURL.scheme == "https" else {
            throw RemoteMediaError.insecureURL
        }

        let (data, response) = try await session.data(from: item.originalURL)
        guard let response = response as? HTTPURLResponse else {
            throw RemoteMediaError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw RemoteMediaError.statusCode(response.statusCode)
        }
        guard data.count <= maximumBytes else {
            throw RemoteMediaError.responseTooLarge(limit: maximumBytes)
        }

        let rawContentType = response.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init)
        let contentType = rawContentType?.lowercased()
        let fileExtension: String
        switch contentType {
        case "image/gif":
            fileExtension = "gif"
        case "image/png":
            fileExtension = "png"
        case "image/jpeg":
            fileExtension = "jpg"
        case "image/webp":
            fileExtension = "webp"
        default:
            throw RemoteMediaError.unsupportedContentType(contentType)
        }

        let digest = SHA256.hash(data: Data(item.originalURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return Download(
            data: data,
            contentType: contentType ?? "application/octet-stream",
            suggestedFilename: "\(digest).\(fileExtension)"
        )
    }
}
