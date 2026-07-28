import ApplicationServices
import Foundation

protocol BrowserDomainProviding: Sendable {
    func host(
        for bundleIdentifier: String,
        processIdentifier: pid_t
    ) throws -> String?
}

struct BrowserAccessibilityElement: @unchecked Sendable {
    let rawValue: AnyObject

    init(rawValue: AnyObject) {
        self.rawValue = rawValue
    }

    var identity: ObjectIdentifier {
        ObjectIdentifier(rawValue)
    }
}

protocol BrowserAccessibilityReading: Sendable {
    func focusedWindow(
        for processIdentifier: pid_t
    ) throws -> BrowserAccessibilityElement?
    func children(
        of element: BrowserAccessibilityElement
    ) throws -> [BrowserAccessibilityElement]
    func role(of element: BrowserAccessibilityElement) throws -> String?
    func subrole(of element: BrowserAccessibilityElement) throws -> String?
    func identifier(of element: BrowserAccessibilityElement) throws -> String?
    func description(
        of element: BrowserAccessibilityElement
    ) throws -> String?
    func value(of element: BrowserAccessibilityElement) throws -> String?
}

enum BrowserAccessibilityReadError: Error, Equatable {
    case invalidAttributeValue(String)
    case axFailure(operation: String, code: Int32)
}

final class MacBrowserAccessibilityReader:
    BrowserAccessibilityReading,
    @unchecked Sendable
{
    func focusedWindow(
        for processIdentifier: pid_t
    ) throws -> BrowserAccessibilityElement? {
        let application = AXUIElementCreateApplication(processIdentifier)
        guard
            let window = try copyAttribute(
                kAXFocusedWindowAttribute,
                from: application,
                operation: "read browser focused window"
            )
        else {
            return nil
        }
        guard CFGetTypeID(window) == AXUIElementGetTypeID() else {
            throw BrowserAccessibilityReadError.invalidAttributeValue(
                kAXFocusedWindowAttribute
            )
        }
        return BrowserAccessibilityElement(rawValue: window as AnyObject)
    }

    func children(
        of element: BrowserAccessibilityElement
    ) throws -> [BrowserAccessibilityElement] {
        guard
            let value = try copyAttribute(
                kAXChildrenAttribute,
                from: axElement(element),
                operation: "read browser accessibility children"
            )
        else {
            return []
        }
        guard let values = value as? [AnyObject] else {
            throw BrowserAccessibilityReadError.invalidAttributeValue(
                kAXChildrenAttribute
            )
        }
        return values.compactMap { value in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return nil
            }
            return BrowserAccessibilityElement(rawValue: value)
        }
    }

    func role(of element: BrowserAccessibilityElement) throws -> String? {
        try stringAttribute(kAXRoleAttribute, of: element)
    }

    func subrole(of element: BrowserAccessibilityElement) throws -> String? {
        try stringAttribute(kAXSubroleAttribute, of: element)
    }

    func identifier(
        of element: BrowserAccessibilityElement
    ) throws -> String? {
        try stringAttribute(kAXIdentifierAttribute, of: element)
    }

    func description(
        of element: BrowserAccessibilityElement
    ) throws -> String? {
        try stringAttribute(kAXDescriptionAttribute, of: element)
    }

    func value(of element: BrowserAccessibilityElement) throws -> String? {
        guard
            let value = try copyAttribute(
                kAXValueAttribute,
                from: axElement(element),
                operation: "read browser address value"
            )
        else {
            return nil
        }
        if let string = value as? String {
            return string
        }
        if let url = value as? URL {
            return url.absoluteString
        }
        throw BrowserAccessibilityReadError.invalidAttributeValue(
            kAXValueAttribute
        )
    }

    private func stringAttribute(
        _ attribute: String,
        of element: BrowserAccessibilityElement
    ) throws -> String? {
        guard
            let value = try copyAttribute(
                attribute,
                from: axElement(element),
                operation: "read browser \(attribute)"
            )
        else {
            return nil
        }
        guard let string = value as? String else {
            throw BrowserAccessibilityReadError.invalidAttributeValue(
                attribute
            )
        }
        return string
    }

    private func copyAttribute(
        _ attribute: String,
        from element: AXUIElement,
        operation: String
    ) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        )
        if error == .attributeUnsupported || error == .noValue {
            return nil
        }
        guard error == .success else {
            throw BrowserAccessibilityReadError.axFailure(
                operation: operation,
                code: error.rawValue
            )
        }
        return value
    }

    private func axElement(
        _ reference: BrowserAccessibilityElement
    ) -> AXUIElement {
        reference.rawValue as! AXUIElement
    }
}

