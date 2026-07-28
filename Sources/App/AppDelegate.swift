import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState: AppState

    private var statusItem: NSStatusItem?
    private var onboardingWindow: NSWindow?
    private var libraryWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var uiTestSurfaceWindow: NSWindow?
    private var uiTestSuggestionController:
        RuntimeSuggestionPanelController?
    private var runtimeController: MojiPondRuntimeController?
    private var usageStore: FileEmojiUsageStore?
    private(set) var libraryStore: LibraryStore?
    private var libraryViewModel: LibraryViewModel?
    private var pendingMediaCopyFallback:
        RuntimeMediaCopyFallbackDiagnostic?
    private var cancellables = Set<AnyCancellable>()
    private let launchConfiguration: AppLaunchConfiguration

    override init() {
        let launchConfiguration = AppLaunchConfiguration.current
        self.launchConfiguration = launchConfiguration
        appState = launchConfiguration.makeAppState()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains(
            NativeUpdateInstallRequest.launchArgument
        ) {
            guard let request = NativeUpdateInstallRequest.parse(
                arguments: arguments
            ) else {
                showInstallerFailure(
                    NativeUpdateInstallError.unsafeInstallLayout,
                    revealCandidate: false
                )
                return
            }
            runNativeUpdateInstaller(request)
            return
        }

        let updateReadinessRequest:
            NativeUpdateReadinessRequest?
        if arguments.contains(
            NativeUpdateReadinessRequest.launchArgument
        ) {
            guard let request = NativeUpdateReadinessRequest.parse(
                arguments: arguments
            ) else {
                NSApp.terminate(nil)
                return
            }
            updateReadinessRequest = request
        } else {
            updateReadinessRequest = nil
        }

        if printPermissionDiagnosticIfRequested() {
            NSApp.terminate(nil)
            return
        }

        if launchConfiguration.isUITesting {
            if let appearance = launchConfiguration.uiTestAppearance {
                NSApp.appearance = NSAppearance(
                    named: appearance == .light
                        ? .aqua
                        : .darkAqua
                )
            }
            configureUITestServices()
            configureStatusItem()
            switch launchConfiguration.initialScreen {
            case .library:
                showLibrary()
            case .settings:
                showSettings()
            case .importPreview:
                showUITestImportPreview()
            case .suggestions:
                showUITestSuggestionSurface(mode: .suggestions)
            case .browser:
                showUITestSuggestionSurface(mode: .browser)
            case .onboarding, .none:
                showOnboarding()
            }
            return
        }

        if
            ProcessInfo.processInfo.environment[
                "XCTestConfigurationFilePath"
            ] == nil
        {
            AdaptiveGlyphPayloadService.shared.prewarmEncoder()
        }
        appState.start()
        let servicesStarted = configureApplicationServices()
        observeApplicationState()
        configureStatusItem()
        switch launchConfiguration.initialPresentation(
            hasCompletedOnboarding:
                appState.hasCompletedOnboarding
        ) {
        case .library:
            showLibrary()
        case .onboarding:
            showOnboarding()
        case .statusItemOnly:
            break
        }
        if let updateReadinessRequest {
            guard servicesStarted, statusItem != nil else {
                NSApp.terminate(nil)
                return
            }
            do {
                try SystemNativeUpdateReadinessCoordinator.signal(
                    updateReadinessRequest,
                    applicationURL: Bundle.main.bundleURL
                )
            } catch {
                NSApp.terminate(nil)
            }
        }
    }

    private func runNativeUpdateInstaller(
        _ request: NativeUpdateInstallRequest
    ) {
        let candidateURL = Bundle.main.bundleURL
        let engine = NativeUpdateInstallerEngine()
        Task.detached {
            do {
                _ = try await engine.install(
                    request: request,
                    candidateApplicationURL: candidateURL
                )
                await MainActor.run {
                    NSApp.terminate(nil)
                }
            } catch {
                await MainActor.run {
                    self.showInstallerFailure(
                        error,
                        revealCandidate:
                            error as? NativeUpdateInstallError
                                == .destinationNotWritable
                    )
                }
            }
        }
    }

    private func showInstallerFailure(
        _ error: Error,
        revealCandidate: Bool
    ) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "MojiPond could not finish the update"
        alert.informativeText =
            (error as? LocalizedError)?.errorDescription
                ?? "The installed app was left unchanged."
        alert.alertStyle = .critical
        if revealCandidate {
            alert.addButton(withTitle: "Show Verified App in Finder")
            alert.addButton(withTitle: "Close")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([
                    Bundle.main.bundleURL
                ])
            }
        } else {
            alert.addButton(withTitle: "Close")
            alert.runModal()
        }
        NSApp.terminate(nil)
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
        if let denialNotice = appState.runtimeDenialNotice {
            menu.addItem(
                withTitle: denialNotice,
                action: nil,
                keyEquivalent: ""
            ).isEnabled = false
        }
        if pendingMediaCopyFallback?.payload != nil {
            menu.addItem(
                withTitle: "Copy Media Instead",
                action: #selector(copyPendingMedia),
                keyEquivalent: ""
            )
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
        addUpdateItems(to: menu)
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
        window.styleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable
        ]
        window.setContentSize(NSSize(width: 760, height: 570))
        window.minSize = NSSize(width: 680, height: 520)
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

        let rootView: LibraryShellView
        if let libraryViewModel {
            rootView = LibraryShellView(
                appState: appState,
                viewModel: libraryViewModel
            )
        } else {
            rootView = LibraryShellView(appState: appState)
        }
        let controller = NSHostingController(rootView: rootView)
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

        let giphyKeyStore: any GiphyAPIKeyStoring
        if launchConfiguration.isUITesting {
            giphyKeyStore = UITestGiphyAPIKeyStore()
        } else {
            giphyKeyStore = KeychainGiphyAPIKeyStore()
        }
        let controller = NSHostingController(
            rootView: SettingsRootView(
                appState: appState,
                giphyKeyStore: giphyKeyStore
            )
        )
        let window = NSWindow(contentViewController: controller)
        window.title = "MojiPond Settings"
        window.styleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable
        ]
        window.setContentSize(NSSize(width: 680, height: 540))
        window.minSize = NSSize(width: 620, height: 500)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    private func showUITestImportPreview() {
        guard let libraryViewModel else {
            appState.setRuntimeNotice(
                "The deterministic import preview could not be prepared."
            )
            showLibrary()
            return
        }
        let controller = NSHostingController(
            rootView: LibraryImportPreviewView(
                viewModel: libraryViewModel
            )
        )
        let window = NSWindow(contentViewController: controller)
        window.title = "MojiPond Import Preview"
        window.styleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable
        ]
        window.setContentSize(NSSize(width: 900, height: 700))
        window.minSize = NSSize(width: 780, height: 600)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        uiTestSurfaceWindow = window
    }

    private func showUITestSuggestionSurface(
        mode: RuntimeInterceptionMode
    ) {
        let rows = [
            RuntimeSuggestionRow(
                id: "ui-test.wave",
                glyph: "👋",
                shortcode: "wave",
                name: "Waving hand"
            ),
            RuntimeSuggestionRow(
                id: "ui-test.frog",
                glyph: "🐸",
                shortcode: "frog",
                name: "Frog"
            ),
            RuntimeSuggestionRow(
                id: "ui-test.lizard",
                glyph: "🦎",
                shortcode: "lizard",
                name: "Lizard"
            ),
            RuntimeSuggestionRow(
                id: "ui-test.lily",
                glyph: "🪷",
                shortcode: "lotus",
                name: "Lotus"
            ),
            RuntimeSuggestionRow(
                id: "ui-test.sparkles",
                glyph: "✨",
                shortcode: "sparkles",
                name: "Sparkles"
            )
        ]
        let snapshot = RuntimeSuggestionPanelSnapshot(
            revision: 1,
            transactionID: ParserTransactionID(rawValue: 1),
            mode: mode,
            rows: rows,
            selectedIndex: 1,
            query: mode == .browser ? "pond" : nil
        )
        let panelSize =
            RuntimeSuggestionPanelController.preferredSize(
                for: snapshot
            )
        guard
            let display =
                CaretPanelPositioner.currentDisplays().first
        else {
            appState.setRuntimeNotice(
                "The deterministic suggestion surface could not be positioned."
            )
            return
        }
        let quartzCaret = CGRect(
            x: display.quartzFrame.midX - panelSize.width / 2,
            y: display.quartzFrame.midY - panelSize.height / 2,
            width: 2,
            height: 20
        )
        let controller = RuntimeSuggestionPanelController()
        guard controller.applyReportingVisibility(
            .show(
                snapshot: snapshot,
                quartzCaretBounds: quartzCaret
            )
        ) else {
            appState.setRuntimeNotice(
                "The deterministic suggestion surface could not be shown."
            )
            return
        }
        uiTestSuggestionController = controller
    }

    @objc
    private func openEmojiBrowser() {
        runtimeController?.openBrowser()
    }

    @objc
    private func copyPendingMedia() {
        guard let payload = pendingMediaCopyFallback?.payload else {
            return
        }
        let copied = MacPasteboardAccess().replaceContents(with: [payload])
        pendingMediaCopyFallback = nil
        appState.setRuntimeNotice(
            copied
                ? "Media copied to the clipboard."
                : "MojiPond could not copy the media."
        )
        rebuildStatusMenu()
    }

    @objc
    private func checkForUpdates() {
        appState.updates.checkManually(
            automaticChecksEnabled:
                appState.preferences.network.allowsUpdateChecks
        )
    }

    @objc
    private func downloadAndVerifyUpdate() {
        appState.updates.stageAvailableUpdate()
    }

    @objc
    private func showVerifiedUpdateForManualInstall() {
        let alert = NSAlert()
        alert.messageText = "Prepare the verified app for manual installation?"
        alert.informativeText =
            "MojiPond will verify the signed ZIP and both app identities "
            + "again. It will then reveal the staged app in Finder. Quit "
            + "MojiPond, replace the installed copy at its existing "
            + "location, and relaunch it."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Revalidate and Show in Finder")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        Task {
            guard let plan =
                await appState.updates.revalidateInstallation() else {
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([
                plan.stagedApplicationURL
            ])
        }
    }

    @objc
    private func installVerifiedUpdateAndRelaunch() {
        let alert = NSAlert()
        alert.messageText = "Install the verified update and relaunch?"
        alert.informativeText =
            "MojiPond will verify the signed ZIP and both app identities "
            + "again, quit this process, replace the app using a locked "
            + "atomic swap, verify the installed result, and relaunch. "
            + "Any failure after replacement begins restores this version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install & Relaunch")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        Task {
            if await appState.updates.installAndRelaunch() {
                NSApp.terminate(nil)
            }
        }
    }

    @objc
    private func discardVerifiedUpdate() {
        appState.updates.discardStagedUpdate()
    }

    @objc
    private func openUpdateReleaseNotes() {
        guard
            let metadata = appState.updates.availableMetadata,
            let releaseNotesURL = metadata.releaseNotesURL
        else {
            return
        }
        NSWorkspace.shared.open(releaseNotesURL)
    }

    private func addUpdateItems(to menu: NSMenu) {
        switch appState.updates.state {
        case let .available(metadata):
            menu.addItem(
                withTitle:
                    "Download & Verify MojiPond \(metadata.version)…",
                action: #selector(downloadAndVerifyUpdate),
                keyEquivalent: ""
            )
            if metadata.releaseNotesURL != nil {
                menu.addItem(
                    withTitle: "Read Update Release Notes…",
                    action: #selector(openUpdateReleaseNotes),
                    keyEquivalent: ""
                )
            }
        case let .staging(metadata):
            menu.addItem(
                withTitle:
                    "Downloading & Verifying MojiPond \(metadata.version)…",
                action: nil,
                keyEquivalent: ""
            ).isEnabled = false
        case let .revalidating(metadata):
            menu.addItem(
                withTitle:
                    "Revalidating MojiPond \(metadata.version)…",
                action: nil,
                keyEquivalent: ""
            ).isEnabled = false
        case let .launchingInstaller(metadata):
            menu.addItem(
                withTitle:
                    "Starting MojiPond \(metadata.version) Installer…",
                action: nil,
                keyEquivalent: ""
            ).isEnabled = false
        case let .staged(metadata, _):
            switch appState.updates.nativeInstallAvailability {
            case .available:
                menu.addItem(
                    withTitle:
                        "Install MojiPond \(metadata.version) & Relaunch…",
                    action:
                        #selector(installVerifiedUpdateAndRelaunch),
                    keyEquivalent: ""
                )
            case .manualInstallRequired:
                menu.addItem(
                    withTitle:
                        "Show Verified MojiPond \(metadata.version) in Finder…",
                    action:
                        #selector(showVerifiedUpdateForManualInstall),
                    keyEquivalent: ""
                )
            case .unavailable, .none:
                menu.addItem(
                    withTitle: "Verified Update Needs Attention",
                    action: nil,
                    keyEquivalent: ""
                ).isEnabled = false
            }
            menu.addItem(
                withTitle: "Discard Verified Update",
                action: #selector(discardVerifiedUpdate),
                keyEquivalent: ""
            )
            if metadata.releaseNotesURL != nil {
                menu.addItem(
                    withTitle: "Read Update Release Notes…",
                    action: #selector(openUpdateReleaseNotes),
                    keyEquivalent: ""
                )
            }
        case .checking:
            menu.addItem(
                withTitle: "Checking for Updates…",
                action: nil,
                keyEquivalent: ""
            ).isEnabled = false
        case .unconfigured,
             .idle,
             .current,
             .incompatible,
             .disabled,
             .failed:
            menu.addItem(
                withTitle: "Check for Updates…",
                action: #selector(checkForUpdates),
                keyEquivalent: ""
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtimeController?.stop()
        appState.permissions.stopLiveUpdates()
        appState.updates.prepareForTermination()
        if let rootURL = launchConfiguration.ephemeralRootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
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
        if case let .contextSuspended(denial) = appState.runtimeState {
            switch denial {
            case .excludedApplication, .excludedDomain:
                return "nosign"
            case .secureEventInput, .secureField, .secureStatusUnknown:
                return "lock.circle"
            case .applicationUnknown, .domainUnknown, .permissionUnavailable:
                return "exclamationmark.circle"
            }
        }
        if case .sessionLocked = appState.runtimeState {
            return "lock.circle"
        }
        return "water.waves"
    }

    @discardableResult
    private func configureApplicationServices() -> Bool {
        do {
            let paths = try ApplicationPaths.live()
            let builtInPack = try BuiltInRuntimeCatalogLoader().loadPack()
            let usage = try FileEmojiUsageStore(fileURL: paths.usageFile)
            let library = LibraryStore(
                rootURL: paths.libraryRoot,
                reservedShortcodes:
                    BuiltInShortcodeReservations.shortcodes(
                        in: builtInPack
                    )
            )
            let runtime = try MojiPondRuntimeController(
                preferences: appState.preferences,
                usageStore: usage,
                managedMediaRoot: paths.libraryRoot,
                mediaCacheRoot: paths.mediaCacheRoot
            )
            let libraryViewModel = LibraryViewModel(
                store: library,
                paths: paths,
                builtInLoader: { builtInPack },
                usageStore: usage,
                onMutation: { [weak self] _ in
                    Task {
                        await self?.reloadRuntimeCatalog()
                    }
                },
                onUsageMutation: { [weak self] in
                    self?.runtimeController?.reloadUsageSnapshot()
                }
            )

            usageStore = usage
            libraryStore = library
            self.libraryViewModel = libraryViewModel
            runtimeController = runtime
            runtime.onDiagnostic = { [weak self] diagnostic in
                self?.handleRuntimeDiagnostic(diagnostic)
            }
            runtime.onMediaCopyFallback = { [weak self] diagnostic in
                self?.handleMediaCopyFallback(diagnostic)
            }
            runtime.start()

            Task { [weak self] in
                await self?.reloadRuntimeCatalog()
            }
            return true
        } catch {
            appState.setRuntimeState(.failed(error.localizedDescription))
            appState.setRuntimeNotice(
                "Startup failed. Open Setup & Permissions for details."
            )
            return false
        }
    }

    private func configureUITestServices() {
        guard let rootURL = launchConfiguration.ephemeralRootURL else {
            return
        }
        let paths = ApplicationPaths(
            applicationSupportBase: rootURL.appendingPathComponent(
                "Application Support",
                isDirectory: true
            ),
            cachesBase: rootURL.appendingPathComponent(
                "Caches",
                isDirectory: true
            )
        )
        do {
            let builtInPack = try BuiltInRuntimeCatalogLoader().loadPack()
            let library = LibraryStore(
                rootURL: paths.libraryRoot,
                reservedShortcodes:
                    BuiltInShortcodeReservations.shortcodes(
                        in: builtInPack
                    )
            )
            libraryStore = library
            let viewModel = LibraryViewModel(
                store: library,
                paths: paths,
                importer: launchConfiguration.initialScreen
                    == .importPreview
                    ? UITestLibraryImportPreparer(
                        workspaceRootURL: paths.importStagingRoot
                    )
                    : nil,
                builtInLoader: { builtInPack }
            )
            libraryViewModel = viewModel
            if launchConfiguration.initialScreen == .importPreview {
                Task {
                    await viewModel.reload()
                    viewModel.prepareImport(
                        .files([], packName: "Pond Favorites")
                    )
                }
            }
        } catch {
            appState.setRuntimeState(.failed(error.localizedDescription))
            appState.setRuntimeNotice(
                "Built-in emoji catalog unavailable."
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

        appState.updates.$state
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.rebuildStatusMenu()
            }
            .store(in: &cancellables)

        Publishers.CombineLatest4(
            appState.$preferences.removeDuplicates(),
            appState.permissions.$snapshot.removeDuplicates(),
            appState.$runtimeState.removeDuplicates(),
            Publishers.CombineLatest(
                appState.$runtimeNotice.removeDuplicates(),
                appState.$runtimeDenialNotice.removeDuplicates()
            )
        )
        .dropFirst()
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
        case .clipboardRestoreFailed:
            appState.setRuntimeNotice(
                "The emoji was inserted, but macOS could not restore the previous clipboard."
            )
        case let .sessionDenied(denial):
            let notice = runtimeNotice(for: denial)
            if appState.runtimeDenialNotice != notice {
                appState.setRuntimeDenialNotice(notice)
            }
        case .sessionAllowed:
            if appState.runtimeDenialNotice != nil {
                appState.setRuntimeDenialNotice(nil)
            }
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

    private func handleMediaCopyFallback(
        _ diagnostic: RuntimeMediaCopyFallbackDiagnostic
    ) {
        pendingMediaCopyFallback =
            diagnostic.payload == nil ? nil : diagnostic
        let action = diagnostic.payload == nil
            ? ""
            : " Choose Copy Media Instead from the MojiPond menu."
        appState.setRuntimeNotice(
            mediaFallbackMessage(for: diagnostic.reason) + action
        )
        rebuildStatusMenu()
    }

    private func mediaFallbackMessage(
        for reason: RuntimeMediaCopyFallbackReason
    ) -> String {
        switch reason {
        case .notMessages:
            "Automatic media paste is currently verified only in Messages; "
                + "the token was left intact."
        case .managedLibraryUnavailable:
            "The custom media library is unavailable; the token was left intact."
        case .invalidManagedAsset:
            "This media item failed its safety or integrity check."
        case .animatedWebPExperimental:
            "Animated WebP paste is experimental, so MojiPond left the token intact."
        case .downloadFailed:
            "The selected media could not be downloaded."
        case .unsupportedDownloadedMedia:
            "The downloaded media was empty, unsafe, or unsupported."
        case let .insertionFailed(reason):
            insertionFallbackMessage(for: reason)
        }
    }

    private func insertionFallbackMessage(
        for reason: InsertionFailureReason
    ) -> String {
        switch reason {
        case .targetChanged:
            "The text target changed before MojiPond could paste."
        case .secureOrUnsupportedTarget:
            "MojiPond left the token intact in this secure or unsupported field."
        case .eventPostingUnavailable:
            "macOS did not allow MojiPond to post the paste shortcut."
        case .unsafeClipboardSnapshot:
            "MojiPond could not safely preserve the current clipboard."
        case .clipboardWriteFailed:
            "MojiPond could not stage the media on the clipboard."
        case .unknown:
            "MojiPond could not safely insert the selected media."
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
        case .domainUnknown:
            "MojiPond could not verify this website safely."
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

private struct UITestLibraryImportPreparer: LibraryImportPreparing {
    let workspaceRootURL: URL

    func prepare(
        _ request: ImportRequest,
        against library: MojiPondLibrary,
        reservedShortcodeOwners: [ReservedShortcodeOwner]
    ) async throws -> ImportPreparation {
        _ = request
        let workspaceURL = workspaceRootURL.appendingPathComponent(
            "deterministic-preview",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let sourceURL = workspaceURL.appendingPathComponent(
            "mojipond.json",
            isDirectory: false
        )
        let preparedPack = PreparedPackImport(
            id: UUID(
                uuidString: "2E648977-7196-4434-8B7C-C8E005A0D279"
            )!,
            name: "Pond Favorites",
            manifest: PackManifestMetadata(
                packID: PackIdentifier(
                    rawValue: "ui-test.pond-favorites"
                )!,
                name: "Pond Favorites",
                version: "1.0.0",
                author: "MojiPond UI Fixture",
                description:
                    "A deterministic mixed import review surface."
            ),
            source: PackSource(
                kind: .folder,
                displayLocation: "Pond Favorites"
            ),
            items: [
                PreparedEmoji(
                    id: UUID(
                        uuidString:
                            "588D3AA7-BE09-49B0-B106-92E5C4FD35B2"
                    )!,
                    shortcode: Shortcode(rawValue: "wave")!,
                    aliases: [Shortcode(rawValue: "hello_pond")!],
                    displayName: "Pond wave",
                    tags: ["hello", "water"],
                    category: "Pond",
                    order: 0,
                    unicode: "👋",
                    sourceURL: sourceURL,
                    sourceFilename: "wave.json"
                ),
                PreparedEmoji(
                    id: UUID(
                        uuidString:
                            "9A089087-CBB5-4233-9C65-710F6AF1C67B"
                    )!,
                    shortcode: Shortcode(rawValue: "pond_frog")!,
                    aliases: [Shortcode(rawValue: "frog_friend")!],
                    displayName: "Pond frog",
                    tags: ["frog", "friend"],
                    category: "Pond",
                    order: 1,
                    unicode: "🐸",
                    sourceURL: sourceURL,
                    sourceFilename: "Pond Frog.json"
                ),
                PreparedEmoji(
                    id: UUID(
                        uuidString:
                            "85BC7489-981B-40CD-810E-CFA464A3BE5D"
                    )!,
                    shortcode: Shortcode(rawValue: "lily_pad")!,
                    aliases: [],
                    displayName: "Lily pad",
                    tags: ["plant", "water"],
                    category: "Pond",
                    order: 2,
                    unicode: "🪷",
                    sourceURL: sourceURL,
                    sourceFilename: "Lily Pad.json"
                )
            ]
        )
        let scan = ImportScanResult(
            preparedPack: preparedPack,
            rejections: [
                ImportRejection(
                    source: "oversized-frog.svg",
                    reason:
                        "SVG is not imported because it cannot be rendered safely."
                )
            ],
            ignoredFileCount: 2
        )
        let preview = ImportCollisionAnalyzer.makePreview(
            scanResult: scan,
            library: library,
            reservedShortcodeOwners: reservedShortcodeOwners
        )
        return ImportPreparation(
            preview: preview,
            duplicateContent: [],
            workspaceURL: workspaceURL,
            reservedShortcodeOwners: reservedShortcodeOwners
        )
    }
}

private struct UITestGiphyAPIKeyStore: GiphyAPIKeyStoring {
    func apiKey() throws -> String {
        throw RemoteMediaError.missingAPIKey
    }

    func save(_ value: String) throws {
        _ = value
    }

    func delete() throws {}
}
