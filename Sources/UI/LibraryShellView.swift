import SwiftUI

struct LibraryShellView: View {
    @ObservedObject var appState: AppState
    @StateObject private var viewModel: LibraryViewModel

    @State private var showsBuiltInDetails = false
    @State private var selectedItem: LibraryDisplayItem?
    @State private var packDetails: PackDetailSelection?
    @State private var isDropTargeted = false
    @State private var dropTargetPackID: UUID?
    @FocusState private var focusedSidebarScope: LibraryScope?
    @Environment(\.colorSchemeContrast) private var contrast
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
                .navigationSplitViewColumnWidth(min: 175, ideal: 200, max: 240)
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
        .frame(minWidth: 780, minHeight: 520)
        .tint(PondDesign.pond)
        .background {
            PondWindowBackdrop()
        }
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
        .sheet(isPresented: importPreviewPresented) {
            LibraryImportPreviewView(viewModel: viewModel)
        }
        .sheet(item: $selectedItem) { item in
            LibraryItemDetailView(
                viewModel: viewModel,
                item: item,
                showsPersonalAliasEditor: viewModel.scope == .aliases
            )
        }
        .sheet(item: $packDetails) { selection in
            LibraryPackDetailView(
                viewModel: viewModel,
                packID: selection.id
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
            Button(
                viewModel.pendingRemoval?.confirmationButtonTitle ?? "Remove",
                role: .destructive
            ) {
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                PondMark(size: 30)
                Text("Library")
                    .font(.headline)
                    .fontDesign(.rounded)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Rectangle()
                .fill(PondDesign.ripple.opacity(0.2))
                .frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    sidebarSectionTitle("Library")

                    sidebarScopeRow(
                        .all,
                        title: "All Emoji",
                        icon: "square.grid.2x2",
                        count: viewModel.allDisplayItems.count
                    )
                    sidebarScopeRow(
                        .favorites,
                        title: "Favorites",
                        icon: "star",
                        count: viewModel.usageSnapshot.favoriteItemIDs.count
                    )
                    sidebarScopeRow(
                        .aliases,
                        title: "Aliases",
                        icon: "tag",
                        count: viewModel.personalAliasCount,
                        countDescription: viewModel.personalAliasCount == 1
                            ? "1 personal alias"
                            : "\(viewModel.personalAliasCount) personal aliases"
                    )
                    sidebarScopeRow(
                        .builtIn,
                        title: "Built-in",
                        icon: "face.smiling",
                        count: viewModel.builtInPack?.items.count ?? 0
                    )
                    sidebarScopeRow(
                        .custom,
                        title: "Custom",
                        icon: "shippingbox",
                        count: viewModel.packs.reduce(0) {
                            $0 + $1.items.count
                        }
                    )

                    if !viewModel.packs.isEmpty {
                        sidebarSectionTitle("Packs")
                            .padding(.top, 12)

                        ForEach(viewModel.packs) { pack in
                            sidebarPackRow(pack)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
            }
        }
        .background(PondDesign.sidebarSurface.opacity(0.9))
    }

    private func sidebarSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 11)
            .padding(.bottom, 3)
    }

    private func sidebarScopeRow(
        _ scope: LibraryScope,
        title: String,
        icon: String,
        count: Int,
        countDescription: String? = nil
    ) -> some View {
        let isSelected = viewModel.scope == scope
        let accessibilityCount = countDescription ?? "\(count) emoji"

        return Button {
            viewModel.scope = scope
            focusedSidebarScope = scope
        } label: {
            sidebarRowLabel(
                title: title,
                icon: icon,
                count: count,
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
        .focusable()
        .pondFocusEffectDisabled()
        .focused($focusedSidebarScope, equals: scope)
        .onMoveCommand(perform: moveSidebarSelection)
        .accessibilityLabel("\(title), \(accessibilityCount)")
        .accessibilityIdentifier("library.sidebar.\(scope.id)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func sidebarPackRow(_ pack: EmojiPack) -> some View {
        let scope = LibraryScope.pack(pack.id)
        let isSelected = viewModel.scope == scope

        return Button {
            viewModel.scope = scope
            focusedSidebarScope = scope
        } label: {
            sidebarRowLabel(
                title: pack.name,
                icon: "shippingbox",
                count: pack.items.count,
                isSelected: isSelected,
                status: pack.isEnabled ? nil : "Disabled"
            )
        }
        .buttonStyle(.plain)
        .focusable()
        .pondFocusEffectDisabled()
        .focused($focusedSidebarScope, equals: scope)
        .onMoveCommand(perform: moveSidebarSelection)
        .accessibilityLabel(
            "\(pack.name), \(pack.items.count) emoji, "
                + (pack.isEnabled ? "enabled" : "disabled")
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("library.sidebar.pack.\(pack.id.uuidString)")
        .help("Drag to reorder packs")
        .draggable(pack.id.uuidString) {
            Label(pack.name, systemImage: "shippingbox")
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.regularMaterial)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: PondDesign.compactCornerRadius
                    )
                )
        }
        .dropDestination(for: String.self) { values, _ in
            handlePackDrop(values, onto: pack.id)
        } isTargeted: { isTargeted in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                if isTargeted {
                    dropTargetPackID = pack.id
                } else if dropTargetPackID == pack.id {
                    dropTargetPackID = nil
                }
            }
        }
        .overlay {
            if dropTargetPackID == pack.id {
                RoundedRectangle(
                    cornerRadius: PondDesign.compactCornerRadius
                )
                .stroke(PondDesign.pond, lineWidth: 2)
                .allowsHitTesting(false)
            }
        }
        .accessibilityAction(named: "Move Up") {
            Task {
                await viewModel.movePack(pack.id, by: -1)
            }
        }
        .accessibilityAction(named: "Move Down") {
            Task {
                await viewModel.movePack(pack.id, by: 1)
            }
        }
        .contextMenu {
            Button(pack.isEnabled ? "Disable Pack" : "Enable Pack") {
                Task {
                    await viewModel.setPackEnabled(
                        pack.id,
                        isEnabled: !pack.isEnabled
                    )
                }
            }
            Button("Pack Details") {
                packDetails = PackDetailSelection(id: pack.id)
            }
            Divider()
            Button("Remove Pack…", role: .destructive) {
                viewModel.requestRemovePack(pack)
            }
        }
    }

