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
    @State private var destination: SettingsDestination
    @FocusState private var focusedDestination: SettingsDestination?
    @Environment(\.colorSchemeContrast) private var contrast
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
        ZStack {
            PondWindowBackdrop()

            HStack(spacing: 0) {
                sidebar

                Rectangle()
                    .fill(PondDesign.ripple.opacity(0.22))
                    .frame(width: 1)

                ScrollView {
                    VStack(
                        alignment: .leading,
                        spacing: PondDesign.sectionSpacing
                    ) {
                        PondPageHeader(
                            icon: destination.icon,
                            title: destination.rawValue,
                            detail: destination.detail
                        )

                        selectedPage
                    }
                    .frame(maxWidth: 600, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 22)
                }
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 4) {
                ForEach(SettingsDestination.allCases) { item in
                    Button {
                        destination = item
                        focusedDestination = item
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.icon)
                                .font(.system(size: 15, weight: .medium))
                                .frame(width: 21)
                            Text(item.rawValue)
                                .font(.callout.weight(.medium))
                            Spacer()
                        }
                        .foregroundStyle(
                            destination == item
                                ? AnyShapeStyle(Color.primary)
                                : AnyShapeStyle(.primary)
                        )
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(
                            destination == item
                                ? PondDesign.pond.opacity(
                                    contrast == .increased ? 0.24 : 0.11
                                )
                                : Color.clear,
                            in: RoundedRectangle(
                                cornerRadius: PondDesign.compactCornerRadius
                            )
                        )
                        .overlay {
                            if destination == item
                                && contrast == .increased {
                                RoundedRectangle(
                                    cornerRadius:
                                        PondDesign.compactCornerRadius
                                )
                                .stroke(PondDesign.pond, lineWidth: 2)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pondFocusEffectDisabled()
                    .focused($focusedDestination, equals: item)
                    .onMoveCommand(perform: moveSettingsDestination)
                    .accessibilityAddTraits(
                        destination == item ? .isSelected : []
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 16)

            Spacer(minLength: 20)

            Rectangle()
                .fill(PondDesign.ripple.opacity(0.16))
                .frame(height: 1)
                .padding(.horizontal, 14)

            if appState.isEnabled && !appState.canMonitorTyping {
                Button {
                    destination = .privacy
                } label: {
                    sidebarStatus
                }
                .buttonStyle(.plain)
                .help("Open Privacy settings")
                .accessibilityHint("Opens MojiPond Privacy settings")
            } else {
                sidebarStatus
            }
        }
        .frame(width: 176)
        .frame(maxHeight: .infinity)
        .background(PondDesign.sidebarSurface.opacity(0.9))
    }

    @ViewBuilder
    private var selectedPage: some View {
        switch destination {
        case .general:
            general
        case .shortcuts:
            shortcuts
        case .library:
            library
        case .privacy:
            privacy
        case .about:
            about
        }
    }

    private var general: some View {
        VStack(spacing: PondDesign.sectionSpacing) {
            SettingsCard {
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
                    Button("Open MojiPond Library") {
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
                    Button("Manage Aliases") {
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
                            }
                            .buttonStyle(.plain)
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
                        }
                        .buttonStyle(.plain)
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var triggerText: String {
        appState.preferences.shortcode.trigger.rawValue
    }

    private var triggerExample: String {
        "\(triggerText)wave\(triggerText)"
    }

    private var sidebarStatusColor: Color {
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

    private var sidebarStatusDetail: String {
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

    private var sidebarStatus: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(sidebarStatusColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(appState.statusSummary)
                    .font(.caption.weight(.semibold))
                Text(sidebarStatusDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var userApplicationExclusions: [ApplicationExclusion] {
        appState.preferences.exclusions.userApplications
    }

    private func moveSettingsDestination(
        _ direction: MoveCommandDirection
    ) {
        let destinations = SettingsDestination.allCases
        guard let currentIndex = destinations.firstIndex(
            of: focusedDestination ?? destination
        ) else {
            return
        }
        let nextIndex: Int
        switch direction {
        case .up:
            nextIndex = max(destinations.startIndex, currentIndex - 1)
        case .down:
            nextIndex = min(
                destinations.index(before: destinations.endIndex),
                currentIndex + 1
            )
        default:
            return
        }
        guard nextIndex != currentIndex else {
            return
        }
        destination = destinations[nextIndex]
        focusedDestination = destination
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
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(PondDesign.pond)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)

            Spacer(minLength: 10)
            accessory
                .fixedSize(horizontal: true, vertical: false)
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
