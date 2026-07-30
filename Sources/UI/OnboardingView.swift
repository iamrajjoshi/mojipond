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

    @State private var step = 0
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

            Group {
                switch step {
                case 0:
                    setupStep
                default:
                    practiceStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(
            minWidth: 680,
            idealWidth: 760,
            minHeight: 520,
            idealHeight: 570
        )
        .background(.background)
    }

    private var header: some View {
        HStack {
            Label("MojiPond", systemImage: "water.waves")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(height: 56)
    }

    private var setupStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 18) {
                    PondMark(size: 64)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(
                            "Type \(triggerText)wave\(triggerText) to insert 👋"
                        )
                            .font(.title2.weight(.semibold))
                        Text(
                            "MojiPond replaces shortcodes in Messages "
                                + "and other Mac apps."
                        )
                        .foregroundStyle(.secondary)
                    }
                }

                if !appState.isInstalledInApplications {
                    Label {
                        Text(
                            "Move MojiPond to Applications before granting "
                                + "access. This keeps macOS permissions tied "
                                + "to the same app."
                        )
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(PondDesign.warningForeground)
                    }
                    .padding(12)
                    .background(
                        PondDesign.warningBackground,
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                }

                PermissionCard(
                    icon: "keyboard",
                    title: "Input Monitoring",
                    detail:
                        "Observes global key events to recognize one bounded "
                        + "shortcode. Unrelated keys are discarded; typing is "
                        + "not saved.",
                    status: permissions.snapshot.inputMonitoring,
                    request: { permissions.requestInputMonitoring() },
                    openSettings: {
                        openPermissionSettings(.inputMonitoring)
                    }
                )

                PermissionCard(
                    icon: "accessibility",
                    title: "Accessibility",
                    detail:
                        "Reads bounded text and caret position to show "
                        + "suggestions and replace your shortcode. Message "
                        + "text is not saved.",
                    status: permissions.snapshot.accessibility,
                    request: { permissions.requestAccessibility() },
                    openSettings: {
                        openPermissionSettings(.accessibility)
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

                Label(
                    "Shortcodes are processed on this Mac. "
                        + "MojiPond does not save your messages.",
                    systemImage: "lock.shield"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding(30)
        }
    }

    private var practiceStep: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: appState.canMonitorTyping ? "checkmark.circle.fill" : "rectangle.and.pencil.and.ellipsis")
                    .font(.system(size: 48))
                    .foregroundStyle(appState.canMonitorTyping ? PondDesign.lily : PondDesign.pond)
                    .accessibilityHidden(true)

                VStack(spacing: 7) {
                    Text(
                        appState.canMonitorTyping
                            ? "Try a shortcode"
                            : "Try a shortcode here"
                    )
                        .font(.title2.weight(.semibold))
                    Text(
                        appState.canMonitorTyping
                            ? "Type \(triggerText)wave\(triggerText) below."
                            : "Type \(triggerText)wave\(triggerText) below. "
                                + "This practice field works without system access."
                    )
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
                }

                Group {
                    if practiceCatalogAvailability == .available {
                        practiceEditor
                    } else {
                        practiceCatalogFailure
                    }
                }
                .frame(maxWidth: 460)
            }
            .padding(34)
            .frame(maxWidth: .infinity)
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
                    .background.secondary,
                    in: RoundedRectangle(cornerRadius: 9)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(.separator)
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
            if step > 0 {
                Button("Back") {
                    step -= 1
                }
            }

            Spacer()

            if step == 0 && !appState.canMonitorTyping {
                Button("Use Library Only") {
                    finish()
                }
            }

            Button(step == 0 ? "Try It" : "Open Library") {
                if step == 0 {
                    step = 1
                } else {
                    finish()
                }
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .frame(height: 64)
    }

    private func finish() {
        appState.finishOnboarding()
        onFinish()
    }

    private func openPermissionSettings(_ permission: SystemPermission) {
        permissionNavigationError =
            permissionSettingsOpener.openSettings(for: permission)
                ? nil
                : "Could not open System Settings. Open Privacy & Security manually."
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
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        PondCard {
            HStack(alignment: .top, spacing: 15) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(PondDesign.pond)
                    .frame(width: 28)
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

                switch status.primaryAction {
                case .request:
                    Button("Allow", action: request)
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("Allow \(title)")
                case .openSettings:
                    Button("Open Settings", action: openSettings)
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("Open \(title) Settings")
                case nil:
                    EmptyView()
                }
            }
        }
    }
}

struct PermissionStatusView: View {
    let permissionName: String
    let status: SystemPermissionStatus

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
        case .notRequested: "Not requested"
        case .denied: "Not allowed"
        case .granted: "Allowed"
        case .revoked: "Access removed"
        }
    }

    private var icon: String {
        switch status {
        case .granted: "checkmark.circle.fill"
        case .revoked: "arrow.counterclockwise.circle.fill"
        case .denied: "xmark.circle.fill"
        case .notRequested: "circle.dashed"
        }
    }

    private var foregroundColor: Color {
        switch status {
        case .granted: PondDesign.lily
        case .denied, .revoked: PondDesign.warningForeground
        case .notRequested: .secondary
        }
    }

    private var backgroundColor: Color {
        switch status {
        case .denied, .revoked:
            PondDesign.warningBackground
        case .granted:
            PondDesign.lily.opacity(0.12)
        case .notRequested:
            Color.secondary.opacity(0.12)
        }
    }
}
