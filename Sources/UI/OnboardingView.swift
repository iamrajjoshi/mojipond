import AppKit
import SwiftUI

enum OnboardingPracticeCatalogAvailability: Equatable, Sendable {
    case available
    case unavailable

    var title: String {
        switch self {
        case .available:
            "Practice suggestions ready"
        case .unavailable:
            "Practice suggestions unavailable"
        }
    }

    var message: String {
        switch self {
        case .available:
            "The built-in emoji catalog is ready."
        case .unavailable:
            "MojiPond could not load its built-in emoji catalog. You can try again or continue to the Library."
        }
    }
}

struct OnboardingPracticeCatalog {
    let searchIndex: EmojiSearchIndex?
    let availability: OnboardingPracticeCatalogAvailability

    static func load(
        using loader: () throws -> EmojiSearchIndex
    ) -> OnboardingPracticeCatalog {
        do {
            return OnboardingPracticeCatalog(
                searchIndex: try loader(),
                availability: .available
            )
        } catch {
            return OnboardingPracticeCatalog(
                searchIndex: nil,
                availability: .unavailable
            )
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var permissions: SystemPermissionCenter
    let onFinish: () -> Void

    @State private var practiceText = ""
    @State private var practiceSelectionIndex = 0
    @State private var practiceFeedback: String?
    @State private var permissionNavigationError: String?
    @State private var practiceIndex: EmojiSearchIndex?
    @State private var practiceCatalogAvailability:
        OnboardingPracticeCatalogAvailability
    private let practiceCatalogLoader: () throws -> EmojiSearchIndex
    private let permissionSettingsOpener:
        any SystemPermissionSettingsOpening

    init(appState: AppState, onFinish: @escaping () -> Void) {
        self.init(
            appState: appState,
            practiceCatalogLoader: {
                try BuiltInRuntimeCatalogLoader().loadSearchIndex()
            },
            onFinish: onFinish
        )
    }

    init(
        appState: AppState,
        practiceCatalogLoader: @escaping () throws -> EmojiSearchIndex,
        permissionSettingsOpener:
            any SystemPermissionSettingsOpening =
                MacSystemPermissionSettingsOpener(),
        onFinish: @escaping () -> Void
    ) {
        let practiceCatalog = OnboardingPracticeCatalog.load(
            using: practiceCatalogLoader
        )
        self.appState = appState
        permissions = appState.permissions
        self.onFinish = onFinish
        self.practiceCatalogLoader = practiceCatalogLoader
        self.permissionSettingsOpener = permissionSettingsOpener
        _practiceIndex = State(initialValue: practiceCatalog.searchIndex)
        _practiceCatalogAvailability = State(
            initialValue: practiceCatalog.availability
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            setupContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(
            minWidth: 660,
            idealWidth: 720,
            minHeight: 560,
            idealHeight: 620
        )
        .background {
            PondWindowBackdrop()
        }
        .tint(PondDesign.pond)
    }

    private var header: some View {
        HStack(spacing: 10) {
            PondMark(size: 28)
            Text("MojiPond")
                .font(.headline)
            Spacer()
            Text("Setup")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background(.bar)
    }

    private var setupContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PondDesign.sectionSpacing) {
                PondPageHeader(
                    icon: "face.smiling",
                    title: "Type emoji by name",
                    detail:
                        "Try \(triggerText)wave\(triggerText) below. Then grant access to use shortcuts in other apps."
                )

                PondCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Try it")
                                .font(.headline)
                                .fontDesign(.rounded)
                            Spacer()
                            Text("No access needed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Group {
                            if practiceCatalogAvailability == .available {
                                practiceEditor
                            } else {
                                practiceCatalogFailure
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Use it anywhere")
                        .font(.headline)
                        .fontDesign(.rounded)
                    Text(
                        "MojiPond needs two macOS permissions to notice a shortcut and replace it."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)

                    VStack(spacing: 0) {
                        PermissionCard(
                            icon: "keyboard",
                            title: "Input Monitoring",
                            detail: "Notices when you start a shortcut.",
                            status: permissions.snapshot.inputMonitoring,
                            requestEnabled: true,
                            request: { permissions.requestInputMonitoring() },
                            openSettings: {
                                openPermissionSettings(.inputMonitoring)
                            }
                        )

                        Divider()
                            .padding(.leading, 46)

                        PermissionCard(
                            icon: "accessibility",
                            title: "Accessibility",
                            detail: "Places the picker and inserts your choice.",
                            status: permissions.snapshot.accessibility,
                            requestEnabled: true,
                            request: { permissions.requestAccessibility() },
                            openSettings: {
                                openPermissionSettings(.accessibility)
                            }
                        )
                    }
                    .background(
                        PondDesign.surface,
                        in: RoundedRectangle(
                            cornerRadius: PondDesign.cornerRadius,
                            style: .continuous
                        )
                    )
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: PondDesign.cornerRadius,
                            style: .continuous
                        )
                        .stroke(PondDesign.separator.opacity(0.65))
                    }
                }

                if let permissionNavigationError {
                    Label(
                        permissionNavigationError,
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.callout)
                    .foregroundStyle(PondDesign.warningForeground)
                }

                Label(
                    "Shortcut matching stays on this Mac. MojiPond does not save what you type.",
                    systemImage: "lock.shield"
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                PondCard {
                    SettingsRow(
                        icon: "stethoscope",
                        title: "Share crash reports",
                        detail:
                            "On by default. Sends crash and hang diagnostics, including stack traces and app/runtime context, to Sentry. Standard request metadata, including IP, reaches Sentry. Shortcut text, clipboard contents, screenshots, and emoji files stay on this Mac.",
                        detailAccessibilityIdentifier:
                            "onboarding.crashReportsDisclosure"
                    ) {
                        Toggle(
                            "Share crash reports",
                            isOn: Binding(
                                get: {
                                    appState.preferences.network
                                        .allowsCrashReports
                                },
                                set: { enabled in
                                    appState.updatePreferences {
                                        $0.network.allowsCrashReports = enabled
                                    }
                                }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(PondDesign.lily)
                        .accessibilityLabel("Share crash reports")
                        .accessibilityIdentifier(
                            "onboarding.crashReportsToggle"
                        )
                    }
                }
            }
            .frame(maxWidth: 640)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    private var practiceEditor: some View {
        VStack(spacing: 8) {
            PracticeShortcutField(
                text: $practiceText,
                placeholder: "Type \(triggerText)wave\(triggerText) here",
                onMove: movePracticeSelection,
                onSubmit: acceptFirstPracticeSuggestion
            )
            .frame(height: 28)
            .onChange(of: practiceText) { _ in
                practiceSelectionIndex = 0
                replaceExactPracticeTokenIfNeeded()
            }
            .accessibilityIdentifier("onboarding.practiceField")

            if !practiceSuggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(
                        Array(practiceSuggestions.prefix(3).enumerated()),
                        id: \.element.item.id
                    ) { index, result in
                        Button {
                            acceptPracticeResult(result)
                        } label: {
                            HStack(spacing: 10) {
                                Text(unicodeValue(for: result.item) ?? "◇")
                                    .font(.title2)
                                    .frame(width: 30)
                                Text(
                                    "\(triggerText)\(result.item.shortcode.rawValue)\(triggerText)"
                                )
                                .fontDesign(.monospaced)
                                Spacer()
                                if index == practiceSelectionIndex {
                                    Text("Return")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 38)
                            .background(
                                index == practiceSelectionIndex
                                    ? PondDesign.pond.opacity(0.09)
                                    : Color.clear
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(
                            index == practiceSelectionIndex
                                ? "Press Return to insert"
                                : "Select to insert"
                        )
                    }
                }
                .background(
                    PondDesign.raisedSurface,
                    in: RoundedRectangle(cornerRadius: 9)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(PondDesign.ripple.opacity(0.2))
                }
            }

            if let practiceFeedback {
                Label(practiceFeedback, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(PondDesign.lily)
            }
        }
    }

    private var practiceCatalogFailure: some View {
        PondCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    practiceCatalogAvailability.title,
                    systemImage: "exclamationmark.triangle"
                )
                .font(.headline)

                Text(practiceCatalogAvailability.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Try Again", action: reloadPracticeCatalog)
                    .accessibilityHint(
                        "Attempts to reload the built-in emoji catalog"
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    private var footer: some View {
        HStack {
            if !appState.canMonitorTyping {
                Text(
                    "You can return from Finish Setup in the MojiPond menu."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if appState.canMonitorTyping {
                Button("Finish Setup", action: finish)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Continue Without Shortcuts", action: finish)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
        .background(PondDesign.surface.opacity(0.94))
    }

    private func finish() {
        appState.finishOnboarding()
        onFinish()
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

    private var triggerText: String {
        appState.preferences.shortcode.trigger.rawValue
    }

    private func reloadPracticeCatalog() {
        let catalog = OnboardingPracticeCatalog.load(
            using: practiceCatalogLoader
        )
        practiceIndex = catalog.searchIndex
        practiceCatalogAvailability = catalog.availability
    }

    private var practiceSuggestions: [EmojiSearchResult] {
        guard let practiceIndex,
              let query = activePracticeQuery,
              !query.isEmpty else {
            return []
        }
        return practiceIndex.search(query, limit: 3).filter {
            if case .unicode = $0.item.content {
                return true
            }
            return false
        }
    }

    private var activePracticeQuery: String? {
        let trigger = appState.preferences.shortcode.trigger.character
        guard let start = practiceText.lastIndex(of: trigger) else {
            return nil
        }
        let value = String(practiceText[practiceText.index(after: start)...])
        guard value.utf8.count <= Shortcode.maximumLength,
              value.utf8.allSatisfy({
                  (0x61...0x7A).contains($0)
                      || (0x30...0x39).contains($0)
                      || $0 == 0x5F
                      || $0 == 0x2B
                      || $0 == 0x2D
              }) else {
            return nil
        }
        return value
    }

    private func replaceExactPracticeTokenIfNeeded() {
        guard
            appState.preferences.shortcode.replacesOnExactClosingTrigger,
            let practiceIndex
        else {
            return
        }
        let trigger = appState.preferences.shortcode.trigger.character
        guard practiceText.last == trigger else {
            return
        }
        let beforeClosing = practiceText.dropLast()
        guard let opening = beforeClosing.lastIndex(of: trigger) else {
            return
        }
        let tokenStart = beforeClosing.index(after: opening)
        let token = String(beforeClosing[tokenStart...])
        guard let result = practiceIndex.exactMatch(for: token),
              let value = unicodeValue(for: result.item) else {
            return
        }
        practiceText.replaceSubrange(opening..., with: value)
        practiceFeedback = "Shortcode replaced"
    }

    private func acceptFirstPracticeSuggestion() {
        let suggestions = practiceSuggestions
        guard suggestions.indices.contains(practiceSelectionIndex) else {
            return
        }
        acceptPracticeResult(suggestions[practiceSelectionIndex])
    }

    private func movePracticeSelection(_ direction: MoveCommandDirection) {
        let suggestions = practiceSuggestions
        guard !suggestions.isEmpty else {
            return
        }
        switch direction {
        case .up:
            practiceSelectionIndex = max(0, practiceSelectionIndex - 1)
        case .down:
            practiceSelectionIndex = min(
                suggestions.index(before: suggestions.endIndex),
                practiceSelectionIndex + 1
            )
        default:
            break
        }
    }

    private func acceptPracticeResult(_ result: EmojiSearchResult) {
        guard let value = unicodeValue(for: result.item),
              let opening = practiceText.lastIndex(
                  of: appState.preferences.shortcode.trigger.character
              ) else {
            return
        }
        practiceText.replaceSubrange(opening..., with: value)
        practiceFeedback = "Emoji inserted"
    }

    private func unicodeValue(for item: EmojiItem) -> String? {
        guard case let .unicode(content) = item.content else {
            return nil
        }
        return content.value
    }
}

private struct PracticeShortcutField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onMove: (MoveCommandDirection) -> Void
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.font = NSFont.systemFont(ofSize: 17)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.focusRingType = .default
        field.setAccessibilityIdentifier("onboarding.practiceField")
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PracticeShortcutField

        init(parent: PracticeShortcutField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else {
                return
            }
            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(.up)
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(.down)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            default:
                return false
            }
        }
    }
}

private struct PermissionCard: View {
    let icon: String
    let title: String
    let detail: String
    let status: SystemPermissionStatus
    let requestEnabled: Bool
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(
                    status == .granted
                        ? PondDesign.lily
                        : PondDesign.pond
                )
                .frame(width: 28, height: 28)
                .background(
                    (status == .granted
                        ? PondDesign.lily
                        : PondDesign.pond).opacity(0.1),
                    in: RoundedRectangle(
                        cornerRadius: PondDesign.compactCornerRadius
                    )
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title)
                        .font(.headline)
                    PermissionStatusView(
                        permissionName: title,
                        status: status
                    )
                }
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 14)

            permissionAction
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var permissionAction: some View {
        switch status {
        case .notRequested:
            Button("Allow", action: request)
                .buttonStyle(.borderedProminent)
                .disabled(!requestEnabled)
                .accessibilityLabel("Request \(title) Access")
        case .pending, .denied, .revoked:
            Button("System Settings…", action: openSettings)
                .accessibilityLabel("Open \(title) Settings")
        case .granted:
            EmptyView()
        }
    }
}

struct PermissionStatusView: View {
    let permissionName: String
    let status: SystemPermissionStatus
    var isRequired = true

    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(backgroundColor, in: Capsule())
            .accessibilityLabel("\(permissionName) permission")
            .accessibilityValue(title)
    }

    private var title: String {
        switch status {
        case .notRequested:
            isRequired ? "Needs access" : "Optional"
        case .denied:
            isRequired ? "Needs access" : "Denied"
        case .revoked:
            isRequired ? "Needs access" : "Access removed"
        case .pending: "Waiting for approval"
        case .granted: "Granted"
        }
    }

    private var icon: String {
        switch status {
        case .granted: "checkmark.circle.fill"
        case .pending: "clock.fill"
        case .revoked: "arrow.counterclockwise.circle.fill"
        case .denied: "xmark.circle.fill"
        case .notRequested: "circle.dashed"
        }
    }

    private var foregroundColor: Color {
        switch status {
        case .granted: PondDesign.lily
        case .pending: PondDesign.pond
        case .denied, .revoked: PondDesign.warningForeground
        case .notRequested: .secondary
        }
    }

    private var backgroundColor: Color {
        switch status {
        case .pending:
            PondDesign.pond.opacity(0.12)
        case .denied, .revoked:
            PondDesign.warningBackground
        case .granted:
            PondDesign.lily.opacity(0.12)
        case .notRequested:
            Color.secondary.opacity(0.12)
        }
    }
}
