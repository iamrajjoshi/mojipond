import SwiftUI

struct SettingsRootView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var permissions: SystemPermissionCenter

    @AppStorage("shortcuts.trigger") private var trigger = ":"
    @AppStorage("shortcuts.acceptTab") private var acceptTab = true
    @AppStorage("shortcuts.acceptReturn") private var acceptReturn = true
    @AppStorage("shortcuts.exactReplacement") private var exactReplacement = true
    @AppStorage("shortcuts.doubleTriggerBrowser") private var doubleTriggerBrowser = true
    @AppStorage("media.stickersEnabled") private var stickersEnabled = true
    @AppStorage("media.giphyEnabled") private var giphyEnabled = false

    init(appState: AppState) {
        self.appState = appState
        permissions = appState.permissions
    }

    var body: some View {
        TabView {
            Form {
                Toggle("Enable MojiPond", isOn: $appState.isEnabled)
                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { appState.launchAtLoginEnabled },
                        set: { appState.setLaunchAtLogin($0) }
                    )
                )
                if let error = appState.launchAtLoginError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Section("Online media") {
                    Toggle("Enable /sticker in Messages", isOn: $stickersEnabled)
                    Toggle("Enable /gif in Messages", isOn: $giphyEnabled)
                    Text("GIF search is optional and sends only your explicit search term to GIPHY.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gear") }

            Form {
                Picker("Trigger", selection: $trigger) {
                    ForEach([":", ";", "/", "\\", "@", "#", "~", "|"], id: \.self) {
                        Text($0).tag($0)
                    }
                }
                Toggle("Accept with Tab", isOn: $acceptTab)
                Toggle("Accept with Return", isOn: $acceptReturn)
                Toggle("Replace exact closing tokens", isOn: $exactReplacement)
                Toggle("Open browser with \(trigger)\(trigger)", isOn: $doubleTriggerBrowser)
            }
            .formStyle(.grouped)
            .tabItem { Label("Shortcuts", systemImage: "keyboard") }

            Form {
                PermissionSettingsRow(
                    title: "Input Monitoring",
                    status: permissions.snapshot.inputMonitoring,
                    request: { permissions.requestInputMonitoring() }
                )
                PermissionSettingsRow(
                    title: "Accessibility",
                    status: permissions.snapshot.accessibility,
                    request: { permissions.requestAccessibility() }
                )
                Section("Exclusions") {
                    Text("Password fields, terminals, virtual machines, Slack, and Discord are ignored by default.")
                        .foregroundStyle(.secondary)
                    Button("Manage Excluded Apps…") {}
                    Button("Manage Excluded Websites…") {}
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Privacy", systemImage: "hand.raised") }

            Form {
                LabeledContent("Version", value: "0.1.0")
                LabeledContent("Updates", value: "Disabled until a signed feed is configured")
                Link("View source repository", destination: URL(string: "https://github.com/iamrajjoshi/mojipond")!)
                Text("Your pond for every emote.")
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(14)
        .frame(width: 620, height: 460)
    }
}

private struct PermissionSettingsRow: View {
    let title: String
    let status: SystemPermissionStatus
    let request: () -> Void

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            PermissionStatusView(status: status)
            if status != .granted {
                Button("Allow", action: request)
            }
        }
    }
}

