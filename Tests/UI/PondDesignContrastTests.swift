import AppKit
import XCTest
@testable import MojiPond

@MainActor
final class PondDesignContrastTests: XCTestCase {
    func testStatusForegroundsMeetNormalTextContrastAcrossAppearances() throws {
        let foregrounds: [(String, NSColor)] = [
            ("warning", PondDesign.warningForegroundColor),
            ("error", PondDesign.errorForegroundColor)
        ]
        let backgrounds: [(String, NSColor)] = [
            ("window", .windowBackgroundColor),
            ("control", .controlBackgroundColor),
            ("under-page", .underPageBackgroundColor)
        ]

        for (appearanceName, appearance) in try appearances() {
            for (foregroundName, foregroundColor) in foregrounds {
                let foreground = try resolve(
                    foregroundColor,
                    appearance: appearance
                )
                for (backgroundName, color) in backgrounds {
                    let background = try resolve(
                        color,
                        appearance: appearance
                    )
                    let ratio = contrastRatio(
                        foreground,
                        background
                    )

                    XCTAssertGreaterThanOrEqual(
                        ratio,
                        4.5,
                        "\(foregroundName) foreground has "
                            + "\(ratio) contrast against \(backgroundName) "
                            + "in \(appearanceName)"
                    )
                }
            }
        }
    }

    func testWarningForegroundContrastsWithWarningBackground() throws {
        for (appearanceName, appearance) in try appearances() {
            let foreground = try resolve(
                PondDesign.warningForegroundColor,
                appearance: appearance
            )
            let background = try resolve(
                PondDesign.warningBackgroundColor,
                appearance: appearance
            )
            let ratio = contrastRatio(foreground, background)

            XCTAssertGreaterThanOrEqual(
                ratio,
                4.5,
                "Warning colors have \(ratio) contrast in \(appearanceName)"
            )
        }
    }

    func testBrandTextContrastsWithDeepWater() throws {
        for (appearanceName, appearance) in try appearances() {
            let foreground = try resolve(
                PondDesign.onDeepWaterColor,
                appearance: appearance
            )
            let background = try resolve(
                PondDesign.deepWaterColor,
                appearance: appearance
            )
            let ratio = contrastRatio(foreground, background)

            XCTAssertGreaterThanOrEqual(
                ratio,
                4.5,
                "Brand text has \(ratio) contrast in \(appearanceName)"
            )
        }
    }

    func testSelectedTextContrastsWithSelectionBackground() throws {
        for (appearanceName, appearance) in try appearances() {
            let foreground = try resolve(
                .white,
                appearance: appearance
            )
            let background = try resolve(
                PondDesign.selectionBackgroundColor,
                appearance: appearance
            )
            let ratio = contrastRatio(foreground, background)

            XCTAssertGreaterThanOrEqual(
                ratio,
                4.5,
                "Selected text has \(ratio) contrast in \(appearanceName)"
            )
        }
    }

    private func appearances() throws -> [(String, NSAppearance)] {
        try [
            ("light", NSAppearance.Name.aqua),
            ("dark", .darkAqua),
            ("high-contrast light", .accessibilityHighContrastAqua),
            ("high-contrast dark", .accessibilityHighContrastDarkAqua)
        ].map { name, appearanceName in
            (
                name,
                try XCTUnwrap(NSAppearance(named: appearanceName))
            )
        }
    }

    private func resolve(
        _ color: NSColor,
        appearance: NSAppearance
    ) throws -> NSColor {
        var resolvedColor: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolvedColor = color.usingColorSpace(.sRGB)
        }
        return try XCTUnwrap(resolvedColor)
    }

    private func contrastRatio(
        _ lhs: NSColor,
        _ rhs: NSColor
    ) -> CGFloat {
        let lhsLuminance = relativeLuminance(lhs)
        let rhsLuminance = relativeLuminance(rhs)
        return (
            max(lhsLuminance, rhsLuminance) + 0.05
        ) / (
            min(lhsLuminance, rhsLuminance) + 0.05
        )
    }

    private func relativeLuminance(_ color: NSColor) -> CGFloat {
        0.2126 * linearize(color.redComponent)
            + 0.7152 * linearize(color.greenComponent)
            + 0.0722 * linearize(color.blueComponent)
    }

    private func linearize(_ component: CGFloat) -> CGFloat {
        guard component > 0.04045 else {
            return component / 12.92
        }
        return CGFloat(
            pow(
                Double((component + 0.055) / 1.055),
                2.4
            )
        )
    }
}