    private func handlePackDrop(
        _ values: [String],
        onto destinationPackID: UUID
    ) -> Bool {
        defer {
            dropTargetPackID = nil
        }
        guard
            let value = values.first,
            let sourcePackID = UUID(uuidString: value),
            sourcePackID != destinationPackID,
            viewModel.packs.contains(where: { $0.id == sourcePackID })
        else {
            return false
        }

        Task {
            await viewModel.movePack(
                sourcePackID,
                toPack: destinationPackID
            )
        }
        return true
    }

    private func moveSidebarSelection(_ direction: MoveCommandDirection) {
        let scopes = [
            LibraryScope.all,
            .favorites,
            .aliases,
            .builtIn,
            .custom
        ] + viewModel.packs.map { .pack($0.id) }
        guard
            let currentIndex = scopes.firstIndex(
                of: focusedSidebarScope ?? viewModel.scope
            )
        else {
            return
        }

        let nextIndex: Int
        switch direction {
        case .up:
            nextIndex = max(scopes.startIndex, currentIndex - 1)
        case .down:
            nextIndex = min(scopes.index(before: scopes.endIndex), currentIndex + 1)
        default:
            return
        }
        guard nextIndex != currentIndex else {
            return
        }

        let nextScope = scopes[nextIndex]
        viewModel.scope = nextScope
        focusedSidebarScope = nextScope
    }

