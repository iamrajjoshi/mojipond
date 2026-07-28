import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var permissions: SystemPermissionCenter
    let onFinish: () -> Void

    @State private var step = 0
    @State private var practiceText = ""

    init(appState: AppState, onFinish: @escaping () -> Void) {
        self.appState = appState
        permissions = appState.permissions
        self.onFinish = onFinish
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
                    Text("Two permissions, used narrowly")
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

            TextField("Type :wave: here", text: $practiceText)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .frame(width: 460)
                .accessibilityIdentifier("onboarding.practiceField")

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

