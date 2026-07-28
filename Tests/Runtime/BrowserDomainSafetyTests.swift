import ApplicationServices
import Foundation
import XCTest
@testable import MojiPond

final class BrowserDomainSafetyTests: XCTestCase {
    func testSafariReadsOnlyItsIdentifiedAddressField() throws {
        let webpageField = BrowserFixtureNode(
            role: kAXTextFieldRole,
            identifier: "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD",
            value: "https://attacker.example"
        )
        let webArea = BrowserFixtureNode(
            role: "AXWebArea",
            children: [webpageField]
        )
        let addressField = BrowserFixtureNode(
            role: kAXTextFieldRole,
            identifier: "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD",
            value: " HTTPS://Chat.Example.COM.:443/thread "
        )
        let root = BrowserFixtureNode(
            role: kAXWindowRole,
            children: [
                webArea,
                BrowserFixtureNode(
                    role: kAXToolbarRole,
                    children: [addressField]
                )
            ]
        )
        let provider = AXBrowserDomainProvider(
            accessibility: BrowserFixtureReader(root: root)
        )

        XCTAssertEqual(
            try provider.host(
                for: "com.apple.Safari",
                processIdentifier: 42
            ),
            "chat.example.com"
        )
    }

    func testChromeFamilyUsesConservativeAddressBarMetadata() throws {
        let ordinaryField = BrowserFixtureNode(
            role: kAXTextFieldRole,
            description: "Search this page",
            value: "https://wrong.example"
        )
        let addressField = BrowserFixtureNode(
            role: kAXTextFieldRole,
            description: "Address and search bar",
            value: "docs.example.com/path"
        )
        let root = BrowserFixtureNode(
            role: kAXWindowRole,
            children: [ordinaryField, addressField]
        )
        let reader = BrowserFixtureReader(root: root)

        for bundleIdentifier in [
            "com.google.Chrome",
            "com.microsoft.edgemac",
            "com.brave.Browser",
            "company.thebrowser.Browser",
            "org.chromium.Chromium"
        ] {
            XCTAssertEqual(
                try AXBrowserDomainProvider(accessibility: reader).host(
                    for: bundleIdentifier,
                    processIdentifier: 7
                ),
                "docs.example.com",
                bundleIdentifier
            )
        }
    }

    func testUnsupportedBrowserAndUnmarkedTextFieldsReturnNoHost() throws {
        let root = BrowserFixtureNode(
            role: kAXWindowRole,
            children: [
                BrowserFixtureNode(
                    role: kAXTextFieldRole,
                    description: "Website",
                    value: "https://private.example"
                )
            ]
        )
        let provider = AXBrowserDomainProvider(
            accessibility: BrowserFixtureReader(root: root)
        )

        XCTAssertNil(
            try provider.host(
                for: "org.mozilla.firefox",
                processIdentifier: 8
            )
        )
        XCTAssertNil(
            try provider.host(
                for: "com.google.Chrome",
                processIdentifier: 8
            )
        )
    }

    func testHostNormalizerAcceptsWebURLsAndRejectsAmbiguousValues() {
        XCTAssertEqual(
            BrowserAddressBarURLNormalizer.host(
                from: "https://Sub.Example.com./inbox?q=1"
            ),
            "sub.example.com"
        )
        XCTAssertEqual(
            BrowserAddressBarURLNormalizer.host(from: "example.com:8443/a"),
            "example.com"
        )
        XCTAssertEqual(
            BrowserAddressBarURLNormalizer.host(from: "localhost:3000/a"),
            "localhost"
        )

        for rejectedValue in [
            "search words",
            "https://user@example.com",
            "chrome://settings",
            "file:///tmp/private",
            "https://exa_mple.com",
            "https://[::1]/",
            "https://example.com/\u{0007}"
        ] {
            XCTAssertNil(
                BrowserAddressBarURLNormalizer.host(from: rejectedValue),
                rejectedValue
            )
        }
    }

    func testContextProviderDeniesAnExcludedParentDomain() throws {
        let textSystem = BrowserDomainTextSystem()
        let provider = RuntimeAccessibilityTextContextProvider(
            accessibility: AccessibilityTextAdapter(system: textSystem),
            permissionChecker: FixedRuntimePermissionChecker(),
            secureInputChecker: FixedRuntimeSecureInputChecker(),
            applicationIdentity: FixedRuntimeApplicationIdentityProvider(
                bundleIdentifier: "com.google.Chrome"
            ),
            browserDomainProvider: FixedBrowserDomainProvider(
                behavior: .host("chat.example.com")
            ),
            exclusions: ExclusionPreferences(
                domains: [
                    try XCTUnwrap(
                        DomainExclusion(
                            domain: "example.com",
                            includesSubdomains: true
                        )
                    )
                ]
            )
        )

        XCTAssertThrowsError(
            try provider.capture(expectedToken: ":frog:", trigger: ":")
        ) { error in
            XCTAssertEqual(
                error as? RuntimeTextCaptureError,
                .denied(.excludedDomain("example.com"))
            )
        }
    }

