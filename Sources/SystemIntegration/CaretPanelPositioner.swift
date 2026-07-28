import AppKit
import CoreGraphics
import Foundation

struct DisplayGeometry: Equatable, Sendable {
    /// Screen frame in AppKit's bottom-left-origin coordinate system.
    let appKitFrame: CGRect
    /// Matching display bounds in Quartz's top-left-origin coordinate system.
    let quartzFrame: CGRect
    let visibleFrame: CGRect
}

enum CaretPanelEdge: Equatable, Sendable {
    case below
    case above
}

struct CaretPanelPlacement: Equatable, Sendable {
    let frame: CGRect
    let edge: CaretPanelEdge
}

enum CaretPanelPositioner {
    @MainActor
    static func currentDisplays() -> [DisplayGeometry] {
        NSScreen.screens.compactMap { screen in
            guard
                let number = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? NSNumber
            else {
                return nil
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            return DisplayGeometry(
                appKitFrame: screen.frame,
                quartzFrame: CGDisplayBounds(displayID),
                visibleFrame: screen.visibleFrame
            )
        }
    }

    static func appKitCaretRect(
        fromQuartz rectangle: CGRect,
        displays: [DisplayGeometry]
    ) -> CGRect? {
        guard !displays.isEmpty else {
            return nil
        }
        let probe = CGPoint(
            x: rectangle.midX,
            y: rectangle.height > 0 ? rectangle.midY : rectangle.minY
        )
        let display = displays.first(where: { $0.quartzFrame.contains(probe) })
            ?? displays.min(by: {
                squaredDistance(from: probe, to: $0.quartzFrame)
                    < squaredDistance(from: probe, to: $1.quartzFrame)
            })
        guard let display else {
            return nil
        }

        let localX = rectangle.minX - display.quartzFrame.minX
        let localY = rectangle.minY - display.quartzFrame.minY
        return CGRect(
            x: display.appKitFrame.minX + localX,
            y: display.appKitFrame.maxY - localY - rectangle.height,
            width: rectangle.width,
            height: rectangle.height
        )
    }

    static func placement(
        panelSize: CGSize,
        nearAppKitCaret caret: CGRect,
        visibleFrame: CGRect,
        gap: CGFloat = 6,
        fallbackCaretHeight: CGFloat = 18
    ) -> CaretPanelPlacement {
        let normalizedPanelSize = CGSize(
            width: min(max(1, panelSize.width), max(1, visibleFrame.width)),
            height: min(max(1, panelSize.height), max(1, visibleFrame.height))
        )
        let normalizedCaret = CGRect(
            x: caret.minX,
            y: caret.minY,
            width: max(1, caret.width),
            height: max(fallbackCaretHeight, caret.height)
        )

        let spaceBelow = normalizedCaret.minY - visibleFrame.minY
        let spaceAbove = visibleFrame.maxY - normalizedCaret.maxY
        let fitsBelow = spaceBelow >= normalizedPanelSize.height + gap
        let edge: CaretPanelEdge = fitsBelow || spaceBelow >= spaceAbove
            ? .below
            : .above

        let proposedY: CGFloat = switch edge {
        case .below:
            normalizedCaret.minY - gap - normalizedPanelSize.height
        case .above:
            normalizedCaret.maxY + gap
        }
        let proposedX = normalizedCaret.minX
        let maximumX = visibleFrame.maxX - normalizedPanelSize.width
        let maximumY = visibleFrame.maxY - normalizedPanelSize.height
        let origin = CGPoint(
            x: min(max(proposedX, visibleFrame.minX), maximumX),
            y: min(max(proposedY, visibleFrame.minY), maximumY)
        )

        return CaretPanelPlacement(
            frame: CGRect(origin: origin, size: normalizedPanelSize),
            edge: edge
        )
    }

    @MainActor
    @discardableResult
    static func position(
        _ panel: NSPanel,
        nearQuartzCaret quartzCaret: CGRect,
        displays: [DisplayGeometry]? = nil,
        gap: CGFloat = 6
    ) -> CaretPanelPlacement? {
        let displays = displays ?? currentDisplays()
        guard
            let caret = appKitCaretRect(
                fromQuartz: quartzCaret,
                displays: displays
            )
        else {
            return nil
        }
        let probe = CGPoint(x: caret.midX, y: caret.midY)
        guard let display = displays.first(where: { $0.appKitFrame.contains(probe) })
            ?? displays.first
        else {
            return nil
        }

        let result = placement(
            panelSize: panel.frame.size,
            nearAppKitCaret: caret,
            visibleFrame: display.visibleFrame,
            gap: gap
        )
        panel.setFrame(result.frame, display: false)
        return result
    }

    private static func squaredDistance(
        from point: CGPoint,
        to rectangle: CGRect
    ) -> CGFloat {
        let dx = max(
            max(rectangle.minX - point.x, 0),
            point.x - rectangle.maxX
        )
        let dy = max(
            max(rectangle.minY - point.y, 0),
            point.y - rectangle.maxY
        )
        return dx * dx + dy * dy
    }
}

final class NonactivatingCaretPanel: NSPanel {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    convenience init(contentRect: CGRect) {
        self.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovable = false
        isReleasedWhenClosed = false
    }
}
