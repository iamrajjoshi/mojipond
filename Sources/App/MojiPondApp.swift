import SwiftUI

@main
struct MojiPondApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsPlaceholderView()
        }
    }
}

private struct SettingsPlaceholderView: View {
    var body: some View {
        ContentUnavailableView {
            Label("MojiPond is getting ready", systemImage: "water.waves")
        } description: {
            Text("Open MojiPond from the menu bar.")
        }
        .frame(width: 520, height: 360)
    }
}