    func testContextProviderFailsClosedForSupportedBrowserDomainLookupFailure()
        throws
    {
        let textSystem = BrowserDomainTextSystem()
        let provider = RuntimeAccessibilityTextContextProvider(
            accessibility: AccessibilityTextAdapter(system: textSystem),
            permissionChecker: FixedRuntimePermissionChecker(),
            secureInputChecker: FixedRuntimeSecureInputChecker(),
            applicationIdentity: FixedRuntimeApplicationIdentityProvider(
                bundleIdentifier: "com.google.Chrome"
            ),
            browserDomainProvider: FixedBrowserDomainProvider(
                behavior: .failure
            ),
            exclusions: ExclusionPreferences(
                domains: [
                    try XCTUnwrap(
                        DomainExclusion(domain: "example.com")
                    )
                ]
            )
        )

        XCTAssertThrowsError(
            try provider.capture(
                expectedToken: ":frog:",
                trigger: ":"
            )
        ) { error in
            XCTAssertEqual(
                error as? RuntimeTextCaptureError,
                .denied(.domainUnknown("com.google.Chrome"))
            )
        }
    }
}

private final class BrowserFixtureNode: @unchecked Sendable {
    let role: String?
    let subrole: String?
    let identifier: String?
    let accessibilityDescription: String?
    let value: String?
    let children: [BrowserFixtureNode]

    init(
        role: String? = nil,
        subrole: String? = nil,
        identifier: String? = nil,
        description: String? = nil,
        value: String? = nil,
        children: [BrowserFixtureNode] = []
    ) {
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        accessibilityDescription = description
        self.value = value
        self.children = children
    }

    var element: BrowserAccessibilityElement {
        BrowserAccessibilityElement(rawValue: self)
    }
}

private struct BrowserFixtureReader: BrowserAccessibilityReading {
    let root: BrowserFixtureNode

    func focusedWindow(
        for processIdentifier: pid_t
    ) throws -> BrowserAccessibilityElement? {
        _ = processIdentifier
        return root.element
    }

    func children(
        of element: BrowserAccessibilityElement
    ) throws -> [BrowserAccessibilityElement] {
        node(for: element).children.map(\.element)
    }

    func role(of element: BrowserAccessibilityElement) throws -> String? {
        node(for: element).role
    }

    func subrole(of element: BrowserAccessibilityElement) throws -> String? {
        node(for: element).subrole
    }

    func identifier(
        of element: BrowserAccessibilityElement
    ) throws -> String? {
        node(for: element).identifier
    }

    func description(
        of element: BrowserAccessibilityElement
    ) throws -> String? {
        node(for: element).accessibilityDescription
    }

    func value(of element: BrowserAccessibilityElement) throws -> String? {
        node(for: element).value
    }

    private func node(
        for element: BrowserAccessibilityElement
    ) -> BrowserFixtureNode {
        element.rawValue as! BrowserFixtureNode
    }
}

private struct FixedRuntimePermissionChecker: RuntimePermissionChecking {
    func currentPermissions() -> RuntimePermissionPreflight {
        RuntimePermissionPreflight(
            inputMonitoringGranted: true,
            accessibilityGranted: true
        )
    }
}

private struct FixedRuntimeSecureInputChecker: RuntimeSecureInputChecking {
    var secureEventInputEnabled: Bool {
        false
    }
}

private struct FixedRuntimeApplicationIdentityProvider:
    RuntimeApplicationIdentityProviding
{
    let bundleIdentifier: String?

    func bundleIdentifier(for processIdentifier: pid_t) -> String? {
        _ = processIdentifier
        return bundleIdentifier
    }
}

private struct FixedBrowserDomainProvider: BrowserDomainProviding {
    enum Behavior: Sendable {
        case host(String)
        case failure
    }

    let behavior: Behavior

    func host(
        for bundleIdentifier: String,
        processIdentifier: pid_t
    ) throws -> String? {
        _ = bundleIdentifier
        _ = processIdentifier
        switch behavior {
        case let .host(host):
            return host
        case .failure:
            throw TestBrowserDomainError.unavailable
        }
    }
}

private enum TestBrowserDomainError: Error {
    case unavailable
}

private final class BrowserDomainTextSystem: AccessibilityTextSystem {
    private let element = AccessibilityElementReference(rawValue: NSObject())
    private let text = ":frog:"
    private let selection = NSRange(location: 6, length: 0)

    func focusedElement() throws -> AccessibilityElementReference {
        element
    }

    func processIdentifier(
        of element: AccessibilityElementReference
    ) throws -> pid_t {
        _ = element
        return 42
    }

    func elementsAreEqual(
        _ lhs: AccessibilityElementReference,
        _ rhs: AccessibilityElementReference
    ) -> Bool {
        lhs === rhs
    }

    func value(of element: AccessibilityElementReference) throws -> String {
        _ = element
        return text
    }

    func numberOfCharacters(
        in element: AccessibilityElementReference
    ) throws -> Int? {
        _ = element
        return text.utf16.count
    }

    func string(
        for range: NSRange,
        in element: AccessibilityElementReference
    ) throws -> String? {
        _ = element
        try AccessibilityTextAdapter.validate(range, in: text)
        return (text as NSString).substring(with: range)
    }

    func selectedTextRange(
        of element: AccessibilityElementReference
    ) throws -> NSRange {
        _ = element
        return selection
    }

    func bounds(
        for range: NSRange,
        in element: AccessibilityElementReference
    ) throws -> CGRect? {
        _ = range
        _ = element
        return nil
    }

    func subrole(
        of element: AccessibilityElementReference
    ) throws -> String? {
        _ = element
        return nil
    }

    func isAttributeSettable(
        _ attribute: String,
        in element: AccessibilityElementReference
    ) throws -> Bool {
        _ = attribute
        _ = element
        return true
    }

    func setSelectedTextRange(
        _ range: NSRange,
        in element: AccessibilityElementReference
    ) throws {
        _ = range
        _ = element
    }

    func setSelectedText(
        _ text: String,
        in element: AccessibilityElementReference
    ) throws {
        _ = text
        _ = element
    }
}
