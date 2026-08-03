import AppKit
import SwiftUI

extension View {
    @ViewBuilder
    func pondFocusEffectDisabled() -> some View {
        if #available(macOS 14.0, *) {
            focusEffectDisabled()
        } else {
            self
        }
    }
}

enum PondDesign {
    static let cornerRadius: CGFloat = 14
    static let compactCornerRadius: CGFloat = 9
    static let contentPadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 18
    static let rowSpacing: CGFloat = 12
    static let separator = Color(nsColor: .separatorColor)
    static let windowTop = Color(nsColor: windowTopColor)
    static let windowBottom = Color(nsColor: windowBottomColor)
    static let surface = Color(nsColor: surfaceColor)
    static let raisedSurface = Color(nsColor: raisedSurfaceColor)
    static let sidebarSurface = Color(nsColor: sidebarSurfaceColor)
    static let deepWater = Color(nsColor: deepWaterColor)
    static let onDeepWater = Color(nsColor: onDeepWaterColor)
    static let ripple = Color(nsColor: rippleColor)
    static let lotus = Color(nsColor: lotusColor)
    static let pond = Color(nsColor: pondColor)
    static let lily = Color(nsColor: lilyColor)
    static let warningForeground = Color(
        nsColor: warningForegroundColor
    )
    static let warningBackground = Color(
        nsColor: warningBackgroundColor
    )
    static let errorForeground = Color(
        nsColor: errorForegroundColor
    )

    static let windowTopColor = adaptiveColor(
        name: "MojiPondWindowTop",
        light: NSColor(
            srgbRed: 0.965,
            green: 0.976,
            blue: 0.972,
            alpha: 1
        ),
        dark: NSColor(
            srgbRed: 0.045,
            green: 0.055,
            blue: 0.057,
            alpha: 1
        ),
        highContrastLight: NSColor.white,
        highContrastDark: NSColor(
            srgbRed: 0.015,
            green: 0.04,
            blue: 0.05,
            alpha: 1
        )
    )

    static let windowBottomColor = adaptiveColor(
        name: "MojiPondWindowBottom",
        light: NSColor(
            srgbRed: 0.94,
            green: 0.955,
            blue: 0.949,
            alpha: 1
        ),
        dark: NSColor(
            srgbRed: 0.032,
            green: 0.039,
            blue: 0.041,
            alpha: 1
        ),
        highContrastLight: NSColor.white,
        highContrastDark: NSColor.black
    )

    static let surfaceColor = adaptiveColor(
        name: "MojiPondSurface",
        light: NSColor(
            srgbRed: 0.992,
            green: 0.995,
            blue: 0.993,
            alpha: 1
        ),
        dark: NSColor(
            srgbRed: 0.078,
            green: 0.088,
            blue: 0.09,
            alpha: 1
        ),
        highContrastLight: NSColor.white,
        highContrastDark: NSColor(
            srgbRed: 0.035,
            green: 0.055,
            blue: 0.06,
            alpha: 1
        )
    )

    static let raisedSurfaceColor = adaptiveColor(
        name: "MojiPondRaisedSurface",
        light: NSColor.white,
        dark: NSColor(
            srgbRed: 0.105,
            green: 0.116,
            blue: 0.118,
            alpha: 1
        ),
        highContrastLight: NSColor.white,
        highContrastDark: NSColor(
            srgbRed: 0.07,
            green: 0.09,
            blue: 0.10,
            alpha: 1
        )
    )

    static let sidebarSurfaceColor = adaptiveColor(
        name: "MojiPondSidebarSurface",
        light: NSColor(
            srgbRed: 0.925,
            green: 0.948,
            blue: 0.943,
            alpha: 1
        ),
        dark: NSColor(
            srgbRed: 0.028,
            green: 0.055,
            blue: 0.058,
            alpha: 1
        ),
        highContrastLight: NSColor(
            srgbRed: 0.93,
            green: 0.97,
            blue: 0.97,
            alpha: 1
        ),
        highContrastDark: NSColor(
            srgbRed: 0.015,
            green: 0.05,
            blue: 0.06,
            alpha: 1
        )
    )

    static let deepWaterColor = adaptiveColor(
        name: "MojiPondDeepWater",
        light: NSColor(
            srgbRed: 0.025,
            green: 0.19,
            blue: 0.21,
            alpha: 1
        ),
        dark: NSColor(
            srgbRed: 0.02,
            green: 0.15,
            blue: 0.17,
            alpha: 1
        ),
        highContrastLight: NSColor(
            srgbRed: 0,
            green: 0.14,
            blue: 0.18,
            alpha: 1
        ),
        highContrastDark: NSColor(
            srgbRed: 0,
            green: 0.10,
            blue: 0.13,
            alpha: 1
        )
    )

    static let onDeepWaterColor = adaptiveColor(
        name: "MojiPondOnDeepWater",
        light: NSColor.white,
        dark: NSColor(
            srgbRed: 0.94,
            green: 1,
            blue: 1,
            alpha: 1
        ),
        highContrastLight: NSColor.white,
        highContrastDark: NSColor.white
    )