    private func sidebarRowLabel(
        title: String,
        icon: String,
        count: Int,
        isSelected: Bool,
        status: String? = nil
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isSelected ? PondDesign.pond : .primary)
                .frame(width: 19)
                .accessibilityHidden(true)
            Text(title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(count.formatted())
                .font(.caption.monospacedDigit())
                .foregroundStyle(isSelected ? PondDesign.pond : .secondary)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(
            isSelected
                ? PondDesign.pond.opacity(
                    contrast == .increased ? 0.24 : 0.11
                )
                : Color.clear,
            in: RoundedRectangle(
                cornerRadius: PondDesign.compactCornerRadius
            )
        )
        .overlay {
            if isSelected && contrast == .increased {
                RoundedRectangle(
                    cornerRadius: PondDesign.compactCornerRadius
                )
                .stroke(PondDesign.pond, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
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
        .background(PondDesign.windowBottom.opacity(0.92))
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(viewModel.selectedScopeTitle)
                        .font(.title2.weight(.semibold))
                    Text(viewModel.selectedScopeSubtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                        .accessibilityLabel(
                            viewModel.selectedScopeSubtitle
                        )
                }
                Spacer()

                Button {
                    chooseZIP()
                } label: {
                    Label(
                        "Import ZIP…",
                        systemImage: "square.and.arrow.down"
                    )
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint(
                    "Choose one local ZIP archive, or drop a ZIP anywhere in the Library"
                )

                if case .builtIn = viewModel.scope {
                    Button("Source & License…", systemImage: "info.circle") {
                        showsBuiltInDetails = true
                    }
                } else if let pack = viewModel.selectedPack {
                    LibraryPackEnabledToggle(
                        viewModel: viewModel,
                        pack: pack
                    )
                    Button("Pack Details…", systemImage: "info.circle") {
                        packDetails = PackDetailSelection(id: pack.id)
                    }
                }
            }

            HStack(spacing: 8) {
                Menu {
                    Picker("Category", selection: $viewModel.categoryFilter) {
                        Text("All Categories")
                            .tag(String?.none)
                        ForEach(
                            viewModel.availableCategories,
                            id: \.self
                        ) { category in
                            Text(category)
                                .tag(Optional(category))
                        }
                    }

                    Picker("Content Type", selection: $viewModel.contentFilter) {
                        ForEach(LibraryContentFilter.allCases) { filter in
                            Text(filter.title)
                                .tag(filter)
                        }
                    }
                } label: {
                    Label(filterLabel, systemImage: "line.3.horizontal.decrease")
                }
                .fixedSize()

                if hasActiveFilters {
                    Button("Clear", action: clearFilters)
                        .buttonStyle(.plain)
                        .foregroundStyle(PondDesign.pond)
                }

                Spacer()
            }
        }
        .padding(PondDesign.contentPadding)
        .background(PondDesign.surface.opacity(0.82))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PondDesign.ripple.opacity(0.22))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .idle, .loading:
            LibraryLoadingView()
        case let .failed(message):
            GeometryReader { proxy in
                PondEmptyState(
                    "Library unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: message
                ) {
                    Button("Try Again") {
                        Task {
                            await viewModel.reload()
                        }
                    }
                }
                .frame(
                    width: proxy.size.width,
                    height: proxy.size.height
                )
            }
        case .loaded, .partial:
            if viewModel.visibleItems.isEmpty {
                GeometryReader { proxy in
                    PondEmptyState(
                        emptyTitle,
                        systemImage: emptyIcon,
                        description: emptyDescription
                    ) {
                        if hasActiveFilters {
                            Button("Clear Filters") {
                                clearFilters()
                            }
                        }
                    }
                    .frame(
                        width: proxy.size.width,
                        height: proxy.size.height
                    )
                }
            } else if viewModel.layout == .grid {
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(
                                .adaptive(minimum: 118, maximum: 154),
                                spacing: 10
                            )
                        ],
                        spacing: 10
                    ) {
                        ForEach(viewModel.visibleItems) { item in
                            LibraryEmojiCard(
                                item: item,
                                personalAliases: viewModel.customAliases(
                                    for: item
                                ),
                                showsPersonalAliases:
                                    viewModel.scope == .aliases
                            ) {
                                selectedItem = item
                            }
                            .contextMenu {
                                emojiContextMenu(for: item)
                            }
                        }
                    }
                    .padding(PondDesign.contentPadding)
                }
            } else {
                List(viewModel.visibleItems) { item in
                    LibraryEmojiListRow(
                        item: item,
                        personalAliases: viewModel.customAliases(for: item),
                        showsPersonalAliases: viewModel.scope == .aliases
                    ) {
                        selectedItem = item
                    }
                    .contextMenu {
                        emojiContextMenu(for: item)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder
    private func emojiContextMenu(
        for item: LibraryDisplayItem
    ) -> some View {
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
        Button("Show Details…") {
            selectedItem = item
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
        hasActiveFilters ? "No matching emoji" : "No emoji in this view"
    }

    private var emptyIcon: String {
        hasActiveFilters ? "magnifyingglass" : "water.waves"
    }

    private var emptyDescription: String {
        if hasActiveFilters {
            return "Try another search, or clear the current filters."
        }
        if case .custom = viewModel.scope {
            return "Import a ZIP pack to add custom emoji."
        }
        if case .favorites = viewModel.scope {
            return "Mark emoji as favorites from an item’s context menu or detail view."
        }
        if case .aliases = viewModel.scope {
            return "No emoji are available to alias. Clear the filters or import a ZIP pack."
        }
        if case .pack = viewModel.scope {
            return "This pack is empty. Review a replacement ZIP in Pack Details."
        }
        return "Change the filters or import a custom ZIP pack."
    }

    private var hasActiveFilters: Bool {
        !viewModel.searchText.isEmpty
            || viewModel.categoryFilter != nil
            || viewModel.contentFilter != .all
    }

    private var filterLabel: String {
        let activeCount = (viewModel.categoryFilter == nil ? 0 : 1)
            + (viewModel.contentFilter == .all ? 0 : 1)
        return activeCount == 0 ? "Filters" : "Filters (\(activeCount))"
    }

    private func clearFilters() {
        viewModel.searchText = ""
        viewModel.categoryFilter = nil
        viewModel.contentFilter = .all
    }

    private func chooseZIP() {
        guard let url = LibraryZIPPicker.choose(
            title: "Choose an emoji ZIP"
        ) else {
            return
        }
        viewModel.prepareImport(.zipArchive(url))
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
            .background(
                PondDesign.raisedSurface,
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(PondDesign.ripple.opacity(0.45))
            }
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
