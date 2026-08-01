import AppKit
import Combine
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum RuntimeMediaPanelState: Equatable, Sendable {
    case idle
    case loading
    case results
    case offline
    case empty
    case cancelled
    case rateLimited
    case failed(MediaCommandFailure)
    case resolving

    var allowsResultSelection: Bool {
        switch self {
        case .results, .offline:
            true
        case .idle, .loading, .empty, .cancelled, .rateLimited,
             .failed, .resolving:
            false
        }
    }

    var capturesBusySelectionKeys: Bool {
        self == .resolving
    }
}

enum RuntimeMediaPreviewPlayback: Equatable, Hashable, Sendable {
    case animated
    case staticFrame

    var animates: Bool {
        self == .animated
    }
}

enum RuntimeMediaPreviewPolicy {
    static func playback(
        isSelected: Bool,
        reduceMotion: Bool
    ) -> RuntimeMediaPreviewPlayback {
        isSelected && !reduceMotion ? .animated : .staticFrame
    }

    nonisolated static func prepareImageData(
        _ data: Data,
        playback: RuntimeMediaPreviewPlayback,
        limits: AssetValidationLimits
    ) -> Data? {
        guard
            (try? AssetValidator(limits: limits).validate(data: data)) != nil
        else {
            return nil
        }
        guard playback == .staticFrame else {
            return data
        }
        return staticThumbnailData(from: data)
    }

    nonisolated private static func staticThumbnailData(
        from data: Data
    ) -> Data? {
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ),
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 256,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary
            )
        else {
            return nil
        }
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            return nil
        }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return output as Data
    }
}

enum RuntimeMediaPreviewLoadState: Equatable, Sendable {
    case loading
    case loaded
    case failed

    var accessibilityDescription: String? {
        switch self {
        case .loading:
            "Preview loading"
        case .loaded:
            nil
        case .failed:
            "Preview unavailable"
        }
    }
}

enum RuntimeMediaAttributionPolicy {
    static func normalized(
        items: [MediaCommandResult],
        declared: [MediaCommandAttribution]
    ) -> [MediaCommandAttribution] {
        var result = declared
        if items.contains(where: {
            $0.media.provider == .notoAnimatedEmoji
        }), !result.contains(.notoAnimatedEmoji) {
            result.append(.notoAnimatedEmoji)
        }
        return result
    }
}

struct RuntimeMediaPanelItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let previewURL: URL
    let provider: RemoteMediaProvider

    init(
        id: String,
        title: String,
        previewURL: URL,
        provider: RemoteMediaProvider
    ) {
        self.id = id
        self.title = title
        self.previewURL = previewURL
        self.provider = provider
    }
}

struct RuntimeMediaPanelSnapshot: Equatable, Sendable {
    let revision: UInt64
    let command: MediaCommandKind?
    let state: RuntimeMediaPanelState
    let items: [RuntimeMediaPanelItem]
    let selectedIndex: Int?
    let attributions: [MediaCommandAttribution]

    static let empty = RuntimeMediaPanelSnapshot(
        revision: 0,
        command: nil,
        state: .idle,
        items: [],
        selectedIndex: nil,
        attributions: []
    )

    var canActivateSelection: Bool {
        !items.isEmpty && state.allowsResultSelection
    }

    var capturesSelectionKeys: Bool {
        canActivateSelection
            || (!items.isEmpty && state.capturesBusySelectionKeys)
    }

    var interactionHint: String {
        if state == .resolving {
            return "preparing  ·  esc cancel"
        }
        if canActivateSelection {
            return "arrows choose  ·  ↩ insert  ·  esc close"
        }
        if state == .cancelled {
            return "closing…"
        }
        if state == .idle {
            return "type to search  ·  esc close"
        }
        return "type to refine  ·  esc close"
    }

    var interactionAccessibilityLabel: String {
        if state == .resolving {
            return "Preparing media, Escape cancels"
        }
        if canActivateSelection {
            return "Arrow keys choose, Return inserts, Escape closes"
        }
        if state == .cancelled {
            return "Closing media search"
        }
        if state == .idle {
            return "Type to search, Escape closes"
        }
        return "Type to refine the search, Escape closes"
    }
}