    static let rippleColor = adaptiveColor(
        name: "MojiPondRipple",
        light: NSColor(
            srgbRed: 0.14,
            green: 0.48,
            blue: 0.50,
            alpha: 1
        ),
        dark: NSColor(
            srgbRed: 0.38,
            green: 0.74,
            blue: 0.77,
            alpha: 1
        ),
        highContrastLight: NSColor(
            srgbRed: 0,
            green: 0.38,
            blue: 0.48,
            alpha: 1
        ),
        highContrastDark: NSColor(
            srgbRed: 0.48,
            green: 0.92,
            blue: 1,
            alpha: 1
        )
    )

    static let lotusColor = adaptiveColor(
        name: "MojiPondLotus",
        light: NSColor(
            srgbRed: 0.76,
            green: 0.24,
            blue: 0.35,
            alpha: 1
        ),
        dark: NSColor(
            srgbRed: 1,
            green: 0.50,
            blue: 0.58,
            alpha: 1
        ),
        highContrastLight: NSColor(
            srgbRed: 0.58,
            green: 0.08,
            blue: 0.18,
            alpha: 1
        ),
        highContrastDark: NSColor(
            srgbRed: 1,
            green: 0.66,
            blue: 0.72,
            alpha: 1
        )
    )

    private static let pondColor = adaptiveColor(
        name: "MojiPondPond",
        light: NSColor(
            srgbRed: 0.02,
            green: 0.30,
            blue: 0.33,
            alpha: 1
        ),
        dark: NSColor(
            srgbRed: 0.42,
            green: 0.80,
            blue: 0.82,
            alpha: 1
        ),
        highContrastLight: NSColor(
            srgbRed: 0.02,
            green: 0.25,
            blue: 0.33,
            alpha: 1
        ),
        highContrastDark: NSColor(
            srgbRed: 0.58,
            green: 0.91,
            blue: 1,
            alpha: 1
        )
    )

    private static let lilyColor = adaptiveColor(
        name: "MojiPondLily",
        light: NSColor(
            srgbRed: 0.07,
            green: 0.38,
            blue: 0.16,
            alpha: 1
        ),
        dark: NSColor(
            srgbRed: 0.55,
            green: 0.88,
            blue: 0.60,
            alpha: 1
        ),
        highContrastLight: NSColor(
            srgbRed: 0.02,
            green: 0.29,
            blue: 0.10,
            alpha: 1
        ),
        highContrastDark: NSColor(
            srgbRed: 0.67,
            green: 1,
            blue: 0.70,
            alpha: 1
        )
    )

    static let selectionBackgroundColor = adaptiveColor(
        name: "MojiPondSelection",
        light: NSColor(
            srgbRed: 0.04,
            green: 0.30,
            blue: 0.38,
            alpha: 1
        ),
        dark: NSColor(
            srgbRed: 0.07,
            green: 0.36,
            blue: 0.44,
            alpha: 1
        ),
        highContrastLight: NSColor(
            srgbRed: 0.01,
            green: 0.22,
            blue: 0.29,
            alpha: 1
        ),
        highContrastDark: NSColor(
            srgbRed: 0.03,
            green: 0.28,
            blue: 0.35,
            alpha: 1
        )
    )

    static let warningForegroundColor = adaptiveColor(
        name: "MojiPondWarningForeground",
        light: NSColor(
            srgbRed: 0.30,
            green: 0.10,
            blue: 0,
            alpha: 1
        ),
        dark: NSColor(
            srgbRed: 1,
            green: 0.75,
            blue: 0.45,
            alpha: 1
        ),
        highContrastLight: NSColor(
            srgbRed: 0.22,
            green: 0.05,
            blue: 0,
            alpha: 1
        ),
        highContrastDark: NSColor(
            srgbRed: 1,
            green: 0.85,
            blue: 0.68,
            alpha: 1
        )
    )

    static let warningBackgroundColor = adaptiveColor(
        name: "MojiPondWarningBackground",
        light: NSColor(
            srgbRed: 1,
            green: 0.94,
            blue: 0.88,
            alpha: 1
        ),
        dark: NSColor(
            srgbRed: 0.20,
            green: 0.11,
            blue: 0.04,
            alpha: 1
        ),
        highContrastLight: NSColor(
            srgbRed: 1,
            green: 0.97,
            blue: 0.93,
            alpha: 1
        ),
        highContrastDark: NSColor(
            srgbRed: 0.12,
            green: 0.06,
            blue: 0.02,
            alpha: 1
        )
    )

