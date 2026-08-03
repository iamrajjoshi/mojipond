import AppKit
import Combine
import SwiftUI

enum RuntimeSuggestionPresentationMetrics {
    static let maximumVisibleRows = 6
    static let maximumVisibleBrowserRows = 7
    static let suggestionRowHeight: CGFloat = 42
    static let browserHeaderHeight: CGFloat = 42
    static let browserRowHeight: CGFloat = 42
    static let suggestionFooterHeight: CGFloat = 26
    static let suggestionDividerHeight: CGFloat = 1
}

struct RuntimeSuggestionRow: Identifiable, Equatable, Sendable {
    let id: EmojiItem.ID
    let glyph: String
    let artworkURL: URL?
    let artworkFallbackURL: URL?
    let artworkRootURL: URL?
    let shortcode: String
    let name: String

    init(
        id: EmojiItem.ID,
        glyph: String,
        artworkURL: URL? = nil,
        artworkFallbackURL: URL? = nil,
        artworkRootURL: URL? = nil,
        shortcode: String,
        name: String
    ) {
        self.id = id
        self.glyph = glyph
        self.artworkURL = artworkURL
        self.artworkFallbackURL = artworkFallbackURL
        self.artworkRootURL = artworkRootURL
        self.shortcode = shortcode
        self.name = name
    }
}

struct RuntimeSuggestionPanelSnapshot: Equatable, Sendable {
    let revision: UInt64
    let transactionID: ParserTransactionID
    let mode: RuntimeInterceptionMode
    let rows: [RuntimeSuggestionRow]
    let selectedIndex: Int
    let query: String?
    let trigger: ShortcodeTrigger
    let acceptsTab: Bool
    let acceptsReturn: Bool

    init(
        revision: UInt64,
        transactionID: ParserTransactionID,
        mode: RuntimeInterceptionMode,
        rows: [RuntimeSuggestionRow],
        selectedIndex: Int,
        query: String?,
        trigger: ShortcodeTrigger = .colon,
        acceptsTab: Bool = true,
        acceptsReturn: Bool = true
    ) {
        self.revision = revision
        self.transactionID = transactionID
        self.mode = mode
        self.rows = rows
        self.selectedIndex = selectedIndex
        self.query = query
        self.trigger = trigger
        self.acceptsTab = acceptsTab
        self.acceptsReturn = acceptsReturn
    }

    var visibleRows: [RuntimeSuggestionRow] {
        guard mode == .suggestions else {
            return rows
        }
        return Array(
            rows.prefix(
                RuntimeSuggestionPresentationMetrics.maximumVisibleRows
            )
        )
    }

    var selectedRow: RuntimeSuggestionRow? {
        return rows.indices.contains(selectedIndex)
            ? rows[selectedIndex]
            : nil
    }

    var compactInteractionHint: String {
        if visibleRows.isEmpty {
            if mode == .browser, (query ?? "").isEmpty {
                return "type to search  ·  esc close"
            }
            return "⌫ edit  ·  esc close"
        }

        switch (acceptsTab, acceptsReturn) {
        case (true, true):
            return "↑↓ choose  ·  tab or ↩ insert  ·  esc close"
        case (true, false):
            return "↑↓ choose  ·  tab insert  ·  esc close"
        case (false, true):
            return "↑↓ choose  ·  ↩ insert  ·  esc close"
        case (false, false):
            return "↑↓ choose  ·  esc close"
        }
    }

    var compactInteractionAccessibilityLabel: String {
        if visibleRows.isEmpty {
            if mode == .browser, (query ?? "").isEmpty {
                return "Type to search, Escape closes"
            }
            return "Backspace edits, Escape closes"
        }

        switch (acceptsTab, acceptsReturn) {
        case (true, true):
            return "Up and Down Arrow choose, Tab or Return inserts, Escape closes"
        case (true, false):
            return "Up and Down Arrow choose, Tab inserts, Escape closes"
        case (false, true):
            return "Up and Down Arrow choose, Return inserts, Escape closes"
        case (false, false):
            return "Up and Down Arrow choose, Escape closes"
        }
    }
}

enum RuntimeVoiceOverAnnouncement {
    static func suggestionUpdate(
        _ snapshot: RuntimeSuggestionPanelSnapshot,
        after previous: RuntimeSuggestionPanelSnapshot?
    ) -> String {
        guard
            let previous,
            previous.transactionID == snapshot.transactionID,
            previous.mode == snapshot.mode,
            previous.query == snapshot.query,
            previous.rows.count == snapshot.rows.count,
            previous.selectedRow?.id != snapshot.selectedRow?.id
        else {
            return suggestions(snapshot)
        }

        return selectedDescription(
            row: snapshot.selectedRow,
            trigger: snapshot.trigger
        )
    }

