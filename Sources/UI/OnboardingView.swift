import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var permissions: SystemPermissionCenter
    let onFinish: () -> Void

    @State private var step = 0
    @State private var practiceText = ""
    @State private var practiceFeedback: String?
    private let practiceIndex: EmojiSearchIndex?

    init(appState: AppState, onFinish: @escaping () -> Void) {
        self.appState = appState
        permissions = appState.permissions
        self.onFinish = onFinish
        practiceIndex = try? BuiltInRuntimeCatalogLoader().loadSearchIndex()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Group {
                switch step {
                case 0:
                    welcomeStep
                case 1:
                    permissionStep
                default:
                    practiceStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(width: 760, height: 570)
        .background(.background)
    }

    private var header: some View {
        HStack {
            Label("MojiPond", systemImage: "water.waves")
                .font(.headline)
            Spacer()
            HStack(spacing: 7) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(index <= step ? PondDesign.pond : Color.secondary.opacity(0.2))
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("Step \(index + 1)")
                        .accessibilityValue(index == step ? "Current" : index < step ? "Completed" : "Upcoming")
                }
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 56)
    }

    private var welcomeStep: some View {
        VStack(spacing: 22) {
            PondMark(size: 88)

            VStack(spacing: 8) {
                Text("Every emote, right where you type")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("Use familiar shortcodes in Messages and across your Mac, then add the custom packs that make conversations yours.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 570)
            }

            HStack(spacing: 12) {
                FeatureCard(
                    icon: "keyboard",
                    title: "Stay in flow",
                    detail: "Type :wave: and keep going."
                )
                FeatureCard(
                    icon: "square.grid.2x2",
                    title: "Bring your packs",
                    detail: "Folders, ZIPs, Slack, and GitHub."
                )
                FeatureCard(
                    icon: "lock.shield",
                    title: "Local by default",
                    detail: "Your messages never leave your Mac."
                )
            }
            .frame(maxWidth: 650)
        }
        .padding(34)
    }

    private var permissionStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Permissions, used narrowly")
                        .font(.title2.weight(.semibold))
                    Text("macOS requires your approval. MojiPond cannot grant these permissions itself.")
                        .foregroundStyle(.secondary)
                }

                if !appState.isInstalledInApplications {
                    Label {
                        Text("Install MojiPond in Applications before granting access so macOS can recognize a stable app location.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .padding(12)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }

                PermissionCard(
                    icon: "keyboard",
                    title: "Input Monitoring",
                    detail: "Notices only the short token that begins with your trigger. Raw typing is never saved or logged.",
                    status: permissions.snapshot.inputMonitoring,
                    buttonTitle: "Allow Input Monitoring",
                    request: { permissions.requestInputMonitoring() },
                    openSettings: {
                        openPrivacySettings(anchor: "Privacy_ListenEvent")
                    }
                )

                PermissionCard(
                    icon: "accessibility",
                    title: "Accessibility",
                    detail: "Finds the active text field, anchors suggestions at the caret, and replaces the shortcode you selected.",
                    status: permissions.snapshot.accessibility,
                    buttonTitle: "Allow Accessibility",
                    request: { permissions.requestAccessibility() },
                    openSettings: {
                        openPrivacySettings(anchor: "Privacy_Accessibility")
                    }
                )

                PermissionCard(
                    icon: "doc.on.clipboard",
                    title: "Event Posting",
                    detail: "Lets MojiPond issue the paste command for an image or GIF. Unicode replacement does not need this permission.",
                    status: permissions.snapshot.eventPosting,
                    buttonTitle: "Allow Media Pasting",
                    request: { permissions.requestEventPosting() },
                    openSettings: {
                        openPrivacySettings(anchor: "Privacy_Accessibility")
                    }
                )

                Label(
                    "MojiPond does not request Screen Recording, Full Disk Access, Contacts, or access to your Messages database.",
                    systemImage: "checkmark.shield"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding(30)
        }
    }

    private var practiceStep: some View {
        VStack(spacing: 22) {
            Image(systemName: appState.canMonitorTyping ? "checkmark.circle.fill" : "rectangle.and.pencil.and.ellipsis")
                .font(.system(size: 48))
                .foregroundStyle(appState.canMonitorTyping ? PondDesign.lily : PondDesign.pond)
                .accessibilityHidden(true)

            VStack(spacing: 7) {
                Text(appState.canMonitorTyping ? "You’re ready to ripple" : "Library mode is ready")
                    .font(.title2.weight(.semibold))
                Text(
                    appState.canMonitorTyping
                        ? "Try typing :wave: below. Suggestions should appear beside your caret."
                        : "You can browse and copy emoji now, then grant typing permissions whenever you’re ready."
                )
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)
            }

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
            .frame(width: 460)

            Label(
                "MojiPond favors doing nothing when it is not certain, so ordinary Tab and Return behavior stays untouched.",
                systemImage: "hand.raised"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 520)
        }
        .padding(34)
    }

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Back") {
                    step -= 1
                }
            }

            Spacer()

            if step == 1 && !appState.canMonitorTyping {
                Button("Continue in Library Mode") {
                    step = 2
                }
            }

            Button(step == 2 ? "Open MojiPond" : "Continue") {
                if step < 2 {
                    step += 1
                } else {
                    appState.finishOnboarding()
                    onFinish()
                }
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .frame(height: 64)
    }

    private func openPrivacySettings(anchor: String) {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)",
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private var triggerText: String {
        appState.preferences.shortcode.trigger.rawValue
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
        practiceFeedback = "Exact token replaced locally"
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
        practiceFeedback = "Suggestion inserted locally"
    }

    private func unicodeValue(for item: EmojiItem) -> String? {
        guard case let .unicode(content) = item.content else {
            return nil
        }
        return content.value
    }
}

private struct FeatureCard: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        PondCard {
            VStack(alignment: .leading, spacing: 9) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(PondDesign.pond)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PermissionCard: View {
    let icon: String
    let title: String
    let detail: String
    let status: SystemPermissionStatus
    let buttonTitle: String
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
                        PermissionStatusView(status: status)
                    }
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 14)

                VStack(alignment: .trailing, spacing: 8) {
                    if status != .granted {
                        Button(buttonTitle, action: request)
                            .buttonStyle(.borderedProminent)
                        Button("Open System Settings", action: openSettings)
                            .buttonStyle(.link)
                    }
                }
            }
        }
    }
}

struct PermissionStatusView: View {
    let status: SystemPermissionStatus

    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
            .accessibilityLabel("Permission status")
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

    private var color: Color {
        switch status {
        case .granted: PondDesign.lily
        case .denied, .revoked: .orange
        case .notRequested: .secondary
        }
    }
}
