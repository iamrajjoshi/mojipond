import Foundation

actor RemoteMediaDownloader {
    private let responseLoader: BoundedHTTPSResponseLoader
    private let maximumBytes: Int

    init(session: URLSession = .shared, maximumBytes: Int = 25 * 1_024 * 1_024) {
        responseLoader = BoundedHTTPSResponseLoader(session: session)
        self.maximumBytes = maximumBytes
    }

    func download(_ item: RemoteMediaItem) async throws -> MediaDownload {
        guard RemoteMediaURLPolicy.allows(
            item.originalURL,
            for: item.provider
        ) else {
            throw RemoteMediaError.insecureURL
        }

        let loaded: BoundedHTTPResponse
        do {
            loaded = try await responseLoader.load(
                URLRequest(url: item.originalURL),
                maximumBytes: maximumBytes,
                redirectPolicy: .sameHost
            )
        } catch let error as BoundedHTTPSLoadError {
            switch error {
            case .responseTooLarge:
                throw RemoteMediaError.responseTooLarge(limit: maximumBytes)
            case .insecureRequestURL, .insecureRedirectURL, .disallowedRedirectHost:
                throw RemoteMediaError.insecureURL
            case .invalidResponse:
                throw RemoteMediaError.invalidResponse
            }
        }
        let data = loaded.data
        let response = loaded.response
        guard (200..<300).contains(response.statusCode) else {
            throw RemoteMediaError.statusCode(response.statusCode)
        }

        let rawContentType = response.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init)
        let contentType = rawContentType?.lowercased()
        let fileExtension: String
        let expectedFormat: AssetFormat
        switch contentType {
        case "image/gif":
            fileExtension = "gif"
            expectedFormat = .gif
        case "image/png":
            fileExtension = "png"
            expectedFormat = .png
        case "image/jpeg":
            fileExtension = "jpg"
            expectedFormat = .jpeg
        case "image/webp":
            fileExtension = "webp"
            expectedFormat = .webP
        default:
            throw RemoteMediaError.unsupportedContentType(contentType)
        }
        var validationLimits = AssetValidationLimits.default
        validationLimits.maximumFileBytes = Int64(maximumBytes)
        do {
            _ = try AssetValidator(limits: validationLimits).validate(
                data: data,
                expectedFormat: expectedFormat
            )
        } catch {
            throw RemoteMediaError.unsafeImage
        }

        let digest = ContentHasher.sha256(
            of: Data(item.originalURL.absoluteString.utf8)
        ).sha256
        return MediaDownload(
            data: data,
            contentType: contentType ?? "application/octet-stream",
            suggestedFilename: "\(digest).\(fileExtension)"
        )
    }
}