    static func suggestions(
        _ snapshot: RuntimeSuggestionPanelSnapshot
    ) -> String {
        if snapshot.mode == .committing {
            guard let row = snapshot.selectedRow else {
                return "Adding custom emoji. Escape cancels."
            }
            return "Adding \(row.name). Escape cancels."
        }
        let selected = selectedDescription(
            row: snapshot.selectedRow,
            trigger: snapshot.trigger
        )
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

    private static func selectedDescription(
        row: RuntimeSuggestionRow?,
        trigger: ShortcodeTrigger
    ) -> String {
        guard let row else {
            return ""
        }
        return "Selected \(row.name), \(trigger.accessibilityName) "
            + "\(row.shortcode) \(trigger.accessibilityName)."
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

enum RuntimeSuggestionPanelInteraction: Equatable, Sendable {
    case hover(
        transactionID: ParserTransactionID,
        itemID: EmojiItem.ID
    )
    case accept(
        transactionID: ParserTransactionID,
        itemID: EmojiItem.ID
    )
}

@MainActor
protocol RuntimeSuggestionPresenting: AnyObject {
    func apply(_ update: RuntimeSuggestionPanelUpdate)
    func applyReportingVisibility(
        _ update: RuntimeSuggestionPanelUpdate
    ) -> Bool
    func configureInteractions(
        handler: @escaping @Sendable (
            RuntimeSuggestionPanelInteraction
        ) -> Void,
        quartzFrameDidChange: @escaping @Sendable (CGRect?) -> Void
    )
}

extension RuntimeSuggestionPresenting {
    func applyReportingVisibility(
        _ update: RuntimeSuggestionPanelUpdate
    ) -> Bool {
        apply(update)
        return true
    }

    func configureInteractions(
        handler: @escaping @Sendable (
            RuntimeSuggestionPanelInteraction
        ) -> Void,
        quartzFrameDidChange: @escaping @Sendable (CGRect?) -> Void
    ) {
        _ = handler
        quartzFrameDidChange(nil)
    }

}

@MainActor
private final class RuntimeSuggestionPanelModel: ObservableObject {
    @Published var snapshot: RuntimeSuggestionPanelSnapshot
    var interactionHandler:
        (@Sendable (RuntimeSuggestionPanelInteraction) -> Void)?

    init(snapshot: RuntimeSuggestionPanelSnapshot) {
        self.snapshot = snapshot
    }

    func send(_ interaction: RuntimeSuggestionPanelInteraction) {
        interactionHandler?(interaction)
    }
}

@MainActor
final class RuntimeSuggestionPanelController: RuntimeSuggestionPresenting {
    private let panel: NonactivatingCaretPanel
    private let suggestionModel: RuntimeSuggestionPanelModel
    private let hostingController: NSHostingController<RuntimeSuggestionPanelView>
    private var latestRevision: UInt64 = 0
    private var lastSuggestionAnnouncement: String?
    private var lastAnnouncedSuggestionSnapshot:
        RuntimeSuggestionPanelSnapshot?
    private var quartzFrameDidChange:
        (@Sendable (CGRect?) -> Void)?

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
        panel = NonactivatingCaretPanel(
            contentRect: CGRect(x: 0, y: 0, width: 380, height: 48)
        )
        panel.contentViewController = hostingController
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.setAccessibilityLabel("MojiPond emoji suggestions")
        panel.setAccessibilityIdentifier("runtime.suggestionPanel")

    }

    func apply(_ update: RuntimeSuggestionPanelUpdate) {
        _ = applyReportingVisibility(update)
    }

    func configureInteractions(
        handler: @escaping @Sendable (
            RuntimeSuggestionPanelInteraction
        ) -> Void,
        quartzFrameDidChange: @escaping @Sendable (CGRect?) -> Void
    ) {
        suggestionModel.interactionHandler = handler
        self.quartzFrameDidChange = quartzFrameDidChange
        quartzFrameDidChange(
            panel.isVisible ? currentQuartzPanelFrame() : nil
        )
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
            quartzFrameDidChange?(nil)
            lastSuggestionAnnouncement = nil
            lastAnnouncedSuggestionSnapshot = nil
            return false

        case let .show(snapshot, caretBounds):
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
                quartzFrameDidChange?(nil)
                return false
            }
            quartzFrameDidChange?(currentQuartzPanelFrame())
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
            announceSuggestions(snapshot)
            return true
        }
    }

    private func currentQuartzPanelFrame() -> CGRect? {
        Self.quartzFrame(
            forAppKitFrame: panel.frame,
            displays: CaretPanelPositioner.currentDisplays()
        )
    }