enum BrowserAddressBarURLNormalizer {
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    static func host(from rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard
            !value.isEmpty,
            value.utf8.count <= 4_096,
            value.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            }),
            !value.contains(where: \.isWhitespace),
            !value.contains("@")
        else {
            return nil
        }

        let valueForParsing: String
        if let schemeSeparator = value.range(of: "://") {
            let explicitScheme = String(value[..<schemeSeparator.lowerBound])
            guard
                explicitScheme.lowercased(with: posixLocale) == "http"
                    || explicitScheme.lowercased(with: posixLocale) == "https"
            else {
                return nil
            }
            let authorityStart = schemeSeparator.upperBound
            guard hasValidAuthority(in: value[authorityStart...]) else {
                return nil
            }
            valueForParsing = value
        } else {
            guard
                !value.hasPrefix("//"),
                value.contains(".")
                    || value == "localhost"
                    || value.hasPrefix("localhost:")
            else {
                return nil
            }
            guard hasValidAuthority(in: value[...]) else {
                return nil
            }
            valueForParsing = "https://\(value)"
        }

        guard
            let components = URLComponents(string: valueForParsing),
            components.user == nil,
            components.password == nil,
            let unnormalizedHost = components.host
        else {
            return nil
        }

        let normalizedHost = unnormalizedHost
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased(with: posixLocale)
        return DomainExclusion(
            domain: normalizedHost,
            includesSubdomains: true
        )?.domain
    }

    private static func hasValidAuthority(
        in remainder: Substring
    ) -> Bool {
        let authority = remainder.prefix {
            $0 != "/" && $0 != "?" && $0 != "#"
        }
        guard !authority.isEmpty else {
            return false
        }

        let parts = authority.split(
            separator: ":",
            omittingEmptySubsequences: false
        )
        switch parts.count {
        case 1:
            return true
        case 2:
            guard
                !parts[0].isEmpty,
                !parts[1].isEmpty,
                parts[1].allSatisfy(\.isNumber),
                let port = Int(parts[1]),
                (1 ... 65_535).contains(port)
            else {
                return false
            }
            return true
        default:
            return false
        }
    }
}

struct AXBrowserDomainProvider: BrowserDomainProviding {
    private enum BrowserFamily {
        case safari
        case chromium
    }

    private struct QueueEntry {
        let element: BrowserAccessibilityElement
        let depth: Int
    }

    private static let safariBundleIdentifiers: Set<String> = [
        "com.apple.safari",
        "com.apple.safaritechnologypreview"
    ]

    private static let chromiumBundleIdentifiers: Set<String> = [
        "com.brave.browser",
        "com.brave.browser.beta",
        "com.brave.browser.nightly",
        "com.google.chrome",
        "com.google.chrome.beta",
        "com.google.chrome.canary",
        "com.google.chrome.dev",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.beta",
        "com.microsoft.edgemac.canary",
        "com.microsoft.edgemac.dev",
        "com.operasoftware.opera",
        "com.operasoftware.operaair",
        "com.operasoftware.operanext",
        "com.vivaldi.vivaldi",
        "com.vivaldi.vivaldi.snapshot",
        "company.thebrowser.browser",
        "org.chromium.chromium"
    ]

