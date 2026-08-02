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
        artworkState: LibraryArtworkLoadState,
        personalAliases: [String]? = nil
    ) -> String {
        [
            item.accessibilityLabel,
            personalAliases.map(personalAliasDescription),
            artworkState.accessibilityLabel
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    private static func personalAliasDescription(
        _ aliases: [String]
    ) -> String {
        guard !aliases.isEmpty else {
            return "no personal aliases"
        }
        let values = aliases.map { "colon \($0) colon" }
            .joined(separator: ", ")
        return "personal aliases, \(values)"
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
        .background(
            PondDesign.raisedSurface,
            in: RoundedRectangle(cornerRadius: PondDesign.compactCornerRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: PondDesign.compactCornerRadius)
                .stroke(PondDesign.separator.opacity(0.6))
        }
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
    var fallbackURL: URL? = nil
    var managedRootURL: URL? = nil
    var contentPadding: CGFloat = 5
    var showsLoadingIndicator = true
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
                    if showsLoadingIndicator {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(
                                LibraryArtworkLoadState.loading
                                    .accessibilityLabel ?? ""
                            )
                    } else {
                        Color.clear
                            .accessibilityHidden(true)
                    }
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
        .padding(contentPadding)
        .task(
            id: LibraryArtworkLoadRequest(
                primaryURL: url,
                fallbackURL: fallbackURL,
                managedRootURL: managedRootURL
            )
        ) {
            thumbnail = nil
            updateLoadState(.loading)
            do {
                let loaded = try await LibraryThumbnailCandidateLoader
                    .thumbnail(
                        primaryURL: url,
                        fallbackURL: fallbackURL,
                        managedRootURL: managedRootURL,
                        using: loader
                    )
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

private struct LibraryArtworkLoadRequest: Equatable {
    let primaryURL: URL
    let fallbackURL: URL?
    let managedRootURL: URL?
}

enum LibraryThumbnailCandidateError: Error, Equatable {
    case unsafeSource
    case unavailable
}

enum LibraryThumbnailCandidateLoader {
    static func thumbnail(
        primaryURL: URL,
        fallbackURL: URL?,
        managedRootURL: URL? = nil,
        using loader: any LibraryThumbnailLoading
    ) async throws -> LibraryThumbnail {
        let candidates = [primaryURL, fallbackURL]
            .compactMap { $0 }
            .reduce(into: [URL]()) { result, candidate in
                if !result.contains(candidate) {
                    result.append(candidate)
                }
            }
        var lastError: (any Error)?
        for candidate in candidates {
            do {
                let validatedURL = try validatedURL(
                    candidate,
                    beneath: managedRootURL
                )
                return try await loader.thumbnail(for: validatedURL)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        if let lastError {
            throw lastError
        }
        throw LibraryThumbnailCandidateError.unavailable
    }

    private static func validatedURL(
        _ candidate: URL,
        beneath managedRootURL: URL?
    ) throws -> URL {
        let standardizedCandidate = candidate.standardizedFileURL
        guard let managedRootURL else {
            return standardizedCandidate
        }
        let canonicalRoot = managedRootURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let canonicalCandidate = standardizedCandidate
            .resolvingSymlinksInPath()
        let rootPath = canonicalRoot.path
        guard canonicalCandidate.path.hasPrefix(
            rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        ) else {
            throw LibraryThumbnailCandidateError.unsafeSource
        }
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: canonicalCandidate.path,
                isDirectory: &isDirectory
            ),
            !isDirectory.boolValue,
            (try? canonicalCandidate.resourceValues(
                forKeys: [.isRegularFileKey]
            ).isRegularFile) == true
        else {
            throw LibraryThumbnailCandidateError.unavailable
        }
        return canonicalCandidate
    }
}

struct LibraryEmojiCard: View {
    let item: LibraryDisplayItem
    var personalAliases: [String] = []
    var showsPersonalAliases = false
    let action: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var isHovered = false
    @State private var artworkLoadState =
        LibraryArtworkLoadState.loading

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                LibraryEmojiArtwork(
                    item: item,
                    size: 52,
                    loadStateChanged: {
                        artworkLoadState = $0
                    }
                )

                VStack(spacing: 2) {
                    Text(":\(item.shortcode):")
                        .font(.caption.monospaced().weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .help(":\(item.shortcode):")
                    Text(item.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(item.displayName)
                    if showsPersonalAliases, !personalAliases.isEmpty {
                        LibraryPersonalAliasSummary(
                            aliases: personalAliases
                        )
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(9)
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
        .accessibilityHint(
            showsPersonalAliases
                ? "Opens emoji details to add or edit personal aliases"
                : "Opens emoji details"
        )
    }

    private var cardBackground: Color {
        guard isHovered || isFocused else {
            return PondDesign.surface.opacity(0.56)
        }
        return PondDesign.pond.opacity(
            contrast == .increased ? 0.16 : 0.075
        )
    }

    private var cardBorder: Color {
        if isFocused {
            return PondDesign.pond
        }
        if isHovered {
            return PondDesign.pond.opacity(
                contrast == .increased ? 1 : 0.3
            )
        }
        return PondDesign.separator.opacity(
            contrast == .increased ? 0.9 : 0.5
        )
    }

    private var cardBorderWidth: CGFloat {
        isFocused || contrast == .increased ? 2 : 1
    }

    private var accessibilityLabel: String {
        LibraryItemAccessibility.label(
            for: item,
            artworkState: resolvedArtworkLoadState,
            personalAliases: showsPersonalAliases ? personalAliases : nil
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
    var personalAliases: [String] = []
    var showsPersonalAliases = false
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
                        .lineLimit(1)
                        .help(":\(item.shortcode):")
                    Text(item.displayName)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(item.displayName)
                    if showsPersonalAliases, !personalAliases.isEmpty {
                        LibraryPersonalAliasSummary(
                            aliases: personalAliases
                        )
                    }
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
        .accessibilityHint(
            showsPersonalAliases
                ? "Opens emoji details to add or edit personal aliases"
                : "Opens emoji details"
        )
    }

    private var accessibilityLabel: String {
        LibraryItemAccessibility.label(
            for: item,
            artworkState: resolvedArtworkLoadState,
            personalAliases: showsPersonalAliases ? personalAliases : nil
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

private struct LibraryPersonalAliasSummary: View {
    let aliases: [String]

    var body: some View {
        Label(summary, systemImage: aliases.isEmpty ? "plus.circle" : "tag.fill")
            .font(.caption2)
            .foregroundStyle(
                aliases.isEmpty ? Color.secondary : PondDesign.pond
            )
            .lineLimit(1)
            .accessibilityHidden(true)
    }

    private var summary: String {
        guard !aliases.isEmpty else {
            return "Add alias"
        }
        return aliases.map { ":\($0):" }.joined(separator: ", ")
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
            Image(systemName: notice.kind.symbolName)
                .foregroundStyle(notice.kind.tint)
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
        .background(notice.kind.tint.opacity(0.1))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

extension LibraryNotice.Kind {
    var symbolName: String {
        switch self {
        case .information:
            "checkmark.circle.fill"
        case .warning:
            "exclamationmark.triangle.fill"
        case .error:
            "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .information:
            PondDesign.lily
        case .warning:
            PondDesign.warningForeground
        case .error:
            PondDesign.errorForeground
        }
    }
}

struct LibraryPackMoveButtons: View {
    @ObservedObject var viewModel: LibraryViewModel
    let packID: UUID

    var body: some View {
        Button("Move Up") {
            Task {
                await viewModel.movePack(packID, by: -1)
            }
        }
        .disabled(!viewModel.canMovePack(packID, by: -1))

        Button("Move Down") {
            Task {
                await viewModel.movePack(packID, by: 1)
            }
        }
        .disabled(!viewModel.canMovePack(packID, by: 1))
    }
}

struct LibraryPackEnabledToggle: View {
    @ObservedObject var viewModel: LibraryViewModel
    let pack: EmojiPack

    var body: some View {
        Toggle(
            "Enabled",
            isOn: Binding(
                get: { pack.isEnabled },
                set: { enabled in
                    Task {
                        await viewModel.setPackEnabled(
                            pack.id,
                            isEnabled: enabled
                        )
                    }
                }
            )
        )
        .toggleStyle(.switch)
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
                    Text("Drop ZIP to review before importing")
                        .font(.headline)
                    Text("Drop one ZIP archive.")
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
            .accessibilityLabel("Drop one ZIP archive to prepare an emoji pack import")
        }
    }
}

struct LibraryLoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Loading emoji…")
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
