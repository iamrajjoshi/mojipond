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
        let store = UserDefaultsPreferencesStore(defaults: defaults)
        var expected = MojiPondPreferences.defaults
        expected.shortcode.trigger = .semicolon
        expected.shortcode.showsSuggestionsOnBareTrigger = true
        expected.network.allowsGitHubImports = true
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
        defaults.set(true, forKey: "media.giphyEnabled")

        let migrated = UserDefaultsPreferencesStore(defaults: defaults).load()

        XCTAssertEqual(migrated.activationMode, .paused)
        XCTAssertEqual(migrated.shortcode.trigger, .hash)
        XCTAssertFalse(migrated.shortcode.acceptsTab)
        XCTAssertTrue(migrated.network.allowsGIFSearch)
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
            UserDefaultsPreferencesStore(defaults: defaults).load(),
            .defaults
        )
    }
}
