import AppKit
import SwiftUI

enum PondDesign {
    static let cornerRadius: CGFloat = 10
    static let compactCornerRadius: CGFloat = 8
    static let contentPadding: CGFloat = 16
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
            srgbRed: 0.93,
            green: 0.97,
            blue: 0.97,
            alpha: 1
        ),
        dark: NSColor(
            srgbRed: 0.035,
            green: 0.075,
            blue: 0.085,
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
            srgbRed: 0.985,
            green: 0.99,
            blue: 0.985,
            alpha: 1
        ),
        dark: NSColor(
            srgbRed: 0.055,
            green: 0.065,
            blue: 0.07,
            alpha: 1
        ),
        highContrastLight: NSColor.white,
        highContrastDark: NSColor.black
    )

    static let surfaceColor = adaptiveColor(
        name: "MojiPondSurface",
        light: NSColor(
            srgbRed: 0.985,
            green: 0.995,
            blue: 0.99,
            alpha: 1
        ),
        dark: NSColor(
            srgbRed: 0.075,
            green: 0.105,
            blue: 0.11,
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
            green: 0.135,
            blue: 0.14,
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
            srgbRed: 0.89,
            green: 0.95,
            blue: 0.95,
            alpha: 1
        ),
        dark: NSColor(
            srgbRed: 0.025,
            green: 0.09,
            blue: 0.105,
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
            green: 0.20,
            blue: 0.24,
            alpha: 1
        ),
        dark: NSColor(
            srgbRed: 0.02,
            green: 0.14,
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
            srgbRed: 0.13,
            green: 0.56,
            blue: 0.64,
            alpha: 1
        ),
        dark: NSColor(
            srgbRed: 0.33,
            green: 0.78,
            blue: 0.84,
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
            srgbRed: 0.05,
            green: 0.34,
            blue: 0.43,
            alpha: 1
        ),
        dark: NSColor(
            srgbRed: 0.45,
            green: 0.82,
            blue: 0.91,
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
            .padding(14)
            .background(
                PondDesign.surface,
                in: RoundedRectangle(
                    cornerRadius: PondDesign.cornerRadius
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: PondDesign.cornerRadius)
                    .stroke(
                        PondDesign.ripple.opacity(
                            contrast == .increased ? 1 : 0.2
                        ),
                        lineWidth: contrast == .increased ? 2 : 1
                    )
            }
            .shadow(
                color: Color.black.opacity(contrast == .increased ? 0 : 0.035),
                radius: 7,
                y: 2
            )
    }
}

struct PondWindowBackdrop: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [
                        PondDesign.windowTop,
                        PondDesign.windowBottom
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                ZStack {
                    ForEach([150.0, 245.0, 350.0], id: \.self) { size in
                        Circle()
                            .stroke(
                                PondDesign.ripple.opacity(0.055),
                                lineWidth: 1
                            )
                            .frame(width: size, height: size)
                    }
                }
                .position(
                    x: proxy.size.width - 36,
                    y: 30
                )

                Circle()
                    .fill(PondDesign.lotus.opacity(0.03))
                    .frame(width: 190, height: 190)
                    .position(x: 18, y: proxy.size.height - 12)
            }
        }
        .accessibilityHidden(true)
    }
}

struct PondPageHeader: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(PondDesign.onDeepWater)
                .frame(width: 34, height: 34)
                .background(
                    PondDesign.deepWater,
                    in: RoundedRectangle(
                        cornerRadius: PondDesign.compactCornerRadius
                    )
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                .fill(
                    PondDesign.surface.opacity(
                        reduceTransparency ? 1 : 0.97
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
                    PondDesign.ripple.opacity(
                        contrast == .increased ? 1 : 0.58
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
        .shadow(color: PondDesign.pond.opacity(0.16), radius: 8, y: 3)
        .accessibilityHidden(true)
    }
}
