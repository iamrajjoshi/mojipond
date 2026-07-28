import Foundation

struct EmojiUsageStatistics: Codable, Equatable, Sendable {
    var useCount: Int
    var lastUsedAt: Date?
    var skinToneUseCounts: [EmojiSkinTone: Int]
    var lastUsedSkinTone: EmojiSkinTone?

    init(
        useCount: Int = 0,
        lastUsedAt: Date? = nil,
        skinToneUseCounts: [EmojiSkinTone: Int] = [:],
        lastUsedSkinTone: EmojiSkinTone? = nil
    ) {
        self.useCount = useCount
        self.lastUsedAt = lastUsedAt
        self.skinToneUseCounts = skinToneUseCounts
        self.lastUsedSkinTone = lastUsedSkinTone
    }
}

struct RecentEmojiUse: Codable, Equatable, Sendable {
    let itemID: EmojiItem.ID
    let usedAt: Date
    let skinTone: EmojiSkinTone?
}

struct EmojiUsageSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var statisticsByItemID: [EmojiItem.ID: EmojiUsageStatistics]
    var recents: [RecentEmojiUse]
    var favoriteItemIDs: [EmojiItem.ID]
    var customAliasesByItemID: [EmojiItem.ID: [String]]
    var preferredSkinToneByItemID: [EmojiItem.ID: EmojiSkinTone]

    init(
        schemaVersion: Int = currentSchemaVersion,
        statisticsByItemID: [EmojiItem.ID: EmojiUsageStatistics] = [:],
        recents: [RecentEmojiUse] = [],
        favoriteItemIDs: [EmojiItem.ID] = [],
        customAliasesByItemID: [EmojiItem.ID: [String]] = [:],
        preferredSkinToneByItemID: [EmojiItem.ID: EmojiSkinTone] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.statisticsByItemID = statisticsByItemID
        self.recents = recents
        self.favoriteItemIDs = Self.unique(favoriteItemIDs)
        self.customAliasesByItemID = customAliasesByItemID
        self.preferredSkinToneByItemID = preferredSkinToneByItemID
    }

    func statistics(for itemID: EmojiItem.ID) -> EmojiUsageStatistics {
        statisticsByItemID[itemID] ?? EmojiUsageStatistics()
    }

    func isFavorite(_ itemID: EmojiItem.ID) -> Bool {
        favoriteItemIDs.contains(itemID)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

protocol EmojiUsageStore: Sendable {
    func snapshot() async throws -> EmojiUsageSnapshot
    func recordUse(
        itemID: EmojiItem.ID,
        skinTone: EmojiSkinTone?,
        at date: Date
    ) async throws
    func setFavorite(_ isFavorite: Bool, itemID: EmojiItem.ID) async throws
    func setCustomAliases(_ aliases: [String], itemID: EmojiItem.ID) async throws
    func setPreferredSkinTone(_ skinTone: EmojiSkinTone?, itemID: EmojiItem.ID) async throws
    func resetUsageRanking() async throws
}

actor InMemoryEmojiUsageStore: EmojiUsageStore {
    private var state: EmojiUsageSnapshot
    private let recentLimit: Int

    init(
        initialState: EmojiUsageSnapshot = EmojiUsageSnapshot(),
        recentLimit: Int = 100
    ) {
        state = initialState
        self.recentLimit = max(1, recentLimit)
    }

    func snapshot() async throws -> EmojiUsageSnapshot {
        state
    }

    func recordUse(
        itemID: EmojiItem.ID,
        skinTone: EmojiSkinTone?,
        at date: Date
    ) async throws {
        state.recordUse(itemID: itemID, skinTone: skinTone, at: date, recentLimit: recentLimit)
    }

    func setFavorite(_ isFavorite: Bool, itemID: EmojiItem.ID) async throws {
        state.setFavorite(isFavorite, itemID: itemID)
    }

    func setCustomAliases(_ aliases: [String], itemID: EmojiItem.ID) async throws {
        state.setCustomAliases(aliases, itemID: itemID)
    }

    func setPreferredSkinTone(_ skinTone: EmojiSkinTone?, itemID: EmojiItem.ID) async throws {
        state.setPreferredSkinTone(skinTone, itemID: itemID)
    }

    func resetUsageRanking() async throws {
        state.resetUsageRanking()
    }
}

enum FileEmojiUsageStoreError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSchema(found: Int, latest: Int)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(found, latest):
            "Usage data schema \(found) is newer than the supported schema \(latest)."
        }
    }
}

