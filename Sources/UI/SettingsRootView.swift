import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum UsageRankingResetNotice {
    static let success = "Recents and usage ranking were reset."
    static let failure = "Usage ranking could not be reset."
}

struct SettingsRootView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var permissions: SystemPermissionCenter
    @ObservedObject private var updates: AppUpdateController

    @State private var domainDraft = ""
    @State private var exclusionError: String?
    @State private var permissionNavigationError: String?
    @State private var showsUsageResetConfirmation = false
    @State private var showsManualUpdateConfirmation = false
    @State private var showsNativeUpdateConfirmation = false
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
        TabView {
            general
                .tabItem { Label("General", systemImage: "gear") }
            shortcuts
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            library
                .tabItem { Label("Library", systemImage: "square.grid.2x2") }
            privacy
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
            about
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(14)
        .frame(
            minWidth: 620,
            idealWidth: 680,
            minHeight: 500,
            idealHeight: 540
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

    private var general: some View {
        Form {
            Section {
                Toggle(
                    "Enable MojiPond",
                    isOn: Binding(
                        get: { appState.isEnabled },
                        set: { appState.setEnabled($0) }
                    )
                )
                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { appState.launchAtLoginEnabled },
                        set: { appState.setLaunchAtLogin($0) }
                    )
                )
                if let error = appState.launchAtLoginError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(PondDesign.warningForeground)
                }
            }

            Section("Online features") {
                Toggle(
                    "Allow /sticker downloads in Messages",
                    isOn: preference(\.network.allowsStickerSearch)
                )
                if updates.canCheckForUpdates {
                    Toggle(
                        "Check for signed updates",
                        isOn: preference(\.network.allowsUpdateChecks)
                    )
                }
                Text(
                    updates.canCheckForUpdates
                        ? "Sticker downloads and update checks are off by default."
                        : "Sticker downloads are off by default."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var shortcuts: some View {
        Form {
            Picker(
                "Shortcode trigger",
                selection: preference(\.shortcode.trigger)
            ) {
                ForEach(ShortcodeTrigger.allCases, id: \.self) { trigger in
                    Text(trigger.rawValue).tag(trigger)
                }
            }

            Picker(
                "Default skin tone",
                selection: preference(\.defaultSkinTone)
            ) {
                Text("Automatic").tag(EmojiSkinTone?.none)
                ForEach(EmojiSkinTone.allCases, id: \.self) { tone in
                    Text("\(tone.modifier) \(tone.displayName)")
                        .tag(Optional(tone))
                }
            }

            Section("Suggestions") {
                Toggle(
                    "Show suggestions on a bare trigger",
                    isOn: preference(
                        \.shortcode.showsSuggestionsOnBareTrigger
                    )
                )
                Toggle(
                    "Accept with Tab",
                    isOn: preference(\.shortcode.acceptsTab)
                )
                Toggle(
                    "Accept with Return",
                    isOn: preference(\.shortcode.acceptsReturn)
                )
                Toggle(
                    "Replace an exact closing token",
                    isOn: preference(
                        \.shortcode.replacesOnExactClosingTrigger
                    )
                )
                Toggle(
                    "Open the browser with \(triggerText)\(triggerText)",
                    isOn: preference(
                        \.shortcode.opensBrowserOnDoubleTrigger
                    )
                )
            }

            LabeledContent("Example") {
                Text("\(triggerText)lizard\(triggerText) → 🦎")
                    .fontDesign(.monospaced)
            }
        }
        .formStyle(.grouped)
    }

    private var library: some View {
        Form {
            Section("Local data") {
                Text(
                    "Imported packs, aliases, favorites, and ranking stay on "
                        + "this Mac. Pack assets are copied into managed "
                        + "Application Support storage."
                )
                .foregroundStyle(.secondary)
                Button("Open MojiPond Library") {
                    NotificationCenter.default.post(
                        name: .mojiPondShowLibrary,
                        object: nil
                    )
                }
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
                }
            }

            Section("Portable packs") {
                Text(
                    "The Library imports one local ZIP archive at a time and "
                        + "shows a review before installing it."
                )
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var privacy: some View {
        Form {
            Section("System permissions") {
                PermissionSettingsRow(
                    title: "Input Monitoring",
                    detail:
                        "Observes global key events for one bounded shortcode. "
                        + "Unrelated keys are discarded; typing is not saved.",
                    status: permissions.snapshot.inputMonitoring,
                    request: { permissions.requestInputMonitoring() },
                    openSettings: {
                        openPermissionSettings(.inputMonitoring)
                    }
                )
                PermissionSettingsRow(
                    title: "Accessibility",
                    detail:
                        "Reads bounded text and caret position to show "
                        + "suggestions and replace your shortcode. Message "
                        + "text is not saved.",
                    status: permissions.snapshot.accessibility,
                    request: { permissions.requestAccessibility() },
                    openSettings: {
                        openPermissionSettings(.accessibility)
                    }
                )
                PermissionSettingsRow(
                    title: "Send & Media Pasting",
                    detail:
                        "Optional. Pastes custom images in Messages and "
                        + "preserves Return after insertion. macOS lists "
                        + "this access under Accessibility.",
                    status: permissions.snapshot.eventPosting,
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
                }
            }

            Section("Excluded apps") {
                ForEach(appState.preferences.exclusions.applications) { app in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.displayName)
                            Text(app.bundleIdentifier)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if app.bundleIdentifier
                            != Bundle.main.bundleIdentifier?.lowercased() {
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
                    }
                }
                Button("Add Application…", action: chooseExcludedApplication)
            }

            Section("Excluded websites") {
                ForEach(appState.preferences.exclusions.domains) { domain in
                    HStack {
                        Text(domain.domain)
                        Spacer()
                        Text(domain.includesSubdomains ? "Includes subdomains" : "Exact host")
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
                }
                HStack {
                    TextField("example.com", text: $domainDraft)
                        .onSubmit(addDomainExclusion)
                    Button("Add", action: addDomainExclusion)
                        .disabled(domainDraft.isEmpty)
                }
                if let exclusionError {
                    Text(exclusionError)
                        .font(.caption)
                        .foregroundStyle(PondDesign.warningForeground)
                }
                Text(
                    "Domain exclusions apply only in browsers where MojiPond "
                        + "can safely identify the active host."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var about: some View {
        Form {
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
        .formStyle(.grouped)
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
        permissionNavigationError =
            permissionSettingsOpener.openSettings(for: permission)
                ? nil
                : "Could not open System Settings. Open Privacy & Security manually."
    }

    private func addDomainExclusion() {
        guard let exclusion = DomainExclusion(domain: domainDraft) else {
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

private struct PermissionSettingsRow: View {
    let title: String
    let detail: String
    let status: SystemPermissionStatus
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            PermissionStatusView(permissionName: title, status: status)
            switch status.primaryAction {
            case .request:
                Button("Allow", action: request)
                    .accessibilityLabel("Allow \(title)")
            case .openSettings:
                Button("Open Settings", action: openSettings)
                    .accessibilityLabel("Open \(title) Settings")
            case nil:
                EmptyView()
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
}