    private static let safariIdentifiers: Set<String> = [
        "web_browser_address_and_search_field"
    ]

    private static let chromiumIdentifiers: Set<String> = [
        "address-and-search-bar",
        "omnibox"
    ]

    private static let chromiumDescriptions: Set<String> = [
        "address and search bar",
        "address bar"
    ]

    private let accessibility: any BrowserAccessibilityReading
    private let maximumDepth: Int
    private let maximumElementCount: Int

    init(
        accessibility: any BrowserAccessibilityReading =
            MacBrowserAccessibilityReader(),
        maximumDepth: Int = 12,
        maximumElementCount: Int = 256
    ) {
        self.accessibility = accessibility
        self.maximumDepth = max(0, maximumDepth)
        self.maximumElementCount = max(1, maximumElementCount)
    }

    func host(
        for bundleIdentifier: String,
        processIdentifier: pid_t
    ) throws -> String? {
        guard let family = Self.family(for: bundleIdentifier) else {
            return nil
        }
        guard
            let focusedWindow = try accessibility.focusedWindow(
                for: processIdentifier
            )
        else {
            return nil
        }

        var queue = [
            QueueEntry(element: focusedWindow, depth: 0)
        ]
        var nextIndex = 0
        var visited = Set<ObjectIdentifier>()

        while
            nextIndex < queue.count,
            visited.count < maximumElementCount
        {
            let entry = queue[nextIndex]
            nextIndex += 1
            guard visited.insert(entry.element.identity).inserted else {
                continue
            }

            guard
                let role =
                    (try? accessibility.role(of: entry.element)) ?? nil
            else {
                continue
            }
            if isAddressBar(
                entry.element,
                role: role,
                family: family
            ),
               let value = try? accessibility.value(of: entry.element),
               let host = BrowserAddressBarURLNormalizer.host(from: value) {
                return host
            }

            guard
                entry.depth < maximumDepth,
                role != "AXWebArea"
            else {
                continue
            }
            let children =
                (try? accessibility.children(of: entry.element)) ?? []
            let availableCapacity = maximumElementCount - queue.count
            guard availableCapacity > 0 else {
                continue
            }
            queue.append(
                contentsOf: children.prefix(availableCapacity).map {
                    QueueEntry(element: $0, depth: entry.depth + 1)
                }
            )
        }
        return nil
    }

    static func supportsDomainLookup(
        for bundleIdentifier: String
    ) -> Bool {
        family(for: bundleIdentifier) != nil
    }

    private static func family(
        for bundleIdentifier: String
    ) -> BrowserFamily? {
        let normalized = bundleIdentifier.lowercased(
            with: Locale(identifier: "en_US_POSIX")
        )
        if Self.safariBundleIdentifiers.contains(normalized) {
            return .safari
        }
        if Self.chromiumBundleIdentifiers.contains(normalized) {
            return .chromium
        }
        return nil
    }

    private func isAddressBar(
        _ element: BrowserAccessibilityElement,
        role: String?,
        family: BrowserFamily
    ) -> Bool {
        guard role == kAXTextFieldRole || role == kAXComboBoxRole else {
            return false
        }

        let identifier = normalizedMetadata(
            try? accessibility.identifier(of: element)
        )
        switch family {
        case .safari:
            if let identifier,
               Self.safariIdentifiers.contains(identifier) {
                return true
            }
            let subrole = try? accessibility.subrole(of: element)
            let description = normalizedMetadata(
                try? accessibility.description(of: element)
            )
            return subrole == kAXSearchFieldSubrole
                && description == "smart search field"
        case .chromium:
            if let identifier,
               Self.chromiumIdentifiers.contains(identifier) {
                return true
            }
            let description = normalizedMetadata(
                try? accessibility.description(of: element)
            )
            return description.map(
                Self.chromiumDescriptions.contains
            ) ?? false
        }
    }

    private func normalizedMetadata(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        return normalized.isEmpty ? nil : normalized
    }
}
