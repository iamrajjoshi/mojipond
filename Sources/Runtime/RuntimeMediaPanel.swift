import AppKit
import SwiftUI

enum RuntimeMediaPanelState: Equatable, Sendable {
    case idle
    case loading
    case results
    case offline
    case empty
    case cancelled
    case networkDisabled
    case rateLimited
    case failed(MediaCommandFailure)
    case resolving
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
        if items.contains(where: {
            $0.media.provider == .giphy
        }), !result.contains(.giphy) {
            result.append(.giphy)
        }
        return result
    }
}

struct RuntimeMediaPanelItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let previewURL: URL
    let provider: RemoteMediaProvider
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

struct RuntimeMediaPanelView: View {
    let snapshot: RuntimeMediaPanelSnapshot

    static func preferredSize(
        for snapshot: RuntimeMediaPanelSnapshot
    ) -> CGSize {
        let hasGrid = !snapshot.items.isEmpty
        return CGSize(
            width: 500,
            height: hasGrid ? 310 : 146
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
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("MojiPond media search")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(
                systemName: snapshot.command == .gif
                    ? "photo.stack"
                    : "sparkles.rectangle.stack"
            )
            .foregroundStyle(.tint)
            Text(snapshot.command?.invocation ?? "Media")
                .font(.headline.monospaced())
            statusBadge
            Spacer()
            Text("arrows choose  ·  ↩ insert  ·  esc close")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch snapshot.state {
        case .offline:
            Text("OFFLINE")
                .runtimeMediaBadge(color: .orange)
        case .loading, .resolving:
            ProgressView()
                .controlSize(.small)
        default:
            EmptyView()
        }
    }

    private var mediaGrid: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 8),
                count: 4
            ),
            spacing: 8
        ) {
            ForEach(Array(snapshot.items.enumerated()), id: \.element.id) {
                index,
                item in
                VStack(spacing: 4) {
                    RuntimeAnimatedMediaPreview(
                        url: item.previewURL,
                        provider: item.provider
                    )
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
                    index == snapshot.selectedIndex
                        ? Color.white
                        : Color.primary
                )
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            index == snapshot.selectedIndex
                                ? Color.accentColor
                                : Color.primary.opacity(0.055)
                        )
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(
                    index == snapshot.selectedIndex ? [.isSelected] : []
                )
            }
        }
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
        case .networkDisabled:
            Label(
                "Network GIF search is off. Enable it in Settings.",
                systemImage: "network.slash"
            )
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
                if attribution == .giphy {
                    Text(attribution.text)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.black, in: Capsule())
                } else {
                    Text(attribution.text)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
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
        case .missingGIPHYAPIKey:
            "Add a GIPHY API key in Settings."
        case .providerUnavailable:
            "The media provider is unavailable."
        case .invalidProviderResponse:
            "The provider returned an invalid response."
        case .unsupportedMedia:
            "The provider returned unsupported media."
        }
    }
}

private extension View {
    func runtimeMediaBadge(color: Color) -> some View {
        font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

private struct RuntimeAnimatedMediaPreview: NSViewRepresentable {
    let url: URL
    let provider: RemoteMediaProvider

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageFrameStyle = .none
        imageView.animates = true
        imageView.wantsLayer = true
        context.coordinator.load(
            url,
            provider: provider,
            into: imageView
        )
        return imageView
    }

    func updateNSView(_ imageView: NSImageView, context: Context) {
        context.coordinator.load(
            url,
            provider: provider,
            into: imageView
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
    final class Coordinator {
        private static let maximumPreviewBytes = 8 * 1_024 * 1_024
        private static let session =
            RuntimeMediaNetworkPolicy.nonCachingSession()
        private var representedURL: URL?
        private var representedProvider: RemoteMediaProvider?
        private var task: Task<Void, Never>?

        func load(
            _ url: URL,
            provider: RemoteMediaProvider,
            into imageView: NSImageView
        ) {
            guard
                representedURL != url
                    || representedProvider != provider
            else {
                return
            }
            representedURL = url
            representedProvider = provider
            task?.cancel()
            imageView.image = nil

            task = Task { @MainActor [weak imageView] in
                let data: Data
                do {
                    if url.isFileURL {
                        data = try Data(
                            contentsOf: url,
                            options: [.mappedIfSafe]
                        )
                    } else {
                        guard url.scheme?.lowercased() == "https" else {
                            return
                        }
                        let request =
                            RuntimeMediaNetworkPolicy.nonCachingRequest(
                                for: url
                            )
                        let (downloaded, response) =
                            try await Self.session.data(for: request)
                        guard
                            let response = response as? HTTPURLResponse,
                            (200 ..< 300).contains(response.statusCode),
                            response.mimeType?.hasPrefix("image/") == true
                        else {
                            return
                        }
                        data = downloaded
                    }
                    try Task.checkCancellation()
                    guard
                        !data.isEmpty,
                        data.count <= Self.maximumPreviewBytes,
                        let image = NSImage(data: data)
                    else {
                        return
                    }
                    imageView?.image = image
                } catch {
                    return
                }
            }
        }

        func cancel() {
            task?.cancel()
            task = nil
            representedURL = nil
            representedProvider = nil
        }
    }
}
