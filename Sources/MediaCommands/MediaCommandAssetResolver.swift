import CryptoKit
import Foundation

protocol MediaCommandRemoteDownloading: Sendable {
    func downloadOriginal(_ item: RemoteMediaItem) async throws -> MediaCommandDownload
}

extension RemoteMediaDownloader: MediaCommandRemoteDownloading {
    func downloadOriginal(_ item: RemoteMediaItem) async throws -> MediaCommandDownload {
        let download = try await download(item)
        return MediaCommandDownload(
            data: download.data,
            contentType: download.contentType,
            suggestedFilename: download.suggestedFilename
        )
    }
}

struct MediaCommandAssetResolver: Sendable {
    let remoteDownloader: any MediaCommandRemoteDownloading

    init(
        remoteDownloader: any MediaCommandRemoteDownloading =
            RemoteMediaDownloader()
    ) {
        self.remoteDownloader = remoteDownloader
    }

    func resolve(_ result: MediaCommandResult) async throws -> MediaCommandDownload {
        switch result.origin {
        case let .bundled(asset):
            let data: Data
            do {
                data = try Data(
                    contentsOf: asset.fileURL,
                    options: [.mappedIfSafe]
                )
            } catch {
                throw NotoOfflineCatalogError.assetUnreadable(
                    asset.fileURL.lastPathComponent
                )
            }
            guard
                data.count == asset.expectedByteCount,
                Self.sha256(data) == asset.expectedSHA256
            else {
                throw NotoOfflineCatalogError.assetCorrupt(
                    asset.fileURL.lastPathComponent
                )
            }
            return MediaCommandDownload(
                data: data,
                contentType: "image/gif",
                suggestedFilename: asset.fileURL.lastPathComponent
            )
        case .remote:
            // The downloader returns the provider's original bytes untouched.
            return try await remoteDownloader.downloadOriginal(result.media)
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
