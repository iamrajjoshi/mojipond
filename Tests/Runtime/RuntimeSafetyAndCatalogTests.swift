import Foundation
import XCTest
@testable import MojiPond

final class RuntimeSafetyAndCatalogTests: XCTestCase {
    func testSafetyPolicyFailsClosedForEveryUnknownSecurityBoundary() {
        let policy = RuntimeSessionSafetyPolicy()
        let granted = RuntimePermissionPreflight(
            inputMonitoringGranted: true,
            accessibilityGranted: true
        )

        XCTAssertEqual(
            policy.evaluate(
                RuntimeSessionSafetyInput(
                    permissions: RuntimePermissionPreflight(
                        inputMonitoringGranted: false,
                        accessibilityGranted: true
                    ),
                    secureEventInputEnabled: false,
                    focusedElementIsSecure: false,
                    bundleIdentifier: "com.apple.MobileSMS"
                )
            ),
            .permissionUnavailable
        )
        XCTAssertEqual(
            policy.evaluate(
                RuntimeSessionSafetyInput(
                    permissions: granted,
                    secureEventInputEnabled: false,
                    focusedElementIsSecure: nil,
                    bundleIdentifier: "com.apple.MobileSMS"
                )
            ),
            .secureStatusUnknown
        )
        XCTAssertEqual(
            policy.evaluate(
                RuntimeSessionSafetyInput(
                    permissions: granted,
                    secureEventInputEnabled: false,
                    focusedElementIsSecure: false,
                    bundleIdentifier: nil
                )
            ),
            .applicationUnknown
        )
    }

    func testSafetyPolicyHonorsDefaultExclusionsAndAllowsMessages() {
        let policy = RuntimeSessionSafetyPolicy()
        let permissions = RuntimePermissionPreflight(
            inputMonitoringGranted: true,
            accessibilityGranted: true
        )

        XCTAssertEqual(
            policy.evaluate(
                RuntimeSessionSafetyInput(
                    permissions: permissions,
                    secureEventInputEnabled: false,
                    focusedElementIsSecure: false,
                    bundleIdentifier: "com.apple.Terminal"
                )
            ),
            .excludedApplication("com.apple.terminal")
        )
        XCTAssertNil(
            policy.evaluate(
                RuntimeSessionSafetyInput(
                    permissions: permissions,
                    secureEventInputEnabled: false,
                    focusedElementIsSecure: false,
                    bundleIdentifier: "com.apple.MobileSMS"
                )
            )
        )
    }

    func testSafetyPolicyAlwaysBlocksProtectedAppsWhenStoredExclusionsAreEmpty() throws {
        let storedExclusions = Data(
            #"{"applications":[],"domains":[]}"#.utf8
        )
        let policy = RuntimeSessionSafetyPolicy(
            exclusions: try JSONDecoder().decode(
                ExclusionPreferences.self,
                from: storedExclusions
            )
        )
        let permissions = RuntimePermissionPreflight(
            inputMonitoringGranted: true,
            accessibilityGranted: true
        )

        for bundleIdentifier in [
            "com.apple.keychainaccess",
            "com.mitchellh.ghostty",
            "com.apple.ScreenContinuity",
            "com.tinyspeck.chatlyio",
            "com.microsoft.teams2"
        ] {
            XCTAssertEqual(
                policy.evaluate(
                    RuntimeSessionSafetyInput(
                        permissions: permissions,
                        secureEventInputEnabled: false,
                        focusedElementIsSecure: false,
                        bundleIdentifier: bundleIdentifier
                    )
                ),
                .excludedApplication(bundleIdentifier.lowercased())
            )
        }
    }

