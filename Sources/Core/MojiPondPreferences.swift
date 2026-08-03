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
    var allowsCrashReports: Bool

    init(
        allowsCrashReports: Bool = true
    ) {
        self.allowsCrashReports = allowsCrashReports
    }

    private enum CodingKeys: String, CodingKey {
        case allowsCrashReports
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
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
        ApplicationExclusion(bundleIdentifier: "com.apple.Passwords", displayName: "Passwords"),
        ApplicationExclusion(bundleIdentifier: "com.apple.keychainaccess", displayName: "Keychain Access"),
        ApplicationExclusion(bundleIdentifier: "com.nordsec.nordpass", displayName: "NordPass"),
        ApplicationExclusion(bundleIdentifier: "me.proton.pass.electron", displayName: "Proton Pass"),
        ApplicationExclusion(bundleIdentifier: "com.lastpass.lastpassmacdesktop", displayName: "LastPass"),
        ApplicationExclusion(bundleIdentifier: "com.keepersecurity.passwordmanager", displayName: "Keeper"),
        ApplicationExclusion(bundleIdentifier: "com.callpod.keepermac.lite", displayName: "Keeper (App Store)"),
        ApplicationExclusion(bundleIdentifier: "in.sinew.Enpass-Desktop", displayName: "Enpass"),
        ApplicationExclusion(bundleIdentifier: "com.markmcguill.strongbox", displayName: "Strongbox"),
        ApplicationExclusion(bundleIdentifier: "com.markmcguill.strongbox.mac", displayName: "Strongbox (Legacy)"),
        ApplicationExclusion(bundleIdentifier: "com.hicknhacksoftware.MacPass", displayName: "MacPass"),
        ApplicationExclusion(bundleIdentifier: "com.apple.Terminal", displayName: "Terminal"),
        ApplicationExclusion(bundleIdentifier: "com.googlecode.iterm2", displayName: "iTerm2"),
        ApplicationExclusion(bundleIdentifier: "dev.warp.Warp-Stable", displayName: "Warp"),
        ApplicationExclusion(bundleIdentifier: "net.kovidgoyal.kitty", displayName: "kitty"),
        ApplicationExclusion(bundleIdentifier: "org.alacritty", displayName: "Alacritty"),
        ApplicationExclusion(bundleIdentifier: "com.mitchellh.ghostty", displayName: "Ghostty"),
        ApplicationExclusion(bundleIdentifier: "com.github.wez.wezterm", displayName: "WezTerm"),
        ApplicationExclusion(bundleIdentifier: "co.zeit.hyper", displayName: "Hyper"),
        ApplicationExclusion(bundleIdentifier: "com.raphaelamorim.rio", displayName: "Rio"),
        ApplicationExclusion(bundleIdentifier: "org.tabby", displayName: "Tabby"),
        ApplicationExclusion(bundleIdentifier: "com.termius.mac", displayName: "Termius"),
        ApplicationExclusion(bundleIdentifier: "dev.commandline.waveterm", displayName: "Wave Terminal"),
        ApplicationExclusion(bundleIdentifier: "com.parallels.desktop.console", displayName: "Parallels Desktop"),
        ApplicationExclusion(bundleIdentifier: "com.parallels.desktop.appstore", displayName: "Parallels Desktop (App Store)"),
        ApplicationExclusion(bundleIdentifier: "com.vmware.fusion", displayName: "VMware Fusion"),
        ApplicationExclusion(bundleIdentifier: "com.microsoft.rdc.macos", displayName: "Microsoft Remote Desktop"),
        ApplicationExclusion(bundleIdentifier: "com.apple.ScreenSharing", displayName: "Screen Sharing"),
        ApplicationExclusion(bundleIdentifier: "com.apple.ScreenContinuity", displayName: "iPhone Mirroring"),
        ApplicationExclusion(bundleIdentifier: "com.utmapp.UTM", displayName: "UTM"),
        ApplicationExclusion(bundleIdentifier: "org.virtualbox.app.VirtualBox", displayName: "VirtualBox"),
        ApplicationExclusion(bundleIdentifier: "org.virtualbox.app.VirtualBoxVM", displayName: "VirtualBox VM"),
        ApplicationExclusion(bundleIdentifier: "com.vmware.vmrc", displayName: "VMware Remote Console"),
        ApplicationExclusion(bundleIdentifier: "com.carriez.rustdesk", displayName: "RustDesk"),
        ApplicationExclusion(bundleIdentifier: "com.philandro.anydesk", displayName: "AnyDesk"),
        ApplicationExclusion(bundleIdentifier: "com.teamviewer.TeamViewer", displayName: "TeamViewer"),
        ApplicationExclusion(bundleIdentifier: "com.teamviewer.Desktop", displayName: "TeamViewer Session"),
        ApplicationExclusion(bundleIdentifier: "com.p5sys.jump.mac.viewer", displayName: "Jump Desktop"),
        ApplicationExclusion(bundleIdentifier: "com.edovia.screens.5", displayName: "Screens"),
        ApplicationExclusion(bundleIdentifier: "com.citrix.receiver.nomas", displayName: "Citrix Workspace"),
        ApplicationExclusion(bundleIdentifier: "com.citrix.XenAppViewer", displayName: "Citrix Viewer"),
        ApplicationExclusion(bundleIdentifier: "com.tinyspeck.slackmacgap", displayName: "Slack"),
        ApplicationExclusion(bundleIdentifier: "com.tinyspeck.chatlyio", displayName: "Slack (App Store)"),
        ApplicationExclusion(bundleIdentifier: "com.hnc.Discord", displayName: "Discord"),
        ApplicationExclusion(bundleIdentifier: "com.hammerandchisel.discord", displayName: "Discord (App Store)"),
        ApplicationExclusion(bundleIdentifier: "com.hnc.DiscordCanary", displayName: "Discord Canary"),
        ApplicationExclusion(bundleIdentifier: "com.hnc.DiscordPTB", displayName: "Discord PTB"),
        ApplicationExclusion(bundleIdentifier: "com.microsoft.teams2", displayName: "Microsoft Teams"),
        ApplicationExclusion(bundleIdentifier: "com.Mattermost.Desktop", displayName: "Mattermost"),
        ApplicationExclusion(bundleIdentifier: "org.zulip.zulip-electron", displayName: "Zulip"),
        ApplicationExclusion(bundleIdentifier: "dev.vencord.vesktop", displayName: "Vesktop"),
        ApplicationExclusion(bundleIdentifier: "chat.rocket", displayName: "Rocket.Chat")
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