/// A small, actor-isolated JSON store. Every mutation is encoded with sorted
/// keys and atomically replaces the previous file.
actor FileEmojiUsageStore: EmojiUsageStore {
    private let fileURL: URL
    private let recentLimit: Int
    private var state: EmojiUsageSnapshot

    init(
        fileURL: URL,
        recentLimit: Int = 100
    ) throws {
        self.fileURL = fileURL
        self.recentLimit = max(1, recentLimit)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            var decoded = try decoder.decode(EmojiUsageSnapshot.self, from: data)
            guard decoded.schemaVersion <= EmojiUsageSnapshot.currentSchemaVersion else {
                throw FileEmojiUsageStoreError.unsupportedSchema(
                    found: decoded.schemaVersion,
                    latest: EmojiUsageSnapshot.currentSchemaVersion
                )
            }
            if decoded.schemaVersion < EmojiUsageSnapshot.currentSchemaVersion {
                decoded.schemaVersion = EmojiUsageSnapshot.currentSchemaVersion
                try Self.write(decoded, to: fileURL)
            }
            state = decoded
        } else {
            state = EmojiUsageSnapshot()
        }
    }

    func snapshot() async throws -> EmojiUsageSnapshot {
        state
    }

    func recordUse(
        itemID: EmojiItem.ID,
        skinTone: EmojiSkinTone?,
        at date: Date
    ) async throws {
        var candidate = state
        candidate.recordUse(itemID: itemID, skinTone: skinTone, at: date, recentLimit: recentLimit)
        try persist(candidate)
        state = candidate
    }

    func setFavorite(_ isFavorite: Bool, itemID: EmojiItem.ID) async throws {
        var candidate = state
        candidate.setFavorite(isFavorite, itemID: itemID)
        try persist(candidate)
        state = candidate
    }

    func setCustomAliases(_ aliases: [String], itemID: EmojiItem.ID) async throws {
        var candidate = state
        candidate.setCustomAliases(aliases, itemID: itemID)
        try persist(candidate)
        state = candidate
    }

    func setPreferredSkinTone(_ skinTone: EmojiSkinTone?, itemID: EmojiItem.ID) async throws {
        var candidate = state
        candidate.setPreferredSkinTone(skinTone, itemID: itemID)
        try persist(candidate)
        state = candidate
    }

    func resetUsageRanking() async throws {
        var candidate = state
        candidate.resetUsageRanking()
        try persist(candidate)
        state = candidate
    }

    private func persist(_ candidate: EmojiUsageSnapshot) throws {
        try Self.write(candidate, to: fileURL)
    }

    private static func write(_ candidate: EmojiUsageSnapshot, to fileURL: URL) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(candidate)
        try data.write(to: fileURL, options: .atomic)
    }
}

private extension EmojiUsageSnapshot {
    mutating func recordUse(
        itemID: EmojiItem.ID,
        skinTone: EmojiSkinTone?,
        at date: Date,
        recentLimit: Int
    ) {
        var statistics = statisticsByItemID[itemID] ?? EmojiUsageStatistics()
        statistics.useCount += 1
        statistics.lastUsedAt = max(statistics.lastUsedAt ?? .distantPast, date)
        if let skinTone {
            statistics.skinToneUseCounts[skinTone, default: 0] += 1
            statistics.lastUsedSkinTone = skinTone
            preferredSkinToneByItemID[itemID] = skinTone
        }
        statisticsByItemID[itemID] = statistics

        recents.removeAll { $0.itemID == itemID }
        recents.append(RecentEmojiUse(itemID: itemID, usedAt: date, skinTone: skinTone))
        recents.sort {
            if $0.usedAt != $1.usedAt {
                return $0.usedAt > $1.usedAt
            }
            return $0.itemID < $1.itemID
        }
        if recents.count > recentLimit {
            recents.removeLast(recents.count - recentLimit)
        }
    }

    mutating func setFavorite(_ isFavorite: Bool, itemID: EmojiItem.ID) {
        favoriteItemIDs.removeAll { $0 == itemID }
        if isFavorite {
            favoriteItemIDs.append(itemID)
        }
    }

    mutating func setCustomAliases(_ aliases: [String], itemID: EmojiItem.ID) {
        var seen = Set<String>()
        let normalized = aliases.compactMap { alias -> String? in
            let value = EmojiAliasSyntax.normalizedToken(alias)
            guard EmojiAliasSyntax.isValidToken(value), seen.insert(value).inserted else {
                return nil
            }
            return value
        }
        if normalized.isEmpty {
            customAliasesByItemID.removeValue(forKey: itemID)
        } else {
            customAliasesByItemID[itemID] = normalized
        }
    }

    mutating func setPreferredSkinTone(_ skinTone: EmojiSkinTone?, itemID: EmojiItem.ID) {
        if let skinTone {
            preferredSkinToneByItemID[itemID] = skinTone
        } else {
            preferredSkinToneByItemID.removeValue(forKey: itemID)
        }
    }

    mutating func resetUsageRanking() {
        statisticsByItemID.removeAll()
        recents.removeAll()
        preferredSkinToneByItemID.removeAll()
    }
}
