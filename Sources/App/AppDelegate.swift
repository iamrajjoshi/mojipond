import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var welcomeWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        showWelcome()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "water.waves",
            accessibilityDescription: "MojiPond"
        )
        item.button?.toolTip = "MojiPond"

        let menu = NSMenu()
        menu.addItem(withTitle: "Open MojiPond", action: #selector(showWelcome), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MojiPond", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc
    private func showWelcome() {
        if let welcomeWindow {
            welcomeWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = NSHostingController(rootView: WelcomeView())
        let window = NSWindow(contentViewController: controller)
        window.title = "MojiPond"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 720, height: 480))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        welcomeWindow = window
    }
}

private struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "water.waves")
                .font(.system(size: 54, weight: .medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Welcome to MojiPond")
                    .font(.largeTitle.weight(.semibold))
                Text("Your pond for every emote.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Text("Type familiar shortcodes anywhere on your Mac, and keep your own custom emoji packs close at hand.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 470)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Label("Local first", systemImage: "lock.shield")
                Label("Keyboard driven", systemImage: "keyboard")
                Label("Custom packs", systemImage: "square.grid.2x2")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

