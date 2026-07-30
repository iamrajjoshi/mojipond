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
}

enum RuntimeMediaPreviewPlayback: Equatable, Sendable {
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
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency)
    private var reduceTransparency

    private var snapshot: RuntimeMediaPanelSnapshot {
        model.snapshot
    }

    static func preferredSize(
        for snapshot: RuntimeMediaPanelSnapshot
    ) -> CGSize {
        let hasGrid = !snapshot.items.isEmpty
        return CGSize(
            width: 500,
            height: hasGrid ? 430 : 146
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if snapshot.items.isEmpty {
                status
                    .frame(maxWidth: .infinity, minHeight: 54)
            } else {
                mediaGrid
            }

            footer
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    reduceTransparency
                        ? AnyShapeStyle(
                            Color(nsColor: .windowBackgroundColor)
                        )
                        : AnyShapeStyle(.regularMaterial)
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    .primary.opacity(
                        contrast == .increased ? 0.5 : 0.12
                    ),
                    lineWidth: contrast == .increased ? 2 : 1
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("MojiPond media search")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles.rectangle.stack")
            .foregroundStyle(.tint)
            Text(snapshot.command?.invocation ?? "Media")
                .font(.headline.monospaced())
            statusBadge
            Spacer()
            Text("arrows choose  ·  ↩ insert  ·  esc close")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    "Arrow keys choose, Return inserts, Escape closes"
                )
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
                        count: 4
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
            .frame(height: 326)
            .scrollIndicators(.visible)
            .onAppear {
                scrollToSelection(using: proxy)
            }
            // A retained hosting view no longer receives onAppear for every
            // result set. Re-scroll on the snapshot revision so index 0 in a
            // new grid cannot inherit the old grid's scroll offset.
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
                failureMessage(failure),
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
    }

    private func failureMessage(_ failure: MediaCommandFailure) -> String {
        switch failure {
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
                    cornerRadius: 8,
                    style: .continuous
                )
            )
            Text(item.title)
                .font(.caption2)
                .lineLimit(1)
        }
        .padding(5)
        .foregroundStyle(
            isSelected
                ? PondDesign.selectionForeground
                : Color.primary
        )
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    isSelected
                        ? PondDesign.selectionBackground
                        : Color.primary.opacity(0.055)
                )
        }
        .overlay(alignment: .topTrailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PondDesign.selectionForeground)
                    .padding(8)
                    .accessibilityHidden(true)
            }
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
            .foregroundStyle(.secondary)
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

private struct RuntimeAnimatedMediaPreview: NSViewRepresentable {
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
        private enum PreviewError: Error {
            case unavailable
        }

        private static let maximumPreviewBytes = 4 * 1_024 * 1_024
        private static let session =
            RuntimeMediaNetworkPolicy.nonCachingSession()
        private static let responseLoader = BoundedHTTPSResponseLoader(
            session: session
        )
        private var representedURL: URL?
        private var representedProvider: RemoteMediaProvider?
        private var representedAnimation = false
        private var task: Task<Void, Never>?
        private var generation: UInt64 = 0

        func load(
            _ url: URL,
            provider: RemoteMediaProvider,
            animates: Bool,
            into imageView: NSImageView,
            stateChanged: @escaping @MainActor (
                RuntimeMediaPreviewLoadState
            ) -> Void
        ) {
            guard
                representedURL != url
                    || representedProvider != provider
                    || representedAnimation != animates
            else {
                return
            }
            representedURL = url
            representedProvider = provider
            representedAnimation = animates
            task?.cancel()
            generation &+= 1
            let requestGeneration = generation
            imageView.image = nil
            imageView.animates = false

            task = Task { @MainActor [weak self, weak imageView] in
                guard let self else {
                    return
                }
                stateChanged(.loading)
                let data: Data
                do {
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
                            fileSize <= Self.maximumPreviewBytes
                        else {
                            throw PreviewError.unavailable
                        }
                        data = try Data(
                            contentsOf: url,
                            options: [.mappedIfSafe]
                        )
                    } else {
                        guard RemoteMediaURLPolicy.allows(
                            url,
                            for: provider
                        ) else {
                            throw PreviewError.unavailable
                        }
                        let request =
                            RuntimeMediaNetworkPolicy.nonCachingRequest(
                                for: url
                            )
                        let loaded = try await Self.responseLoader.load(
                            request,
                            maximumBytes: Self.maximumPreviewBytes,
                            redirectPolicy: .sameHost
                        )
                        let response = loaded.response
                        guard
                            (200 ..< 300).contains(response.statusCode),
                            response.mimeType?.hasPrefix("image/") == true
                        else {
                            throw PreviewError.unavailable
                        }
                        data = loaded.data
                    }
                    try Task.checkCancellation()
                    var limits = AssetValidationLimits.default
                    limits.maximumFileBytes = Int64(
                        Self.maximumPreviewBytes
                    )
                    limits.maximumPixelWidth = 2_048
                    limits.maximumPixelHeight = 2_048
                    limits.maximumPixelsPerFrame = 4_194_304
                    limits.maximumFrameCount = 90
                    limits.maximumTotalAnimationPixels = 24_000_000
                    limits.maximumAnimationDurationSeconds = 30
                    let playback: RuntimeMediaPreviewPlayback =
                        animates ? .animated : .staticFrame
                    let preparedData = await Task.detached(
                        priority: .utility
                    ) { () -> Data? in
                        RuntimeMediaPreviewPolicy.prepareImageData(
                            data,
                            playback: playback,
                            limits: limits
                        )
                    }.value
                    guard
                        let preparedData,
                        !preparedData.isEmpty,
                        let image = NSImage(data: preparedData)
                    else {
                        throw PreviewError.unavailable
                    }
                    guard
                        !Task.isCancelled,
                        generation == requestGeneration,
                        let imageView
                    else {
                        return
                    }
                    imageView.animates = animates
                    imageView.image = image
                    stateChanged(.loaded)
                } catch is CancellationError {
                    return
                } catch {
                    guard
                        !Task.isCancelled,
                        generation == requestGeneration
                    else {
                        return
                    }
                    imageView?.animates = false
                    imageView?.image = nil
                    stateChanged(.failed)
                }
            }
        }

        func cancel() {
            task?.cancel()
            task = nil
            generation &+= 1
            representedURL = nil
            representedProvider = nil
            representedAnimation = false
        }
    }
}
