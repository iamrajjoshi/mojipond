import XCTest
@testable import MojiPond

final class MojiPondPreferencesTests: XCTestCase {
    func testDefaultsAreLocalFirstAndUseFrozenAutocompleteBehavior() {
        let preferences = MojiPondPreferences.defaults

        XCTAssertEqual(preferences.activationMode, .enabled)
        XCTAssertFalse(preferences.launchAtLogin)
        XCTAssertEqual(preferences.shortcode.trigger, .colon)
        XCTAssertTrue(preferences.shortcode.acceptsTab)
        XCTAssertTrue(preferences.shortcode.acceptsReturn)
        XCTAssertFalse(preferences.shortcode.showsSuggestionsOnBareTrigger)
        XCTAssertTrue(preferences.shortcode.replacesOnExactClosingTrigger)
        XCTAssertTrue(preferences.shortcode.opensBrowserOnDoubleTrigger)
        XCTAssertEqual(preferences.shortcode.parserTimeout, 0)
        XCTAssertNil(preferences.defaultSkinTone)
        XCTAssertFalse(preferences.network.allowsStickerSearch)
        XCTAssertFalse(preferences.network.allowsUpdateChecks)
        XCTAssertTrue(preferences.network.allowsCrashReports)
    }

    func testDefaultExclusionsCoverSelfSensitiveAppsTerminalsRemoteToolsAndChat() {
        let exclusions = ExclusionPreferences.defaults
        let expectedBundleIdentifiers = [
            "com.rajjoshi.MojiPond",
            "com.1password.1password",
            "com.apple.Terminal",
            "com.parallels.desktop.console",
            "com.tinyspeck.slackmacgap",
            "com.hnc.Discord"
        ]

        for bundleIdentifier in expectedBundleIdentifiers {
            XCTAssertNotNil(
                exclusions.match(bundleIdentifier: bundleIdentifier, domain: nil),
                "Expected default exclusion for \(bundleIdentifier)"
            )
        }
        XCTAssertNil(
            exclusions.match(bundleIdentifier: "com.apple.MobileSMS", domain: nil)
        )
    }

    func testApplicationExclusionsPartitionProtectedAppsFromDedupedUserApps() {
        let userApplication = ApplicationExclusion(
            bundleIdentifier: "com.example.Editor",
            displayName: "Editor"
        )
        let exclusions = ExclusionPreferences(
            applications: [
                userApplication,
                userApplication,
                ApplicationExclusion(
                    bundleIdentifier: "com.apple.Terminal",
                    displayName: "Renamed Terminal"
                )
            ]
        )

        XCTAssertEqual(exclusions.applications.count, 2)
        XCTAssertEqual(exclusions.userApplications, [userApplication])
        XCTAssertTrue(
            ExclusionPreferences.isProtectedApplication(
                bundleIdentifier: "COM.APPLE.TERMINAL"
            )
        )
        XCTAssertEqual(
            exclusions.effectiveApplications.filter {
                $0.matches(bundleIdentifier: "com.apple.Terminal")
            }.count,
            1
        )
        XCTAssertTrue(exclusions.effectiveApplications.contains(userApplication))
    }

    func testDomainExclusionMatchesExactAndLabelBoundedSubdomains() throws {
        let exclusion = try XCTUnwrap(
            DomainExclusion(domain: "Example.COM.", includesSubdomains: true)
        )

        XCTAssertEqual(exclusion.domain, "example.com")
        XCTAssertTrue(exclusion.matches(host: "example.com"))
        XCTAssertTrue(exclusion.matches(host: "chat.example.com"))
        XCTAssertFalse(exclusion.matches(host: "notexample.com"))
        XCTAssertFalse(exclusion.matches(host: "example.com.evil.test"))
    }

    func testExactOnlyDomainDoesNotMatchSubdomainsAndRejectsMalformedHosts() throws {
        let exclusion = try XCTUnwrap(
            DomainExclusion(domain: "example.com", includesSubdomains: false)
        )

        XCTAssertTrue(exclusion.matches(host: "example.com"))
        XCTAssertFalse(exclusion.matches(host: "chat.example.com"))
        XCTAssertNil(DomainExclusion(domain: "https://example.com"))
        XCTAssertNil(DomainExclusion(domain: "-bad.example"))
        XCTAssertNil(DomainExclusion(domain: "bad..example"))
    }

    func testEveryDocumentedTriggerRoundTripsThroughPreferences() throws {
        XCTAssertEqual(
            Set(ShortcodeTrigger.allCases.map(\.rawValue)),
            Set([":", ";", "/", "\\", "@", "#", "~", "|"])
        )

        for trigger in ShortcodeTrigger.allCases {
            let preferences = MojiPondPreferences(
                shortcode: ShortcodePreferences(trigger: trigger)
            )
            let data = try JSONEncoder().encode(preferences)
            let decoded = try JSONDecoder().decode(MojiPondPreferences.self, from: data)
            XCTAssertEqual(decoded, preferences)
            XCTAssertEqual(ShortcodeTrigger(character: trigger.character), trigger)
        }
    }

    func testLegacyNetworkPreferencesDefaultCrashReportsOn() throws {
        let data = Data(
            #"{"allowsStickerSearch":true,"allowsUpdateChecks":false}"#
                .utf8
        )

        let preferences = try JSONDecoder().decode(
            NetworkPreferences.self,
            from: data
        )

        XCTAssertTrue(preferences.allowsStickerSearch)
        XCTAssertFalse(preferences.allowsUpdateChecks)
        XCTAssertTrue(preferences.allowsCrashReports)
    }

    func testPositiveTimeoutAndParserMaximumAreBounded() {
        XCTAssertEqual(ShortcodePreferences(parserTimeout: 0).parserTimeout, 0)
        XCTAssertEqual(
            ShortcodePreferences(parserTimeout: 0.01).parserTimeout,
            0.1
        )
        XCTAssertEqual(ShortcodePreferences(parserTimeout: 2).parserTimeout, 2)
        XCTAssertEqual(
            ShortcodeParserConfiguration(maximumTokenLength: 10_000).maximumTokenLength,
            Shortcode.maximumLength
        )
        XCTAssertEqual(
            ShortcodeParserConfiguration(maximumTokenLength: 0).maximumTokenLength,
            1
        )
    }
}
