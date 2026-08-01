import Foundation

protocol MediaCommandRemoteDownloading: Sendable {
    func downloadOriginal(_ item: RemoteMediaItem) async throws -> MediaDownload
}

extension RemoteMediaDownloader: MediaCommandRemoteDownloading {
    func downloadOriginal(_ item: RemoteMediaItem) async throws -> MediaDownload {
        try await download(item)
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

    func resolve(_ result: MediaCommandResult) async throws -> MediaDownload {
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
                ContentHasher.sha256(of: data).sha256
                    == asset.expectedSHA256
            else {
                throw NotoOfflineCatalogError.assetCorrupt(
                    asset.fileURL.lastPathComponent
                )
            }
            return MediaDownload(
                data: data,
                contentType: "image/gif",
                suggestedFilename: asset.fileURL.lastPathComponent
            )
        case .remote:
            return try await remoteDownloader.downloadOriginal(result.media)
        }
    }

}
