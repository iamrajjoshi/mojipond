import Foundation

enum LibraryScope: Hashable, Identifiable {
    case all
    case favorites
    case aliases
    case builtIn
    case custom
    case pack(UUID)

    var id: String {
        switch self {
        case .all:
            "all"
        case .favorites:
            "favorites"
        case .aliases:
            "aliases"
        case .builtIn:
            "built-in"
        case .custom:
            "custom"
        case let .pack(id):
            "pack-\(id.uuidString)"
        }
    }
}

enum LibraryContentFilter: String, CaseIterable, Identifiable {
    case all
    case unicode
    case images
    case animated

    var id: Self { self }

    var title: String {
        switch self {
        case .all:
            "All Types"
        case .unicode:
            "Unicode"
        case .images:
            "Images"
        case .animated:
            "Animated"
        }
    }
}

enum LibraryLayout: String, CaseIterable, Identifiable {
    case grid
    case list

    var id: Self { self }

    var icon: String {
        switch self {
        case .grid:
            "square.grid.3x3"
        case .list:
            "list.bullet"
        }
    }
}

enum LibraryLoadState: Equatable {
    case idle
    case loading
    case loaded
    case partial(String)
    case failed(String)
}

struct LibraryDisplayItem: Identifiable, Equatable {
    enum Origin: Equatable {
        case builtIn
        case custom(packID: UUID)
    }

    let id: String
    let origin: Origin
    let packName: String
    let packEnabled: Bool
    let shortcode: String
    let aliases: [String]
    let displayName: String
    let tags: [String]
    let category: String
    let unicode: String?
    let assetURL: URL?
    let format: AssetFormat?
    let isAnimated: Bool
    let order: Int

    var accessibilityLabel: String {
        let kind = isAnimated ? "animated emoji" : (assetURL == nil ? "Unicode emoji" : "image emoji")
        return [
            "\(displayName), colon \(shortcode) colon, \(kind), \(packName)",
            packEnabled ? nil : "pack disabled"
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}

struct LibraryImportSession: Identifiable, Equatable {
    let id: UUID
    let preview: ImportPreview
    let duplicateContent: [ImportDuplicateContentGroup]
    let destination: LibraryImportDestination

    init(
        id: UUID = UUID(),
        preview: ImportPreview,
        duplicateContent: [ImportDuplicateContentGroup],
        destination: LibraryImportDestination = .newPack
    ) {
        self.id = id
        self.preview = preview
        self.duplicateContent = duplicateContent
        self.destination = destination
    }

    func sourceURL(for itemID: UUID) -> URL? {
        preview.preparedPack.items.first(
            where: { $0.id == itemID }
        )?.assetSourceURL
    }
}

enum LibraryImportDestination: Equatable, Sendable {
    case newPack
    case replace(packID: UUID)
}

enum LibraryConflictChoice: String, CaseIterable, Identifiable {
    case keepExisting
    case replaceExisting
    case renameIncoming
    case dropIncomingAlias

    var id: Self { self }

    var title: String {
        switch self {
        case .keepExisting:
            "Keep existing"
        case .replaceExisting:
            "Replace existing"
        case .renameIncoming:
            "Rename incoming"
        case .dropIncomingAlias:
            "Drop incoming alias"
        }
    }
}

struct LibraryRemovalTarget: Identifiable, Equatable {
    enum Kind: Equatable {
        case pack(UUID)
        case item(packID: UUID, itemID: UUID)
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let message: String
}

struct LibraryItemDraft: Equatable {
    let packID: UUID
    let itemID: UUID
    var shortcode: String
    var aliases: String
    var displayName: String
    var tags: String
    var category: String

    init(packID: UUID, item: LibraryEmoji) {
        self.packID = packID
        itemID = item.id
        shortcode = item.shortcode.rawValue
        aliases = item.aliases.map(\.rawValue).joined(separator: ", ")
        displayName = item.displayName ?? ""
        tags = item.tags.joined(separator: ", ")
        category = item.category ?? ""
    }
}

struct LibraryNotice: Identifiable, Equatable {
    enum Kind: Equatable {
        case information
        case warning
        case error
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let message: String
}
