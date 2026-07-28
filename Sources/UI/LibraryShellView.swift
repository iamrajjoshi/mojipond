import SwiftUI

struct LibraryShellView: View {
    @ObservedObject var appState: AppState
    @State private var selection: LibrarySection? = .all
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            List(LibrarySection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .navigationTitle("MojiPond")
            .navigationSplitViewColumnWidth(min: 175, ideal: 205)
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selection?.title ?? "Library")
                            .font(.title2.weight(.semibold))
                        Text(selection?.subtitle ?? "")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                    } label: {
                        Label("Import Pack", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Choose an emoji file, folder, ZIP, or GitHub source")
                }
                .padding(PondDesign.contentPadding)

                Divider()

                ContentUnavailableView {
                    Label("Your pond is taking shape", systemImage: "water.waves")
                } description: {
                    Text("Built-in emoji and imported packs will appear here.")
                } actions: {
                    Button("Import a Pack") {}
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .searchable(text: $searchText, prompt: "Search emoji and packs")
        }
        .frame(minWidth: 840, minHeight: 560)
        .toolbar {
            ToolbarItem(placement: .status) {
                Label(appState.statusSummary, systemImage: statusIcon)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusIcon: String {
        if !appState.isEnabled {
            return "pause.circle"
        }
        return appState.canMonitorTyping ? "checkmark.circle" : "exclamationmark.circle"
    }
}

private enum LibrarySection: String, CaseIterable, Identifiable {
    case all
    case unicode
    case custom
    case stickers
    case gifs

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All Emoji"
        case .unicode: "Built-in"
        case .custom: "Custom Packs"
        case .stickers: "Stickers"
        case .gifs: "GIFs"
        }
    }

    var subtitle: String {
        switch self {
        case .all: "Everything available to autocomplete"
        case .unicode: "Unicode emoji and familiar aliases"
        case .custom: "Your installed image and animation packs"
        case .stickers: "Noto Animated Emoji"
        case .gifs: "Optional search powered by GIPHY"
        }
    }

    var icon: String {
        switch self {
        case .all: "square.grid.2x2"
        case .unicode: "face.smiling"
        case .custom: "shippingbox"
        case .stickers: "sparkles.rectangle.stack"
        case .gifs: "photo.stack"
        }
    }
}

