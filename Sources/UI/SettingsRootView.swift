import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum UsageRankingResetNotice {
    static let success = "Learned ordering was reset."
    static let failure = "Learned ordering could not be reset."
}

private enum SettingsDestination: String, CaseIterable, Identifiable {
    case general = "General"
    case shortcuts = "Shortcuts"
    case library = "Library"
    case privacy = "Privacy"
    case about = "About"

    var id: Self { self }

    var icon: String {
        switch self {
        case .general: "water.waves"
        case .shortcuts: "keyboard"
        case .library: "square.grid.2x2"
        case .privacy: "hand.raised"
        case .about: "info.circle"
        }
    }

    var detail: String {
        switch self {
        case .general:
            "App behavior and updates."
        case .shortcuts:
            "Trigger, insertion keys, and skin tone."
        case .library:
            "Packs, aliases, and favorites."
        case .privacy:
            "Crash reports, permissions, and exclusions."
        case .about:
            "Version and acknowledgements."
        }
    }
}

private enum SettingsNoticeDocument: String, Identifiable {
    case license
    case thirdPartyNotices

    var id: Self { self }

    var title: String {
        switch self {
        case .license:
            "MojiPond License"
        case .thirdPartyNotices:
            "Third-Party Notices"
        }
    }

    var resourceNames: [String] {
        switch self {
        case .license:
            ["MOJIPOND-LICENSE"]
        case .thirdPartyNotices:
            [
                "THIRD-PARTY-NOTICES",
                "SPARKLE-LICENSE",
                "SENTRY-THIRD-PARTY-NOTICES",
            ]
        }
    }

    var contents: String {
        let documents = resourceNames.compactMap { resourceName -> String? in
            guard let url = Bundle.main.url(
                forResource: resourceName,
                withExtension: "txt"
            ) else {
                return nil
            }
            return try? String(contentsOf: url, encoding: .utf8)
        }
        guard documents.count == resourceNames.count else {
            return "The bundled \(title.lowercased()) could not be loaded."
        }
        return documents.joined(separator: "\n\n")
    }
}

