import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryImportSourceView: View {
    @ObservedObject var viewModel: LibraryViewModel
    let githubImportsAllowed: Bool
    let didSubmit: () -> Void

    @State private var source = ImportSource.files
    @State private var githubURL = ""
    @State private var githubRef = ""
    @State private var githubSubdirectory = ""
    @State private var githubPackName = ""
    @State private var allowGitHubNetwork = false
    @State private var allowSlackNetwork = false
    @State private var sourceError: String?
    @FocusState private var focusedField: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                PondMark(size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Import an emoji pack")
                        .font(.title2.weight(.semibold))
                    Text("Every import is reviewed before files are copied into MojiPond.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Picker("Source", selection: $source) {
                ForEach(ImportSource.allCases) { source in
                    Label(source.title, systemImage: source.icon)
                        .tag(source)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityHint("Choose where the emoji pack comes from")

            Group {
                switch source {
                case .files:
                    localSourceCard(
                        title: "Individual image files",
                        detail: "Choose PNG, JPEG, GIF, or WebP files. Filenames become shortcodes.",
                        buttonTitle: "Choose Images…",
                        action: chooseFiles
                    )
                case .folder:
                    VStack(alignment: .leading, spacing: 12) {
                        localSourceCard(
                            title: "Folder",
                            detail: "Scans supported images, portable MojiPond manifests, and Slack emoji.json automatically.",
                            buttonTitle: "Choose Folder…",
                            action: chooseFolder
                        )
                        Toggle("Allow remote URLs if this folder contains a Slack manifest", isOn: $allowSlackNetwork)
                            .font(.callout)
                        networkExplanation
                    }
                case .zip:
                    localSourceCard(
                        title: "ZIP archive",
                        detail: "The archive is safety-checked, extracted into a temporary workspace, and previewed.",
                        buttonTitle: "Choose ZIP…",
                        action: chooseZIP
                    )
                case .slack:
                    VStack(alignment: .leading, spacing: 12) {
                        localSourceCard(
                            title: "Slack emoji.json",
                            detail: "Local image paths work offline. Remote Slack asset URLs require explicit network access.",
                            buttonTitle: "Choose emoji.json…",
                            action: chooseSlackManifest
                        )
                        Toggle("Allow this import to download remote Slack emoji", isOn: $allowSlackNetwork)
                            .font(.callout)
                        networkExplanation
                    }
                case .github:
                    githubForm
                }
            }
            .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)

            HStack {
                Text("Files stay local unless you explicitly enable a network import.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: didSubmit)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 680)
        .onChange(of: source) {
            if source == .github {
                focusedField = .githubURL
            }
        }
        .onChange(of: githubImportsAllowed) {
            if !githubImportsAllowed {
                allowGitHubNetwork = false
            }
        }
    }

    private var githubForm: some View {
        PondCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("Public GitHub repository", systemImage: "network")
                    .font(.headline)

                if !githubImportsAllowed {
                    Label(
                        "Public GitHub imports are off. Enable them in MojiPond Settings → General before reviewing this source.",
                        systemImage: "network.slash"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        "Public GitHub imports are disabled in Settings"
                    )
                }

                TextField("https://github.com/owner/repository", text: $githubURL)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .githubURL)
                    .accessibilityLabel("GitHub repository URL")
                if let sourceError {
                    Label(sourceError, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(PondDesign.errorForeground)
                }

                HStack {
                    TextField("Branch, tag, or commit (optional)", text: $githubRef)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Git reference")
                    TextField("Subfolder (optional)", text: $githubSubdirectory)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Repository subfolder")
                }

                TextField("Pack name override (optional)", text: $githubPackName)
                    .textFieldStyle(.roundedBorder)

                Toggle("Allow this import to contact GitHub", isOn: $allowGitHubNetwork)
                    .disabled(!githubImportsAllowed)

                HStack {
                    networkExplanation
                    Spacer()
                    Button("Review GitHub Import") {
                        guard let url = URL(string: githubURL) else {
                            sourceError = "Enter a full public github.com repository URL."
                            return
                        }
                        sourceError = nil
                        viewModel.prepareImport(
                            .github(
                                url,
                                ref: nilIfBlank(githubRef),
                                subdirectory: nilIfBlank(githubSubdirectory),
                                packName: nilIfBlank(githubPackName)
                            ),
                            networkAccessGranted: allowGitHubNetwork
                        )
                        if allowGitHubNetwork {
                            didSubmit()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        !githubImportsAllowed
                            || githubURL.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                    )
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var networkExplanation: some View {
        Label(
            "Only the selected source is contacted for this import.",
            systemImage: "lock.shield"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func localSourceCard(
        title: String,
        detail: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        PondCard {
            HStack(spacing: 16) {
                Image(systemName: source.icon)
                    .font(.system(size: 30))
                    .foregroundStyle(PondDesign.pond)
                    .frame(width: 40)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(buttonTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "Choose emoji images"
        panel.prompt = "Review"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = supportedImageTypes
        guard panel.runModal() == .OK, !panel.urls.isEmpty else {
            return
        }
        let name = panel.urls.count == 1
            ? panel.urls[0].deletingPathExtension().lastPathComponent
            : "Imported Emoji"
        viewModel.prepareImport(.files(panel.urls, packName: name))
        didSubmit()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose an emoji folder"
        panel.prompt = "Review"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        viewModel.prepareImport(
            .folder(
                url,
                allowRemoteSlackAssets: allowSlackNetwork
            ),
            networkAccessGranted: allowSlackNetwork
        )
        didSubmit()
    }

    private func chooseZIP() {
        let panel = NSOpenPanel()
        panel.title = "Choose an emoji ZIP archive"
        panel.prompt = "Review"
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        viewModel.prepareImport(.zipArchive(url))
        didSubmit()
    }

    private func chooseSlackManifest() {
        let panel = NSOpenPanel()
        panel.title = "Choose Slack emoji.json"
        panel.prompt = "Review"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        viewModel.prepareImport(
            .slackManifest(
                url,
                allowRemoteAssets: allowSlackNetwork
            ),
            networkAccessGranted: allowSlackNetwork
        )
        didSubmit()
    }

    private var supportedImageTypes: [UTType] {
        [.png, .jpeg, .gif] + [UTType(filenameExtension: "webp")].compactMap { $0 }
    }

    private func nilIfBlank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private enum Field {
        case githubURL
    }

    private enum ImportSource: String, CaseIterable, Identifiable {
        case files
        case folder
        case zip
        case slack
        case github

        var id: Self { self }

        var title: String {
            switch self {
            case .files:
                "Files"
            case .folder:
                "Folder"
            case .zip:
                "ZIP"
            case .slack:
                "Slack"
            case .github:
                "GitHub"
            }
        }

        var icon: String {
            switch self {
            case .files:
                "photo.on.rectangle.angled"
            case .folder:
                "folder"
            case .zip:
                "doc.zipper"
            case .slack:
                "number.square"
            case .github:
                "network"
            }
        }
    }
}

struct LibraryImportPreviewView: View {
    @ObservedObject var viewModel: LibraryViewModel

    @State private var selectedTab = PreviewTab.items
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let session = viewModel.importSession {
            VStack(spacing: 0) {
                header(session)
                Divider()

                if let notice = viewModel.notice,
                   notice.kind == .error {
                    LibraryNoticeBanner(notice: notice) {
                        viewModel.dismissNotice()
                    }
                }

                TabView(selection: $selectedTab) {
                    itemPreview(session)
                        .tabItem {
                            Label("Emoji", systemImage: "square.grid.3x3")
                        }
                        .tag(PreviewTab.items)

                    conflictPreview(session)
                        .tabItem {
                            Label(
                                "Conflicts (\(session.preview.collisions.count))",
                                systemImage: "arrow.triangle.branch"
                            )
                        }
                        .tag(PreviewTab.conflicts)

                    issuesPreview(session)
                        .tabItem {
                            Label(
                                "Issues (\(session.preview.rejections.count))",
                                systemImage: "exclamationmark.triangle"
                            )
                        }
                        .tag(PreviewTab.issues)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                Divider()
                footer(session)
            }
            .frame(minWidth: 780, idealWidth: 900, minHeight: 600, idealHeight: 700)
            .overlay {
                if viewModel.isInstallingImport {
                    ZStack {
                        Color.black.opacity(0.12)
                        ProgressView("Installing reviewed files…")
                            .padding(22)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            .interactiveDismissDisabled(viewModel.isInstallingImport)
        } else {
            ProgressView()
                .frame(width: 420, height: 260)
        }
    }

    private func header(_ session: LibraryImportSession) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(PondDesign.pond.opacity(0.12))
                Image(systemName: "square.and.arrow.down")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(PondDesign.pond)
            }
            .frame(width: 46, height: 46)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(reviewTitle(session))
                    .font(.title2.weight(.semibold))
                Text(summary(session))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !session.preview.collisions.isEmpty {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(viewModel.unresolvedConflictCount)")
                        .font(.title3.monospacedDigit().weight(.semibold))
                    Text("decisions left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(20)
    }

    private func itemPreview(_ session: LibraryImportSession) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Accepted emoji")
                    .font(.headline)
                Spacer()
                Text("Source name → shortcode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)

            List(session.preview.items) { item in
                HStack(spacing: 12) {
                    LibraryImportThumbnail(
                        url: session.sourceURL(for: item.id),
                        unicode: item.unicode,
                        isAnimated: item.frameCount > 1
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(":\(item.shortcode.rawValue):")
                            .font(.body.monospaced().weight(.medium))
                        if !item.aliases.isEmpty {
                            Text(
                                "Aliases: "
                                    + item.aliases.map {
                                        ":\($0.rawValue):"
                                    }.joined(separator: ", ")
                            )
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                        Text(item.sourceFilename)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        if let format = item.format {
                            Text(format.displayName)
                                .font(.caption.weight(.medium))
                            Text(
                                "\(item.pixelWidth)×\(item.pixelHeight) · \(ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file))"
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        } else {
                            Text("Unicode")
                                .font(.caption.weight(.medium))
                            Text("Text emoji")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 3)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    itemAccessibilityLabel(item)
                )
            }
            .listStyle(.inset)
        }
    }

    private func conflictPreview(_ session: LibraryImportSession) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shortcode conflicts")
                        .font(.headline)
                    Text("Nothing is replaced unless you choose it explicitly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu("Apply to all…") {
                    Button("Keep all existing emoji") {
                        viewModel.applyChoiceToAll(.keepExisting)
                    }
                    Button("Replace all existing emoji") {
                        viewModel.applyChoiceToAll(.replaceExisting)
                    }
                    Button("Drop all conflicting aliases") {
                        viewModel.applyChoiceToAll(.dropIncomingAlias)
                    }
                }
                .disabled(session.preview.collisions.isEmpty)
            }
            .padding(.vertical, 8)

            if session.preview.collisions.isEmpty {
                ContentUnavailableView(
                    "No shortcode conflicts",
                    systemImage: "checkmark.circle",
                    description: Text("Every incoming shortcode is currently available.")
                )
            } else {
                List(session.preview.collisions) { collision in
                    LibraryCollisionRow(
                        collision: collision,
                        incoming: conflictIncoming(
                            collision,
                            session: session
                        ),
                        existing: conflictExisting(
                            collision,
                            session: session
                        ),
                        choice: viewModel.conflictChoices[collision.id],
                        renameValue: viewModel.conflictRenameValues[collision.id, default: ""],
                        setChoice: {
                            viewModel.setConflictChoice($0, for: collision.id)
                        },
                        setRename: {
                            viewModel.setConflictRename($0, for: collision.id)
                        }
                    )
                    .padding(.vertical, 5)
                }
                .listStyle(.inset)
            }
        }
    }

    private func itemAccessibilityLabel(
        _ item: ImportPreviewItem
    ) -> String {
        let aliases = item.aliases.isEmpty
            ? "no aliases"
            : "aliases "
                + item.aliases.map(\.rawValue).joined(separator: ", ")
        return "\(item.sourceFilename), normalized to colon "
            + "\(item.shortcode.rawValue) colon, \(aliases), "
            + "\(item.format?.displayName ?? "Unicode")"
    }

    private func conflictIncoming(
        _ collision: ImportCollision,
        session: LibraryImportSession
    ) -> LibraryConflictItemPresentation {
        guard
            let item = session.preview.items.first(where: {
                $0.id == collision.incomingCandidateID
            })
        else {
            return .unavailable(
                heading: "Incoming",
                detail: "Incoming item is unavailable"
            )
        }
        return LibraryConflictItemPresentation(
            heading: "Incoming",
            shortcode: item.shortcode.rawValue,
            aliases: item.aliases.map(\.rawValue),
            detail: item.sourceFilename,
            url: session.sourceURL(for: item.id),
            unicode: item.unicode,
            isAnimated: item.frameCount > 1
        )
    }

    private func conflictExisting(
        _ collision: ImportCollision,
        session: LibraryImportSession
    ) -> LibraryConflictItemPresentation {
        switch collision.existing {
        case let .library(owner):
            let displayItem = viewModel.allDisplayItems.first {
                $0.id == "custom-\(owner.itemID.uuidString)"
            }
            return LibraryConflictItemPresentation(
                heading: "Existing · \(owner.packName)",
                shortcode: displayItem?.shortcode
                    ?? collision.shortcode.rawValue,
                aliases: displayItem?.aliases ?? [],
                detail: owner.isAlias
                    ? "Currently claims this as an alias"
                    : "Currently owns this shortcode",
                url: displayItem?.assetURL,
                unicode: displayItem?.unicode,
                isAnimated: displayItem?.isAnimated ?? false
            )
        case let .reserved(owner):
            let heading = switch owner.source {
            case .builtIn:
                "Protected · \(owner.packName)"
            case .customAlias:
                "Protected · Your alias"
            }
            return LibraryConflictItemPresentation(
                heading: heading,
                shortcode: owner.shortcode.rawValue,
                aliases: owner.isAlias ? [owner.shortcode.rawValue] : [],
                detail: owner.isAlias
                    ? "\(owner.itemName) currently claims this as an alias"
                    : "\(owner.itemName) currently owns this shortcode",
                url: nil,
                unicode: nil,
                isAnimated: false
            )
        case let .incoming(candidateID, claim):
            guard
                let item = session.preview.items.first(where: {
                    $0.id == candidateID
                })
            else {
                return .unavailable(
                    heading: "Earlier incoming item",
                    detail: "Earlier item is unavailable"
                )
            }
            let claimDescription = switch claim {
            case .primary:
                "Also claims this as its primary shortcode"
            case .alias:
                "Also claims this as an alias"
            }
            return LibraryConflictItemPresentation(
                heading: "Earlier incoming item",
                shortcode: item.shortcode.rawValue,
                aliases: item.aliases.map(\.rawValue),
                detail: claimDescription,
                url: session.sourceURL(for: item.id),
                unicode: item.unicode,
                isAnimated: item.frameCount > 1
            )
        }
    }

    private func issuesPreview(_ session: LibraryImportSession) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !session.duplicateContent.isEmpty {
                    previewSection(
                        title: "Duplicate content",
                        subtitle: "These files share the same SHA-256 content. They are shown for review but are not silently removed."
                    ) {
                        ForEach(Array(session.duplicateContent.enumerated()), id: \.offset) { _, group in
                            Label(
                                duplicateSummary(group),
                                systemImage: "doc.on.doc"
                            )
                            .font(.callout)
                        }
                    }
                }

                if !session.preview.rejections.isEmpty {
                    previewSection(
                        title: "Rejected files",
                        subtitle: "These files will not be installed."
                    ) {
                        ForEach(session.preview.rejections) { rejection in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "xmark.circle")
                                    .foregroundStyle(
                                        PondDesign.errorForeground
                                    )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rejection.source)
                                        .font(.callout.weight(.medium))
                                    Text(rejection.reason)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if session.preview.ignoredFileCount > 0 {
                    previewSection(
                        title: "Ignored files",
                        subtitle: "Unsupported or unrelated files are left untouched."
                    ) {
                        Text("\(session.preview.ignoredFileCount.formatted()) files ignored")
                            .font(.callout)
                    }
                }

                if session.duplicateContent.isEmpty,
                   session.preview.rejections.isEmpty,
                   session.preview.ignoredFileCount == 0 {
                    ContentUnavailableView(
                        "No import issues",
                        systemImage: "checkmark.shield",
                        description: Text("Every discovered file passed validation.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 320)
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func footer(_ session: LibraryImportSession) -> some View {
        HStack {
            Button("Discard") {
                Task {
                    await viewModel.discardImport()
                    dismiss()
                }
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            if viewModel.unresolvedConflictCount > 0 {
                Label(
                    "\(viewModel.unresolvedConflictCount) unresolved",
                    systemImage: "exclamationmark.circle"
                )
                .font(.callout)
                .foregroundStyle(PondDesign.warningForeground)
            } else {
                Label("Ready to install", systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(PondDesign.lily)
            }

            Button(installButtonTitle(session)) {
                Task {
                    await viewModel.installPreparedImport()
                    if viewModel.importSession == nil {
                        dismiss()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canInstallImport)
            .keyboardShortcut(.defaultAction)
            .accessibilityHint(
                viewModel.canInstallImport
                    ? "Copies the reviewed emoji into MojiPond"
                    : "Resolve all shortcode conflicts first"
            )
        }
        .padding(20)
    }

    private func summary(_ session: LibraryImportSession) -> String {
        let bytes = ByteCountFormatter.string(
            fromByteCount: session.preview.totalByteCount,
            countStyle: .file
        )
        return "\(session.preview.items.count.formatted()) accepted · \(bytes) · \(session.preview.rejections.count.formatted()) rejected · \(session.preview.ignoredFileCount.formatted()) ignored"
    }

    private func reviewTitle(_ session: LibraryImportSession) -> String {
        switch session.destination {
        case .newPack:
            "Review “\(session.preview.preparedPack.name)”"
        case let .append(packID):
            "Review emoji to add to \(packName(packID))"
        case let .replace(packID):
            "Review update for \(packName(packID))"
        }
    }

    private func packName(_ packID: UUID) -> String {
        viewModel.library.packs.first(where: { $0.id == packID })?.name
            ?? "installed pack"
    }

    private func installButtonTitle(_ session: LibraryImportSession) -> String {
        let count = session.preview.items.count.formatted()
        switch session.destination {
        case .newPack:
            return "Install \(count) Emoji"
        case .append:
            return "Add \(count) Emoji"
        case .replace:
            return "Update with \(count) Emoji"
        }
    }

    private func duplicateSummary(_ group: ImportDuplicateContentGroup) -> String {
        let incoming = group.incomingItemIDs.count
        let existing = group.existingItems.count
        return "\(incoming) incoming and \(existing) installed item(s) share \(group.sha256.prefix(10))…"
    }

    private func previewSection<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        PondCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private enum PreviewTab {
        case items
        case conflicts
        case issues
    }
}

private struct LibraryCollisionRow: View {
    let collision: ImportCollision
    let incoming: LibraryConflictItemPresentation
    let existing: LibraryConflictItemPresentation
    let choice: LibraryConflictChoice?
    let renameValue: String
    let setChoice: (LibraryConflictChoice) -> Void
    let setRename: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(":\(collision.shortcode.rawValue):")
                        .font(.body.monospaced().weight(.semibold))
                    Text(conflictDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    ForEach(availableChoices) { option in
                        Button(option.title) {
                            setChoice(option)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(choice?.title ?? "Choose action")
                        Image(systemName: "chevron.down")
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Resolution for \(collision.shortcode.rawValue)")
            }

            HStack(alignment: .top, spacing: 10) {
                conflictIdentity(incoming)
                Image(systemName: "arrow.left.arrow.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity)
                    .accessibilityHidden(true)
                conflictIdentity(existing)
            }

            if choice == .renameIncoming {
                HStack {
                    Text(":")
                        .foregroundStyle(.secondary)
                    TextField(
                        "new_shortcode",
                        text: Binding(
                            get: { renameValue },
                            set: { setRename($0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    Text(":")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("New shortcode")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func conflictIdentity(
        _ item: LibraryConflictItemPresentation
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            LibraryImportThumbnail(
                url: item.url,
                unicode: item.unicode,
                isAnimated: item.isAnimated
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(item.heading)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(":\(item.shortcode):")
                    .font(.callout.monospaced().weight(.medium))
                if !item.aliases.isEmpty {
                    Text(
                        "Aliases: "
                            + item.aliases.map {
                                ":\($0):"
                            }.joined(separator: ", ")
                    )
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Text(item.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .background.secondary,
            in: RoundedRectangle(cornerRadius: 9)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.accessibilityLabel)
    }

    private var availableChoices: [LibraryConflictChoice] {
        var values: [LibraryConflictChoice] = [
            .keepExisting,
            .renameIncoming
        ]
        if case .reserved = collision.existing {
            // Built-in names and user aliases are protected from pack imports.
        } else {
            values.insert(.replaceExisting, at: 1)
        }
        if case .alias = collision.incomingClaim {
            values.append(.dropIncomingAlias)
        }
        return values
    }

    private var conflictDescription: String {
        let claim = switch collision.incomingClaim {
        case .primary:
            "incoming primary shortcode"
        case .alias:
            "incoming alias"
        }
        let existing = switch collision.existing {
        case let .library(owner):
            "already belongs to \(owner.packName)"
        case let .reserved(owner):
            switch owner.source {
            case .builtIn:
                "is protected by \(owner.packName)"
            case .customAlias:
                "is already one of your aliases"
            }
        case .incoming:
            "is also claimed by another incoming emoji"
        }
        return "This \(claim) \(existing)."
    }
}

private struct LibraryConflictItemPresentation {
    let heading: String
    let shortcode: String
    let aliases: [String]
    let detail: String
    let url: URL?
    let unicode: String?
    let isAnimated: Bool

    var accessibilityLabel: String {
        let aliasDescription = aliases.isEmpty
            ? "no aliases"
            : "aliases " + aliases.joined(separator: ", ")
        return "\(heading), colon \(shortcode) colon, "
            + "\(aliasDescription), \(detail)"
    }

    static func unavailable(
        heading: String,
        detail: String
    ) -> Self {
        Self(
            heading: heading,
            shortcode: "unavailable",
            aliases: [],
            detail: detail,
            url: nil,
            unicode: nil,
            isAnimated: false
        )
    }
}

private struct LibraryImportThumbnail: View {
    let url: URL?
    let unicode: String?
    let isAnimated: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let unicode {
                Text(unicode)
                    .font(.system(size: 28))
            } else if let url {
                LibraryAssetArtwork(url: url)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
            }
            if isAnimated {
                Image(systemName: "play.fill")
                    .font(.caption2)
                    .padding(3)
                    .background(.regularMaterial, in: Circle())
            }
        }
        .frame(width: 42, height: 42)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
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
