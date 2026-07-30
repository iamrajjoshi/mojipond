import SwiftUI

struct LibraryShellView: View {
    @ObservedObject var appState: AppState
    @StateObject private var viewModel: LibraryViewModel

    @State private var showsImportSource = false
    @State private var showsNewPack = false
    @State private var showsBuiltInDetails = false
    @State private var selectedItem: LibraryDisplayItem?
    @State private var packDetails: PackDetailSelection?
    @State private var unicodeItemDestination:
        UnicodeItemDestination?
    @State private var isDropTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(appState: AppState) {
        self.appState = appState
        _viewModel = StateObject(wrappedValue: LibraryViewModel.live())
    }

    init(appState: AppState, viewModel: LibraryViewModel) {
        self.appState = appState
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle("MojiPond")
                .navigationSplitViewColumnWidth(min: 190, ideal: 225, max: 280)
        } detail: {
            detail
                .searchable(
                    text: $viewModel.searchText,
                    placement: .toolbar,
                    prompt: "Shortcode, name, tag, or pack"
                )
        }
        .overlay {
            ZStack {
                LibraryDropOverlay(isTargeted: isDropTargeted)
                if viewModel.isPreparingImport {
                    importProgressOverlay
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            viewModel.prepareDroppedURLs(urls)
        } isTargeted: { targeted in
            withAnimation(
                reduceMotion ? nil : .easeOut(duration: 0.16)
            ) {
                isDropTargeted = targeted
            }
        }
        .frame(minWidth: 840, minHeight: 560)
        .environment(
            \.libraryThumbnailLoader,
            viewModel.thumbnailService
        )
        .toolbar {
            ToolbarItemGroup {
                Picker("Layout", selection: $viewModel.layout) {
                    ForEach(LibraryLayout.allCases) { layout in
                        Image(systemName: layout.icon)
                            .tag(layout)
                            .accessibilityLabel(layout == .grid ? "Grid" : "List")
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 76)
            }
        }
        .task {
            if viewModel.loadState == .idle {
                await viewModel.reload()
            }
        }
        .sheet(isPresented: $showsImportSource) {
            LibraryImportSourceView(
                viewModel: viewModel
            ) {
                showsImportSource = false
            }
        }
        .sheet(isPresented: importPreviewPresented) {
            LibraryImportPreviewView(viewModel: viewModel)
        }
        .sheet(isPresented: $showsNewPack) {
            LibraryNewPackView(viewModel: viewModel)
        }
        .sheet(item: $selectedItem) { item in
            LibraryItemDetailView(viewModel: viewModel, item: item)
        }
        .sheet(item: $packDetails) { selection in
            LibraryPackDetailView(
                viewModel: viewModel,
                packID: selection.id
            )
        }
        .sheet(item: $unicodeItemDestination) { destination in
            LibraryAddUnicodeItemView(
                viewModel: viewModel,
                packID: destination.id,
                packName: destination.packName
            )
        }
        .sheet(isPresented: $showsBuiltInDetails) {
            LibraryBuiltInPackDetailView(pack: viewModel.builtInPack)
        }
        .confirmationDialog(
            viewModel.pendingRemoval?.title ?? "Remove from library?",
            isPresented: removalPresented,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                Task {
                    await viewModel.confirmRemoval()
                }
            }
            Button("Cancel", role: .cancel) {
                viewModel.cancelRemoval()
            }
        } message: {
            Text(viewModel.pendingRemoval?.message ?? "")
        }
    }

    private var sidebar: some View {
        List(selection: $viewModel.scope) {
            Section("Library") {
                Label("All Emoji", systemImage: "square.grid.2x2")
                    .badge(viewModel.allDisplayItems.count)
                    .tag(LibraryScope.all)
                Label("Favorites", systemImage: "star")
                    .badge(viewModel.usageSnapshot.favoriteItemIDs.count)
                    .tag(LibraryScope.favorites)
                Label("Built-in", systemImage: "face.smiling")
                    .badge(viewModel.builtInPack?.items.count ?? 0)
                    .tag(LibraryScope.builtIn)
                Label("Custom", systemImage: "shippingbox")
                    .badge(viewModel.packs.reduce(0) { $0 + $1.items.count })
                    .tag(LibraryScope.custom)
            }

            Section("Packs") {
                ForEach(viewModel.packs) { pack in
                    HStack(spacing: 8) {
                        Image(systemName: pack.isEnabled ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(
                                pack.isEnabled ? PondDesign.lily : Color.secondary
                            )
                            .accessibilityHidden(true)
                        Text(pack.name)
                            .lineLimit(1)
                        Spacer()
                        Text(pack.items.count.formatted())
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .tag(LibraryScope.pack(pack.id))
                    .accessibilityLabel(
                        "\(pack.name), \(pack.items.count) emoji, \(pack.isEnabled ? "enabled" : "disabled")"
                    )
                    .contextMenu {
                        Button(pack.isEnabled ? "Disable Pack" : "Enable Pack") {
                            Task {
                                await viewModel.setPackEnabled(
                                    pack.id,
                                    isEnabled: !pack.isEnabled
                                )
                            }
                        }
                        Button("Pack Details…") {
                            packDetails = PackDetailSelection(id: pack.id)
                        }
                        Button("Add Unicode Emoji…") {
                            unicodeItemDestination =
                                UnicodeItemDestination(
                                    id: pack.id,
                                    packName: pack.name
                                )
                        }
                        Divider()
                        Button("Move Up") {
                            Task {
                                await viewModel.movePack(pack.id, by: -1)
                            }
                        }
                        .disabled(!viewModel.canMovePack(pack.id, by: -1))
                        Button("Move Down") {
                            Task {
                                await viewModel.movePack(pack.id, by: 1)
                            }
                        }
                        .disabled(!viewModel.canMovePack(pack.id, by: 1))
                        Divider()
                        Button("Remove Pack…", role: .destructive) {
                            viewModel.requestRemovePack(pack)
                        }
                    }
                }

                Button {
                    showsNewPack = true
                } label: {
                    Label("New Empty Pack…", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }

            Section {
                Text("Drop a ZIP anywhere in this window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let notice = viewModel.notice {
                LibraryNoticeBanner(notice: notice) {
                    viewModel.dismissNotice()
                }
            }

            if case let .partial(message) = viewModel.loadState {
                partialBanner(message)
            }

            content

            if let undoMessage = viewModel.undoMessage {
                undoBar(undoMessage)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(viewModel.selectedScopeTitle)
                        .font(.title2.weight(.semibold))
                    Text(viewModel.selectedScopeSubtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()

                Button {
                    showsImportSource = true
                } label: {
                    Label(
                        "Import ZIP",
                        systemImage: "square.and.arrow.down"
                    )
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("i", modifiers: .command)
                .accessibilityHint(
                    "Choose one local ZIP archive"
                )

                if case .builtIn = viewModel.scope {
                    Button("Source & License", systemImage: "info.circle") {
                        showsBuiltInDetails = true
                    }
                } else if let pack = viewModel.selectedPack {
                    Toggle(
                        "Enabled",
                        isOn: Binding(
                            get: { pack.isEnabled },
                            set: { enabled in
                                Task {
                                    await viewModel.setPackEnabled(pack.id, isEnabled: enabled)
                                }
                            }
                        )
                    )
                    .toggleStyle(.switch)
                    Button(
                        "Add Unicode Emoji",
                        systemImage: "text.badge.plus"
                    ) {
                        unicodeItemDestination =
                            UnicodeItemDestination(
                                id: pack.id,
                                packName: pack.name
                            )
                    }
                    Button("Pack Details", systemImage: "info.circle") {
                        packDetails = PackDetailSelection(id: pack.id)
                    }
                }
            }

            HStack(spacing: 10) {
                Picker("Category", selection: $viewModel.categoryFilter) {
                    Text("All Categories")
                        .tag(String?.none)
                    ForEach(viewModel.availableCategories, id: \.self) { category in
                        Text(category)
                            .tag(Optional(category))
                    }
                }
                .frame(maxWidth: 210)

                Picker("Content Type", selection: $viewModel.contentFilter) {
                    ForEach(LibraryContentFilter.allCases) { filter in
                        Text(filter.title)
                            .tag(filter)
                    }
                }
                .frame(width: 210, alignment: .leading)

                Spacer()

                Text("\(viewModel.visibleItems.count.formatted()) shown")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(viewModel.visibleItems.count) emoji shown")
            }
        }
        .padding(PondDesign.contentPadding)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .idle, .loading:
            LibraryLoadingView()
        case let .failed(message):
            ContentUnavailableView {
                Label("Library unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") {
                    Task {
                        await viewModel.reload()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded, .partial:
            if viewModel.visibleItems.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: emptyIcon)
                } description: {
                    Text(emptyDescription)
                } actions: {
                    if viewModel.searchText.isEmpty {
                        if let pack = viewModel.selectedPack {
                            Button("Add Unicode Emoji") {
                                unicodeItemDestination =
                                    UnicodeItemDestination(
                                        id: pack.id,
                                        packName: pack.name
                                    )
                            }
                        }
                    } else {
                        Button("Clear Search") {
                            viewModel.searchText = ""
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.layout == .grid {
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(
                                .adaptive(minimum: 132, maximum: 190),
                                spacing: 12
                            )
                        ],
                        spacing: 12
                    ) {
                        ForEach(viewModel.visibleItems) { item in
                            LibraryEmojiCard(item: item) {
                                selectedItem = item
                            }
                            .contextMenu {
                                Button(
                                    viewModel.isFavorite(item)
                                        ? "Remove from Favorites"
                                        : "Add to Favorites"
                                ) {
                                    Task {
                                        await viewModel.toggleFavorite(item)
                                    }
                                }
                                Button("Copy Emoji") {
                                    Task {
                                        await viewModel.copyToClipboard(item)
                                    }
                                }
                                Button("Show Details") {
                                    selectedItem = item
                                }
                            }
                        }
                    }
                    .padding(PondDesign.contentPadding)
                }
            } else {
                List(viewModel.visibleItems) { item in
                    LibraryEmojiListRow(item: item) {
                        selectedItem = item
                    }
                    .contextMenu {
                        Button(
                            viewModel.isFavorite(item)
                                ? "Remove from Favorites"
                                : "Add to Favorites"
                        ) {
                            Task {
                                await viewModel.toggleFavorite(item)
                            }
                        }
                        Button("Copy Emoji") {
                            Task {
                                await viewModel.copyToClipboard(item)
                            }
                        }
                        Button("Show Details") {
                            selectedItem = item
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func partialBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(PondDesign.warningForeground)
            VStack(alignment: .leading, spacing: 2) {
                Text("Some library content could not be loaded")
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Retry") {
                Task {
                    await viewModel.reload()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(PondDesign.warningBackground)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func undoBar(_ message: String) -> some View {
        HStack {
            Text(message)
                .font(.callout)
            Spacer()
            Button("Undo") {
                Task {
                    await viewModel.undoLastMutation()
                }
            }
            .keyboardShortcut("z", modifiers: .command)
            Button("Dismiss", systemImage: "xmark") {
                viewModel.dismissUndo()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss undo")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var emptyTitle: String {
        viewModel.searchText.isEmpty
            ? "No emoji in this view"
            : "No matching emoji"
    }

    private var emptyIcon: String {
        viewModel.searchText.isEmpty ? "water.waves" : "magnifyingglass"
    }

    private var emptyDescription: String {
        if !viewModel.searchText.isEmpty {
            return "Try a different shortcode, name, tag, pack, category, or content type."
        }
        if case .custom = viewModel.scope {
            return "Import a ZIP pack to add custom emoji."
        }
        if case .favorites = viewModel.scope {
            return "Mark emoji as favorites from an item’s context menu or detail view."
        }
        if case .pack = viewModel.scope {
            return "This pack is empty. Add Unicode emoji here, or review a replacement ZIP in Pack Details."
        }
        return "Change the filters or import a custom ZIP pack."
    }

    private var importProgressOverlay: some View {
        ZStack {
            Color.black.opacity(0.08)
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Inspecting import…")
                    .font(.headline)
                Text("Validating files and preparing a local preview.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Cancel") {
                    viewModel.cancelImport()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preparing emoji import")
    }

    private var importPreviewPresented: Binding<Bool> {
        Binding {
            viewModel.importSession != nil
        } set: { isPresented in
            if !isPresented, viewModel.importSession != nil {
                Task {
                    await viewModel.discardImport()
                }
            }
        }
    }

    private var removalPresented: Binding<Bool> {
        Binding {
            viewModel.pendingRemoval != nil
        } set: { isPresented in
            if !isPresented {
                viewModel.cancelRemoval()
            }
        }
    }
}

private struct PackDetailSelection: Identifiable {
    let id: UUID
}

private struct UnicodeItemDestination: Identifiable {
    let id: UUID
    let packName: String
}
