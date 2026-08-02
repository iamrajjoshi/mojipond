import Foundation

enum ShortcodeTrigger: String, CaseIterable, Codable, Hashable, Sendable {
    case colon = ":"
    case semicolon = ";"
    case slash = "/"
    case backslash = "\\"
    case at = "@"
    case hash = "#"
    case tilde = "~"
    case pipe = "|"

    var character: Character {
        Character(rawValue)
    }

    var accessibilityName: String {
        switch self {
        case .colon: "colon"
        case .semicolon: "semicolon"
        case .slash: "slash"
        case .backslash: "backslash"
        case .at: "at sign"
        case .hash: "hash"
        case .tilde: "tilde"
        case .pipe: "pipe"
        }
    }

    init?(character: Character) {
        self.init(rawValue: String(character))
    }
}

struct ShortcodePreferences: Codable, Equatable, Sendable {
    var trigger: ShortcodeTrigger
    var acceptsTab: Bool
    var acceptsReturn: Bool
    var showsSuggestionsOnBareTrigger: Bool
    var replacesOnExactClosingTrigger: Bool
    var opensBrowserOnDoubleTrigger: Bool
    var parserTimeout: TimeInterval

    init(
        trigger: ShortcodeTrigger = .colon,
        acceptsTab: Bool = true,
        acceptsReturn: Bool = true,
        showsSuggestionsOnBareTrigger: Bool = false,
        replacesOnExactClosingTrigger: Bool = true,
        opensBrowserOnDoubleTrigger: Bool = true,
        parserTimeout: TimeInterval = 0
    ) {
        self.trigger = trigger
        self.acceptsTab = acceptsTab
        self.acceptsReturn = acceptsReturn
        self.showsSuggestionsOnBareTrigger = showsSuggestionsOnBareTrigger
        self.replacesOnExactClosingTrigger = replacesOnExactClosingTrigger
        self.opensBrowserOnDoubleTrigger = opensBrowserOnDoubleTrigger
        self.parserTimeout = parserTimeout > 0
            ? max(0.1, parserTimeout)
            : 0
    }
}

enum GlobalActivationMode: String, Codable, Equatable, Sendable {
    case enabled
    case paused
}

struct NetworkPreferences: Codable, Equatable, Sendable {
    var allowsStickerSearch: Bool
    var allowsUpdateChecks: Bool
    var allowsCrashReports: Bool

    init(
        allowsStickerSearch: Bool = false,
        allowsUpdateChecks: Bool = false,
        allowsCrashReports: Bool = true
    ) {
        self.allowsStickerSearch = allowsStickerSearch
        self.allowsUpdateChecks = allowsUpdateChecks
        self.allowsCrashReports = allowsCrashReports
    }

    private enum CodingKeys: String, CodingKey {
        case allowsStickerSearch
        case allowsUpdateChecks
        case allowsCrashReports
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allowsStickerSearch = try container.decodeIfPresent(
            Bool.self,
            forKey: .allowsStickerSearch
        ) ?? false
        allowsUpdateChecks = try container.decodeIfPresent(
            Bool.self,
            forKey: .allowsUpdateChecks
        ) ?? false
        allowsCrashReports = try container.decodeIfPresent(
            Bool.self,
            forKey: .allowsCrashReports
        ) ?? true
    }
}

struct ApplicationExclusion: Identifiable, Codable, Hashable, Sendable {
    var id: String {
        bundleIdentifier
    }

    let bundleIdentifier: String
    var displayName: String

    init(bundleIdentifier: String, displayName: String) {
        self.bundleIdentifier = bundleIdentifier.lowercased(with: Locale(identifier: "en_US_POSIX"))
        self.displayName = displayName
    }

    func matches(bundleIdentifier candidate: String) -> Bool {
        bundleIdentifier.caseInsensitiveCompare(candidate) == .orderedSame
    }
}

struct DomainExclusion: Identifiable, Codable, Hashable, Sendable {
    var id: String {
        "\(domain)|\(includesSubdomains)"
    }

    let domain: String
    var includesSubdomains: Bool

    init?(domain: String, includesSubdomains: Bool = true) {
        let normalized = Self.normalize(domain)
        guard Self.isValid(normalized) else {
            return nil
        }
        self.domain = normalized
        self.includesSubdomains = includesSubdomains
    }

    func matches(host candidate: String) -> Bool {
        let candidate = Self.normalize(candidate)
        if candidate == domain {
            return true
        }
        return includesSubdomains && candidate.hasSuffix(".\(domain)")
    }

    private static func normalize(_ domain: String) -> String {
        domain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func isValid(_ domain: String) -> Bool {
        guard !domain.isEmpty, domain.utf8.count <= 253 else {
            return false
        }

        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else {
            return false
        }
        return labels.allSatisfy { label in
            guard !label.isEmpty, label.utf8.count <= 63, label.first != "-", label.last != "-" else {
                return false
            }
            return label.utf8.allSatisfy { byte in
                (0x61...0x7A).contains(byte)
                    || (0x30...0x39).contains(byte)
                    || byte == 0x2D
            }
        }
    }
}

enum ExclusionMatch: Equatable, Sendable {
    case application(ApplicationExclusion)
    case domain(DomainExclusion)
}

struct ExclusionPreferences: Codable, Equatable, Sendable {
    var applications: [ApplicationExclusion]
    var domains: [DomainExclusion]

