import Foundation

enum ApplicationPathsError: Error, Equatable, LocalizedError {
    case applicationSupportUnavailable
    case cachesUnavailable

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            "The Application Support directory is unavailable."
        case .cachesUnavailable:
            "The user cache directory is unavailable."
        }
    }
}

struct ApplicationPaths: Equatable, Sendable {
    let applicationSupportRoot: URL
    let libraryRoot: URL
    let usageFile: URL
    let importStagingRoot: URL
    let cachesRoot: URL

    init(applicationSupportBase: URL, cachesBase: URL) {
        applicationSupportRoot = applicationSupportBase
            .appendingPathComponent("MojiPond", isDirectory: true)
        libraryRoot = applicationSupportRoot
            .appendingPathComponent("Library", isDirectory: true)
        usageFile = applicationSupportRoot
            .appendingPathComponent("usage.json", isDirectory: false)
        importStagingRoot = applicationSupportRoot
            .appendingPathComponent("Import Staging", isDirectory: true)

        cachesRoot = cachesBase
            .appendingPathComponent("MojiPond", isDirectory: true)
    }

    static func live(
        fileManager: FileManager = .default
    ) throws -> ApplicationPaths {
        guard let applicationSupportBase = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ApplicationPathsError.applicationSupportUnavailable
        }
        guard let cachesBase = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            throw ApplicationPathsError.cachesUnavailable
        }
        return ApplicationPaths(
            applicationSupportBase: applicationSupportBase,
            cachesBase: cachesBase
        )
    }
}
