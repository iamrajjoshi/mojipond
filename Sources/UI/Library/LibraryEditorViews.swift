import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryItemDetailView: View {
    @ObservedObject var viewModel: LibraryViewModel
    let item: LibraryDisplayItem
    let showsPersonalAliasEditor: Bool

    @State private var draft: LibraryItemDraft?
    @State private var savedDraft: LibraryItemDraft?
    @State private var customAliasesDraft: String
    @State private var savedCustomAliasesDraft: String
    @State private var aliasSaveConfirmation: String?
    @State private var isSaving = false
    @State private var showsAliasDiscardConfirmation = false
    @State private var showsCustomDiscardConfirmation = false
    @Environment(\.dismiss) private var dismiss

    init(
        viewModel: LibraryViewModel,
        item: LibraryDisplayItem,
        showsPersonalAliasEditor: Bool = false
    ) {
        self.viewModel = viewModel
        self.item = item
        self.showsPersonalAliasEditor = showsPersonalAliasEditor
        if case let .custom(packID) = item.origin,
           let libraryItem = viewModel.item(
               packID: packID,
               itemID: Self.itemID(from: item.id)
           ) {
            let initialDraft = LibraryItemDraft(
                packID: packID,
                item: libraryItem
            )
            _draft = State(initialValue: initialDraft)
            _savedDraft = State(initialValue: initialDraft)
        } else {
            _draft = State(initialValue: nil)
            _savedDraft = State(initialValue: nil)
        }
        let customAliases = viewModel.customAliases(for: item)
            .joined(separator: ", ")
        _customAliasesDraft = State(initialValue: customAliases)
        _savedCustomAliasesDraft = State(initialValue: customAliases)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                LibraryEmojiArtwork(item: item, size: 64)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.displayName)
                        .font(.title2.weight(.semibold))
                    Text(":\(item.shortcode):")
                        .font(.title3.monospaced())
                        .textSelection(.enabled)
                    Label(item.packName, systemImage: "shippingbox")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task {
                        await viewModel.toggleFavorite(item)
                    }
                } label: {
                    Image(
                        systemName: viewModel.isFavorite(item)
                            ? "star.fill"
                            : "star"
                    )
                }
                .buttonStyle(.borderless)
                .help(
                    viewModel.isFavorite(item)
                        ? "Remove from Favorites"
                        : "Add to Favorites"
                )
                .accessibilityLabel(
                    viewModel.isFavorite(item)
                        ? "Remove \(item.displayName) from Favorites"
                        : "Add \(item.displayName) to Favorites"
                )
            }
            .padding(18)

            Divider()

            if showsPersonalAliasEditor {
                personalAliasEditor
            } else if draft != nil {
                customEditor
            } else {
                builtInDetails
            }
        }
        .frame(
            width: 540,
            height: showsPersonalAliasEditor
                ? 480
                : draft == nil ? 460 : 500
        )
        .overlay {
            if isSaving {
                ProgressView()
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .confirmationDialog(
            "Discard unsaved alias changes?",
            isPresented: $showsAliasDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) {
                dismiss()
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Your saved aliases won’t change.")
        }
        .confirmationDialog(
            "Discard unsaved emoji changes?",
            isPresented: $showsCustomDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) {
                dismiss()
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("The saved shortcode and details won’t change.")
        }
    }

    private var personalAliasEditor: some View {
        Form {
            Section("Your aliases") {
                personalAliasFields
            }

            if let notice = viewModel.notice {
                Section {
                    HStack(alignment: .top, spacing: 8) {
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
                            }
                        }
                        Spacer()
                    }
                }
            }

            Section("Emoji") {
                LabeledContent(
                    "Primary shortcode",
                    value: ":\(item.shortcode):"
                )
                LabeledContent("Pack", value: item.packName)
                LabeledContent(
                    "Pack aliases",
                    value: item.aliases.isEmpty
                        ? "None"
                        : item.aliases.map { ":\($0):" }
                            .joined(separator: ", ")
                )
            }
        }
        .formStyle(.grouped)
        .disabled(isSaving)
        .onAppear {
            viewModel.dismissNotice()
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Copy Emoji") {
                    Task {
                        await viewModel.copyToClipboard(item)
                    }
                }
                Spacer()
                Button("Close") {
                    finishAliasEditing()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            .background(.bar)
        }
    }

    private var customEditor: some View {
        Form {
            Section("Autocomplete") {
                TextField(
                    "Shortcode",
                    text: draftBinding(\.shortcode)
                )
                .font(.body.monospaced())
                .accessibilityHint("Colons are optional")

                TextField(
                    "Aliases, separated by commas",
                    text: draftBinding(\.aliases)
                )
                .font(.body.monospaced())
            }

            Section("Discovery") {
                TextField("Display name", text: draftBinding(\.displayName))
                TextField("Tags, separated by commas", text: draftBinding(\.tags))
                TextField("Category", text: draftBinding(\.category))
            }

            Section("Managed file") {
                HStack {
                    Text(item.format?.displayName ?? "Unicode")
                    Spacer()
                    if let assetURL = item.assetURL {
                        Text(assetURL.lastPathComponent)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        .textSelection(.enabled)
                    }
                }
                if item.format == .webP {
                    Label(
                        item.isAnimated
                            ? "On macOS 15, animated WebP inserts frame 0 as an inline emoji. The original animation stays stored, and Copy Media Instead remains available if conversion fails."
                            : "Static WebP is checked at insertion time and includes a PNG compatibility fallback.",
                        systemImage: item.isAnimated
                            ? "flask"
                            : "checkmark.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Button("Replace File…", action: chooseReplacement)
                    .disabled(item.assetURL == nil)
            }

            if let notice = viewModel.notice,
               notice.kind == .error {
                Section {
                    Label(
                        "\(notice.title): \(notice.message)",
                        systemImage: "exclamationmark.circle"
                    )
                    .foregroundStyle(PondDesign.errorForeground)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(isSaving)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Remove Emoji…", role: .destructive) {
                    guard case let .custom(packID) = item.origin,
                          let libraryItem = viewModel.item(
                              packID: packID,
                              itemID: Self.itemID(from: item.id)
                          ) else {
                        return
                    }
                    viewModel.requestRemoveItem(packID: packID, item: libraryItem)
                    dismiss()
                }
                Button("Copy Emoji") {
                    Task {
                        await viewModel.copyToClipboard(item)
                    }
                }
                Spacer()
                Button("Cancel") {
                    finishCustomEditing()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard let currentDraft = self.draft else {
                        return
                    }
                    isSaving = true
                    Task {
                        let saved = await viewModel.updateItem(currentDraft)
                        isSaving = false
                        if saved {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(18)
            .background(.bar)
        }
    }

    private var builtInDetails: some View {
        Form {
            Section("Built-in Unicode emoji") {
                LabeledContent("Shortcode", value: ":\(item.shortcode):")
                LabeledContent(
                    "Aliases",
                    value: item.aliases.isEmpty
                        ? "None"
                        : item.aliases.map { ":\($0):" }.joined(separator: ", ")
                )
                LabeledContent("Category", value: item.category)
                if !item.tags.isEmpty {
                    LabeledContent("Search tags", value: item.tags.joined(separator: ", "))
                }
            }

            Section("Your aliases") {
                personalAliasFields
            }

            if let notice = viewModel.notice {
                Section {
                    Label(
                        notice.message.isEmpty
                            ? notice.title
                            : "\(notice.title): \(notice.message)",
                        systemImage: notice.kind.symbolName
                    )
                    .foregroundStyle(notice.kind.tint)
                }
            }

            if !viewModel.availableSkinTones(for: item).isEmpty {
                Section("Appearance") {
                    Picker(
                        "Preferred skin tone",
                        selection: Binding(
                            get: {
                                viewModel.preferredSkinTone(for: item)
                            },
                            set: { tone in
                                Task {
                                    await viewModel.setPreferredSkinTone(
                                        tone,
                                        for: item
                                    )
                                }
                            }
                        )
                    ) {
                        Text("Use default").tag(EmojiSkinTone?.none)
                        ForEach(
                            viewModel.availableSkinTones(for: item),
                            id: \.self
                        ) { tone in
                            Text("\(tone.modifier) \(tone.displayName)")
                                .tag(Optional(tone))
                        }
                    }
                }
            }

            Section("Source & attribution") {
                LabeledContent("Dataset", value: "github/gemoji")
                LabeledContent("License", value: "MIT")
                Link(
                    "View gemoji source",
                    destination: URL(string: "https://github.com/github/gemoji")!
                )
            }
        }
        .formStyle(.grouped)
        .disabled(isSaving)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Copy Emoji") {
                    Task {
                        await viewModel.copyToClipboard(item)
                    }
                }
                Spacer()
                Button("Close") {
                    finishAliasEditing()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(18)
            .background(.bar)
        }
    }

    private func finishCustomEditing() {
        guard draft != savedDraft else {
            dismiss()
            return
        }
        showsCustomDiscardConfirmation = true
    }

    private func savePersonalAliases() {
        guard
            !isSaving,
            customAliasesDraft != savedCustomAliasesDraft
        else {
            return
        }
        aliasSaveConfirmation = nil
        isSaving = true
        Task {
            await viewModel.setCustomAliases(
                customAliasesDraft,
                for: item
            )
            isSaving = false
            if viewModel.notice?.kind == .information {
                savedCustomAliasesDraft = customAliasesDraft
                aliasSaveConfirmation = "Saved"
                viewModel.dismissNotice()
            }
        }
    }

    private func finishAliasEditing() {
        if customAliasesDraft == savedCustomAliasesDraft {
            dismiss()
        } else {
            showsAliasDiscardConfirmation = true
        }
    }

    private var personalAliasFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add alternate shortcodes for this emoji, separated by commas.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("hello_pond, frog_friend", text: $customAliasesDraft)
                .labelsHidden()
                .font(.body.monospaced())
                .accessibilityLabel("Aliases, separated by commas")
                .accessibilityIdentifier("library.personalAliases")
                .accessibilityHint(
                    "Adds local aliases without changing the emoji pack."
                )
                .onSubmit(savePersonalAliases)
                .onChange(of: customAliasesDraft) { _ in
                    aliasSaveConfirmation = nil
                }

            HStack {
                if let aliasSaveConfirmation {
                    Label(
                        aliasSaveConfirmation,
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(PondDesign.lily)
                    .accessibilityIdentifier(
                        "library.personalAliasesSaved"
                    )
                }
                Spacer()
                Button {
                    savePersonalAliases()
                } label: {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Save Aliases")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    isSaving
                        || customAliasesDraft == savedCustomAliasesDraft
                )
            }
        }
    }

    private func draftBinding(
        _ keyPath: WritableKeyPath<LibraryItemDraft, String>
    ) -> Binding<String> {
        Binding {
            draft?[keyPath: keyPath] ?? ""
        } set: { value in
            draft?[keyPath: keyPath] = value
        }
    }

    private func chooseReplacement() {
        guard let draft else {
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Choose replacement emoji"
        panel.prompt = "Replace"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .gif]
            + [UTType(filenameExtension: "webp")].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        isSaving = true
        Task {
            let replaced = await viewModel.replaceItemAsset(
                packID: draft.packID,
                itemID: draft.itemID,
                sourceURL: url
            )
            isSaving = false
            if replaced {
                dismiss()
            }
        }
    }

    private static func itemID(from displayID: String) -> UUID {
        let rawValue = displayID.replacingOccurrences(of: "custom-", with: "")
        return UUID(uuidString: rawValue) ?? UUID()
    }
}

struct LibraryPackDetailView: View {
    @ObservedObject var viewModel: LibraryViewModel
    let packID: UUID

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let pack = viewModel.library.packs.first(where: { $0.id == packID }) {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(PondDesign.pond.opacity(0.12))
                        Image(systemName: "shippingbox.fill")
                            .font(.title2)
                            .foregroundStyle(PondDesign.pond)
                    }
                    .frame(width: 50, height: 50)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(pack.name)
                            .font(.title2.weight(.semibold))
                        Text(viewModel.sourceSummary(for: pack))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    LibraryPackEnabledToggle(
                        viewModel: viewModel,
                        pack: pack
                    )
                }
                .padding(20)

                Divider()

                Form {
                    Section("Pack") {
                        LabeledContent("Emoji", value: pack.items.count.formatted())
                        if let description = metadataValue(
                            pack.manifest.description
                        ) {
                            LabeledContent("Description", value: description)
                        }
                    }

                    if hasManifestDetails(pack) {
                        Section("Details") {
                            if let author = metadataValue(pack.manifest.author) {
                                LabeledContent("Author", value: author)
                            }
                            if let license = metadataValue(pack.manifest.license) {
                                LabeledContent("License", value: license)
                            }
                            if let sourceURL = pack.manifest.sourceURL {
                                Link("Open source page", destination: sourceURL)
                            }
                        }
                    }

                    Section("Manage") {
                        Button("Replace from ZIP…") {
                            chooseReplacementZIP(for: pack)
                        }
                        .help(
                            "Review one ZIP archive before replacing this pack."
                        )
                        Button("Show Pack Files…") {
                            reveal(pack)
                        }
                        Button("Export Pack…") {
                            export(pack)
                        }
                    }

                    Section {
                        Button("Remove Pack…", role: .destructive) {
                            viewModel.requestRemovePack(pack)
                            dismiss()
                        }
                    }

                    if let notice = viewModel.notice {
                        Section {
                            Label(
                                notice.message.isEmpty
                                    ? notice.title
                                    : "\(notice.title): \(notice.message)",
                                systemImage: notice.kind.symbolName
                            )
                            .foregroundStyle(notice.kind.tint)
                        }
                    }
                }
                .formStyle(.grouped)

                Divider()

                HStack {
                    Spacer()
                    Button("Close") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("library.packDetails.close")
                }
                .padding(18)
                .background(.bar)
            }
            .frame(
                width: 540,
                height: hasManifestDetails(pack) ? 500 : 430
            )
        } else {
            PondEmptyState(
                "Pack removed",
                systemImage: "shippingbox",
                description: "This pack is no longer in your library."
            )
            .frame(width: 520, height: 360)
        }
    }

    private func hasManifestDetails(_ pack: EmojiPack) -> Bool {
        metadataValue(pack.manifest.author) != nil
            || metadataValue(pack.manifest.license) != nil
            || pack.manifest.sourceURL != nil
    }

    private func metadataValue(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed.isEmpty ? nil : trimmed
    }

    private func export(_ pack: EmojiPack) {
        let panel = NSSavePanel()
        panel.title = "Export \(pack.name)"
        panel.prompt = "Export"
        panel.nameFieldStringValue =
            "\(safeFilename(pack.name)).mojipondpack"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else {
            return
        }
        Task {
            _ = await viewModel.exportPack(pack.id, to: destination)
        }
    }

    private func reveal(_ pack: EmojiPack) {
        let managedURL = viewModel.revealURL(for: pack)
        if FileManager.default.fileExists(atPath: managedURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([managedURL])
        } else {
            NSWorkspace.shared.open(viewModel.paths.libraryRoot)
        }
    }

    private func chooseReplacementZIP(for pack: EmojiPack) {
        guard let url = LibraryZIPPicker.choose(
            title: "Choose replacement ZIP for \(pack.name)"
        ) else {
            return
        }
        viewModel.prepareReplacement(
            fromZIP: url,
            for: pack.id
        )
        dismiss()
    }

    private func safeFilename(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:")
            .union(.newlines)
            .union(.controlCharacters)
        let components = value.components(separatedBy: invalid)
        let safe = components.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty ? "Emoji Pack" : safe
    }

}

struct LibraryBuiltInPackDetailView: View {
    let pack: EmojiCatalogPack?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                LabeledContent("Name", value: pack?.name ?? "Built-in Emoji")
                LabeledContent("Emoji", value: (pack?.items.count ?? 0).formatted())
                LabeledContent("Revision", value: pack?.version ?? "Unknown")
                if let description = pack?.packDescription {
                    Text(description)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Attribution") {
                LabeledContent("Author", value: pack?.attribution.author ?? "GitHub, Inc.")
                LabeledContent("License", value: pack?.attribution.licenseName ?? "MIT")
                if let sourceURL = pack?.attribution.sourceURL {
                    Link("Open source repository", destination: sourceURL)
                }
                if let licenseURL = pack?.attribution.licenseURL {
                    Link("Read license", destination: licenseURL)
                }
            }

            Section("Updates") {
                Text("The built-in dataset is pinned and ships with MojiPond. It never downloads in the background.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(18)
            .background(.bar)
        }
        .frame(width: 590, height: 500)
    }
}

private extension AssetFormat {
    var displayName: String {
        switch self {
        case .png:
            "PNG"
        case .jpeg:
            "JPEG"
        case .gif:
            "GIF"
        case .webP:
            "WebP"
        }
    }
}
