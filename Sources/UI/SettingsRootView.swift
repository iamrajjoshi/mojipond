import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum UsageRankingResetNotice {
    static let success = "Recents and usage ranking were reset."
    static let failure = "Usage ranking could not be reset."
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
            "Control when MojiPond runs and when it goes online."
        case .shortcuts:
            "Choose how suggestions open and how emoji are inserted."
        case .library:
            "Manage packs, aliases, favorites, and recents."
        case .privacy:
            "Review permissions and places where suggestions stay off."
        case .about:
            "Version, updates, and local processing details."
        }
    }
}

struct SettingsRootView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var permissions: SystemPermissionCenter
    @ObservedObject private var updates: AppUpdateController

    @State private var domainDraft = ""
    @State private var domainIncludesSubdomains = true
    @State private var exclusionError: String?
    @State private var permissionNavigationError: String?
    @State private var showsUsageResetConfirmation = false
    @State private var showsManualUpdateConfirmation = false
    @State private var showsNativeUpdateConfirmation = false
    @State private var destination = SettingsDestination.general
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
                    VStack(alignment: .leading, spacing: 22) {
                        PondPageHeader(
                            icon: destination.icon,
                            title: destination.rawValue,
                            detail: destination.detail
                        )

                        selectedPage
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(28)
                }
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .tint(PondDesign.pond)
        .frame(
            minWidth: 760,
            idealWidth: 820,
            minHeight: 560,
            idealHeight: 640
        )
        .confirmationDialog(
            "Reset recents and usage ranking?",
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
                "This removes recent emoji and learned ranking. "
                    + "Favorites and preferred skin tones stay unchanged."
            )
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                PondMark(size: 42)
                VStack(alignment: .leading, spacing: 1) {
                    Text("MojiPond")
                        .font(.headline)
                    Text("SETTINGS")
                        .font(.caption2.weight(.semibold))
                        .tracking(1.2)
                        .foregroundStyle(PondDesign.pond)
                }
                Spacer()
                Circle()
                    .fill(PondDesign.lotus)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 18)

            VStack(spacing: 5) {
                ForEach(SettingsDestination.allCases) { item in
                    Button {
                        destination = item
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
                                ? AnyShapeStyle(PondDesign.pond)
                                : AnyShapeStyle(.primary)
                        )
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .background(
                            destination == item
                                ? PondDesign.ripple.opacity(0.16)
                                : Color.clear,
                            in: RoundedRectangle(
                                cornerRadius: PondDesign.compactCornerRadius
                            )
                        )
                        .overlay {
                            if destination == item {
                                RoundedRectangle(
                                    cornerRadius:
                                        PondDesign.compactCornerRadius
                                )
                                .stroke(
                                    PondDesign.ripple.opacity(0.35),
                                    lineWidth: 1
                                )
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(
                        destination == item ? .isSelected : []
                    )
                }
            }
            .padding(.horizontal, 12)

            Spacer(minLength: 20)

            HStack(spacing: 9) {
                Circle()
                    .fill(
                        appState.isEnabled
                            ? PondDesign.lily
                            : Color.secondary
                    )
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(appState.isEnabled ? "Ready to type" : "Paused")
                        .font(.caption.weight(.semibold))
                    Text(
                        appState.isEnabled
                            ? triggerExample
                            : "Suggestions are off"
                    )
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                PondDesign.surface.opacity(0.72),
                in: RoundedRectangle(
                    cornerRadius: PondDesign.compactCornerRadius
                )
            )
            .padding(12)
        }
        .frame(width: 205)
        .frame(maxHeight: .infinity)
        .background(PondDesign.sidebarSurface.opacity(0.94))
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
        VStack(spacing: 16) {
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
                    detail: "Keep MojiPond ready after you sign in."
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

            SettingsCard(
                title: "Stickers in Messages",
                detail:
                    "Built-in stickers stay available offline. Turn this on to fetch more Noto artwork."
            ) {
                SettingsRow(
                    icon: "face.smiling.inverse",
                    title: "Online sticker results",
                    detail: "Type /sticker in Messages to search."
                ) {
                    HStack(spacing: 10) {
                        PondCommandToken(value: "/sticker")
                        Toggle(
                            "Allow /sticker downloads in Messages",
                            isOn: preference(
                                \.network.allowsStickerSearch
                            )
                        )
                        .labelsHidden()
                        .accessibilityLabel(
                            "Allow /sticker downloads in Messages"
                        )
                        .toggleStyle(.switch)
                        .tint(PondDesign.lily)
                    }
                }
            }

            if updates.canCheckForUpdates {
                SettingsCard(title: "Updates") {
                    SettingsRow(
                        icon: "arrow.triangle.2.circlepath",
                        title: "Check for signed updates",
                        detail:
                            "Ask before downloading or installing anything."
                    ) {
                        Toggle(
                            "Check for signed updates",
                            isOn: preference(
                                \.network.allowsUpdateChecks
                            )
                        )
                        .labelsHidden()
                        .accessibilityLabel("Check for signed updates")
                        .toggleStyle(.switch)
                        .tint(PondDesign.lily)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shortcuts: some View {
        VStack(spacing: 16) {
            SettingsCard(
                title: "Acceptance",
                detail: "Choose the keys that insert the selected emoji."
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
                title: "Trigger",
                detail: "The punctuation mark that starts a shortcode."
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
                detail:
                    "Typing both punctuation marks can replace an exact match immediately."
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
        VStack(spacing: 16) {
            SettingsCard(
                title: "Emoji library",
                detail:
                    "Browse built-in emoji, imported ZIP packs, favorites, and local aliases."
            ) {
                SettingsActionRow(
                    icon: "square.grid.2x2",
                    title: "Open the full library",
                    detail: "Search, preview, import, and edit emoji."
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
                    detail:
                        "Map another shortcode to any emoji without changing its pack."
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
                detail: "Your packs and preferences stay on this Mac."
            ) {
                Text(
                    "Imported assets are copied into MojiPond’s Application Support folder."
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                SettingsDivider()

                Button("Reset recents and usage ranking", role: .destructive) {
                    showsUsageResetConfirmation = true
                }
                if let notice = appState.runtimeNotice,
                   notice == UsageRankingResetNotice.success
                    || notice == UsageRankingResetNotice.failure {
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
        VStack(spacing: 16) {
            SettingsCard(
                title: "System permissions",
                detail:
                    "MojiPond asks only for access needed while you type."
            ) {
                PermissionSettingsRow(
                    title: "Input Monitoring",
                    detail: "Notices when you type an emoji shortcut.",
                    status: permissions.snapshot.inputMonitoring,
                    request: { permissions.requestInputMonitoring() },
                    openSettings: {
                        openPermissionSettings(.inputMonitoring)
                    }
                )

                SettingsDivider()

                PermissionSettingsRow(
                    title: "Accessibility",
                    detail:
                        "Finds the active text field and inserts the emoji you choose.",
                    status: permissions.snapshot.accessibility,
                    request: { permissions.requestAccessibility() },
                    openSettings: {
                        openPermissionSettings(.accessibility)
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
                detail:
                    "MojiPond will not show suggestions in apps you add here."
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
            }

            SettingsCard(
                title: "Disabled websites",
                detail:
                    "Supported browsers include subdomains unless you choose an exact host."
            ) {
                ForEach(appState.preferences.exclusions.domains) { domain in
                    HStack {
                        Text(domain.domain)
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
                        .onSubmit(addDomainExclusion)
                    Toggle(
                        "Include subdomains",
                        isOn: $domainIncludesSubdomains
                    )
                    .toggleStyle(.checkbox)
                    Button("Add", action: addDomainExclusion)
                        .disabled(domainDraft.isEmpty)
                }
                if let exclusionError {
                    Text(exclusionError)
                        .font(.caption)
                        .foregroundStyle(PondDesign.warningForeground)
                }
                Text(
                    "If the active website cannot be identified, MojiPond stays off."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            SettingsCard(
                title: "Always disabled",
                detail: "For safety, these app groups cannot be enabled."
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
                    "Slack and Discord, which provide their own emoji shortcuts",
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
            if updates.canCheckForUpdates {
                LabeledContent("Updates", value: updates.statusSummary)
                if case let .failed(message) = updates.state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(PondDesign.errorForeground)
                }
                if let metadata = updates.availableMetadata,
                   let releaseNotesURL = metadata.releaseNotesURL {
                    Link(
                        "Read release notes for \(metadata.version)",
                        destination: releaseNotesURL
                    )
                }
                if case let .available(metadata) = updates.state {
                    Button(
                        "Download & Verify MojiPond \(metadata.version)…"
                    ) {
                        updates.stageAvailableUpdate()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint(
                        "Downloads and verifies the update before installation."
                    )
                }
                if case let .staging(metadata) = updates.state {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text(
                            "Downloading and verifying MojiPond \(metadata.version)…"
                        )
                    }
                }
                if case let .revalidating(metadata) = updates.state {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text(
                            "Verifying MojiPond \(metadata.version)…"
                        )
                    }
                }
                if case let .launchingInstaller(metadata) = updates.state {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text(
                            "Starting the MojiPond \(metadata.version) installer…"
                        )
                    }
                }
                if case let .staged(metadata, _) = updates.state {
                    Label(
                        "MojiPond \(metadata.version) is ready to install.",
                        systemImage: "checkmark.shield.fill"
                    )
                    .foregroundStyle(PondDesign.lily)
                    if let installationStatusMessage =
                        updates.installationStatusMessage {
                        Text(installationStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        switch updates.nativeInstallAvailability {
                        case .available:
                            Button("Install & Relaunch…") {
                                showsNativeUpdateConfirmation = true
                            }
                            .buttonStyle(.borderedProminent)
                        case let .manualInstallRequired(reason):
                            VStack(alignment: .leading, spacing: 6) {
                                Text(reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("Show in Finder…") {
                                    showsManualUpdateConfirmation = true
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        case let .unavailable(reason):
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(PondDesign.errorForeground)
                        case .none:
                            EmptyView()
                        }
                        Button("Discard Download", role: .destructive) {
                            updates.discardStagedUpdate()
                        }
                    }
                }
                Button(
                    updates.isChecking ? "Checking…" : "Check for Updates…"
                ) {
                    updates.checkManually(
                        automaticChecksEnabled:
                        appState.preferences.network.allowsUpdateChecks
                    )
                }
                .disabled(updates.isBusy)
            }
            Text(
                "Shortcodes are processed on this Mac. MojiPond does not "
                    + "save your messages or require an account."
            )
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog(
            "Install the update and relaunch?",
            isPresented: $showsNativeUpdateConfirmation,
            titleVisibility: .visible
        ) {
            Button("Install & Relaunch") {
                Task {
                    if await updates.installAndRelaunch() {
                        NSApp.terminate(nil)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "MojiPond will install the update and relaunch. If installation "
                    + "fails, the current version is restored."
            )
        }
        .confirmationDialog(
            "Show the update in Finder?",
            isPresented: $showsManualUpdateConfirmation,
            titleVisibility: .visible
        ) {
            Button("Show in Finder") {
                Task {
                    guard let plan =
                        await updates.revalidateInstallation() else {
                        return
                    }
                    NSWorkspace.shared.activateFileViewerSelecting([
                        plan.stagedApplicationURL
                    ])
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "MojiPond will check the update again, then show it in Finder."
            )
        }
    }

    private var triggerText: String {
        appState.preferences.shortcode.trigger.rawValue
    }

    private var triggerExample: String {
        "\(triggerText)wave\(triggerText)"
    }

    private var userApplicationExclusions: [ApplicationExclusion] {
        appState.preferences.exclusions.userApplications
    }

    private func clearUsageResetNotice() {
        guard
            appState.runtimeNotice == UsageRankingResetNotice.success
                || appState.runtimeNotice == UsageRankingResetNotice.failure
        else {
            return
        }
        appState.setRuntimeNotice(nil)
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
        appState.updatePreferences {
            guard !$0.exclusions.applications.contains(
                where: { $0.id == exclusion.id }
            ) else {
                return
            }
            $0.exclusions.applications.append(exclusion)
        }
    }

    private func removeApplicationExclusion(_ id: String) {
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
        appState.updatePreferences {
            guard !$0.exclusions.domains.contains(
                where: { $0.id == exclusion.id }
            ) else {
                return
            }
            $0.exclusions.domains.append(exclusion)
        }
        domainDraft = ""
        exclusionError = nil
    }

    private func removeDomainExclusion(_ id: String) {
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
        PondCard {
            VStack(alignment: .leading, spacing: 12) {
                if let title {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.headline)
                        if let detail {
                            Text(detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(
                                    horizontal: false,
                                    vertical: true
                                )
                        }
                    }
                    .padding(.bottom, 2)
                }

                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SettingsRow<Accessory: View>: View {
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
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PondDesign.pond)
                .frame(width: 30, height: 30)
                .background(
                    PondDesign.pond.opacity(0.1),
                    in: RoundedRectangle(
                        cornerRadius: PondDesign.compactCornerRadius
                    )
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 14)
            accessory
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
            .fill(PondDesign.ripple.opacity(0.16))
            .frame(height: 1)
            .padding(.leading, 42)
            .accessibilityHidden(true)
    }
}

private extension ShortcodeTrigger {
    var settingsTitle: String {
        "\(rawValue)  \(accessibilityName)"
    }
}

private struct PermissionSettingsRow: View {
    let title: String
    let detail: String
    let status: SystemPermissionStatus
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(
                systemName:
                    title == "Accessibility"
                        ? "accessibility"
                        : "keyboard"
            )
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(
                status == .granted
                    ? PondDesign.lily
                    : PondDesign.pond
            )
            .frame(width: 30, height: 30)
            .background(
                (status == .granted
                    ? PondDesign.lily
                    : PondDesign.pond).opacity(0.1),
                in: RoundedRectangle(
                    cornerRadius: PondDesign.compactCornerRadius
                )
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            PermissionStatusView(permissionName: title, status: status)
            ForEach(status.availableActions, id: \.self) { action in
                switch action {
                case .request:
                    Button("Request Access", action: request)
                        .accessibilityLabel("Request \(title) Access")
                case .openSettings:
                    Button("Open Settings", action: openSettings)
                        .accessibilityLabel("Open \(title) Settings")
                }
            }
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
