import SwiftUI

private struct LibraryThumbnailLoaderEnvironmentKey:
    EnvironmentKey
{
    static let defaultValue: any LibraryThumbnailLoading =
        LibraryThumbnailPipeline.shared
}

extension EnvironmentValues {
    var libraryThumbnailLoader: any LibraryThumbnailLoading {
        get { self[LibraryThumbnailLoaderEnvironmentKey.self] }
        set { self[LibraryThumbnailLoaderEnvironmentKey.self] = newValue }
    }
}

enum LibraryArtworkLoadState: Equatable, Sendable {
    case loading
    case loaded
    case failed

    var accessibilityLabel: String? {
        switch self {
        case .loading:
            "Loading emoji preview"
        case .loaded:
            nil
        case .failed:
            "Emoji preview unavailable"
        }
    }

    var placeholderSymbolName: String? {
        switch self {
        case .loading, .loaded:
            nil
        case .failed:
            "exclamationmark.triangle"
        }
    }
}

enum LibraryItemAccessibility {
    static func label(
        for item: LibraryDisplayItem,
        artworkState: LibraryArtworkLoadState
    ) -> String {
        [
            item.accessibilityLabel,
            artworkState.accessibilityLabel
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}

struct LibraryEmojiArtwork: View {
    let item: LibraryDisplayItem
    var size: CGFloat = 54
    var loadStateChanged:
        ((LibraryArtworkLoadState) -> Void)? = nil

    var body: some View {
        Group {
            if let unicode = item.unicode {
                Text(unicode)
                    .font(.system(size: size * 0.72))
                    .minimumScaleFactor(0.5)
                    .accessibilityHidden(true)
            } else if let assetURL = item.assetURL {
                LibraryAssetArtwork(
                    url: assetURL,
                    loadStateChanged: loadStateChanged
                )
            } else {
                Image(systemName: "questionmark.square.dashed")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Emoji artwork unavailable")
            }
        }
        .frame(width: size, height: size)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .bottomTrailing) {
            if item.isAnimated {
                Image(systemName: "play.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.black.opacity(0.64), in: Circle())
                    .padding(3)
                    .accessibilityHidden(true)
                }
        }
        .task(id: item.id) {
            if item.unicode != nil {
                loadStateChanged?(.loaded)
            } else if item.assetURL == nil {
                loadStateChanged?(.failed)
            }
        }
    }
}

struct LibraryAssetArtwork: View {
    let url: URL
    var loadStateChanged:
        ((LibraryArtworkLoadState) -> Void)? = nil

    @Environment(\.libraryThumbnailLoader) private var loader
    @State private var thumbnail: LibraryThumbnail?
    @State private var loadState = LibraryArtworkLoadState.loading

    var body: some View {
        Group {
            if let thumbnail {
                Image(
                    decorative: thumbnail.cgImage,
                    scale: 1,
                    orientation: .up
                )
                    .resizable()
                    .scaledToFit()
                    .accessibilityHidden(true)
            } else {
                switch loadState {
                case .loading, .loaded:
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(
                            LibraryArtworkLoadState.loading
                                .accessibilityLabel ?? ""
                        )
                case .failed:
                    Image(
                        systemName:
                            LibraryArtworkLoadState.failed
                                .placeholderSymbolName
                                ?? "exclamationmark.triangle"
                    )
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        LibraryArtworkLoadState.failed
                            .accessibilityLabel ?? ""
                    )
                    .help("Emoji preview unavailable")
                }
            }
        }
        .padding(5)
        .task(id: url) {
            thumbnail = nil
            updateLoadState(.loading)
            do {
                let loaded = try await loader.thumbnail(for: url)
                try Task.checkCancellation()
                thumbnail = loaded
                updateLoadState(.loaded)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                updateLoadState(.failed)
            }
        }
    }

    private func updateLoadState(
        _ state: LibraryArtworkLoadState
    ) {
        loadState = state
        loadStateChanged?(state)
    }
}

struct LibraryEmojiCard: View {
    let item: LibraryDisplayItem
    let action: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var isHovered = false
    @State private var artworkLoadState =
        LibraryArtworkLoadState.loading

    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                LibraryEmojiArtwork(
                    item: item,
                    size: 62,
                    loadStateChanged: {
                        artworkLoadState = $0
                    }
                )

