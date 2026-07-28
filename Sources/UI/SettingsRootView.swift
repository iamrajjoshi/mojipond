import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsRootView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var permissions: SystemPermissionCenter
    @ObservedObject private var updates: AppUpdateController
    @StateObject private var giphyKey: GiphyKeySettingsModel

    @State private var domainDraft = ""
    @State private var exclusionError: String?
    @State private var showsManualUpdateConfirmation = false
    @State private var showsNativeUpdateConfirmation = false

    init(
        appState: AppState,
        giphyKeyStore: any GiphyAPIKeyStoring =
            KeychainGiphyAPIKeyStore()
    ) {
        self.appState = appState
        permissions = appState.permissions
        updates = appState.updates
        _giphyKey = StateObject(
            wrappedValue: GiphyKeySettingsModel(
                store: giphyKeyStore
            )
        )
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
                    "Allow public GitHub pack imports",
                    isOn: preference(\.network.allowsGitHubImports)
                )
                Toggle(
                    "Allow /sticker downloads in Messages",
                    isOn: preference(\.network.allowsStickerSearch)
                )
                Toggle(
                    "Allow /gif search in Messages",
                    isOn: preference(\.network.allowsGIFSearch)
                )
                Toggle(
                    "Check for signed updates",
                    isOn: preference(\.network.allowsUpdateChecks)
                )
                Text(
                    "Online features are independent and off by default. "
                        + "GitHub imports send the requested repository URL; "
                        + "Noto sticker queries stay local after a fixed "
                        + "manifest download; GIPHY and update traffic are "
                        + "described in Privacy."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("GIPHY API key") {
                SecureField(
                    "Paste a GIPHY API key",
                    text: $giphyKey.draftKey
                )
                .accessibilityHint(
                    "The key is stored in Keychain and is never shown again."
                )

                HStack {
                    Label(
                        giphyKey.statusTitle,
                        systemImage: giphyKey.statusSymbolName
                    )
                    .foregroundStyle(
                        giphyKey.hasStoredKey
                            ? PondDesign.lily
                            : Color.secondary
                    )

                    Spacer()

                    Button("Remove", role: .destructive) {
                        giphyKey.remove()
                    }
                    .disabled(!giphyKey.hasStoredKey)

                    Button("Save to Keychain") {
                        giphyKey.save()
                    }
                    .disabled(
                        giphyKey.draftKey.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                    )
                }

                if case let .failed(message) = giphyKey.status {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(PondDesign.errorForeground)
                }

                Text(
                    "Used only for explicit /gif searches in Messages. "
                        + "When GIF search is enabled, MojiPond sends the "
                        + "exact query and this key to GIPHY. Preview "
                        + "renditions for displayed results and the selected "
                        + "original are requested directly and are not persisted. "
                        + "MojiPond does not invoke GIPHY action analytics."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            giphyKey.refresh()
        }
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
                    NotificationCenter.default.post(
                        name: .mojiPondResetUsageRanking,
                        object: nil
                    )
                }
            }

            Section("Portable packs") {
                Text(
                    "MojiPond supports individual files, folders, ZIPs, "
                        + "Slack-style emoji.json files, and public GitHub URLs."
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
                    detail: "Recognizes a bounded shortcode while you type.",
                    status: permissions.snapshot.inputMonitoring,
                    request: { permissions.requestInputMonitoring() }
                )
                PermissionSettingsRow(
                    title: "Accessibility",
                    detail: "Validates the caret and replaces your selection.",
                    status: permissions.snapshot.accessibility,
                    request: { permissions.requestAccessibility() }
                )
                PermissionSettingsRow(
                    title: "Event Posting",
                    detail: "Needed only to paste media into another app.",
                    status: permissions.snapshot.eventPosting,
                    request: { permissions.requestEventPosting() }
                )
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
                    Text("Your pond for every emote.")
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent(
                "Version",
                value: Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String ?? "Development"
            )
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
                    "Downloads the signed archive and verifies its digest, Developer ID signature, Team ID, hardened runtime, timestamp, and Gatekeeper status."
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
                        "Revalidating MojiPond \(metadata.version)…"
                    )
                }
            }
            if case let .launchingInstaller(metadata) = updates.state {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text(
                        "Starting the verified MojiPond \(metadata.version) installer…"
                    )
                }
            }
            if case let .staged(metadata, plan) = updates.state {
                Label(
                    "MojiPond \(metadata.version) passed every available verification.",
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
                            Text(
                                reason
                                    + " Destination: "
                                    + plan.destinationApplicationURL.path
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Button("Show Verified App in Finder…") {
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
            Text(
                "Production updates require a trusted signed feed and must "
                    + "be Developer ID signed, hardened, securely timestamped, "
                    + "and accepted by Gatekeeper. This local ad-hoc build "
                    + "intentionally cannot pass that policy."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Link(
                "View private source repository",
                destination: URL(
                    string: "https://github.com/iamrajjoshi/mojipond"
                )!
            )
            Text(
                "No accounts, telemetry, message database access, "
                    + "or background cloud storage."
            )
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Install the verified update and relaunch?",
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
                "MojiPond will revalidate the signed ZIP and both app identities, quit, perform a locked atomic replacement, verify the installed app, and relaunch it. If any post-replacement step fails, the previous app is restored."
            )
        }
        .confirmationDialog(
            "Prepare the verified app for manual installation?",
            isPresented: $showsManualUpdateConfirmation,
            titleVisibility: .visible
        ) {
            Button("Revalidate and Show in Finder") {
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
                "MojiPond will verify the signed ZIP and both app identities again. Then quit MojiPond, replace the installed copy at its existing location, and relaunch it."
            )
        }
    }

    private var triggerText: String {
        appState.preferences.shortcode.trigger.rawValue
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

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            PermissionStatusView(status: status)
            if status != .granted {
                Button("Allow", action: request)
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
