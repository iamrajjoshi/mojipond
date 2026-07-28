import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    private var statusItem: NSStatusItem?
    private var onboardingWindow: NSWindow?
    private var libraryWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var runtimeController: MojiPondRuntimeController?
    private var usageStore: FileEmojiUsageStore?
    private(set) var libraryStore: LibraryStore?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if printPermissionDiagnosticIfRequested() {
            NSApp.terminate(nil)
            return
        }

        appState.start()
        configureApplicationServices()
        observeApplicationState()
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
            systemSymbolName: statusSymbolName,
            accessibilityDescription: "MojiPond"
        )
        item.button?.toolTip = "MojiPond — \(appState.statusSummary)"

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
        if let notice = appState.runtimeNotice {
            menu.addItem(
                withTitle: notice,
                action: nil,
                keyEquivalent: ""
            ).isEnabled = false
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Library", action: #selector(showLibrary), keyEquivalent: "o")
        menu.addItem(
            withTitle: "Open Emoji Browser",
            action: #selector(openEmojiBrowser),
            keyEquivalent: "b"
        )
        menu.addItem(withTitle: "Setup & Permissions", action: #selector(showOnboarding), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MojiPond", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc
    private func toggleEnabled(_ sender: NSMenuItem) {
        appState.setEnabled(!appState.isEnabled)
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
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = NSHostingController(
            rootView: SettingsRootView(appState: appState)
        )
        let window = NSWindow(contentViewController: controller)
        window.title = "MojiPond Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 680, height: 540))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    @objc
    private func openEmojiBrowser() {
        runtimeController?.openBrowser()
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtimeController?.stop()
        appState.permissions.stopLiveUpdates()
    }

    private func rebuildStatusMenu() {
        statusItem?.menu = nil
        statusItem = nil
        configureStatusItem()
    }

    private var statusSymbolName: String {
        if !appState.isEnabled {
            return "pause.circle"
        }
        if !appState.canMonitorTyping {
            return "exclamationmark.circle"
        }
        if case .failed = appState.runtimeState {
            return "exclamationmark.triangle"
        }
        return "water.waves"
    }

    private func configureApplicationServices() {
        do {
            let paths = try ApplicationPaths.live()
            let usage = try FileEmojiUsageStore(fileURL: paths.usageFile)
            let library = LibraryStore(rootURL: paths.libraryRoot)
            let runtime = try MojiPondRuntimeController(
                preferences: appState.preferences,
                usageStore: usage
            )

            usageStore = usage
            libraryStore = library
            runtimeController = runtime
            runtime.onDiagnostic = { [weak self] diagnostic in
                self?.handleRuntimeDiagnostic(diagnostic)
            }
            runtime.start()

            Task { [weak self] in
                await self?.reloadRuntimeCatalog()
            }
        } catch {
            appState.setRuntimeState(.failed(error.localizedDescription))
            appState.setRuntimeNotice(
                "Startup failed. Open Setup & Permissions for details."
            )
        }
    }

    private func observeApplicationState() {
        appState.$preferences
            .removeDuplicates()
            .sink { [weak self] preferences in
                self?.runtimeController?.updatePreferences(preferences)
            }
            .store(in: &cancellables)

        appState.permissions.$snapshot
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.runtimeController?.permissionStateDidChange()
            }
            .store(in: &cancellables)

        runtimeController?.$state
            .removeDuplicates()
            .sink { [weak self] state in
                self?.appState.setRuntimeState(state)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(
            appState.$preferences,
            appState.permissions.$snapshot,
            appState.$runtimeState
        )
        .debounce(for: .milliseconds(75), scheduler: RunLoop.main)
        .sink { [weak self] _ in
            self?.rebuildStatusMenu()
        }
        .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .mojiPondShowLibrary)
            .sink { [weak self] _ in
                self?.showLibrary()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(
            for: .mojiPondResetUsageRanking
        )
        .sink { [weak self] _ in
            guard let self, let usageStore = self.usageStore else {
                return
            }
            Task {
                do {
                    try await usageStore.resetUsageRanking()
                    await MainActor.run {
                        self.runtimeController?.reloadUsageSnapshot()
                        self.appState.setRuntimeNotice(
                            "Recents and usage ranking were reset."
                        )
                    }
                } catch {
                    await MainActor.run {
                        self.appState.setRuntimeNotice(
                            "Usage ranking could not be reset."
                        )
                    }
                }
            }
        }
        .store(in: &cancellables)
    }

    private func reloadRuntimeCatalog() async {
        guard let libraryStore, let runtimeController else {
            return
        }
        do {
            let builtIn = try BuiltInRuntimeCatalogLoader().loadPack()
            let library = try await libraryStore.snapshot()
            let priorities = Dictionary(
                uniqueKeysWithValues: library.packs.map {
                    ($0.id, 10_000 - $0.priority)
                }
            )
            let custom = try EmojiLibrarySearchAdapter.catalog(
                from: library.packs,
                priorityByPackID: priorities
            )
            runtimeController.updateSearchIndex(
                EmojiSearchIndex(packs: [builtIn] + custom)
            )
        } catch {
            appState.setRuntimeNotice(
                "The custom library could not be loaded."
            )
        }
    }

    private func handleRuntimeDiagnostic(
        _ diagnostic: MojiPondRuntimeDiagnostic
    ) {
        switch diagnostic {
        case .eventTapStarted:
            appState.setRuntimeNotice(nil)
        case .eventTapRepeatedDisablement:
            appState.setRuntimeNotice(
                "Typing monitor was paused after repeated system timeouts."
            )
        case .eventTapCreationFailed, .startupFailed:
            appState.setRuntimeNotice(
                "The typing monitor could not start."
            )
        case .permissionUnavailable:
            appState.setRuntimeNotice(
                "Input Monitoring and Accessibility are required for typing."
            )
        case .unsupportedTarget:
            appState.setRuntimeNotice(
                "This field cannot be edited safely; the token was left intact."
            )
        case let .sessionDenied(denial):
            appState.setRuntimeNotice(runtimeNotice(for: denial))
        case .catalogLoadFailed:
            appState.setRuntimeNotice(
                "The built-in emoji catalog could not be loaded."
            )
        case .eventTapStopped,
             .eventTapDisabledByTimeout,
             .eventTapDisabledByUserInput:
            break
        }
    }

    private func runtimeNotice(for denial: RuntimeSessionDenial) -> String {
        switch denial {
        case .permissionUnavailable:
            "Permissions are currently unavailable."
        case .secureEventInput, .secureField, .secureStatusUnknown:
            "MojiPond is suspended in secure text fields."
        case .applicationUnknown:
            "MojiPond could not verify this app safely."
        case .excludedApplication:
            "MojiPond is paused in this excluded app."
        case .excludedDomain:
            "MojiPond is paused on this excluded website."
        }
    }

    private func printPermissionDiagnosticIfRequested() -> Bool {
        guard ProcessInfo.processInfo.arguments.contains(
            "--print-permissions-and-quit"
        ) else {
            return false
        }

        appState.permissions.refresh()
        let snapshot = appState.permissions.snapshot
        let object: [String: String] = [
            "inputMonitoring": snapshot.inputMonitoring.rawValue,
            "accessibility": snapshot.accessibility.rawValue,
            "eventPosting": snapshot.eventPosting.rawValue
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        }
        return true
    }
}
