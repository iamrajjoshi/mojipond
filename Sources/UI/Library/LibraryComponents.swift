import AppKit
import SwiftUI

struct LibraryEmojiArtwork: View {
    let item: LibraryDisplayItem
    var size: CGFloat = 54

    var body: some View {
        Group {
            if let unicode = item.unicode {
                Text(unicode)
                    .font(.system(size: size * 0.72))
                    .minimumScaleFactor(0.5)
            } else if let assetURL = item.assetURL {
                LibraryAssetArtwork(url: assetURL)
            } else {
                Image(systemName: "questionmark.square.dashed")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(.tertiary)
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
        .accessibilityHidden(true)
    }
}

struct LibraryAssetArtwork: View {
    let url: URL

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(5)
        .task(id: url) {
            image = NSImage(contentsOf: url)
        }
    }
}

struct LibraryEmojiCard: View {
    let item: LibraryDisplayItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                LibraryEmojiArtwork(item: item, size: 62)

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
            .background(.background, in: RoundedRectangle(cornerRadius: PondDesign.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: PondDesign.cornerRadius)
                    .stroke(.separator.opacity(0.55))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(item.packEnabled ? 1 : 0.52)
        .accessibilityLabel(item.accessibilityLabel)
        .accessibilityHint("Opens emoji details")
    }
}

struct LibraryEmojiListRow: View {
    let item: LibraryDisplayItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                LibraryEmojiArtwork(item: item, size: 42)

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

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(item.packEnabled ? 1 : 0.52)
        .accessibilityLabel(item.accessibilityLabel)
        .accessibilityHint("Opens emoji details")
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
            .orange
        case .error:
            .red
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