struct SettingsRootView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var permissions: SystemPermissionCenter
    @ObservedObject private var updates: AppUpdateController

    @State private var domainDraft = ""
    @State private var domainIncludesSubdomains = true
    @State private var applicationExclusionError: String?
    @State private var exclusionError: String?
    @State private var permissionNavigationError: String?
    @State private var showsUsageResetConfirmation = false
    @State private var presentedNotice: SettingsNoticeDocument?
    @State private var destination: SettingsDestination
    private let permissionSettingsOpener:
        any SystemPermissionSettingsOpening

    init(
        appState: AppState,
        permissionSettingsOpener:
            any SystemPermissionSettingsOpening =
                MacSystemPermissionSettingsOpener()
    ) {
        self.appState = appState
        permissions = appState.permissions
        updates = appState.updates
        self.permissionSettingsOpener = permissionSettingsOpener
        let storedDestination = UserDefaults.standard.string(
            forKey: "settings.selectedDestination"
        )
        _destination = State(
            initialValue: storedDestination.flatMap(
                SettingsDestination.init(rawValue:)
            ) ?? .general
        )
    }

    var body: some View {
        TabView(selection: $destination) {
            settingsPane(.general) {
                general
            }
            settingsPane(.shortcuts) {
                shortcuts
            }
            settingsPane(.library) {
                library
            }
            settingsPane(.privacy) {
                privacy
            }
            settingsPane(.about) {
                about
            }
        }
        .tint(PondDesign.pond)
        .confirmationDialog(
            "Reset recent emoji and learned ordering?",
            isPresented: $showsUsageResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                clearUsageResetNotice()
                NotificationCenter.default.post(
                    name: .mojiPondResetUsageRanking,
                    object: nil
                )
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "MojiPond will clear recent emoji and usage ranking. This can’t be undone."
            )
        }
        .sheet(item: $presentedNotice) { document in
            SettingsNoticeDocumentView(document: document)
        }
        .onChange(of: destination) { newDestination in
            UserDefaults.standard.set(
                newDestination.rawValue,
                forKey: "settings.selectedDestination"
            )
        }
        .frame(
            minWidth: 700,
            idealWidth: 740,
            minHeight: 480,
            idealHeight: 520
        )
    }

    private func settingsPane<Content: View>(
        _ item: SettingsDestination,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack {
            PondWindowBackdrop()

            ScrollView {
                VStack(
                    alignment: .leading,
                    spacing: PondDesign.sectionSpacing
                ) {
                    PondPageHeader(
                        icon: item.icon,
                        title: item.rawValue,
                        detail: item.detail
                    )

                    content()
                }
                .frame(maxWidth: 600, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
        }
        .tabItem {
            Label(item.rawValue, systemImage: item.icon)
        }
        .tag(item)
    }

    private var general: some View {
        VStack(spacing: PondDesign.sectionSpacing) {
            SettingsCard {
                runtimeStatus

                SettingsDivider()

                SettingsRow(
                    icon: "water.waves",
                    title: "Enable MojiPond",
                    detail: appState.isEnabled
                        ? "Suggestions appear when you type \(triggerExample)."
                        : "Shortcode suggestions and replacement are paused."
                ) {
                    Toggle(
                        "Enable MojiPond",
                        isOn: Binding(
                            get: { appState.isEnabled },
                            set: { appState.setEnabled($0) }
                        )
                    )
                    .labelsHidden()
                    .accessibilityLabel("Enable MojiPond")
                    .toggleStyle(.switch)
                    .tint(PondDesign.lily)
                }

                SettingsDivider()

                SettingsRow(
                    icon: "arrow.clockwise.circle",
                    title: "Launch at login",
                    detail: "Start MojiPond when you sign in."
                ) {
                    Toggle(
                        "Launch at login",
                        isOn: Binding(
                            get: { appState.launchAtLoginEnabled },
                            set: { appState.setLaunchAtLogin($0) }
                        )
                    )
                    .labelsHidden()
                    .accessibilityLabel("Launch at login")
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(PondDesign.lily)
                }

                if let error = appState.launchAtLoginError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(PondDesign.warningForeground)
                        .padding(.top, 10)
                }
            }

            if updates.isConfigured {
                SettingsCard(title: "Updates") {
                    SettingsRow(
                        icon: "arrow.triangle.2.circlepath",
                        title: "Keep MojiPond up to date",
                        detail: "Checks daily. You choose when to install."
                    ) {
                        Toggle(
                            "Keep MojiPond up to date",
                            isOn: Binding(
                                get: {
                                    updates.automaticChecksEnabled
                                },
                                set: {
                                    updates.setAutomaticChecksEnabled($0)
                                }
                            )
                        )
                        .labelsHidden()
                        .accessibilityLabel("Keep MojiPond up to date")
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .tint(PondDesign.lily)
                    }

                    SettingsDivider()

                    SettingsActionRow(
                        icon: "arrow.clockwise",
                        title: "Check for updates",
                        detail: updates.statusSummary
                    ) {
                        Button("Check for Updates…") {
                            updates.checkManually()
                        }
                        .disabled(!updates.canCheckForUpdates)
                        .accessibilityHint(
                            "Uses Sparkle to securely check for a newer version."
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shortcuts: some View {
        VStack(spacing: PondDesign.sectionSpacing) {
            SettingsCard(
                title: "Acceptance"
            ) {
                SettingsRow(
                    icon: "arrow.right.to.line.compact",
                    title: "Accept with Tab",
                    detail: "Keeps Return free for sending messages."
                ) {
                    Toggle(
                        "Accept with Tab",
                        isOn: preference(\.shortcode.acceptsTab)
                    )
                    .labelsHidden()
                    .accessibilityLabel("Accept with Tab")
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(PondDesign.lily)
                }

                SettingsDivider()

                SettingsRow(
                    icon: "return",
                    title: "Accept with Return",
                    detail: "Return may send the message in some apps."
                ) {
                    Toggle(
                        "Accept with Return",
                        isOn: preference(\.shortcode.acceptsReturn)
                    )
                    .labelsHidden()
                    .accessibilityLabel("Accept with Return")
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(PondDesign.lily)
                }
            }

            SettingsCard(
                title: "Trigger"
            ) {
                SettingsRow(
                    icon: "character.cursor.ibeam",
                    title: "Trigger key",
                    detail:
                        "Letters and numbers are reserved for emoji names."
                ) {
                    Picker(
                        "Shortcode trigger",
                        selection: preference(\.shortcode.trigger)
                    ) {
                        ForEach(
                            ShortcodeTrigger.allCases,
                            id: \.self
                        ) { trigger in
                            Text(trigger.settingsTitle).tag(trigger)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Shortcode trigger")
                    .frame(width: 150)
                }

                SettingsDivider()

                SettingsRow(
                    icon: "rectangle.and.text.magnifyingglass",
                    title:
                        "Show suggestions after typing “\(triggerText)”",
                    detail:
                        "When off, suggestions wait for the first letter."
                ) {
                    Toggle(
                        "Show suggestions on a bare trigger",
                        isOn: preference(
                            \.shortcode.showsSuggestionsOnBareTrigger
                        )
                    )
                    .labelsHidden()
                    .accessibilityLabel(
                        "Show suggestions on a bare trigger"
                    )
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(PondDesign.lily)
                }

                SettingsDivider()

                SettingsRow(
                    icon: "square.grid.3x3",
                    title:
                        "Open browser with \(triggerText)\(triggerText)",
                    detail: "Browse and search the full emoji library."
                ) {
                    Toggle(
                        "Open the browser with \(triggerText)\(triggerText)",
                        isOn: preference(
                            \.shortcode.opensBrowserOnDoubleTrigger
                        )
                    )
                    .labelsHidden()
                    .accessibilityLabel(
                        "Open the browser with \(triggerText)\(triggerText)"
                    )
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(PondDesign.lily)
                }
            }

            SettingsCard(
                title: "Exact shortcodes",
                detail: "Close a shortcode to replace an exact match."
            ) {
                SettingsRow(
                    icon: "text.badge.checkmark",
                    title: "Replace on closing “\(triggerText)”",
                    detail: "Only full aliases are replaced."
                ) {
                    Toggle(
                        "Replace an exact closing token",
                        isOn: preference(
                            \.shortcode.replacesOnExactClosingTrigger
                        )
                    )
                    .labelsHidden()
                    .accessibilityLabel(
                        "Replace an exact closing token"
                    )
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(PondDesign.lily)
                }

                SettingsDivider()

                HStack(spacing: 12) {
                    Text("Example")
                        .font(.callout.weight(.medium))
                    PondCommandToken(
                        value:
                            "\(triggerText)lizard\(triggerText)  →  🦎"
                    )
                    Spacer()
                }
            }

            SettingsCard(title: "Appearance") {
                SettingsRow(
                    icon: "hand.raised.fingers.spread",
                    title: "Default skin tone",
                    detail: "Used when an emoji supports skin tones."
                ) {
                    Picker(
                        "Default skin tone",
                        selection: preference(\.defaultSkinTone)
                    ) {
                        Text("Automatic").tag(EmojiSkinTone?.none)
                        ForEach(
                            EmojiSkinTone.allCases,
                            id: \.self
                        ) { tone in
                            Text("\(tone.modifier) \(tone.displayName)")
                                .tag(Optional(tone))
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Default skin tone")
                    .frame(width: 170)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var library: some View {
        VStack(spacing: PondDesign.sectionSpacing) {
            SettingsCard {
                SettingsActionRow(
                    icon: "square.grid.2x2",
                    title: "Open library",
                    detail: "Browse, import, and manage emoji."
                ) {
                    Button("Open MojiPond Library…") {
                        NotificationCenter.default.post(
                            name: .mojiPondShowLibrary,
                            object: nil
                        )
                    }
                    .buttonStyle(.borderedProminent)
                }

                SettingsDivider()

                SettingsActionRow(
                    icon: "text.badge.plus",
                    title: "Personal aliases",
                    detail: "Add another shortcode to any emoji."
                ) {
                    Button("Manage Aliases…") {
                        NotificationCenter.default.post(
                            name: .mojiPondShowAliases,
                            object: nil
                        )
                    }
                }
            }

            SettingsCard(
                title: "Local data",
                detail: "Packs and settings stay on this Mac."
            ) {
                Text(
                    "Imported images are copied to Application Support."
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                SettingsDivider()

                Text("Clears recent emoji and usage ranking.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reset learned ordering…", role: .destructive) {
                    showsUsageResetConfirmation = true
                }
                if let notice = appState.usageRankingResetNotice {
                    Label(
                        notice,
                        systemImage:
                            notice == UsageRankingResetNotice.success
                                ? "checkmark.circle"
                                : "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .accessibilityIdentifier(
                        "settings.usageResetNotice"
                    )
                    .accessibilityLabel(notice)
                    .foregroundStyle(
                        notice == UsageRankingResetNotice.success
                            ? AnyShapeStyle(.secondary)
                            : AnyShapeStyle(PondDesign.errorForeground)
                    )
                    .padding(.top, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var privacy: some View {
        VStack(spacing: PondDesign.sectionSpacing) {
            SettingsCard(
                title: "Crash reports",
                detail:
                    "Help improve MojiPond when something goes wrong."
            ) {
                SettingsRow(
                    icon: "stethoscope",
                    title: "Share crash reports",
                    detail:
                        "Sends crash and hang diagnostics, including stack traces and app/runtime context, to Sentry. Standard request metadata, including IP, reaches Sentry. MojiPond does not attach typing, clipboard contents, screenshots, or emoji files."
                ) {
                    Toggle(
                        "Share crash reports",
                        isOn: preference(
                            \.network.allowsCrashReports
                        )
                    )
                    .labelsHidden()
                    .accessibilityLabel("Share crash reports")
                    .toggleStyle(.switch)
                    .tint(PondDesign.lily)
                }
            }

            SettingsCard(
                title: "System permissions",
                detail:
                    "Shortcuts need Input Monitoring and Accessibility. Image insertion is optional."
            ) {
                PermissionSettingsRow(
                    icon: "keyboard",
                    title: "Input Monitoring",
                    detail: "Detects emoji shortcuts as you type.",
                    status: permissions.snapshot.inputMonitoring,
                    request: { permissions.requestInputMonitoring() },
                    openSettings: {
                        openPermissionSettings(.inputMonitoring)
                    }
                )

                SettingsDivider()

                PermissionSettingsRow(
                    icon: "accessibility",
                    title: "Accessibility",
                    detail: "Positions suggestions and inserts your choice.",
                    status: permissions.snapshot.accessibility,
                    request: { permissions.requestAccessibility() },
                    openSettings: {
                        openPermissionSettings(.accessibility)
                    }
                )

                SettingsDivider()

                PermissionSettingsRow(
                    icon: "photo.on.rectangle",
                    title: "Image emoji in Messages",
                    detail:
                        "Pastes custom images in Messages. Unicode emoji do not need it.",
                    status: permissions.snapshot.eventPosting,
                    isOptional: true,
                    request: { permissions.requestEventPosting() },
                    openSettings: {
                        openPermissionSettings(.eventPosting)
                    }
                )
                if let permissionNavigationError {
                    Label(
                        permissionNavigationError,
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(PondDesign.warningForeground)
                    .padding(.top, 10)
                }
            }

            SettingsCard(
                title: "Disabled apps",
                detail: "Add an app to keep suggestions off there."
            ) {
                if userApplicationExclusions.isEmpty {
                    Text("No apps added.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(userApplicationExclusions) { app in
                        HStack(spacing: 12) {
                            Image(systemName: "app.dashed")
                                .foregroundStyle(PondDesign.pond)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.displayName)
                                Text(app.bundleIdentifier)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                removeApplicationExclusion(app.id)
                            } label: {
                                Image(systemName: "minus.circle")
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Remove \(app.displayName)")
                            .accessibilityLabel(
                                "Remove \(app.displayName) exclusion"
                            )
                        }
                        if app.id != userApplicationExclusions.last?.id {
                            SettingsDivider()
                        }
                    }
                }

                if !userApplicationExclusions.isEmpty {
                    SettingsDivider()
                }
                Button(
                    "Add Application…",
                    action: chooseExcludedApplication
                )
                if let applicationExclusionError {
                    Text(applicationExclusionError)
                        .font(.caption)
                        .foregroundStyle(PondDesign.warningForeground)
                }
            }

            SettingsCard(
                title: "Disabled websites",
                detail: "Add a site to keep suggestions off there."
            ) {
                ForEach(appState.preferences.exclusions.domains) { domain in
                    HStack {
                        Text(domain.domain)
                            .accessibilityIdentifier(
                                "settings.disabledDomain.\(domain.domain)"
                            )
                        Spacer()
                        Text(
                            domain.includesSubdomains
                                ? "Includes subdomains"
                                : "Exact host"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Button {
                            removeDomainExclusion(domain.id)
                        } label: {
                            Image(systemName: "minus.circle")
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Remove \(domain.domain)")
                        .accessibilityLabel(
                            "Remove \(domain.domain) exclusion"
                        )
                    }
                    if domain.id
                        != appState.preferences.exclusions.domains.last?.id {
                        SettingsDivider()
                    }
                }

                if !appState.preferences.exclusions.domains.isEmpty {
                    SettingsDivider()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Domain")
                        .font(.callout.weight(.medium))
                    HStack {
                        TextField("example.com", text: $domainDraft)
                            .accessibilityLabel("Website domain")
                            .onSubmit(addDomainExclusion)
                            .onChange(of: domainDraft) { _ in
                                exclusionError = nil
                            }
                        Toggle(
                            "Include subdomains",
                            isOn: $domainIncludesSubdomains
                        )
                        .toggleStyle(.checkbox)
                        .onChange(of: domainIncludesSubdomains) { _ in
                            exclusionError = nil
                        }
                        Button("Add", action: addDomainExclusion)
                            .disabled(domainDraft.isEmpty)
                    }
                }
                if let exclusionError {
                    Text(exclusionError)
                        .font(.caption)
                        .foregroundStyle(PondDesign.warningForeground)
                }
                Text(
                    "If MojiPond cannot identify a site, suggestions stay off."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            SettingsCard(
                title: "Always disabled"
            ) {
                Label(
                    "Password managers and secure text fields",
                    systemImage: "key.fill"
                )
                SettingsDivider()
                Label(
                    "Terminals, remote desktops, and virtual machines",
                    systemImage: "terminal.fill"
                )
                SettingsDivider()
                Label(
                    "Chat apps that provide their own emoji shortcuts",
                    systemImage:
                        "bubble.left.and.bubble.right.fill"
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var about: some View {
        SettingsCard {
            HStack(spacing: 16) {
                PondMark(size: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text("MojiPond")
                        .font(.title2.weight(.semibold))
                    Text("Shortcodes and custom emoji for your Mac.")
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent(
                "Version",
                value: Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String ?? "Development"
            )
            Text(
                "Shortcodes are processed on this Mac. MojiPond does not "
                    + "save your messages or require an account."
            )
            .foregroundStyle(.secondary)

            SettingsDivider()

            SettingsActionRow(
                icon: "doc.text",
                title: "Acknowledgements",
                detail: "Licenses for software included with MojiPond."
            ) {
                Button("Third-Party Notices…") {
                    presentedNotice = .thirdPartyNotices
                }
                .accessibilityIdentifier(
                    "settings.about.thirdPartyNotices"
                )
            }

            SettingsDivider()

            SettingsActionRow(
                icon: "checkmark.seal",
                title: "MojiPond license",
                detail: "MojiPond is available under the MIT License."
            ) {
                Button("License…") {
                    presentedNotice = .license
                }
                .accessibilityIdentifier("settings.about.license")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var triggerText: String {
        appState.preferences.shortcode.trigger.rawValue
    }

    private var triggerExample: String {
        "\(triggerText)wave\(triggerText)"
    }

    private var runtimeStatusColor: Color {
        switch appState.statusSummary {
        case "Ready":
            PondDesign.lily
        case "Permissions needed":
            PondDesign.warningForeground
        case "Needs attention":
            PondDesign.errorForeground
        case "Starting…":
            PondDesign.pond
        default:
            Color.secondary
        }
    }

    private var runtimeStatusDetail: String {
        guard appState.isEnabled else {
            return "Suggestions are off"
        }
        guard appState.canMonitorTyping else {
            return "Open Privacy to allow access"
        }
        return appState.statusSummary == "Ready"
            ? "Type \(triggerExample)"
            : "Suggestions are not active"
    }

    private var runtimeStatus: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(runtimeStatusColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(appState.statusSummary)
                    .font(.caption.weight(.semibold))
                Text(runtimeStatusDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var userApplicationExclusions: [ApplicationExclusion] {
        appState.preferences.exclusions.userApplications
    }

    private func clearUsageResetNotice() {
        appState.setUsageRankingResetNotice(nil)
    }

    private func preference<Value>(
        _ keyPath: WritableKeyPath<MojiPondPreferences, Value>
    ) -> Binding<Value> {
        Binding(
            get: { appState.preferences[keyPath: keyPath] },
            set: { value in
                appState.updatePreferences {
                    $0[keyPath: keyPath] = value
                }
            }
        )
    }

    private func chooseExcludedApplication() {
        applicationExclusionError = nil
        let panel = NSOpenPanel()
        panel.title = "Exclude an Application"
        panel.prompt = "Exclude"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundle = Bundle(url: url),
              let identifier = bundle.bundleIdentifier else {
            return
        }

        let exclusion = ApplicationExclusion(
            bundleIdentifier: identifier,
            displayName: bundle.object(
                forInfoDictionaryKey: "CFBundleDisplayName"
            ) as? String ?? url.deletingPathExtension().lastPathComponent
        )
        guard !appState.preferences.exclusions.applications.contains(
            where: { $0.id == exclusion.id }
        ) else {
            applicationExclusionError =
                "\(exclusion.displayName) is already disabled."
            return
        }
        appState.updatePreferences {
            $0.exclusions.applications.append(exclusion)
        }
        applicationExclusionError = nil
    }

    private func removeApplicationExclusion(_ id: String) {
        applicationExclusionError = nil
        appState.updatePreferences {
            $0.exclusions.applications.removeAll { $0.id == id }
        }
    }

    private func openPermissionSettings(_ permission: SystemPermission) {
        let opened = permissionSettingsOpener.openSettings(
            for: permission
        )
        permissionNavigationError = opened
            ? nil
            : "Could not open System Settings. Open Privacy & Security manually."
        if opened {
            permissions.observeGrant(for: permission)
        }
    }

    private func addDomainExclusion() {
        guard let exclusion = DomainExclusion(
            domain: domainDraft,
            includesSubdomains: domainIncludesSubdomains
        ) else {
            exclusionError = "Enter a hostname such as example.com."
            return
        }
        if let existingIndex =
            appState.preferences.exclusions.domains.firstIndex(
                where: { $0.domain == exclusion.domain }
            ) {
            guard appState.preferences.exclusions.domains[
                existingIndex
            ].includesSubdomains != exclusion.includesSubdomains else {
                exclusionError = "This site is already disabled."
                return
            }
            appState.updatePreferences {
                $0.exclusions.domains[existingIndex] = exclusion
            }
            domainDraft = ""
            exclusionError = nil
            return
        }
        appState.updatePreferences {
            $0.exclusions.domains.append(exclusion)
        }
        domainDraft = ""
        exclusionError = nil
    }

    private func removeDomainExclusion(_ id: String) {
        exclusionError = nil
        appState.updatePreferences {
            $0.exclusions.domains.removeAll { $0.id == id }
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String?
    let detail: String?
    private let content: Content

    init(
        title: String? = nil,
        detail: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .fontDesign(.rounded)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )
                    }
                }
                .padding(.horizontal, 2)
            }

            VStack(alignment: .leading, spacing: PondDesign.rowSpacing) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                PondDesign.surface,
                in: RoundedRectangle(
                    cornerRadius: PondDesign.cornerRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: PondDesign.cornerRadius,
                    style: .continuous
                )
                .stroke(PondDesign.separator.opacity(0.65))
            }
        }
    }
}

struct SettingsRow<Accessory: View>: View {
    let icon: String
    let title: String
    let detail: String
    let detailAccessibilityIdentifier: String?
    private let accessory: Accessory

    init(
        icon: String,
        title: String,
        detail: String,
        detailAccessibilityIdentifier: String? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.detailAccessibilityIdentifier = detailAccessibilityIdentifier
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(PondDesign.pond)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                detailText
            }
            .layoutPriority(1)

            Spacer(minLength: 10)
            accessory
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private var detailText: some View {
        let text = Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if let detailAccessibilityIdentifier {
            text.accessibilityIdentifier(detailAccessibilityIdentifier)
        } else {
            text
        }
    }
}

private struct SettingsActionRow<Accessory: View>: View {
    let icon: String
    let title: String
    let detail: String
    private let accessory: Accessory

    init(
        icon: String,
        title: String,
        detail: String,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.accessory = accessory()
    }

    var body: some View {
        SettingsRow(
            icon: icon,
            title: title,
            detail: detail
        ) {
            accessory
        }
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(PondDesign.separator.opacity(0.7))
            .frame(height: 1)
            .padding(.leading, 34)
            .accessibilityHidden(true)
    }
}

private extension ShortcodeTrigger {
    var settingsTitle: String {
        "\(rawValue)  \(accessibilityName)"
    }
}

private struct PermissionSettingsRow: View {
    let icon: String
    let title: String
    let detail: String
    let status: SystemPermissionStatus
    var isOptional = false
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(
                    status == .granted
                        ? PondDesign.lily
                        : PondDesign.pond
                )
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.callout.weight(.medium))
                    PermissionStatusView(
                        permissionName: title,
                        status: status,
                        isRequired: !isOptional
                    )
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                permissionAction
            }
            .layoutPriority(1)
        }
    }

    @ViewBuilder
    private var permissionAction: some View {
        switch status {
        case .notRequested:
            Button("Request Access", action: request)
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Request \(title) Access")
        case .pending, .denied, .revoked:
            Button("System Settings…", action: openSettings)
                .buttonStyle(.plain)
                .foregroundStyle(PondDesign.pond)
                .accessibilityLabel("Open \(title) Settings")
        case .granted:
            EmptyView()
        }
    }
}

private struct SettingsNoticeDocumentView: View {
    let document: SettingsNoticeDocument

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(document.title)
                    .font(.headline)
                Spacer()
            }
            .padding(12)

            Divider()

            ScrollView {
                Text(document.contents)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .accessibilityIdentifier("settings.notice.text")
            }

            Divider()

            HStack {
                Spacer()
                Button("Close", action: dismiss.callAsFunction)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("settings.notice.close")
            }
            .padding(12)
            .background(.bar)
        }
        .frame(
            minWidth: 560,
            idealWidth: 640,
            minHeight: 400,
            idealHeight: 500
        )
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

extension Notification.Name {
    static let mojiPondShowLibrary = Notification.Name(
        "com.rajjoshi.MojiPond.showLibrary"
    )
    static let mojiPondResetUsageRanking = Notification.Name(
        "com.rajjoshi.MojiPond.resetUsageRanking"
    )
    static let mojiPondShowAliases = Notification.Name(
        "com.rajjoshi.MojiPond.showAliases"
    )
}