    func testSafetyPolicyHonorsExactAndSubdomainExclusions() throws {
        let parentDomain = try XCTUnwrap(
            DomainExclusion(
                domain: "example.com",
                includesSubdomains: true
            )
        )
        let exactDomain = try XCTUnwrap(
            DomainExclusion(
                domain: "private.test",
                includesSubdomains: false
            )
        )
        let policy = RuntimeSessionSafetyPolicy(
            exclusions: ExclusionPreferences(
                domains: [parentDomain, exactDomain]
            )
        )
        let permissions = RuntimePermissionPreflight(
            inputMonitoringGranted: true,
            accessibilityGranted: true
        )

        func denial(for domain: String?) -> RuntimeSessionDenial? {
            policy.evaluate(
                RuntimeSessionSafetyInput(
                    permissions: permissions,
                    secureEventInputEnabled: false,
                    focusedElementIsSecure: false,
                    bundleIdentifier: "com.apple.Safari",
                    domain: domain
                )
            )
        }

        XCTAssertEqual(
            denial(for: "chat.example.com"),
            .excludedDomain("example.com")
        )
        XCTAssertEqual(
            denial(for: "private.test"),
            .excludedDomain("private.test")
        )
        XCTAssertNil(denial(for: "sub.private.test"))
        XCTAssertNil(denial(for: nil))
    }

    func testReplacementFactoryRequiresSameProcessAndExactUTF16Range() {
        let originalTarget = AccessibilityTextTarget(
            element: AccessibilityElementReference(rawValue: NSObject()),
            processIdentifier: 42
        )
        let capture = RuntimeTextCapture(
            target: AccessibilityTextTarget(
                element: AccessibilityElementReference(rawValue: NSObject()),
                processIdentifier: 42
            ),
            context: AccessibilityTextContext(
                selection: NSRange(location: 8, length: 0),
                caretBounds: .zero,
                textFragment: "x :frog:",
                textFragmentRange: NSRange(location: 0, length: 8),
                tokenRange: NSRange(location: 2, length: 6)
            )
        )

        let request = RuntimeReplacementRequestFactory.make(
            sessionTarget: originalTarget,
            capture: capture,
            expectedToken: ":frog:"
        )

        XCTAssertEqual(request?.tokenRange, NSRange(location: 2, length: 6))
        XCTAssertEqual(request?.expectedSelection, NSRange(location: 8, length: 0))
        XCTAssertEqual(request?.expectedToken, ":frog:")

        let otherProcessCapture = RuntimeTextCapture(
            target: AccessibilityTextTarget(
                element: AccessibilityElementReference(rawValue: NSObject()),
                processIdentifier: 99
            ),
            context: capture.context
        )
        XCTAssertNil(
            RuntimeReplacementRequestFactory.make(
                sessionTarget: originalTarget,
                capture: otherProcessCapture,
                expectedToken: ":frog:"
            )
        )
    }

    func testRuntimeCaptureCanSafelyAnchorAnEmptyCaretReplacement() throws {
        let system = FakeAccessibilityTextSystem()
        system.text = "draft"
        system.selection = NSRange(
            location: system.text.utf16.count,
            length: 0
        )
        let provider = RuntimeAccessibilityTextContextProvider(
            accessibility: AccessibilityTextAdapter(system: system),
            permissionChecker: GrantedRuntimePermissionChecker(),
            secureInputChecker: InactiveRuntimeSecureInputChecker(),
            applicationIdentity: MessagesRuntimeIdentityProvider()
        )

        let capture = try provider.capture(
            expectedToken: "",
            trigger: ":"
        )
        let request = RuntimeReplacementRequestFactory.make(
            sessionTarget: capture.target,
            capture: capture,
            expectedToken: ""
        )

        XCTAssertEqual(
            capture.context.tokenRange,
            NSRange(location: 5, length: 0)
        )
        XCTAssertEqual(
            request?.expectedSelection,
            NSRange(location: 5, length: 0)
        )
        XCTAssertEqual(request?.expectedToken, "")
    }

    func testRuntimeDiscoveryCapturesTheOpenShortcodeEndingAtTheCaret()
        throws
    {
        let system = FakeAccessibilityTextSystem()
        system.text = "draft :Frog_1"
        system.selection = NSRange(
            location: system.text.utf16.count,
            length: 0
        )
        let provider = makeRuntimeTextContextProvider(system: system)

        let capture = try provider.captureCurrentToken(
            trigger: ":"
        )

        XCTAssertEqual(capture.token, ":Frog_1")
        XCTAssertEqual(
            capture.context.tokenRange,
            NSRange(location: 6, length: 7)
        )
        XCTAssertEqual(
            capture.context.selection,
            NSRange(location: 13, length: 0)
        )
    }