enum RuntimeMediaPanelUpdate: Equatable, Sendable {
    case show(
        snapshot: RuntimeMediaPanelSnapshot,
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
final class RuntimeMediaPanelModel: ObservableObject {
    @Published var snapshot: RuntimeMediaPanelSnapshot

    init(snapshot: RuntimeMediaPanelSnapshot) {
        self.snapshot = snapshot
    }
}

struct RuntimeMediaPanelView: View {
    @ObservedObject var model: RuntimeMediaPanelModel

    private var snapshot: RuntimeMediaPanelSnapshot {
        model.snapshot
    }

    private static let columnCount = 4
    private static let maximumVisibleGridRows = 3
    private static let gridRowHeight: CGFloat = 103
    private static let gridSpacing: CGFloat = 8
    private static let gridChromeHeight: CGFloat = 105

    static func preferredSize(
        for snapshot: RuntimeMediaPanelSnapshot
    ) -> CGSize {
        let hasGrid = !snapshot.items.isEmpty
        return CGSize(
            width: 500,
            height: hasGrid
                ? gridChromeHeight + gridHeight(
                    itemCount: snapshot.items.count
                )
                : 146
        )
    }

    static func gridHeight(itemCount: Int) -> CGFloat {
        let rowCount = min(
            max((itemCount + columnCount - 1) / columnCount, 1),
            maximumVisibleGridRows
        )
        return CGFloat(rowCount) * gridRowHeight
            + CGFloat(max(rowCount - 1, 0)) * gridSpacing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if snapshot.items.isEmpty {
                status
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(
                        PondDesign.raisedSurface,
                        in: RoundedRectangle(
                            cornerRadius: PondDesign.compactCornerRadius,
                            style: .continuous
                        )
                    )
            } else {
                mediaGrid
            }

            footer
        }
        .padding(12)
        .pondFloatingPanel()
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles.rectangle.stack")
                .foregroundStyle(PondDesign.onDeepWater)
            Text(snapshot.command?.invocation ?? "Media")
                .font(.headline.monospaced())
            statusBadge
            Spacer()
            Text(snapshot.interactionHint)
                .font(.caption2)
                .foregroundStyle(
                    PondDesign.onDeepWater.opacity(0.72)
                )
                .accessibilityLabel(
                    snapshot.interactionAccessibilityLabel
                )
        }
        .foregroundStyle(PondDesign.onDeepWater)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(PondDesign.deepWater)
                .padding(.horizontal, -7)
                .padding(.vertical, -5)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PondDesign.ripple.opacity(0.48))
                .frame(height: 1)
                .padding(.horizontal, -7)
                .offset(y: 5)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch snapshot.state {
        case .offline:
            Text("OFFLINE")
                .runtimeMediaBadge(
                    foreground: PondDesign.warningForeground,
                    background: PondDesign.warningBackground
                )
        case .loading, .resolving:
            ProgressView()
                .controlSize(.small)
        default:
            EmptyView()
        }
    }

    private var mediaGrid: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: 8),
                        count: Self.columnCount
                    ),
                    spacing: 8
                ) {
                    ForEach(
                        Array(snapshot.items.enumerated()),
                        id: \.element.id
                    ) { index, item in
                        mediaCell(item, at: index)
                            .id(item.id)
                    }
                }
            }
            .frame(
                height: Self.gridHeight(
                    itemCount: snapshot.items.count
                )
            )
            .scrollIndicators(.visible)
            .onAppear {
                scrollToSelection(using: proxy)
            }
            // A retained hosting view runs onAppear only once. Re-scroll each
            // snapshot so a new grid cannot inherit the old scroll offset.
            .onChange(of: snapshot.revision) {
                scrollToSelection(using: proxy)
            }
        }
    }

    private func mediaCell(
        _ item: RuntimeMediaPanelItem,
        at index: Int
    ) -> some View {
        RuntimeMediaCell(
            item: item,
            isSelected: index == snapshot.selectedIndex
        )
    }

    private func scrollToSelection(
        using proxy: ScrollViewProxy
    ) {
        guard
            let selectedIndex = snapshot.selectedIndex,
            snapshot.items.indices.contains(selectedIndex)
        else {
            return
        }
        proxy.scrollTo(snapshot.items[selectedIndex].id, anchor: .center)
    }

    @ViewBuilder
    private var status: some View {
        switch snapshot.state {
        case .idle:
            Text("Type a search after the command.")
        case .loading:
            Label("Searching…", systemImage: "magnifyingglass")
        case .results:
            Text("No media selected.")
        case .offline:
            Label(
                "Showing bundled results while the network is unavailable.",
                systemImage: "wifi.slash"
            )
        case .empty:
            Label("No matching media.", systemImage: "tray")
        case .cancelled:
            Label("Search cancelled.", systemImage: "xmark.circle")
        case .rateLimited:
            Label(
                "The provider is busy. Try again shortly.",
                systemImage: "hourglass"
            )
        case let .failed(failure):
            Label(
                failure.runtimePresentationMessage,
                systemImage: "exclamationmark.triangle"
            )
        case .resolving:
            Label("Preparing original media…", systemImage: "arrow.down.circle")
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 8) {
            ForEach(snapshot.attributions, id: \.text) { attribution in
                Text(attribution.text)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !snapshot.items.isEmpty {
                Text("\((snapshot.selectedIndex ?? 0) + 1)/\(snapshot.items.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 22)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PondDesign.ripple.opacity(0.22))
                .frame(height: 1)
        }
    }

}

extension MediaCommandFailure {
    var runtimePresentationMessage: String {
        switch self {
        case .invalidQuery:
            "Enter a shorter search term."
        case .providerUnavailable:
            "The media provider is unavailable."
        case .invalidProviderResponse:
            "The provider returned an invalid response."
        case .unsupportedMedia:
            "The provider returned unsupported media."
        }
    }
}

private struct RuntimeMediaCell: View {
    let item: RuntimeMediaPanelItem
    let isSelected: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previewState = RuntimeMediaPreviewLoadState.loading

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RuntimeAnimatedMediaPreview(
                    url: item.previewURL,
                    provider: item.provider,
                    animates: RuntimeMediaPreviewPolicy.playback(
                        isSelected: isSelected,
                        reduceMotion: reduceMotion
                    ).animates,
                    loadState: $previewState
                )

                previewStatus
            }
            .frame(height: 78)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: PondDesign.compactCornerRadius,
                    style: .continuous
                )
            )
            .background(
                PondDesign.surface,
                in: RoundedRectangle(
                    cornerRadius: PondDesign.compactCornerRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: PondDesign.compactCornerRadius,
                    style: .continuous
                )
                .stroke(PondDesign.ripple.opacity(0.16), lineWidth: 1)
            }
            Text(item.title)
                .font(.caption2)
                .lineLimit(1)
        }
        .padding(5)
        .foregroundStyle(
            isSelected
                ? PondDesign.onDeepWater
                : Color.primary
        )
        .background {
            RoundedRectangle(
                cornerRadius: PondDesign.compactCornerRadius,
                style: .continuous
            )
                .fill(
                    isSelected
                        ? PondDesign.deepWater
                        : PondDesign.raisedSurface
                )
        }
        .overlay {
            RoundedRectangle(
                cornerRadius: PondDesign.compactCornerRadius,
                style: .continuous
            )
            .stroke(
                PondDesign.ripple.opacity(0.18),
                lineWidth: 1
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private var previewStatus: some View {
        switch previewState {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .tint(
                    isSelected
                        ? PondDesign.onDeepWater
                        : PondDesign.ripple
                )
                .accessibilityLabel("Loading media preview")
        case .loaded:
            EmptyView()
        case .failed:
            VStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title3)
                Text("Preview unavailable")
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(
                isSelected
                    ? PondDesign.onDeepWater.opacity(0.78)
                    : Color.secondary
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Media preview unavailable")
        }
    }

    private var accessibilityLabel: String {
        [
            item.title,
            previewState.accessibilityDescription
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}

private extension View {
    func runtimeMediaBadge(
        foreground: Color,
        background: Color
    ) -> some View {
        font(.caption2.weight(.bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(background, in: Capsule())
    }
}

struct RuntimeAnimatedMediaPreview: NSViewRepresentable {
    let url: URL
    let provider: RemoteMediaProvider
    let animates: Bool
    @Binding var loadState: RuntimeMediaPreviewLoadState

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageFrameStyle = .none
        imageView.animates = false
        imageView.wantsLayer = true
        context.coordinator.load(
            url,
            provider: provider,
            animates: animates,
            into: imageView,
            stateChanged: updateLoadState
        )
        return imageView
    }

    func updateNSView(_ imageView: NSImageView, context: Context) {
        context.coordinator.load(
            url,
            provider: provider,
            animates: animates,
            into: imageView,
            stateChanged: updateLoadState
        )
    }

    static func dismantleNSView(
        _ imageView: NSImageView,
        coordinator: Coordinator
    ) {
        coordinator.cancel()
        imageView.image = nil
    }

    @MainActor
    private func updateLoadState(
        _ state: RuntimeMediaPreviewLoadState
    ) {
        guard loadState != state else {
            return
        }
        loadState = state
    }

    @MainActor
    final class Coordinator {
        typealias SourceLoader = @MainActor (
            URL,
            RemoteMediaProvider
        ) async throws -> Data

        private enum PreviewError: Error {
            case unavailable
        }

        nonisolated private static let maximumPreviewBytes =
            4 * 1_024 * 1_024
        private static let session =
            RuntimeMediaNetworkPolicy.nonCachingSession()
        private static let responseLoader = BoundedHTTPSResponseLoader(
            session: session
        )
        private var representedURL: URL?
        private var representedProvider: RemoteMediaProvider?
        private var representedAnimation = false
        private let sourceLoader: SourceLoader
        private var sourceTask: Task<Void, Never>?
        private var renderTask: Task<Void, Never>?
        private var sourceGeneration: UInt64 = 0
        private var renderGeneration: UInt64 = 0
        private var validatedSourceData: Data?
        private var preparedDataByPlayback:
            [RuntimeMediaPreviewPlayback: Data] = [:]

        init(sourceLoader: @escaping SourceLoader = Coordinator.loadSource) {
            self.sourceLoader = sourceLoader
        }

        func load(
            _ url: URL,
            provider: RemoteMediaProvider,
            animates: Bool,
            into imageView: NSImageView,
            stateChanged: @escaping @MainActor (
                RuntimeMediaPreviewLoadState
            ) -> Void
        ) {
            let sourceChanged = representedURL != url
                || representedProvider != provider
            guard sourceChanged || representedAnimation != animates else {
                return
            }

            if !sourceChanged {
                representedAnimation = animates
                renderDesiredPlayback(
                    into: imageView,
                    stateChanged: stateChanged
                )
                return
            }

            representedURL = url
            representedProvider = provider
            representedAnimation = animates
            sourceTask?.cancel()
            renderTask?.cancel()
            sourceGeneration &+= 1
            renderGeneration &+= 1
            let requestGeneration = sourceGeneration
            validatedSourceData = nil
            preparedDataByPlayback.removeAll(keepingCapacity: true)
            imageView.image = nil
            imageView.animates = false
            stateChanged(.loading)

            let sourceLoader = sourceLoader
            sourceTask = Task { @MainActor [weak self, weak imageView] in
                guard let self else {
                    return
                }
                let data: Data
                do {
                    data = try await sourceLoader(url, provider)
                    try Task.checkCancellation()
                    let validatedData = await Task.detached(
                        priority: .utility
                    ) { () -> Data? in
                        RuntimeMediaPreviewPolicy.prepareImageData(
                            data,
                            playback: .animated,
                            limits: Self.validationLimits
                        )
                    }.value
                    guard
                        let validatedData,
                        !validatedData.isEmpty
                    else {
                        throw PreviewError.unavailable
                    }
                    guard
                        !Task.isCancelled,
                        sourceGeneration == requestGeneration,
                        let imageView
                    else {
                        return
                    }
                    validatedSourceData = validatedData
                    preparedDataByPlayback[.animated] = validatedData
                    sourceTask = nil
                    renderDesiredPlayback(
                        into: imageView,
                        stateChanged: stateChanged
                    )
                } catch is CancellationError {
                    return
                } catch {
                    guard
                        !Task.isCancelled,
                        sourceGeneration == requestGeneration
                    else {
                        return
                    }
                    sourceTask = nil
                    imageView?.animates = false
                    imageView?.image = nil
                    stateChanged(.failed)
                }
            }
        }

        func cancel() {
            sourceTask?.cancel()
            sourceTask = nil
            renderTask?.cancel()
            renderTask = nil
            sourceGeneration &+= 1
            renderGeneration &+= 1
            representedURL = nil
            representedProvider = nil
            representedAnimation = false
            validatedSourceData = nil
            preparedDataByPlayback.removeAll(keepingCapacity: false)
        }

        private func renderDesiredPlayback(
            into imageView: NSImageView,
            stateChanged: @escaping @MainActor (
                RuntimeMediaPreviewLoadState
            ) -> Void
        ) {
            let playback = RuntimeMediaPreviewPolicy.playback(
                isSelected: representedAnimation,
                reduceMotion: false
            )
            imageView.animates = playback.animates
            renderTask?.cancel()
            renderTask = nil
            renderGeneration &+= 1
            let requestGeneration = renderGeneration

            if let preparedData = preparedDataByPlayback[playback] {
                apply(
                    preparedData,
                    playback: playback,
                    to: imageView,
                    stateChanged: stateChanged
                )
                return
            }
            guard let validatedSourceData else {
                return
            }

            renderTask = Task { @MainActor [weak self, weak imageView] in
                let preparedData = await Task.detached(
                    priority: .utility
                ) { () -> Data? in
                    RuntimeMediaPreviewPolicy.prepareImageData(
                        validatedSourceData,
                        playback: playback,
                        limits: Self.validationLimits
                    )
                }.value
                guard
                    let self,
                    !Task.isCancelled,
                    renderGeneration == requestGeneration,
                    let imageView
                else {
                    return
                }
                let displayData = preparedData ?? validatedSourceData
                preparedDataByPlayback[playback] = displayData
                renderTask = nil
                apply(
                    displayData,
                    playback: playback,
                    to: imageView,
                    stateChanged: stateChanged
                )
            }
        }

        private func apply(
            _ data: Data,
            playback: RuntimeMediaPreviewPlayback,
            to imageView: NSImageView,
            stateChanged: @escaping @MainActor (
                RuntimeMediaPreviewLoadState
            ) -> Void
        ) {
            guard let image = NSImage(data: data) else {
                imageView.animates = false
                imageView.image = nil
                stateChanged(.failed)
                return
            }
            imageView.animates = playback.animates
            imageView.image = image
            stateChanged(.loaded)
        }

        nonisolated private static var validationLimits:
            AssetValidationLimits
        {
            var limits = AssetValidationLimits.default
            limits.maximumFileBytes = Int64(maximumPreviewBytes)
            limits.maximumPixelWidth = 2_048
            limits.maximumPixelHeight = 2_048
            limits.maximumPixelsPerFrame = 4_194_304
            limits.maximumFrameCount = 90
            limits.maximumTotalAnimationPixels = 24_000_000
            limits.maximumAnimationDurationSeconds = 30
            return limits
        }

        private static func loadSource(
            _ url: URL,
            provider: RemoteMediaProvider
        ) async throws -> Data {
            if url.isFileURL {
                let values = try url.resourceValues(
                    forKeys: [
                        .isRegularFileKey,
                        .isSymbolicLinkKey,
                        .fileSizeKey
                    ]
                )
                guard
                    values.isRegularFile == true,
                    values.isSymbolicLink != true,
                    let fileSize = values.fileSize,
                    fileSize > 0,
                    fileSize <= maximumPreviewBytes
                else {
                    throw PreviewError.unavailable
                }
                return try Data(
                    contentsOf: url,
                    options: [.mappedIfSafe]
                )
            }

            guard RemoteMediaURLPolicy.allows(url, for: provider) else {
                throw PreviewError.unavailable
            }
            let request = RuntimeMediaNetworkPolicy.nonCachingRequest(
                for: url
            )
            let loaded = try await responseLoader.load(
                request,
                maximumBytes: maximumPreviewBytes,
                redirectPolicy: .sameHost
            )
            let response = loaded.response
            guard
                (200 ..< 300).contains(response.statusCode),
                response.mimeType?.hasPrefix("image/") == true
            else {
                throw PreviewError.unavailable
            }
            return loaded.data
        }
    }
}
