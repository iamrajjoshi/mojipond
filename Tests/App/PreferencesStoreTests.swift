import XCTest
@testable import MojiPond

final class PreferencesStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "PreferencesStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testRoundTripsSinglePreferenceDocument() {
        let store = makeStore()
        var expected = MojiPondPreferences.defaults
        expected.shortcode.trigger = .semicolon
        expected.shortcode.showsSuggestionsOnBareTrigger = true
        expected.shortcode.parserTimeout = 12
        expected.network.allowsCrashReports = false
        expected.exclusions.domains = [
            DomainExclusion(domain: "example.com")!
        ]

        store.save(expected)

        XCTAssertEqual(store.load(), expected)
    }

    func testMigratesLegacyKeysWhenDocumentIsAbsent() {
        defaults.set(false, forKey: "app.isEnabled")
        defaults.set("#", forKey: "shortcuts.trigger")
        defaults.set(false, forKey: "shortcuts.acceptTab")

        let migrated = makeStore().load()

        XCTAssertEqual(migrated.activationMode, .paused)
        XCTAssertEqual(migrated.shortcode.trigger, .hash)
        XCTAssertFalse(migrated.shortcode.acceptsTab)
        XCTAssertTrue(migrated.network.allowsCrashReports)
        XCTAssertEqual(
            migrated.exclusions,
            ExclusionPreferences.defaults
        )
    }

    func testInvalidOrFutureDocumentFailsClosedToDefaults() throws {
        var future = MojiPondPreferences.defaults
        future.schemaVersion = MojiPondPreferences.currentSchemaVersion + 1
        defaults.set(try JSONEncoder().encode(future), forKey: UserDefaultsPreferencesStore.storageKey)

        XCTAssertEqual(
            makeStore().load(),
            .defaults
        )
    }

    func testVersionOneDocumentDropsRemovedNetworkPreferences() throws {
        var document = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(MojiPondPreferences.defaults)
            ) as? [String: Any]
        )
        document["schemaVersion"] = 1
        var network = try XCTUnwrap(
            document["network"] as? [String: Any]
        )
        network["allowsGitHubImports"] = true
        network["allowsGIFSearch"] = true
        document["network"] = network
        defaults.set(
            try JSONSerialization.data(withJSONObject: document),
            forKey: UserDefaultsPreferencesStore.storageKey
        )

        let migrated = makeStore().load()

        XCTAssertEqual(
            migrated.schemaVersion,
            MojiPondPreferences.currentSchemaVersion
        )
        let persisted = try XCTUnwrap(
            defaults.data(
                forKey: UserDefaultsPreferencesStore.storageKey
            )
        )
        let persistedText = try XCTUnwrap(
            String(data: persisted, encoding: .utf8)
        )
        XCTAssertFalse(persistedText.contains("allowsGitHubImports"))
        XCTAssertFalse(persistedText.contains("allowsGIFSearch"))
    }

    func testVersionTwoDocumentMigratesTimeoutToPersistentDefault() throws {
        var stored = MojiPondPreferences.defaults
        stored.schemaVersion = 2
        stored.shortcode.parserTimeout = 3
        defaults.set(
            try JSONEncoder().encode(stored),
            forKey: UserDefaultsPreferencesStore.storageKey
        )

        let migrated = makeStore().load()

        XCTAssertEqual(
            migrated.schemaVersion,
            MojiPondPreferences.currentSchemaVersion
        )
        XCTAssertEqual(migrated.shortcode.parserTimeout, 0)
        let persistedData = try XCTUnwrap(
            defaults.data(forKey: UserDefaultsPreferencesStore.storageKey)
        )
        let persisted = try JSONDecoder().decode(
            MojiPondPreferences.self,
            from: persistedData
        )
        XCTAssertEqual(persisted, migrated)
    }

    func testLegacyGiphyDataCleanupRemovesDefaultsAndCredential() {
        let cleaner = LegacyProviderCredentialCleanerSpy()
        let store = makeStore(legacyCredentialCleaner: cleaner)
        defaults.set(
            "legacy-customer",
            forKey:
                "com.rajjoshi.MojiPond.giphyCustomerIdentifier"
        )
        defaults.set(true, forKey: "media.giphyEnabled")

        _ = store.load()

        XCTAssertEqual(cleaner.removeCallCount, 1)
        XCTAssertNil(
            defaults.object(
                forKey:
                    "com.rajjoshi.MojiPond.giphyCustomerIdentifier"
            )
        )
        XCTAssertNil(defaults.object(forKey: "media.giphyEnabled"))
        XCTAssertTrue(
            defaults.bool(
                forKey:
                    UserDefaultsPreferencesStore
                        .legacyGiphyDataCleanupKey
            )
        )
    }

    func testLegacyGiphyDataCleanupRemovesDefaultsAndRetriesCredentialAfterFailure() {
        let cleaner = LegacyProviderCredentialCleanerSpy(
            error:
                LegacyProviderCredentialCleanupError(
                    status: -1
                )
        )
        let store = makeStore(legacyCredentialCleaner: cleaner)
        defaults.set(
            "legacy-customer",
            forKey:
                "com.rajjoshi.MojiPond.giphyCustomerIdentifier"
        )
        defaults.set(true, forKey: "media.giphyEnabled")

        _ = store.load()

        XCTAssertEqual(cleaner.removeCallCount, 1)
        XCTAssertNil(
            defaults.object(
                forKey:
                    "com.rajjoshi.MojiPond.giphyCustomerIdentifier"
            )
        )
        XCTAssertNil(defaults.object(forKey: "media.giphyEnabled"))
        XCTAssertFalse(
            defaults.bool(
                forKey:
                    UserDefaultsPreferencesStore
                        .legacyGiphyDataCleanupKey
            )
        )

        cleaner.error = nil
        _ = store.load()

        XCTAssertEqual(cleaner.removeCallCount, 2)
        XCTAssertTrue(
            defaults.bool(
                forKey:
                    UserDefaultsPreferencesStore
                        .legacyGiphyDataCleanupKey
            )
        )
    }

    func testLegacyGiphyDataCleanupRunsWhenOldCredentialMarkerExists() {
        let cleaner = LegacyProviderCredentialCleanerSpy()
        let store = makeStore(legacyCredentialCleaner: cleaner)
        defaults.set(
            true,
            forKey:
                UserDefaultsPreferencesStore
                    .legacyCredentialCleanupKey
        )
        defaults.set(
            "legacy-customer",
            forKey:
                "com.rajjoshi.MojiPond.giphyCustomerIdentifier"
        )
        defaults.set(true, forKey: "media.giphyEnabled")

        _ = store.load()

        XCTAssertEqual(cleaner.removeCallCount, 1)
        XCTAssertNil(
            defaults.object(
                forKey:
                    "com.rajjoshi.MojiPond.giphyCustomerIdentifier"
            )
        )
        XCTAssertNil(defaults.object(forKey: "media.giphyEnabled"))
        XCTAssertTrue(
            defaults.bool(
                forKey:
                    UserDefaultsPreferencesStore
                        .legacyGiphyDataCleanupKey
            )
        )
    }

    func testLegacyGiphyDataCleanupIsIdempotentAfterSuccess() {
        let cleaner = LegacyProviderCredentialCleanerSpy()
        let store = makeStore(legacyCredentialCleaner: cleaner)

        _ = store.load()
        _ = store.load()

        XCTAssertEqual(cleaner.removeCallCount, 1)
        XCTAssertTrue(
            defaults.bool(
                forKey:
                    UserDefaultsPreferencesStore
                        .legacyGiphyDataCleanupKey
            )
        )
    }

    private func makeStore(
        legacyCredentialCleaner:
            any LegacyProviderCredentialCleaning =
                NoopLegacyProviderCredentialCleaner()
    ) -> UserDefaultsPreferencesStore {
        UserDefaultsPreferencesStore(
            defaults: defaults,
            legacyCredentialCleaner: legacyCredentialCleaner
        )
    }
}

private struct NoopLegacyProviderCredentialCleaner:
    LegacyProviderCredentialCleaning
{
    func removeLegacyCredential() throws {}
}

private final class LegacyProviderCredentialCleanerSpy:
    LegacyProviderCredentialCleaning
{
    var error: Error?
    private(set) var removeCallCount = 0

    init(error: Error? = nil) {
        self.error = error
    }

    func removeLegacyCredential() throws {
        removeCallCount += 1
        if let error {
            throw error
        }
    }
}
