import SwiftUI

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

                Group {
                    switch selectedTab {
                    case .items:
                        itemPreview(session)
                    case .conflicts:
                        conflictPreview(session)
                    case .issues:
                        issuesPreview(session)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

                Divider()
                footer(session)
            }
            .frame(
                minWidth: 720,
                idealWidth: 800,
                minHeight: 480,
                idealHeight: 540
            )
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
            .onAppear {
                if viewModel.unresolvedConflictCount > 0 {
                    selectedTab = .conflicts
                }
            }
        } else {
            ProgressView()
                .frame(width: 420, height: 260)
        }
    }

    private func header(_ session: LibraryImportSession) -> some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(PondDesign.pond)
                    .frame(width: 30, height: 30)
                    .background(PondDesign.pond.opacity(0.09), in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(reviewTitle(session))
                        .font(.title2.weight(.semibold))
                        .fontDesign(.rounded)
                        .accessibilityIdentifier("importPreview.title")
                    Text(summary(session))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Picker("Import review", selection: $selectedTab) {
                Text("Emoji (\(session.preview.items.count))")
                    .tag(PreviewTab.items)
                Text("Conflicts (\(session.preview.collisions.count))")
                    .tag(PreviewTab.conflicts)
                Text("Issues (\(issueCount(session)))")
                    .tag(PreviewTab.issues)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 390)
        }
        .padding(20)
    }

    private func itemPreview(_ session: LibraryImportSession) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Valid emoji")
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
                    Text("Choose what happens to each duplicate shortcode.")
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
                PondEmptyState(
                    "No shortcode conflicts",
                    systemImage: "checkmark.circle",
                    description:
                        "No incoming shortcodes conflict with your library."
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
                    ? "Claims this as an alias"
                    : "Owns this shortcode",
                url: displayItem?.assetURL,
                unicode: displayItem?.unicode,
                isAnimated: displayItem?.isAnimated ?? false
            )
        case let .reserved(owner):
            let displayItem = switch owner.source {
            case .builtIn:
                viewModel.allDisplayItems.first {
                    $0.id == "builtin-\(owner.itemID)"
                }
            case .customAlias:
                viewModel.allDisplayItems.first {
                    $0.id == "builtin-\(owner.itemID)"
                        || $0.id == "custom-\(owner.itemID)"
                }
            }
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
                    ? "\(owner.itemName) claims this as an alias"
                    : "\(owner.itemName) owns this shortcode",
                url: displayItem?.assetURL,
                unicode: displayItem?.unicode,
                isAnimated: displayItem?.isAnimated ?? false
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
                        subtitle: "These items use identical image data. Review them before installing."
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
                        subtitle: "Unsupported or unrelated files won't be installed."
                    ) {
                        Text("\(session.preview.ignoredFileCount.formatted()) files ignored")
                            .font(.callout)
                    }
                }

                if session.duplicateContent.isEmpty,
                   session.preview.rejections.isEmpty,
                   session.preview.ignoredFileCount == 0 {
                    PondEmptyState(
                        "No import issues",
                        systemImage: "checkmark.shield",
                        description: "Every discovered file passed validation."
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

            if session.preview.items.isEmpty {
                Label(
                    "No emoji to install",
                    systemImage: "xmark.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            } else if viewModel.unresolvedConflictCount > 0 {
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
                installAccessibilityHint(session)
            )
        }
        .padding(20)
    }

    private func summary(_ session: LibraryImportSession) -> String {
        var parts = [
            countLabel(
                session.preview.items.count,
                singular: "valid emoji",
                plural: "valid emoji"
            )
        ]
        if session.preview.totalByteCount > 0 {
            parts.append(
                ByteCountFormatter.string(
                    fromByteCount: session.preview.totalByteCount,
                    countStyle: .file
                )
            )
        }
        if !session.preview.rejections.isEmpty {
            parts.append(
                countLabel(
                    session.preview.rejections.count,
                    singular: "rejected file"
                )
            )
        }
        if session.preview.ignoredFileCount > 0 {
            parts.append(
                countLabel(
                    session.preview.ignoredFileCount,
                    singular: "ignored file"
                )
            )
        }
        return parts.joined(separator: " · ")
    }

    private func countLabel(
        _ count: Int,
        singular: String,
        plural: String? = nil
    ) -> String {
        let noun = count == 1 ? singular : plural ?? "\(singular)s"
        return "\(count.formatted()) \(noun)"
    }

    private func reviewTitle(_ session: LibraryImportSession) -> String {
        switch session.destination {
        case .newPack:
            "Review “\(session.preview.preparedPack.name)”"
        case let .replace(packID):
            "Review update for \(packName(packID))"
        }
    }

    private func packName(_ packID: UUID) -> String {
        viewModel.library.packs.first(where: { $0.id == packID })?.name
            ?? "installed pack"
    }

    private func installButtonTitle(_ session: LibraryImportSession) -> String {
        guard !session.preview.items.isEmpty else {
            return "Nothing to Install"
        }
        let count = session.preview.items.count.formatted()
        switch session.destination {
        case .newPack:
            return "Install \(count) Emoji"
        case .replace:
            return "Update with \(count) Emoji"
        }
    }

    private func installAccessibilityHint(
        _ session: LibraryImportSession
    ) -> String {
        if viewModel.canInstallImport {
            return "Copies the reviewed emoji into MojiPond"
        }
        if session.preview.items.isEmpty {
            return "The ZIP has no valid emoji"
        }
        return "Resolve all shortcode conflicts first"
    }

    private func duplicateSummary(_ group: ImportDuplicateContentGroup) -> String {
        let incoming = group.incomingItemIDs.count
        let existing = group.existingItems.count
        let incomingLabel = countLabel(
            incoming,
            singular: "incoming item"
        )
        let installedLabel = countLabel(
            existing,
            singular: "installed item"
        )
        return "\(incomingLabel) and \(installedLabel) share \(group.sha256.prefix(10))…"
    }

    private func issueCount(_ session: LibraryImportSession) -> String {
        let count = session.duplicateContent.count
            + session.preview.rejections.count
            + session.preview.ignoredFileCount
        return count.formatted()
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
                    Text(choice?.title ?? "Choose action")
                }
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
            PondDesign.raisedSurface,
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
        .background(
            PondDesign.raisedSurface,
            in: RoundedRectangle(cornerRadius: 8)
        )
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
