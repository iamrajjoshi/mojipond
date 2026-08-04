import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState: AppState

    private let crashReporting = CrashReportingController()
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
            observeApplicationState()
            configureStatusItem()
            switch launchConfiguration.initialScreen {
            case .library, .libraryEmptyPack:
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

        configureCrashReportingIfAllowed()
        if
            ProcessInfo.processInfo.environment[
                "XCTestConfigurationFilePath"
            ] == nil
        {
            AdaptiveGlyphPayloadService.shared.prewarmEncoder()
        }
        appState.start()
        configureApplicationServices()
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
    }

    private func configureStatusItem() {
        let item: NSStatusItem
        if let statusItem {
            item = statusItem
        } else {
            item = NSStatusBar.system.statusItem(
                withLength: NSStatusItem.squareLength
            )
            statusItem = item
        }
        item.button?.image = NSImage(
            systemSymbolName: "water.waves",
            accessibilityDescription: "MojiPond"
        )
        item.button?.toolTip = "MojiPond"

        item.menu = makeStatusMenu()
    }

    func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        let activationItem = NSMenuItem(
            title: appState.isEnabled
                ? "Disable MojiPond"
                : "Enable MojiPond",
            action: #selector(toggleEnabled),
            keyEquivalent: ""
        )
        activationItem.target = self
        menu.addItem(activationItem)
        if pendingMediaCopyFallback?.payload != nil {
            let copyMediaItem = menu.addItem(
                withTitle: "Copy Media Instead",
                action: #selector(copyPendingMedia),
                keyEquivalent: ""
            )
            copyMediaItem.target = self
        }
        menu.addItem(.separator())
        let libraryItem = menu.addItem(
            withTitle: "Emoji Library",
            action: #selector(showLibrary),
            keyEquivalent: ""
        )
        libraryItem.target = self
        if !appState.hasCompletedOnboarding {
            let onboardingItem = menu.addItem(
                withTitle: "Finish Setup…",
                action: #selector(showOnboarding),
                keyEquivalent: ""
            )
            onboardingItem.target = self
        }
        let settingsItem = menu.addItem(
            withTitle: "Settings…",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit MojiPond",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        return menu
    }

    @objc
    private func toggleEnabled(_: NSMenuItem) {
        appState.setEnabled(!appState.isEnabled)
        rebuildStatusMenu()
    }

    @objc
    private func showOnboarding() {
        if let onboardingWindow {
            onboardingWindow.deminiaturize(nil)
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
        window.title = "MojiPond"
        window.styleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable
        ]
        window.setContentSize(NSSize(width: 720, height: 620))
        window.minSize = NSSize(width: 660, height: 560)
        window.center()
        configureFrameAutosave(
            for: window,
            name: "MojiPond.Onboarding"
        )
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
    }

    @objc
    private func showLibrary() {
        if let libraryWindow {
            libraryWindow.deminiaturize(nil)
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
        window.title = "MojiPond"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 920, height: 620))
        window.minSize = NSSize(width: 780, height: 520)
        window.center()
        configureFrameAutosave(for: window, name: "MojiPond.Library")
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        libraryWindow = window
    }

    @objc
    private func showSettings() {
        if let settingsWindow {
            settingsWindow.deminiaturize(nil)
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = NSHostingController(
            rootView: SettingsRootView(appState: appState)
        )
        let window = NSWindow(contentViewController: controller)
        window.title = "MojiPond Settings"
        window.styleMask = [
            .titled,
            .closable
        ]
        window.setContentSize(NSSize(width: 740, height: 520))
        window.center()
        configureFrameAutosave(for: window, name: "MojiPond.Settings")
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    private func configureFrameAutosave(
        for window: NSWindow,
        name: String
    ) {
        guard !launchConfiguration.isUITesting else { return }
        window.setFrameAutosaveName(name)
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
        window.setContentSize(NSSize(width: 800, height: 540))
        window.minSize = NSSize(width: 720, height: 480)
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
            ),
            RuntimeSuggestionRow(
                id: "ui-test.duck",
                glyph: "🦆",
                shortcode: "duck",
                name: "Duck"
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

    func applicationWillTerminate(_ notification: Notification) {
        runtimeController?.stop()
        appState.permissions.stopLiveUpdates()
        if let rootURL = launchConfiguration.ephemeralRootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    private func rebuildStatusMenu() {
        configureStatusItem()
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
                managedMediaRoot: paths.libraryRoot
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
                "Startup failed. Open Settings → Privacy for details."
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
            let usage = try FileEmojiUsageStore(fileURL: paths.usageFile)
            let library = LibraryStore(
                rootURL: paths.libraryRoot,
                reservedShortcodes:
                    BuiltInShortcodeReservations.shortcodes(
                        in: builtInPack
                    )
            )
            usageStore = usage
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
                builtInLoader: { builtInPack },
                usageStore: usage
            )
            libraryViewModel = viewModel
            if launchConfiguration.initialScreen == .libraryEmptyPack {
                Task {
                    do {
                        let pack = try await library.createPack(
                            name: "ZIP Only Pack",
                            source: PackSource(
                                kind: .zipArchive,
                                displayLocation: "pond-pack.zip"
                            )
                        )
                        await viewModel.reload()
                        viewModel.scope = .pack(pack.id)
                    } catch {
                        appState.setRuntimeState(
                            .failed(error.localizedDescription)
                        )
                    }
                }
            }
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
        if CrashReportingLaunchPolicy.allowsReporting(
            isUITesting: launchConfiguration.isUITesting,
            environment: ProcessInfo.processInfo.environment
        ) {
            Publishers.CombineLatest(
                appState.$preferences
                    .map { $0.network.allowsCrashReports },
                appState.$hasCompletedOnboarding
            )
                .map { allowsCrashReports, hasCompletedOnboarding in
                    allowsCrashReports && hasCompletedOnboarding
                }
                .removeDuplicates()
                .sink { [weak self] enabled in
                    self?.crashReporting.setEnabled(enabled)
                }
                .store(in: &cancellables)
        }

        appState.$preferences
            .removeDuplicates()
            .sink { [weak self] preferences in
                self?.runtimeController?.updatePreferences(preferences)
            }
            .store(in: &cancellables)

        appState.$hasCompletedOnboarding
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.rebuildStatusMenu()
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

        NotificationCenter.default.publisher(for: .mojiPondShowAliases)
            .sink { [weak self] _ in
                self?.showLibrary()
                self?.libraryViewModel?.scope = .aliases
                DispatchQueue.main.async { [weak self] in
                    self?.libraryViewModel?.scope = .aliases
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(
            for: .mojiPondResetUsageRanking
        )
        .sink { [weak self] _ in
            self?.resetUsageRanking()
        }
        .store(in: &cancellables)
    }

    private func configureCrashReportingIfAllowed() {
        crashReporting.setEnabled(
            CrashReportingLaunchPolicy.shouldEnable(
                isUITesting: launchConfiguration.isUITesting,
                environment: ProcessInfo.processInfo.environment,
                hasCompletedOnboarding: appState.hasCompletedOnboarding,
                userAllowsCrashReports:
                    appState.preferences.network.allowsCrashReports
            )
        )
    }

    func resetUsageRanking() {
        guard let usageStore else {
            appState.setUsageRankingResetNotice(
                UsageRankingResetNotice.failure
            )
            return
        }
        Task {
            do {
                try await usageStore.resetUsageRanking()
                await MainActor.run {
                    self.runtimeController?.reloadUsageSnapshot()
                    self.appState.setUsageRankingResetNotice(
                        UsageRankingResetNotice.success
                    )
                }
            } catch {
                await MainActor.run {
                    self.appState.setUsageRankingResetNotice(
                        UsageRankingResetNotice.failure
                    )
                }
            }
        }
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
        case .sendAfterInsertionUnavailable:
            appState.setRuntimeNotice(
                "Emoji inserted, but macOS could not send it. Allow Image emoji in Messages in Settings → Privacy."
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
            "Media insertion works only in Messages; "
                + "the token was left intact."
        case .managedLibraryUnavailable:
            "The custom media library is unavailable; the token was left intact."
        case .invalidManagedAsset:
            "This media item failed its safety or integrity check."
        case .animatedWebPExperimental:
            "Animated WebP paste is experimental, so MojiPond left the token intact."
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
            "Typing permissions are unavailable."
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
