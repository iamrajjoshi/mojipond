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
            PondMark(size: 30)
            Text("MojiPond")
                .font(.headline)
            Spacer()
            Text("SETUP")
                .font(.caption)
                .fontWeight(.semibold)
                .tracking(1.1)
                .foregroundStyle(PondDesign.onDeepWater.opacity(0.78))
        }
        .foregroundStyle(PondDesign.onDeepWater)
        .padding(.horizontal, 20)
        .frame(height: 50)
        .background(PondDesign.deepWater)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PondDesign.ripple.opacity(0.5))
                .frame(height: 1)
        }
    }

    private var setupContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PondPageHeader(
                    icon: "keyboard",
                    title: "Set up typing shortcuts",
                    detail:
                        "Allow both permissions, then try \(triggerText)wave\(triggerText)."
                )

                if !appState.isInstalledInApplications {
                    Label {
                        Text(
                            "Move MojiPond to Applications and open that copy before allowing access."
                        )
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(PondDesign.warningForeground)
                    }
                    .padding(10)
                    .background(
                        PondDesign.warningBackground,
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                }

                PermissionCard(
                    icon: "accessibility",
                    title: "Accessibility",
                    detail:
                        "Finds the text field and inserts your choice.",
                    status: permissions.snapshot.accessibility,
                    requestEnabled: canRequestPermissions,
                    request: { permissions.requestAccessibility() },
                    openSettings: {
                        openPermissionSettings(.accessibility)
                    }
                )

                PermissionCard(
                    icon: "keyboard",
                    title: "Input Monitoring",
                    detail:
                        "Notices when you start an emoji shortcut.",
                    status: permissions.snapshot.inputMonitoring,
                    requestEnabled: canRequestPermissions,
                    request: { permissions.requestInputMonitoring() },
                    openSettings: {
                        openPermissionSettings(.inputMonitoring)
                    }
                )

                if let permissionNavigationError {
                    Label(
                        permissionNavigationError,
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.callout)
                    .foregroundStyle(PondDesign.warningForeground)
                }

                PondCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Try it")
                            .font(.headline)
                        Text(
                            "Type \(triggerText)wave\(triggerText). This practice field works before access is allowed."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)

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

                Label(
                    "Shortcuts stay on this Mac. Nothing you type is uploaded.",
                    systemImage: "lock.shield"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }

    private var practiceEditor: some View {
        VStack(spacing: 8) {
            TextField(
                "Type \(triggerText)wave\(triggerText) here",
                text: $practiceText
            )
            .textFieldStyle(.roundedBorder)
            .font(.title3)
            .onSubmit(acceptFirstPracticeSuggestion)
            .onChange(of: practiceText) { _, _ in
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
                                if index == 0 {
                                    Text("Return")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 38)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(
                            index == 0
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
                Text("You can finish setup later from the MojiPond menu.")
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

    private var canRequestPermissions: Bool {
        appState.isInstalledInApplications
            || ProcessInfo.processInfo.arguments.contains(
                AppLaunchConfiguration.uiTestingFlag
            )
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
        guard let result = practiceSuggestions.first else {
            return
        }
        acceptPracticeResult(result)
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
        .padding(12)
        .background(
            status == .granted
                ? PondDesign.lily.opacity(0.045)
                : PondDesign.surface,
            in: RoundedRectangle(cornerRadius: PondDesign.cornerRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: PondDesign.cornerRadius)
                .stroke(
                    status == .granted
                        ? PondDesign.lily.opacity(0.25)
                        : PondDesign.ripple.opacity(0.18),
                    lineWidth: 1
                )
        }
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