    nonisolated static func quartzFrame(
        forAppKitFrame frame: CGRect,
        displays: [DisplayGeometry]
    ) -> CGRect? {
        guard
            frame.width > 0,
            frame.height > 0,
            let display = displays.first(where: {
                $0.appKitFrame.contains(
                    CGPoint(x: frame.midX, y: frame.midY)
                )
            })
        else {
            return nil
        }
        return CGRect(
            x: display.quartzFrame.minX
                + frame.minX - display.appKitFrame.minX,
            y: display.quartzFrame.minY
                + display.appKitFrame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    private func announceSuggestions(
        _ snapshot: RuntimeSuggestionPanelSnapshot
    ) {
        let announcement = RuntimeVoiceOverAnnouncement.suggestionUpdate(
            snapshot,
            after: lastAnnouncedSuggestionSnapshot
        )
        lastAnnouncedSuggestionSnapshot = snapshot
        guard announcement != lastSuggestionAnnouncement else {
            return
        }
        lastSuggestionAnnouncement = announcement
        postAnnouncement(announcement, from: panel)
    }

    private func postAnnouncement(
        _ announcement: String,
        from element: NSPanel
    ) {
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }

    nonisolated static func preferredSize(
        for snapshot: RuntimeSuggestionPanelSnapshot
    ) -> CGSize {
        switch snapshot.mode {
        case .hidden:
            return CGSize(width: 380, height: 1)
        case .committing:
            return CGSize(width: 380, height: 44)
        case .suggestions:
            let visibleRowCount = max(snapshot.visibleRows.count, 1)
            return CGSize(
                width: 380,
                height:
                    CGFloat(visibleRowCount)
                    * RuntimeSuggestionPresentationMetrics
                        .suggestionRowHeight
                    + RuntimeSuggestionPresentationMetrics
                        .suggestionDividerHeight
                    + RuntimeSuggestionPresentationMetrics
                        .suggestionFooterHeight
            )
        case .browser:
            let visibleRowCount = min(
                max(snapshot.rows.count, 1),
                RuntimeSuggestionPresentationMetrics.maximumVisibleBrowserRows
            )
            return CGSize(
                width: 440,
                height:
                    RuntimeSuggestionPresentationMetrics.browserHeaderHeight
                    + CGFloat(visibleRowCount)
                    * RuntimeSuggestionPresentationMetrics.browserRowHeight
                    + RuntimeSuggestionPresentationMetrics
                        .suggestionDividerHeight
                    + RuntimeSuggestionPresentationMetrics
                        .suggestionFooterHeight
            )
        }
    }
}

struct RuntimeSuggestionPanelView: View {
    @ObservedObject fileprivate var model: RuntimeSuggestionPanelModel

    private var snapshot: RuntimeSuggestionPanelSnapshot {
        model.snapshot
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if snapshot.mode == .committing {
                commitProgress
            } else {
                if snapshot.mode == .browser {
                let query = snapshot.query ?? ""
                let resultCount = snapshot.rows.count
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(
                                PondDesign.onDeepWater.opacity(0.72)
                            )
                            .accessibilityHidden(true)
                        if query.isEmpty {
                            Text("Type to search")
                                .foregroundStyle(
                                    PondDesign.onDeepWater.opacity(0.72)
                                )
                        } else {
                            Text(query)
                                .font(.body.monospaced())
                                .foregroundStyle(PondDesign.onDeepWater)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 28,
                        maxHeight: 28,
                        alignment: .leading
                    )
                    .background(
                        PondDesign.onDeepWater.opacity(0.1),
                        in: RoundedRectangle(
                            cornerRadius: 7,
                            style: .continuous
                        )
                    )
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("runtime.browserQuery")
                    .accessibilityLabel("Emoji search")
                    .accessibilityValue(
                        query.isEmpty ? "Type to search" : query
                    )

                    Text(
                        "\(resultCount) "
                            + (resultCount == 1 ? "result" : "results")
                    )
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(
                            PondDesign.onDeepWater.opacity(0.72)
                        )
                        .fixedSize()
                }
                .foregroundStyle(PondDesign.onDeepWater)
                .padding(.horizontal, 10)
                .frame(
                    height: RuntimeSuggestionPresentationMetrics
                        .browserHeaderHeight
                )
                .background(PondDesign.deepWater)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(PondDesign.ripple.opacity(0.48))
                        .frame(height: 1)
                }
                }

                if snapshot.mode == .browser
                    || snapshot.mode == .suggestions {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                rows
                            }
                        }
                        .scrollIndicators(.hidden)
                        .onAppear {
                            if let selected = snapshot.selectedRow {
                                scrollToSelection(selected, with: proxy)
                            }
                        }
                        .onChange(of: snapshot.revision) { _ in
                            if let selected = snapshot.selectedRow {
                                scrollToSelection(selected, with: proxy)
                            }
                        }
                    }
                } else {
                    rows
                }

                Rectangle()
                    .fill(PondDesign.ripple.opacity(0.24))
                    .frame(
                        height: RuntimeSuggestionPresentationMetrics
                            .suggestionDividerHeight
                    )
                Text(snapshot.compactInteractionHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        snapshot.compactInteractionAccessibilityLabel
                    )
                    .padding(.horizontal, 12)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: RuntimeSuggestionPresentationMetrics
                            .suggestionFooterHeight,
                        maxHeight: RuntimeSuggestionPresentationMetrics
                            .suggestionFooterHeight,
                        alignment: .leading
                    )
                    .background(PondDesign.raisedSurface)
            }
        }
        .pondFloatingPanel(backgroundCornerRadius: 12)
    }

    private var commitProgress: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Adding")
                .foregroundStyle(.secondary)
            if let row = snapshot.selectedRow {
                Text(":\(row.shortcode):")
                    .font(.body.monospaced().weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("custom emoji")
                    .font(.body.weight(.medium))
            }
            Spacer(minLength: 8)
            Text("esc cancel")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            RuntimeVoiceOverAnnouncement.suggestions(snapshot)
        )
    }

    @ViewBuilder
    private var rows: some View {
        let rows = snapshot.mode == .suggestions
            ? snapshot.rows
            : snapshot.visibleRows
        if rows.isEmpty {
            Text("No matching emoji")
                .foregroundStyle(.secondary)
                .frame(
                    maxWidth: .infinity,
                    minHeight: snapshot.mode == .browser
                        ? RuntimeSuggestionPresentationMetrics
                            .browserRowHeight
                        : RuntimeSuggestionPresentationMetrics
                            .suggestionRowHeight
                )
        } else {
            let selectedID = snapshot.selectedRow?.id
            ForEach(rows) { row in
                RuntimeSuggestionRowView(
                    row: row,
                    isSelected: row.id == selectedID,
                    compact: snapshot.mode == .browser,
                    trigger: snapshot.trigger,
                    onHover: {
                        model.send(
                            .hover(
                                transactionID: snapshot.transactionID,
                                itemID: row.id
                            )
                        )
                    },
                    onAccept: {
                        model.send(
                            .accept(
                                transactionID: snapshot.transactionID,
                                itemID: row.id
                            )
                        )
                    }
                )
                .id(row.id)
            }
        }
    }

    private func scrollToSelection(
        _ selected: RuntimeSuggestionRow,
        with proxy: ScrollViewProxy
    ) {
        proxy.scrollTo(
            selected.id,
            anchor: snapshot.mode == .browser ? .center : nil
        )
    }
}

