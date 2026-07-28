import AppKit
import Combine
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
    let query: String?

    var selectedRow: RuntimeSuggestionRow? {
        rows.indices.contains(selectedIndex) ? rows[selectedIndex] : nil
    }
}

enum RuntimeVoiceOverAnnouncement {
    static func suggestions(
        _ snapshot: RuntimeSuggestionPanelSnapshot
    ) -> String {
        let selected = selectedDescription(row: snapshot.selectedRow)
        if snapshot.mode == .browser {
            let count = snapshot.rows.count
            let word = count == 1 ? "result" : "results"
            let query = snapshot.query ?? ""
            let scope = query.isEmpty
                ? "\(count) emoji \(word)."
                : "\(count) \(word) for \(query)."
            return [scope, selected]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        let count = snapshot.rows.count
        let word = count == 1 ? "suggestion" : "suggestions"
        return ["\(count) emoji \(word).", selected]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func media(
        _ snapshot: RuntimeMediaPanelSnapshot
    ) -> String {
        let state: String
        switch snapshot.state {
        case .idle:
            state = "Media search ready."
        case .loading:
            state = "Searching for media."
        case .results:
            state = "\(snapshot.items.count) media results."
        case .offline:
            state = "Offline. Showing \(snapshot.items.count) bundled results."
        case .empty:
            state = "No matching media."
        case .cancelled:
            state = "Media search cancelled."
        case .networkDisabled:
            state = "Network GIF search is disabled."
        case .rateLimited:
            state = "Media provider is busy."
        case .failed:
            state = "Media search failed."
        case .resolving:
            state = "Preparing selected media."
        }
        guard
            let selectedIndex = snapshot.selectedIndex,
            snapshot.items.indices.contains(selectedIndex)
        else {
            return state
        }
        return "\(state) Selected \(snapshot.items[selectedIndex].title)."
    }

    private static func selectedDescription(
        row: RuntimeSuggestionRow?
    ) -> String {
        guard let row else {
            return ""
        }
        return "Selected \(row.name), colon \(row.shortcode) colon."
    }
}

enum RuntimeSuggestionPanelUpdate: Equatable, Sendable {
    case show(
        snapshot: RuntimeSuggestionPanelSnapshot,
        quartzCaretBounds: CGRect
    )
    case retain(revision: UInt64)
    case hide(revision: UInt64)

    var revision: UInt64 {
        switch self {
        case let .show(snapshot, _):
            snapshot.revision
        case let .retain(revision):
            revision
        case let .hide(revision):
            revision
        }
    }
}

@MainActor
protocol RuntimeSuggestionPresenting: AnyObject {
    func apply(_ update: RuntimeSuggestionPanelUpdate)
    func applyMedia(_ update: RuntimeMediaPanelUpdate)
    func applyReportingVisibility(
        _ update: RuntimeSuggestionPanelUpdate
    ) -> Bool
    func applyMediaReportingVisibility(
        _ update: RuntimeMediaPanelUpdate
    ) -> Bool
}

extension RuntimeSuggestionPresenting {
    func applyMedia(_ update: RuntimeMediaPanelUpdate) {
        _ = update
    }

    func applyReportingVisibility(
        _ update: RuntimeSuggestionPanelUpdate
    ) -> Bool {
        apply(update)
        return true
    }

    func applyMediaReportingVisibility(
        _ update: RuntimeMediaPanelUpdate
    ) -> Bool {
        applyMedia(update)
        return true
    }
}

/// A keyboard-only, nonactivating surface. Ignoring mouse events is deliberate:
/// a global click always dismisses the active transaction instead of racing a
/// panel click against a focus change in the destination app.
@MainActor
private final class RuntimeSuggestionPanelModel: ObservableObject {
    @Published var snapshot: RuntimeSuggestionPanelSnapshot

    init(snapshot: RuntimeSuggestionPanelSnapshot) {
        self.snapshot = snapshot
    }
}

@MainActor
final class RuntimeSuggestionPanelController: RuntimeSuggestionPresenting {
    private let panel: NonactivatingCaretPanel
    private let suggestionModel: RuntimeSuggestionPanelModel
    private let hostingController: NSHostingController<RuntimeSuggestionPanelView>
    private let mediaPanel: NonactivatingCaretPanel
    private let mediaModel: RuntimeMediaPanelModel
    private let mediaHostingController:
        NSHostingController<RuntimeMediaPanelView>
    private var latestRevision: UInt64 = 0
    private var latestMediaRevision: UInt64 = 0
    private var lastSuggestionAnnouncement: String?
    private var lastMediaAnnouncement: String?

    init() {
        let initialSnapshot = RuntimeSuggestionPanelSnapshot(
            revision: 0,
            transactionID: ParserTransactionID(rawValue: 0),
            mode: .hidden,
            rows: [],
            selectedIndex: 0,
            query: nil
        )
        let suggestionModel = RuntimeSuggestionPanelModel(
            snapshot: initialSnapshot
        )
        self.suggestionModel = suggestionModel
        hostingController = NSHostingController(
            rootView: RuntimeSuggestionPanelView(model: suggestionModel)
        )
        let mediaModel = RuntimeMediaPanelModel(snapshot: .empty)
        self.mediaModel = mediaModel
        mediaHostingController = NSHostingController(
            rootView: RuntimeMediaPanelView(model: mediaModel)
        )
        panel = NonactivatingCaretPanel(
            contentRect: CGRect(x: 0, y: 0, width: 380, height: 48)
        )
        mediaPanel = NonactivatingCaretPanel(
            contentRect: CGRect(x: 0, y: 0, width: 500, height: 210)
        )
        panel.contentViewController = hostingController
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.setAccessibilityLabel("MojiPond emoji suggestions")
        panel.setAccessibilityIdentifier("runtime.suggestionPanel")

        mediaPanel.contentViewController = mediaHostingController
        mediaPanel.backgroundColor = .clear
        mediaPanel.isOpaque = false
        mediaPanel.hasShadow = true
        mediaPanel.ignoresMouseEvents = true
        mediaPanel.setAccessibilityLabel("MojiPond media search")
        mediaPanel.setAccessibilityIdentifier("runtime.mediaPanel")
    }

    func applyMedia(_ update: RuntimeMediaPanelUpdate) {
        _ = applyMediaReportingVisibility(update)
    }

    func applyMediaReportingVisibility(
        _ update: RuntimeMediaPanelUpdate
    ) -> Bool {
        guard update.revision >= latestMediaRevision else {
            return false
        }
        latestMediaRevision = update.revision

        switch update {
        case .hide:
            mediaPanel.orderOut(nil)
            lastMediaAnnouncement = nil
            return false
        case let .show(snapshot, caretBounds):
            panel.orderOut(nil)
            mediaModel.snapshot = snapshot
            mediaPanel.setContentSize(
                RuntimeMediaPanelView.preferredSize(for: snapshot)
            )
            guard CaretPanelPositioner.position(
                mediaPanel,
                nearQuartzCaret: caretBounds
            ) != nil else {
                mediaPanel.orderOut(nil)
                return false
            }
            if !mediaPanel.isVisible {
                mediaPanel.orderFrontRegardless()
            }
            announceMedia(snapshot)
            return true
        }
    }

    func apply(_ update: RuntimeSuggestionPanelUpdate) {
        _ = applyReportingVisibility(update)
    }

    func applyReportingVisibility(
        _ update: RuntimeSuggestionPanelUpdate
    ) -> Bool {
        guard update.revision >= latestRevision else {
            return false
        }
        latestRevision = update.revision

        switch update {
        case .retain:
            return panel.isVisible

        case let .hide(revision):
            _ = revision
            panel.orderOut(nil)
            lastSuggestionAnnouncement = nil
            return false

        case let .show(snapshot, caretBounds):
            guard !snapshot.rows.isEmpty || snapshot.mode == .browser else {
                panel.orderOut(nil)
                return false
            }
            suggestionModel.snapshot = snapshot
            panel.title = snapshot.mode == .browser
                ? "MojiPond Emoji Browser"
                : "MojiPond Caret Suggestions"
            panel.setAccessibilityLabel(
                snapshot.mode == .browser
                    ? "MojiPond emoji browser"
                    : "MojiPond emoji suggestions"
            )
            let size = Self.preferredSize(for: snapshot)
            panel.setContentSize(size)
            guard CaretPanelPositioner.position(
                panel,
                nearQuartzCaret: caretBounds
            ) != nil else {
                panel.orderOut(nil)
                return false
            }
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
            announceSuggestions(snapshot)
            return true
        }
    }

    private func announceSuggestions(
        _ snapshot: RuntimeSuggestionPanelSnapshot
    ) {
        let announcement = RuntimeVoiceOverAnnouncement.suggestions(snapshot)
        guard announcement != lastSuggestionAnnouncement else {
            return
        }
        lastSuggestionAnnouncement = announcement
        postAnnouncement(announcement, from: panel)
    }

    private func announceMedia(
        _ snapshot: RuntimeMediaPanelSnapshot
    ) {
        let announcement = RuntimeVoiceOverAnnouncement.media(snapshot)
        guard announcement != lastMediaAnnouncement else {
            return
        }
        lastMediaAnnouncement = announcement
        postAnnouncement(announcement, from: mediaPanel)
    }

    private func postAnnouncement(
        _ announcement: String,
        from element: Any
    ) {
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    nonisolated static func preferredSize(
        for snapshot: RuntimeSuggestionPanelSnapshot
    ) -> CGSize {
        switch snapshot.mode {
        case .hidden:
            CGSize(width: 380, height: 1)
        case .suggestions:
            CGSize(width: 380, height: 282)
        case .browser:
            CGSize(
                width: 440,
                height: CGFloat(min(max(snapshot.rows.count, 1), 8) * 44 + 48)
            )
        case .media:
            CGSize(width: 440, height: 1)
        }
    }
}

struct RuntimeSuggestionPanelView: View {
    @ObservedObject fileprivate var model: RuntimeSuggestionPanelModel
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency)
    private var reduceTransparency

    private var snapshot: RuntimeSuggestionPanelSnapshot {
        model.snapshot
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if snapshot.mode == .browser {
                HStack(spacing: 8) {
                    Image(systemName: "water.waves")
                        .foregroundStyle(.tint)
                    Text("MojiPond")
                        .font(.headline)
                    if let query = snapshot.query, !query.isEmpty {
                        Text(query)
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("↑↓ choose  ·  ↩ insert  ·  esc close")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(
                            "Up and Down Arrow choose, Return inserts, "
                                + "Escape closes"
                        )
                }
                .padding(.horizontal, 12)
                .frame(height: 42)
            }

            if snapshot.mode == .browser {
                ScrollViewReader { proxy in
                    ScrollView {
                        rows
                    }
                    .onAppear {
                        if let selected = snapshot.selectedRow {
                            proxy.scrollTo(selected.id, anchor: .center)
                        }
                    }
                    .onChange(of: snapshot.selectedRow?.id) {
                        if let selected = snapshot.selectedRow {
                            proxy.scrollTo(selected.id, anchor: .center)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    rows
                    Spacer(minLength: 0)
                    Divider()
                    Text("↑↓ choose  ·  tab or ↩ insert  ·  esc close")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(
                            "Up and Down Arrow choose, Tab or Return inserts, "
                                + "Escape closes"
                        )
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                }
                .frame(height: 270, alignment: .top)
            }
        }
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    reduceTransparency
                        ? AnyShapeStyle(
                            Color(nsColor: .windowBackgroundColor)
                        )
                        : AnyShapeStyle(.regularMaterial)
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    .primary.opacity(
                        contrast == .increased ? 0.5 : 0.12
                    ),
                    lineWidth: contrast == .increased ? 2 : 1
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            snapshot.mode == .browser
                ? "MojiPond emoji browser"
                : "MojiPond emoji suggestions"
        )
    }

    @ViewBuilder
    private var rows: some View {
        if snapshot.rows.isEmpty {
            Text("No matching emoji")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
        } else {
            ForEach(Array(snapshot.rows.enumerated()), id: \.element.id) {
                index,
                row in
                RuntimeSuggestionRowView(
                    row: row,
                    isSelected: index == snapshot.selectedIndex,
                    compact: snapshot.mode == .browser
                )
                .id(row.id)
            }
        }
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
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(PondDesign.selectionForeground)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: compact ? 44 : 48)
        .foregroundStyle(
            isSelected
                ? PondDesign.selectionForeground
                : Color.primary
        )
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isSelected
                        ? PondDesign.selectionBackground
                        : Color.clear
                )
                .padding(.horizontal, 5)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.name), colon \(row.shortcode) colon")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
