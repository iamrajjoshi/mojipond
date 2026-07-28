import AppKit
import SwiftUI

struct RuntimeSuggestionRow: Identifiable, Equatable, Sendable {
    let id: EmojiItem.ID
    let glyph: String
    let shortcode: String
    let name: String
}

struct RuntimeSuggestionPanelSnapshot: Equatable, Sendable {
    let revision: UInt64
    let transactionID: ParserTransactionID
    let mode: RuntimeInterceptionMode
    let rows: [RuntimeSuggestionRow]
    let selectedIndex: Int

    var selectedRow: RuntimeSuggestionRow? {
        rows.indices.contains(selectedIndex) ? rows[selectedIndex] : nil
    }
}

enum RuntimeSuggestionPanelUpdate: Equatable, Sendable {
    case show(
        snapshot: RuntimeSuggestionPanelSnapshot,
        quartzCaretBounds: CGRect
    )
    case hide(revision: UInt64)

    var revision: UInt64 {
        switch self {
        case let .show(snapshot, _):
            snapshot.revision
        case let .hide(revision):
            revision
        }
    }
}

@MainActor
protocol RuntimeSuggestionPresenting: AnyObject {
    func apply(_ update: RuntimeSuggestionPanelUpdate)
}

/// A keyboard-only, nonactivating surface. Ignoring mouse events is deliberate:
/// a global click always dismisses the active transaction instead of racing a
/// panel click against a focus change in the destination app.
@MainActor
final class RuntimeSuggestionPanelController: RuntimeSuggestionPresenting {
    private let panel: NonactivatingCaretPanel
    private let hostingController: NSHostingController<RuntimeSuggestionPanelView>
    private var latestRevision: UInt64 = 0

    init() {
        let initial = RuntimeSuggestionPanelView(
            snapshot: RuntimeSuggestionPanelSnapshot(
                revision: 0,
                transactionID: ParserTransactionID(rawValue: 0),
                mode: .hidden,
                rows: [],
                selectedIndex: 0
            )
        )
        hostingController = NSHostingController(rootView: initial)
        panel = NonactivatingCaretPanel(
            contentRect: CGRect(x: 0, y: 0, width: 380, height: 48)
        )
        panel.contentViewController = hostingController
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.setAccessibilityLabel("MojiPond emoji suggestions")
    }

    func apply(_ update: RuntimeSuggestionPanelUpdate) {
        guard update.revision >= latestRevision else {
            return
        }
        latestRevision = update.revision

        switch update {
        case let .hide(revision):
            _ = revision
            panel.orderOut(nil)

        case let .show(snapshot, caretBounds):
            guard !snapshot.rows.isEmpty else {
                panel.orderOut(nil)
                return
            }
            hostingController.rootView = RuntimeSuggestionPanelView(
                snapshot: snapshot
            )
            let size = Self.panelSize(for: snapshot)
            panel.setContentSize(size)
            guard CaretPanelPositioner.position(
                panel,
                nearQuartzCaret: caretBounds
            ) != nil else {
                panel.orderOut(nil)
                return
            }
            panel.orderFrontRegardless()
        }
    }

    private static func panelSize(
        for snapshot: RuntimeSuggestionPanelSnapshot
    ) -> CGSize {
        switch snapshot.mode {
        case .hidden:
            CGSize(width: 380, height: 1)
        case .suggestions:
            CGSize(
                width: 380,
                height: CGFloat(snapshot.rows.count * 48 + 12)
            )
        case .browser:
            CGSize(
                width: 440,
                height: CGFloat(snapshot.rows.count * 44 + 48)
            )
        }
    }
}

struct RuntimeSuggestionPanelView: View {
    let snapshot: RuntimeSuggestionPanelSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if snapshot.mode == .browser {
                HStack(spacing: 8) {
                    Image(systemName: "water.waves")
                        .foregroundStyle(.tint)
                    Text("MojiPond")
                        .font(.headline)
                    Spacer()
                    Text("↑↓ choose  ·  ↩ insert  ·  esc close")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(height: 42)
            }

            ForEach(Array(snapshot.rows.enumerated()), id: \.element.id) {
                index,
                row in
                RuntimeSuggestionRowView(
                    row: row,
                    isSelected: index == snapshot.selectedIndex,
                    compact: snapshot.mode == .browser
                )
            }
        }
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            snapshot.mode == .browser
                ? "MojiPond emoji browser"
                : "MojiPond emoji suggestions"
        )
    }
}

private struct RuntimeSuggestionRowView: View {
    let row: RuntimeSuggestionRow
    let isSelected: Bool
    let compact: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(row.glyph)
                .font(.system(size: compact ? 22 : 25))
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(":\(row.shortcode):")
                    .font(.system(.body, design: .monospaced, weight: .medium))
                    .lineLimit(1)
                if !compact {
                    Text(row.name)
                        .font(.caption)
                        .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .frame(height: compact ? 44 : 48)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
                .padding(.horizontal, 5)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.name), colon \(row.shortcode) colon")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