    func testRuntimeDiscoveryAllowsABareOpeningTrigger() throws {
        let system = FakeAccessibilityTextSystem()
        system.text = "draft :"
        system.selection = NSRange(
            location: system.text.utf16.count,
            length: 0
        )
        let provider = makeRuntimeTextContextProvider(system: system)

        let capture = try provider.captureCurrentToken(
            trigger: ":"
        )

        XCTAssertEqual(capture.token, ":")
    }

    func testRuntimeDiscoveryRejectsSelectionsMiddlePositionsAndClosedTokens()
        throws
    {
        let cases: [(text: String, selection: NSRange)] = [
            (
                text: ":frog",
                selection: NSRange(location: 1, length: 3)
            ),
            (
                text: ":frog",
                selection: NSRange(location: 3, length: 0)
            ),
            (
                text: ":frog:",
                selection: NSRange(location: 6, length: 0)
            )
        ]

        for testCase in cases {
            let system = FakeAccessibilityTextSystem()
            system.text = testCase.text
            system.selection = testCase.selection
            let provider = makeRuntimeTextContextProvider(system: system)

            XCTAssertThrowsError(
                try provider.captureCurrentToken(trigger: ":"),
                "Expected discovery to reject \(testCase)"
            ) { error in
                XCTAssertEqual(
                    error as? RuntimeTextCaptureError,
                    .invalidTokenContext
                )
            }
        }
    }

    func testRuntimeDiscoveryRetainsTheExistingSafetyChecks() {
        let system = FakeAccessibilityTextSystem()
        system.text = ":frog"
        system.selection = NSRange(location: 5, length: 0)
        let provider = RuntimeAccessibilityTextContextProvider(
            accessibility: AccessibilityTextAdapter(system: system),
            permissionChecker: CachedRuntimePermissionChecker(),
            secureInputChecker: InactiveRuntimeSecureInputChecker(),
            applicationIdentity: MessagesRuntimeIdentityProvider()
        )

        XCTAssertThrowsError(
            try provider.captureCurrentToken(trigger: ":")
        ) { error in
            XCTAssertEqual(
                error as? RuntimeTextCaptureError,
                .denied(.permissionUnavailable)
            )
        }
    }

    func testCatalogLoaderBuildsExactLocalIndexFromInjectedData() throws {
        let data = Data(
            """
            [
              {
                "emoji": "🐸",
                "description": "frog face",
                "category": "Animals & Nature",
                "aliases": ["frog"],
                "tags": ["pond"],
                "unicode_version": "6.0",
                "skin_tones": false
              }
            ]
            """.utf8
        )
        let loader = BuiltInRuntimeCatalogLoader(
            dataProvider: FixedRuntimeCatalogDataProvider(data: data)
        )

        let result = try loader.loadSearchIndex().exactMatch(for: "frog")

        XCTAssertEqual(result?.item.shortcode.rawValue, "frog")
        guard case let .unicode(content)? = result?.item.content else {
            return XCTFail("Expected Unicode content")
        }
        XCTAssertEqual(content.value, "🐸")
    }

    private func makeRuntimeTextContextProvider(
        system: FakeAccessibilityTextSystem
    ) -> RuntimeAccessibilityTextContextProvider {
        RuntimeAccessibilityTextContextProvider(
            accessibility: AccessibilityTextAdapter(system: system),
            permissionChecker: GrantedRuntimePermissionChecker(),
            secureInputChecker: InactiveRuntimeSecureInputChecker(),
            applicationIdentity: MessagesRuntimeIdentityProvider()
        )
    }
}

private struct FixedRuntimeCatalogDataProvider: RuntimeCatalogDataProviding {
    let data: Data

    func gemojiData() throws -> Data {
        data
    }
}

private struct GrantedRuntimePermissionChecker:
    RuntimePermissionChecking
{
    func currentPermissions() -> RuntimePermissionPreflight {
        RuntimePermissionPreflight(
            inputMonitoringGranted: true,
            accessibilityGranted: true
        )
    }
}

private struct InactiveRuntimeSecureInputChecker:
    RuntimeSecureInputChecking
{
    var secureEventInputEnabled: Bool {
        false
    }
}

private struct MessagesRuntimeIdentityProvider:
    RuntimeApplicationIdentityProviding
{
    func bundleIdentifier(for processIdentifier: pid_t) -> String? {
        _ = processIdentifier
        return "com.apple.MobileSMS"
    }
}