private struct RuntimeSuggestionRowView: View {
    let row: RuntimeSuggestionRow
    let isSelected: Bool
    let compact: Bool
    let trigger: ShortcodeTrigger
    let onHover: () -> Void
    let onAccept: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let artworkURL = row.artworkURL {
                    LibraryAssetArtwork(
                        url: artworkURL,
                        fallbackURL: row.artworkFallbackURL,
                        managedRootURL: row.artworkRootURL,
                        contentPadding: 1,
                        showsLoadingIndicator: false
                    )
                } else {
                    Text(row.glyph)
                        .font(.system(size: compact ? 22 : 25))
                }
            }
            .frame(width: 32, height: 32)
            .background(
                PondDesign.raisedSurface,
                in: RoundedRectangle(
                    cornerRadius: 7,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(
                        PondDesign.ripple.opacity(0.18),
                        lineWidth: 1
                    )
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(
                    "\(trigger.rawValue)\(row.shortcode)"
                        + "\(trigger.rawValue)"
                )
                    .font(.system(.body, design: .monospaced, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Text(row.name)
                    .font(.caption)
                    .foregroundStyle(
                        isSelected
                            ? PondDesign.onDeepWater.opacity(0.78)
                            : Color.secondary
                    )
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .frame(
            height: compact
                ? RuntimeSuggestionPresentationMetrics.browserRowHeight
                : RuntimeSuggestionPresentationMetrics.suggestionRowHeight
        )
        .foregroundStyle(
            isSelected
                ? PondDesign.onDeepWater
                : Color.primary
        )
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isSelected
                        ? PondDesign.deepWater
                        : Color.clear
                )
                .padding(.horizontal, 5)
        }
        .contentShape(Rectangle())
        .onHover { isInside in
            if isInside {
                onHover()
            }
        }
        .onTapGesture(perform: onAccept)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(row.name), \(trigger.accessibilityName) "
                + "\(row.shortcode) \(trigger.accessibilityName)"
        )
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