    static let errorForegroundColor = adaptiveColor(
        name: "MojiPondErrorForeground",
        light: NSColor(
            srgbRed: 0.38,
            green: 0.02,
            blue: 0.01,
            alpha: 1
        ),
        dark: NSColor(
            srgbRed: 1,
            green: 0.64,
            blue: 0.61,
            alpha: 1
        ),
        highContrastLight: NSColor(
            srgbRed: 0.28,
            green: 0.01,
            blue: 0,
            alpha: 1
        ),
        highContrastDark: NSColor(
            srgbRed: 1,
            green: 0.78,
            blue: 0.75,
            alpha: 1
        )
    )

    private static func adaptiveColor(
        name: String,
        light: NSColor,
        dark: NSColor,
        highContrastLight: NSColor,
        highContrastDark: NSColor
    ) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            switch appearance.bestMatch(
                from: [
                    .accessibilityHighContrastDarkAqua,
                    .accessibilityHighContrastAqua,
                    .darkAqua,
                    .aqua
                ]
            ) {
            case .accessibilityHighContrastDarkAqua:
                highContrastDark
            case .accessibilityHighContrastAqua:
                highContrastLight
            case .darkAqua:
                dark
            default:
                light
            }
        }
    }
}

struct PondCard<Content: View>: View {
    private let content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .background(
                PondDesign.surface,
                in: RoundedRectangle(
                    cornerRadius: PondDesign.cornerRadius
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: PondDesign.cornerRadius)
                    .stroke(
                        PondDesign.separator.opacity(
                            contrast == .increased ? 1 : 0.65
                        ),
                        lineWidth: contrast == .increased ? 2 : 1
                    )
            }
            .shadow(
                color: Color.black.opacity(contrast == .increased ? 0 : 0.025),
                radius: 3,
                y: 1
            )
    }
}

struct PondWindowBackdrop: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            LinearGradient(
                colors: [
                    PondDesign.windowTop.opacity(0.9),
                    PondDesign.windowBottom.opacity(0.72)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    PondDesign.ripple.opacity(0.045),
                    .clear
                ],
                center: .topTrailing,
                startRadius: 16,
                endRadius: 520
            )
        }
        .accessibilityHidden(true)
    }
}

struct PondPageHeader: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(PondDesign.pond)
                .frame(width: 30, height: 30)
                .background(
                    PondDesign.pond.opacity(0.09),
                    in: Circle()
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .fontDesign(.rounded)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PondEmptyState<Actions: View>: View {
    let title: String
    let systemImage: String
    let description: String
    private let actions: Actions

    init(
        _ title: String,
        systemImage: String,
        description: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(PondDesign.pond)
                .accessibilityHidden(true)

            VStack(spacing: 5) {
                Text(title)
                    .font(.headline)
                    .fontDesign(.rounded)

                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            actions
                .padding(.top, 2)
        }
        .multilineTextAlignment(.center)
        .padding(28)
        .frame(maxWidth: 420)
        .accessibilityElement(children: .contain)
    }
}

extension PondEmptyState where Actions == EmptyView {
    init(
        _ title: String,
        systemImage: String,
        description: String
    ) {
        self.init(
            title,
            systemImage: systemImage,
            description: description
        ) {
            EmptyView()
        }
    }
}

struct PondCommandToken: View {
    let value: String

    var body: some View {
        Text(value)
            .font(.callout.monospaced().weight(.semibold))
            .foregroundStyle(PondDesign.pond)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                PondDesign.pond.opacity(0.1),
                in: RoundedRectangle(
                    cornerRadius: PondDesign.compactCornerRadius
                )
            )
    }
}

struct PondInteractiveButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(
                reduceMotion
                    ? 1
                    : configuration.isPressed ? 0.985 : 1
            )
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.1),
                value: configuration.isPressed
            )
    }
}

private struct PondFloatingPanelModifier: ViewModifier {
    let backgroundCornerRadius: CGFloat

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency)
    private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(
                    cornerRadius: backgroundCornerRadius,
                    style: .continuous
                )
                .fill(.ultraThickMaterial)

                RoundedRectangle(
                    cornerRadius: backgroundCornerRadius,
                    style: .continuous
                )
                .fill(
                    PondDesign.surface.opacity(
                        reduceTransparency ? 1 : 0.9
                    )
                )
            }
            .clipShape(
                RoundedRectangle(
                    cornerRadius: PondDesign.cornerRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: PondDesign.cornerRadius,
                    style: .continuous
                )
                .strokeBorder(
                    PondDesign.separator.opacity(
                        contrast == .increased ? 1 : 0.9
                    ),
                    lineWidth: contrast == .increased ? 2 : 1
                )
            }
            .accessibilityElement(children: .contain)
    }
}

extension View {
    func pondFloatingPanel(
        backgroundCornerRadius: CGFloat = PondDesign.cornerRadius
    ) -> some View {
        modifier(
            PondFloatingPanelModifier(
                backgroundCornerRadius: backgroundCornerRadius
            )
        )
    }
}

struct PondMark: View {
    var size: CGFloat = 72

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
        .shadow(color: Color.black.opacity(0.12), radius: 5, y: 2)
        .accessibilityHidden(true)
    }
}
