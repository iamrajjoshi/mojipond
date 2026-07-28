import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    private var statusItem: NSStatusItem?
    private var onboardingWindow: NSWindow?
    private var libraryWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appState.start()
        configureStatusItem()
        if appState.hasCompletedOnboarding {
            showLibrary()
        } else {
            showOnboarding()
        }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "water.waves",
            accessibilityDescription: "MojiPond"
        )
        item.button?.toolTip = "MojiPond"

        let menu = NSMenu()
        let enabledItem = NSMenuItem(
            title: "MojiPond Enabled",
            action: #selector(toggleEnabled),
            keyEquivalent: ""
        )
        enabledItem.state = appState.isEnabled ? .on : .off
        menu.addItem(enabledItem)
        menu.addItem(
            withTitle: appState.statusSummary,
            action: nil,
            keyEquivalent: ""
        ).isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Library", action: #selector(showLibrary), keyEquivalent: "o")
        menu.addItem(withTitle: "Setup & Permissions", action: #selector(showOnboarding), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MojiPond", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc
    private func toggleEnabled(_ sender: NSMenuItem) {
        appState.isEnabled.toggle()
        sender.state = appState.isEnabled ? .on : .off
        rebuildStatusMenu()
    }

    @objc
    private func showOnboarding() {
        if let onboardingWindow {
            onboardingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = NSHostingController(
            rootView: OnboardingView(appState: appState) { [weak self] in
                self?.onboardingWindow?.orderOut(nil)
                self?.showLibrary()
            }
        )
        let window = NSWindow(contentViewController: controller)
        window.title = "Set Up MojiPond"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 760, height: 570))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
    }

    @objc
    private func showLibrary() {
        if let libraryWindow {
            libraryWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = NSHostingController(
            rootView: LibraryShellView(appState: appState)
        )
        let window = NSWindow(contentViewController: controller)
        window.title = "MojiPond Library"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 960, height: 660))
        window.minSize = NSSize(width: 840, height: 560)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        libraryWindow = window
    }

    @objc
    private func showSettings() {
        NSApp.sendAction(
            Selector(("showSettingsWindow:")),
            to: nil,
            from: nil
        )
        NSApp.activate(ignoringOtherApps: true)
    }

    private func rebuildStatusMenu() {
        statusItem?.menu = nil
        statusItem = nil
        configureStatusItem()
    }
}