    static let protectedApplications = uniquedApplications([
        ApplicationExclusion(bundleIdentifier: "com.rajjoshi.MojiPond", displayName: "MojiPond"),
        ApplicationExclusion(bundleIdentifier: "com.1password.1password", displayName: "1Password"),
        ApplicationExclusion(bundleIdentifier: "com.agilebits.onepassword7", displayName: "1Password 7"),
        ApplicationExclusion(bundleIdentifier: "com.bitwarden.desktop", displayName: "Bitwarden"),
        ApplicationExclusion(bundleIdentifier: "org.keepassxc.keepassxc", displayName: "KeePassXC"),
        ApplicationExclusion(bundleIdentifier: "com.apple.Terminal", displayName: "Terminal"),
        ApplicationExclusion(bundleIdentifier: "com.googlecode.iterm2", displayName: "iTerm2"),
        ApplicationExclusion(bundleIdentifier: "dev.warp.Warp-Stable", displayName: "Warp"),
        ApplicationExclusion(bundleIdentifier: "net.kovidgoyal.kitty", displayName: "kitty"),
        ApplicationExclusion(bundleIdentifier: "org.alacritty", displayName: "Alacritty"),
        ApplicationExclusion(bundleIdentifier: "com.parallels.desktop.console", displayName: "Parallels Desktop"),
        ApplicationExclusion(bundleIdentifier: "com.vmware.fusion", displayName: "VMware Fusion"),
        ApplicationExclusion(bundleIdentifier: "com.microsoft.rdc.macos", displayName: "Microsoft Remote Desktop"),
        ApplicationExclusion(bundleIdentifier: "com.tinyspeck.slackmacgap", displayName: "Slack"),
        ApplicationExclusion(bundleIdentifier: "com.hnc.Discord", displayName: "Discord")
    ])

    var userApplications: [ApplicationExclusion] {
        Self.uniquedApplications(
            applications.filter {
                !Self.isProtectedApplication(bundleIdentifier: $0.bundleIdentifier)
            }
        )
    }

    var effectiveApplications: [ApplicationExclusion] {
        Self.uniquedApplications(Self.protectedApplications + userApplications)
    }

    init(
        applications: [ApplicationExclusion] = [],
        domains: [DomainExclusion] = []
    ) {
        self.applications = Self.uniquedApplications(applications)
        self.domains = Self.uniquedDomains(domains)
    }

    func match(bundleIdentifier: String?, domain: String?) -> ExclusionMatch? {
        if let bundleIdentifier,
           let exclusion = effectiveApplications.first(where: { $0.matches(bundleIdentifier: bundleIdentifier) }) {
            return .application(exclusion)
        }
        if let domain, let exclusion = domains.first(where: { $0.matches(host: domain) }) {
            return .domain(exclusion)
        }
        return nil
    }

    static let defaults = ExclusionPreferences(
        applications: protectedApplications
    )

    static func isProtectedApplication(bundleIdentifier: String) -> Bool {
        protectedApplications.contains {
            $0.matches(bundleIdentifier: bundleIdentifier)
        }
    }

    private static func uniquedApplications(
        _ applications: [ApplicationExclusion]
    ) -> [ApplicationExclusion] {
        var seen = Set<String>()
        return applications.filter {
            seen.insert($0.bundleIdentifier.lowercased(with: Locale(identifier: "en_US_POSIX"))).inserted
        }
    }

    private static func uniquedDomains(_ domains: [DomainExclusion]) -> [DomainExclusion] {
        var seen = Set<String>()
        return domains.filter { seen.insert($0.id).inserted }
    }
}

struct MojiPondPreferences: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 3

    var schemaVersion: Int
    var activationMode: GlobalActivationMode
    var launchAtLogin: Bool
    var shortcode: ShortcodePreferences
    var defaultSkinTone: EmojiSkinTone?
    var exclusions: ExclusionPreferences
    var network: NetworkPreferences

    init(
        schemaVersion: Int = currentSchemaVersion,
        activationMode: GlobalActivationMode = .enabled,
        launchAtLogin: Bool = false,
        shortcode: ShortcodePreferences = ShortcodePreferences(),
        defaultSkinTone: EmojiSkinTone? = nil,
        exclusions: ExclusionPreferences = .defaults,
        network: NetworkPreferences = NetworkPreferences()
    ) {
        self.schemaVersion = schemaVersion
        self.activationMode = activationMode
        self.launchAtLogin = launchAtLogin
        self.shortcode = shortcode
        self.defaultSkinTone = defaultSkinTone
        self.exclusions = exclusions
        self.network = network
    }

    static let defaults = MojiPondPreferences()
}
