import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryNewPackView: View {
    @ObservedObject var viewModel: LibraryViewModel

    @State private var draft = LibraryPackDraft()
    @FocusState private var nameFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Create an empty pack")
                    .font(.title2.weight(.semibold))
                Text("Set its identity and attribution now, then add files through the same review flow.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Form {
                TextField("Name", text: $draft.name)
                    .focused($nameFocused)
                TextField("Author", text: $draft.author)
                TextField("Version", text: $draft.version)
                TextField("License", text: $draft.license)
                TextField("HTTPS source URL", text: $draft.sourceURL)
                TextField("Description", text: $draft.description, axis: .vertical)
                    .lineLimit(2...5)
            }
            .formStyle(.grouped)

            if let notice = viewModel.notice,
               notice.kind == .error {
                Label(
                    "\(notice.title): \(notice.message)",
                    systemImage: "exclamationmark.circle"
                )
                .font(.caption)
                .foregroundStyle(PondDesign.errorForeground)
            }

            HStack {
                Label(
                    "After creation, open Pack Details and choose Add Files.",
                    systemImage: "checkmark.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Create Pack") {
                    Task {
                        let created = await viewModel.createPack(draft)
                        if created {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 590)
        .onAppear {
            nameFocused = true
        }
    }
}

struct LibraryAddUnicodeItemView: View {
    @ObservedObject var viewModel: LibraryViewModel
    let packID: UUID
    let packName: String

    @State private var draft: LibraryUnicodeItemDraft
    @State private var isSaving = false
    @FocusState private var emojiFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(
        viewModel: LibraryViewModel,
        packID: UUID,
        packName: String
    ) {
        self.viewModel = viewModel
        self.packID = packID
        self.packName = packName
        _draft = State(
            initialValue: LibraryUnicodeItemDraft(packID: packID)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(PondDesign.pond.opacity(0.1))
                    Text(draft.unicode.isEmpty ? "＋" : draft.unicode)
                        .font(.system(size: 42))
                        .foregroundStyle(
                            draft.unicode.isEmpty
                                ? Color.secondary
                                : Color.primary
                        )
                        .lineLimit(1)
                }
                .frame(width: 76, height: 76)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Add Unicode emoji")
                        .font(.title2.weight(.semibold))
                    Text("Create a local shortcode in \(packName).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Form {
                Section("Emoji") {
                    TextField(
                        "One Unicode emoji",
                        text: $draft.unicode
                    )
                    .focused($emojiFocused)
                    .font(.title2)
                    .accessibilityIdentifier(
                        "library.addUnicode.emoji"
                    )
                    Text(
                        "Enter one emoji grapheme, including a flag, keycap, skin tone, or joined sequence."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section("Autocomplete") {
                    TextField(
                        "Shortcode",
                        text: $draft.shortcode
                    )
                    .font(.body.monospaced())
                    .accessibilityHint("Colons are optional")
                    TextField(
                        "Aliases, separated by commas",
                        text: $draft.aliases
                    )
                    .font(.body.monospaced())
                }

                Section("Discovery") {
                    TextField(
                        "Display name",
                        text: $draft.displayName
                    )
                    TextField(
                        "Tags, separated by commas",
                        text: $draft.tags
                    )
                    TextField(
                        "Category",
                        text: $draft.category
                    )
                }
            }
            .formStyle(.grouped)

            if let notice = viewModel.notice,
               notice.kind == .error {
                Label(
                    "\(notice.title): \(notice.message)",
                    systemImage: "exclamationmark.circle"
                )
                .font(.caption)
                .foregroundStyle(PondDesign.errorForeground)
            }

            HStack {
                Label(
                    "Stored locally and included in portable schema-v2 exports.",
                    systemImage: "externaldrive.badge.checkmark"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Add Emoji") {
                    isSaving = true
                    Task {
                        let created = await viewModel.createUnicodeItem(
                            draft
                        )
                        isSaving = false
                        if created {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    isSaving
                        || draft.unicode.isEmpty
                        || draft.shortcode
                            .trimmingCharacters(
                                in: .whitespacesAndNewlines
                            )
                            .isEmpty
                )
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620)
        .onAppear {
            emojiFocused = true
        }
        .overlay {
            if isSaving {
                ProgressView()
                    .padding(18)
                    .background(
                        .regularMaterial,
                        in: RoundedRectangle(cornerRadius: 12)
                    )
            }
        }
    }
}

struct LibraryItemDetailView: View {
    @ObservedObject var viewModel: LibraryViewModel
    let item: LibraryDisplayItem

    @State private var draft: LibraryItemDraft?
    @State private var customAliasesDraft: String
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    init(viewModel: LibraryViewModel, item: LibraryDisplayItem) {
        self.viewModel = viewModel
        self.item = item
        if case let .custom(packID) = item.origin,
           let libraryItem = viewModel.item(
               packID: packID,
               itemID: Self.itemID(from: item.id)
           ) {
            _draft = State(initialValue: LibraryItemDraft(packID: packID, item: libraryItem))
        } else {
            _draft = State(initialValue: nil)
        }
        _customAliasesDraft = State(
            initialValue: viewModel.customAliases(for: item)
                .joined(separator: ", ")
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                LibraryEmojiArtwork(item: item, size: 88)
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
            .padding(24)

            Divider()

            if let draft {
                customEditor(draft)
            } else {
                builtInDetails
            }
        }
        .frame(width: 610, height: 570)
        .overlay {
            if isSaving {
                ProgressView()
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func customEditor(_ draft: LibraryItemDraft) -> some View {
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
                .keyboardShortcut("c", modifiers: .command)
                Spacer()
                Button("Cancel") {
                    dismiss()
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
                TextField(
                    "Aliases, separated by commas",
                    text: $customAliasesDraft
                )
                .font(.body.monospaced())
                .accessibilityHint(
                    "Adds local aliases without changing the bundled dataset."
                )
                Button("Save Aliases") {
                    isSaving = true
                    Task {
                        await viewModel.setCustomAliases(
                            customAliasesDraft,
                            for: item
                        )
                        isSaving = false
                    }
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
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Copy Emoji") {
                    Task {
                        await viewModel.copyToClipboard(item)
                    }
                }
                .keyboardShortcut("c", modifiers: .command)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(18)
            .background(.bar)
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
    let githubImportsAllowed: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var showsGitHubUpdateConfirmation = false
    @State private var showsGitHubCheckConfirmation = false
    @State private var allowRemoteSlackAssets = false

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
                }
                .padding(24)

                Divider()

                Form {
                    Section("Pack") {
                        LabeledContent("Emoji", value: pack.items.count.formatted())
                        LabeledContent("Version", value: pack.manifest.version)
                        LabeledContent("Pack ID", value: pack.manifest.packID.rawValue)
                        if let description = pack.manifest.description {
                            LabeledContent("Description", value: description)
                        }
                    }

                    Section("Attribution") {
                        LabeledContent("Author", value: pack.manifest.author ?? "Not provided")
                        LabeledContent("License", value: pack.manifest.license ?? "Not provided")
                        if let sourceURL = pack.manifest.sourceURL {
                            Link("Open source page", destination: sourceURL)
                        }
                    }

                    Section("Source") {
                        LabeledContent("Imported from", value: viewModel.sourceSummary(for: pack))
                        LabeledContent(
                            "Installed",
                            value: pack.updateMetadata.installedAt.formatted(
                                date: .abbreviated,
                                time: .shortened
                            )
                        )
                        LabeledContent(
                            "Last changed",
                            value: pack.updateMetadata.lastUpdatedAt.formatted(
                                date: .abbreviated,
                                time: .shortened
                            )
                        )
                        if let revision = pack.updateMetadata.sourceRevision {
                            LabeledContent("Revision", value: revision)
                        }
                    }

                    Section("Actions") {
                        Button("Export Portable Pack…") {
                            export(pack)
                        }
                        Button("Reveal Managed Files in Finder") {
                            reveal(pack)
                        }
                        Button("Add Files…") {
                            addFiles(to: pack)
                        }
                        .help("Review and append individual image files to this pack.")

                        if pack.source.kind == .github {
                            githubRevisionStatus(for: pack)

                            Button("Check GitHub Revision…") {
                                showsGitHubCheckConfirmation = true
                            }
                            .disabled(
                                !githubImportsAllowed
                                    || viewModel.githubRevisionState(
                                        for: pack.id
                                    ) == .checking
                            )
                            .help(
                                githubImportsAllowed
                                    ? "Contact only GitHub’s commit API and compare source revisions."
                                    : "Enable public GitHub imports in Settings → General first."
                            )

                            if case .updateAvailable =
                                viewModel.githubRevisionState(for: pack.id) {
                                Button("Review Available Update…") {
                                    showsGitHubUpdateConfirmation = true
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        } else {
                            Button("Replace Contents from Local Source…") {
                                chooseReplacementSource(for: pack)
                            }
                            .help("Review a new folder, archive, Slack manifest, or set of files before replacing this pack.")
                        }

                        if pack.source.kind == .github,
                           !githubImportsAllowed {
                            Label(
                                "GitHub imports are disabled in Settings.",
                                systemImage: "network.slash"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        if pack.source.kind == .slackManifest
                            || pack.source.kind == .folder {
                            Toggle(
                                "Allow remote Slack assets during re-import",
                                isOn: $allowRemoteSlackAssets
                            )
                            Text("Network access applies only to the next reviewed import.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .formStyle(.grouped)

                Divider()

                HStack {
                    Button("Remove Pack…", role: .destructive) {
                        viewModel.requestRemovePack(pack)
                        dismiss()
                    }
                    Spacer()
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
                    Button("Done") {
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding(18)
            }
            .frame(width: 660, height: 680)
            .confirmationDialog(
                "Contact GitHub to compare revisions?",
                isPresented: $showsGitHubCheckConfirmation,
                titleVisibility: .visible
            ) {
                Button("Allow This Revision Check") {
                    Task {
                        await viewModel.checkGitHubRevision(
                            for: pack.id,
                            networkAccessGranted: true
                        )
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "MojiPond will send the configured public repository and ref to GitHub’s commit API. It will not download pack files during this check."
                )
            }
            .confirmationDialog(
                "Contact GitHub for this update?",
                isPresented: $showsGitHubUpdateConfirmation,
                titleVisibility: .visible
            ) {
                Button("Allow GitHub and Review Update") {
                    viewModel.prepareGitHubUpdate(
                        for: pack.id,
                        networkAccessGranted: true
                    )
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("MojiPond will contact only github.com and GitHub’s archive host, download this pack’s configured ref, then show every change before installing.")
            }
        } else {
            ContentUnavailableView(
                "Pack removed",
                systemImage: "shippingbox",
                description: Text("This pack is no longer in your library.")
            )
            .frame(width: 520, height: 360)
        }
    }

    @ViewBuilder
    private func githubRevisionStatus(for pack: EmojiPack) -> some View {
        switch viewModel.githubRevisionState(for: pack.id) {
        case .none:
            if let checkedAt = pack.updateMetadata.lastCheckedAt {
                LabeledContent(
                    "Last revision check",
                    value: checkedAt.formatted(
                        date: .abbreviated,
                        time: .shortened
                    )
                )
            }
        case .checking:
            Label("Checking GitHub revision…", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        case let .current(revision):
            Label(
                "Up to date at \(shortRevision(revision))",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(PondDesign.lily)
        case let .updateAvailable(installed, latest):
            Label(
                "Update available: \(shortRevision(installed)) → \(shortRevision(latest))",
                systemImage: "arrow.down.circle.fill"
            )
            .foregroundStyle(PondDesign.pond)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(PondDesign.warningForeground)
        }
    }

    private func shortRevision(_ revision: String?) -> String {
        revision.map { String($0.prefix(10)) } ?? "unknown"
    }

    private func export(_ pack: EmojiPack) {
        let panel = NSSavePanel()
        panel.title = "Export \(pack.name)"
        panel.prompt = "Export"
        panel.nameFieldStringValue = "\(safeFilename(pack.name)).mojipondpack"
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

    private func addFiles(to pack: EmojiPack) {
        let panel = NSOpenPanel()
        panel.title = "Add emoji to \(pack.name)"
        panel.prompt = "Review"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = supportedImportTypes
        guard panel.runModal() == .OK, !panel.urls.isEmpty else {
            return
        }
        viewModel.prepareAddFiles(panel.urls, to: pack.id)
        dismiss()
    }

    private func chooseReplacementSource(for pack: EmojiPack) {
        let panel = NSOpenPanel()
        panel.title = "Choose replacement source for \(pack.name)"
        panel.prompt = "Review"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = supportedImportTypes + [.zip, .json]
        guard panel.runModal() == .OK, !panel.urls.isEmpty else {
            return
        }
        viewModel.prepareReplacement(
            from: panel.urls,
            for: pack.id,
            allowRemoteSlackAssets: allowRemoteSlackAssets
        )
        dismiss()
    }

    private var supportedImportTypes: [UTType] {
        [.png, .jpeg, .gif] + [UTType(filenameExtension: "webp")].compactMap { $0 }
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
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
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
