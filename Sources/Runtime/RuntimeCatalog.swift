import Foundation

enum RuntimeCatalogError: Error, Equatable, LocalizedError, Sendable {
    case builtInDatasetMissing
    case builtInDatasetUnreadable

    var errorDescription: String? {
        switch self {
        case .builtInDatasetMissing:
            "The bundled gemoji dataset is missing."
        case .builtInDatasetUnreadable:
            "The bundled gemoji dataset could not be read."
        }
    }
}

protocol RuntimeCatalogDataProviding: Sendable {
    func gemojiData() throws -> Data
}

struct BundleRuntimeCatalogDataProvider: RuntimeCatalogDataProviding, @unchecked Sendable {
    let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    func gemojiData() throws -> Data {
        guard let url = resourceURL else {
            throw RuntimeCatalogError.builtInDatasetMissing
        }
        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw RuntimeCatalogError.builtInDatasetUnreadable
        }
    }

    private var resourceURL: URL? {
        if let url = bundle.url(
            forResource: "gemoji",
            withExtension: "json",
            subdirectory: "Data"
        ) {
            return url
        }
        if let url = bundle.url(
            forResource: "gemoji",
            withExtension: "json"
        ) {
            return url
        }
        guard let resources = bundle.resourceURL else {
            return nil
        }
        let nested = resources
            .appendingPathComponent("Data", isDirectory: true)
            .appendingPathComponent("gemoji.json", isDirectory: false)
        return FileManager.default.fileExists(atPath: nested.path)
            ? nested
            : nil
    }
}

struct BuiltInRuntimeCatalogLoader: Sendable {
    let dataProvider: any RuntimeCatalogDataProviding
    let decoder: GemojiDatasetDecoder

    init(
        dataProvider: any RuntimeCatalogDataProviding =
            BundleRuntimeCatalogDataProvider(),
        decoder: GemojiDatasetDecoder = GemojiDatasetDecoder()
    ) {
        self.dataProvider = dataProvider
        self.decoder = decoder
    }

    func loadPack() throws -> EmojiCatalogPack {
        try decoder.decode(dataProvider.gemojiData())
    }

    func loadSearchIndex() throws -> EmojiSearchIndex {
        try EmojiSearchIndex(packs: [loadPack()])
    }
}
