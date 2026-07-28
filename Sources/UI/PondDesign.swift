import AppKit
import SwiftUI

enum PondDesign {
    static let cornerRadius: CGFloat = 12
    static let compactCornerRadius: CGFloat = 9
    static let contentPadding: CGFloat = 20
    static let pond = Color(nsColor: pondColor)
    static let lily = Color(nsColor: lilyColor)
    static let selectionBackground = Color(
        nsColor: selectionBackgroundColor
    )
    static let selectionForeground = Color.white
    static let warningForeground = Color(
        nsColor: warningForegroundColor
    )
    static let warningBackground = Color(
        nsColor: warningBackgroundColor
    )
    static let errorForeground = Color(
        nsColor: errorForegroundColor
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

    private static let selectionBackgroundColor = adaptiveColor(
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
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: PondDesign.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: PondDesign.cornerRadius)
                    .stroke(
                        .separator.opacity(
                            contrast == .increased ? 1 : 0.55
                        ),
                        lineWidth: contrast == .increased ? 2 : 1
                    )
            }
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

struct PondMark: View {
    var size: CGFloat = 72

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
        .shadow(color: PondDesign.pond.opacity(0.22), radius: 16, y: 8)
        .accessibilityHidden(true)
    }
}
