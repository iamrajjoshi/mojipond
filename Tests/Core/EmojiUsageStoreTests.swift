import XCTest
@testable import MojiPond

final class EmojiUsageStoreTests: XCTestCase {
    func testInMemoryStoreTracksCountsRecentsToneFavoritesAndAliases() async throws {
        let store = InMemoryEmojiUsageStore(recentLimit: 2)
        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = Date(timeIntervalSince1970: 200)

        try await store.recordUse(itemID: "wave", skinTone: .medium, at: firstDate)
        try await store.recordUse(itemID: "party", skinTone: nil, at: secondDate)
        try await store.recordUse(itemID: "wave", skinTone: .dark, at: secondDate)
        try await store.setFavorite(true, itemID: "wave")
        try await store.setCustomAliases(
            ["HELLO", "hello", "not valid", "+1"],
            itemID: "wave"
        )

        let snapshot = try await store.snapshot()
        let statistics = snapshot.statistics(for: "wave")
        XCTAssertEqual(statistics.useCount, 2)
        XCTAssertEqual(statistics.skinToneUseCounts[.medium], 1)
        XCTAssertEqual(statistics.skinToneUseCounts[.dark], 1)
        XCTAssertEqual(statistics.lastUsedSkinTone, .dark)
        XCTAssertEqual(snapshot.preferredSkinToneByItemID["wave"], .dark)
        XCTAssertEqual(snapshot.recents.map(\.itemID), ["party", "wave"])
        XCTAssertTrue(snapshot.isFavorite("wave"))
        XCTAssertEqual(snapshot.customAliasesByItemID["wave"], ["hello", "+1"])
    }

    func testResetUsageRankingPreservesFavoritesAndCustomAliases() async throws {
        let store = InMemoryEmojiUsageStore()
        try await store.recordUse(itemID: "wave", skinTone: .medium, at: Date())
        try await store.setFavorite(true, itemID: "wave")
        try await store.setCustomAliases(["hello"], itemID: "wave")

        try await store.resetUsageRanking()
        let snapshot = try await store.snapshot()

        XCTAssertTrue(snapshot.statisticsByItemID.isEmpty)
        XCTAssertTrue(snapshot.recents.isEmpty)
        XCTAssertTrue(snapshot.preferredSkinToneByItemID.isEmpty)
        XCTAssertTrue(snapshot.isFavorite("wave"))
        XCTAssertEqual(snapshot.customAliasesByItemID["wave"], ["hello"])
    }

    func testFileStorePersistsEveryMutationAndCanBeReopened() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MojiPondUsageTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("usage.json")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let firstStore = try FileEmojiUsageStore(fileURL: fileURL)
        let usedAt = Date(timeIntervalSince1970: 123.456)
        try await firstStore.recordUse(itemID: "wave", skinTone: .mediumDark, at: usedAt)
        try await firstStore.setFavorite(true, itemID: "wave")
        try await firstStore.setCustomAliases(["ocean"], itemID: "wave")

        let secondStore = try FileEmojiUsageStore(fileURL: fileURL)
        let snapshot = try await secondStore.snapshot()

        XCTAssertEqual(snapshot.statistics(for: "wave").useCount, 1)
        XCTAssertEqual(snapshot.statistics(for: "wave").lastUsedAt, usedAt)
        XCTAssertEqual(snapshot.preferredSkinToneByItemID["wave"], .mediumDark)
        XCTAssertTrue(snapshot.isFavorite("wave"))
        XCTAssertEqual(snapshot.customAliasesByItemID["wave"], ["ocean"])
    }

    func testFileStoreRejectsFutureSchema() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MojiPondUsageSchemaTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("usage.json")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let future = EmojiUsageSnapshot(schemaVersion: 999)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(future).write(to: fileURL)

        XCTAssertThrowsError(try FileEmojiUsageStore(fileURL: fileURL)) { error in
            XCTAssertEqual(
                error as? FileEmojiUsageStoreError,
                .unsupportedSchema(
                    found: 999,
                    latest: EmojiUsageSnapshot.currentSchemaVersion
                )
            )
        }
    }

    func testFileStoreMigratesOlderSchemaAndAtomicallyPersistsCurrentVersion() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MojiPondUsageMigrationTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("usage.json")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = EmojiUsageSnapshot(
            schemaVersion: 0,
            favoriteItemIDs: ["wave"]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(legacy).write(to: fileURL)

        let store = try FileEmojiUsageStore(fileURL: fileURL)
        let snapshot = try await store.snapshot()

        XCTAssertEqual(snapshot.schemaVersion, EmojiUsageSnapshot.currentSchemaVersion)
        XCTAssertTrue(snapshot.isFavorite("wave"))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let persisted = try decoder.decode(
            EmojiUsageSnapshot.self,
            from: Data(contentsOf: fileURL)
        )
        XCTAssertEqual(persisted.schemaVersion, EmojiUsageSnapshot.currentSchemaVersion)
    }
}