                VStack(spacing: 2) {
                    Text(":\(item.shortcode):")
                        .font(.callout.monospaced().weight(.medium))
                        .lineLimit(1)
                    Text(item.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(
                cardBackground,
                in: RoundedRectangle(
                    cornerRadius: PondDesign.cornerRadius
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: PondDesign.cornerRadius)
                    .stroke(
                        cardBorder,
                        lineWidth: cardBorderWidth
                    )
            }
            .overlay(alignment: .topLeading) {
                if !item.packEnabled {
                    LibraryPackStateBadge()
                        .padding(7)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PondInteractiveButtonStyle())
        .focused($isFocused)
        .onHover {
            isHovered = $0
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.12),
            value: isHovered
        )
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens emoji details")
    }

    private var cardBackground: Color {
        guard isHovered || isFocused else {
            return Color(nsColor: .controlBackgroundColor)
        }
        return PondDesign.pond.opacity(
            contrast == .increased ? 0.16 : 0.09
        )
    }

    private var cardBorder: Color {
        if isFocused {
            return PondDesign.pond
        }
        return Color(nsColor: .separatorColor).opacity(
            contrast == .increased ? 1 : 0.55
        )
    }

    private var cardBorderWidth: CGFloat {
        isFocused || contrast == .increased ? 2 : 1
    }

    private var accessibilityLabel: String {
        LibraryItemAccessibility.label(
            for: item,
            artworkState: resolvedArtworkLoadState
        )
    }

    private var resolvedArtworkLoadState:
        LibraryArtworkLoadState
    {
        if item.unicode != nil {
            return .loaded
        }
        if item.assetURL == nil {
            return .failed
        }
        return artworkLoadState
    }
}

struct LibraryEmojiListRow: View {
    let item: LibraryDisplayItem
    let action: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var isHovered = false
    @State private var artworkLoadState =
        LibraryArtworkLoadState.loading

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                LibraryEmojiArtwork(
                    item: item,
                    size: 42,
                    loadStateChanged: {
                        artworkLoadState = $0
                    }
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(":\(item.shortcode):")
                        .font(.body.monospaced().weight(.medium))
                    Text(item.displayName)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(item.packName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(item.category)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if !item.packEnabled {
                    LibraryPackStateBadge()
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isHovered || isFocused
                    ? PondDesign.pond.opacity(
                        contrast == .increased ? 0.16 : 0.09
                    )
                    : Color.clear,
                in: RoundedRectangle(
                    cornerRadius: PondDesign.compactCornerRadius
                )
            )
            .overlay {
                if isFocused {
                    RoundedRectangle(
                        cornerRadius: PondDesign.compactCornerRadius
                    )
                    .stroke(PondDesign.pond, lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PondInteractiveButtonStyle())
        .focused($isFocused)
        .onHover {
            isHovered = $0
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.12),
            value: isHovered
        )
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens emoji details")
    }

    private var accessibilityLabel: String {
        LibraryItemAccessibility.label(
            for: item,
            artworkState: resolvedArtworkLoadState
        )
    }

    private var resolvedArtworkLoadState:
        LibraryArtworkLoadState
    {
        if item.unicode != nil {
            return .loaded
        }
        if item.assetURL == nil {
            return .failed
        }
        return artworkLoadState
    }
}

private struct LibraryPackStateBadge: View {
    var body: some View {
        Label("Disabled", systemImage: "pause.circle.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(.separator)
            }
            .accessibilityHidden(true)
    }
}

struct LibraryNoticeBanner: View {
    let notice: LibraryNotice
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbolName)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.callout.weight(.semibold))
                if !notice.message.isEmpty {
                    Text(notice.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss notice")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(tint.opacity(0.1))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var symbolName: String {
        switch notice.kind {
        case .information:
            "checkmark.circle.fill"
        case .warning:
            "exclamationmark.triangle.fill"
        case .error:
            "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch notice.kind {
        case .information:
            PondDesign.lily
        case .warning:
            PondDesign.warningForeground
        case .error:
            PondDesign.errorForeground
        }
    }
}

struct LibraryDropOverlay: View {
    let isTargeted: Bool

    var body: some View {
        if isTargeted {
            ZStack {
                Color.black.opacity(0.08)
                VStack(spacing: 12) {
                    Image(systemName: "square.and.arrow.down.on.square.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(PondDesign.pond)
                    Text("Drop to review before importing")
                        .font(.headline)
                    Text("Images, folders, ZIP archives, and Slack emoji.json are supported.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(28)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .overlay {
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(PondDesign.pond, style: StrokeStyle(lineWidth: 2, dash: [7]))
                }
            }
            .transition(.opacity)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Drop files to prepare an emoji pack import")
        }
    }
}

struct LibraryLoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Gathering your emoji…")
                .font(.headline)
            Text("Loading the built-in catalog and installed packs.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading emoji library")
    }
}
