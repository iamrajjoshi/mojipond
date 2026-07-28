import Foundation
import XCTest
@testable import MojiPond

@MainActor
final class LibraryViewModelTests: XCTestCase {
    func testLoadsSearchesAndFiltersBuiltInAndCustomEmoji() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let frog = try TestSupport.writeImage(
            to: fixture.workspace.appendingPathComponent("frog.png")
        )
        _ = try await install(
            files: [frog],
            name: "Frog Pack",
            into: fixture.store
        )
        let viewModel = makeViewModel(fixture)

        await viewModel.reload()

        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertEqual(viewModel.allDisplayItems.count, 2)
        viewModel.searchText = ":frog:"
        XCTAssertEqual(viewModel.visibleItems.map(\.shortcode), ["frog"])

        viewModel.searchText = ""
        viewModel.contentFilter = .unicode
        XCTAssertEqual(viewModel.visibleItems.map(\.shortcode), ["wave"])

        viewModel.contentFilter = .images
        XCTAssertEqual(viewModel.visibleItems.map(\.shortcode), ["frog"])
    }

    func testCopiesBuiltInUnicodeWithoutTypingPermissions() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let pasteboard = FakePasteboard(items: [.text("existing")])
        let viewModel = makeViewModel(
            fixture,
            pasteboard: pasteboard
        )
        await viewModel.reload()

        let wave = try XCTUnwrap(
            viewModel.allDisplayItems.first(where: {
                $0.shortcode == "wave"
            })
        )
        viewModel.copyToClipboard(wave)

        XCTAssertEqual(
            pasteboard.items.first?.representations.first?.data,
            Data("👋".utf8)
        )
        XCTAssertEqual(viewModel.notice?.kind, .information)
    }

    func testCopiesOriginalManagedImageBytes() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let source = try TestSupport.writeImage(
            to: fixture.workspace.appendingPathComponent("frog.png")
        )
        let original = try Data(contentsOf: source)
        _ = try await install(
            files: [source],
            name: "Frog Pack",
            into: fixture.store
        )
        let pasteboard = FakePasteboard()
        let viewModel = makeViewModel(
            fixture,
            pasteboard: pasteboard
        )
        await viewModel.reload()

        let frog = try XCTUnwrap(
            viewModel.allDisplayItems.first(where: {
                $0.shortcode == "frog"
            })
        )
        viewModel.copyToClipboard(frog)

        XCTAssertEqual(
            pasteboard.items.first?.representations.first?.data,
            original
        )
        XCTAssertEqual(
            pasteboard.items.first?.representations.first?.typeIdentifier,
            "public.png"
        )
        XCTAssertEqual(viewModel.notice?.kind, .information)
    }

    func testNetworkImportRequiresExplicitPerImportConsent() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let viewModel = makeViewModel(fixture)
        await viewModel.reload()

        viewModel.prepareImport(
            .github(URL(string: "https://github.com/example/emoji")!)
        )

        XCTAssertFalse(viewModel.isPreparingImport)
        XCTAssertEqual(viewModel.notice?.kind, .warning)
        XCTAssertEqual(viewModel.notice?.title, "Network access not granted")
        XCTAssertNil(viewModel.importSession)
    }

    func testConflictRenameInstallsAndCallsMutationCallback() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let originalFolder = fixture.workspace.appendingPathComponent(
            "Original",
            isDirectory: true
        )
        let incomingFolder = fixture.workspace.appendingPathComponent(
            "Incoming",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: originalFolder,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: incomingFolder,
            withIntermediateDirectories: false
        )
        let original = try TestSupport.writeImage(
            to: originalFolder.appendingPathComponent("frog.png")
        )
        let incoming = try TestSupport.writeImage(
            to: incomingFolder.appendingPathComponent("frog.png"),
            width: 3,
            height: 3
        )
        _ = try await install(
            files: [original],
            name: "Original",
            into: fixture.store
        )
        var callbackCount = 0
        let viewModel = makeViewModel(fixture) { _ in
            callbackCount += 1
        }
        await viewModel.reload()

        viewModel.prepareImport(.files([incoming], packName: "Incoming"))
        await waitForImportPreparation(viewModel)
        let session = try XCTUnwrap(viewModel.importSession)
        let collision = try XCTUnwrap(session.preview.collisions.first)
        XCTAssertEqual(viewModel.unresolvedConflictCount, 1)

        viewModel.setConflictChoice(.renameIncoming, for: collision.id)
        viewModel.setConflictRename("frog_friend", for: collision.id)
        XCTAssertTrue(viewModel.canInstallImport)
        await viewModel.installPreparedImport()

        XCTAssertNil(viewModel.importSession)
        XCTAssertEqual(callbackCount, 1)
        let snapshot = try await fixture.store.snapshot()
        XCTAssertEqual(snapshot.packs.count, 2)
        XCTAssertTrue(
            snapshot.packs.flatMap(\.items)
                .contains { $0.shortcode.rawValue == "frog_friend" }
        )
    }

    func testAddsFilesToExistingPackThroughReviewedImport() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let frog = try TestSupport.writeImage(
            to: fixture.workspace.appendingPathComponent("frog.png")
        )
        let toad = try TestSupport.writeImage(
            to: fixture.workspace.appendingPathComponent("toad.png"),
            width: 3,
            height: 3
        )
        let pack = try await install(
            files: [frog],
            name: "Pond",
            into: fixture.store
        )
        var latestCallback: MojiPondLibrary?
        let viewModel = makeViewModel(fixture) {
            latestCallback = $0
        }
        await viewModel.reload()

        viewModel.prepareAddFiles([toad], to: pack.id)
        await waitForImportPreparation(viewModel)
        XCTAssertEqual(
            viewModel.importSession?.destination,
            .append(packID: pack.id)
        )
        XCTAssertTrue(viewModel.canInstallImport)
        await viewModel.installPreparedImport()

        let updated = try XCTUnwrap(
            latestCallback?.packs.first(where: { $0.id == pack.id })
        )
        XCTAssertEqual(
            updated.items.map(\.shortcode.rawValue).sorted(),
            ["frog", "toad"]
        )
        XCTAssertEqual(viewModel.scope, .pack(pack.id))
    }

    func testReplacesPackContentsWithoutSelfCollision() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let frog = try TestSupport.writeImage(
            to: fixture.workspace.appendingPathComponent("frog.png")
        )
        let newt = try TestSupport.writeImage(
            to: fixture.workspace.appendingPathComponent("newt.png"),
            width: 4,
            height: 4
        )
        let pack = try await install(
            files: [frog],
            name: "Pond",
            into: fixture.store
        )
        let viewModel = makeViewModel(fixture)
        await viewModel.reload()

        viewModel.prepareReplacement(from: [newt], for: pack.id)
        await waitForImportPreparation(viewModel)
        let session = try XCTUnwrap(viewModel.importSession)
        XCTAssertEqual(session.destination, .replace(packID: pack.id))
        XCTAssertTrue(session.preview.collisions.isEmpty)
        await viewModel.installPreparedImport()

        let snapshot = try await fixture.store.snapshot()
        let updated = try XCTUnwrap(
            snapshot.packs.first(where: { $0.id == pack.id })
        )
        XCTAssertEqual(updated.items.map(\.shortcode.rawValue), ["newt"])
        XCTAssertEqual(updated.id, pack.id)
    }

    func testTogglePackCanBeUndone() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let frog = try TestSupport.writeImage(
            to: fixture.workspace.appendingPathComponent("frog.png")
        )
        let pack = try await install(
            files: [frog],
            name: "Pond",
            into: fixture.store
        )
        let viewModel = makeViewModel(fixture)
        await viewModel.reload()

        await viewModel.setPackEnabled(pack.id, isEnabled: false)
        XCTAssertFalse(
            try XCTUnwrap(
                viewModel.library.packs.first(where: { $0.id == pack.id })
            ).isEnabled
        )
        XCTAssertNotNil(viewModel.undoMessage)

        await viewModel.undoLastMutation()
        XCTAssertTrue(
            try XCTUnwrap(
                viewModel.library.packs.first(where: { $0.id == pack.id })
            ).isEnabled
        )
    }

    func testCreatesEditsReplacesAndRemovesThroughViewModel() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let viewModel = makeViewModel(fixture)
        await viewModel.reload()

        var draft = LibraryPackDraft()
        draft.name = "My Pond"
        draft.author = "Raj"
        let created = await viewModel.createPack(draft)
        XCTAssertTrue(created)
        let pack = try XCTUnwrap(viewModel.selectedPack)

        let frog = try TestSupport.writeImage(
            to: fixture.workspace.appendingPathComponent("frog.png")
        )
        viewModel.prepareAddFiles([frog], to: pack.id)
        await waitForImportPreparation(viewModel)
        await viewModel.installPreparedImport()

        let installedItem = try XCTUnwrap(
            viewModel.library.packs
                .first(where: { $0.id == pack.id })?
                .items.first
        )
        var itemDraft = LibraryItemDraft(
            packID: pack.id,
            item: installedItem
        )
        itemDraft.shortcode = ":pond_frog:"
        itemDraft.aliases = "froggo, green_friend"
        itemDraft.displayName = "Pond Frog"
        itemDraft.tags = "frog, pond"
        itemDraft.category = "Amphibians"
        let updated = await viewModel.updateItem(itemDraft)
        XCTAssertTrue(updated)

        let edited = try XCTUnwrap(
            viewModel.item(packID: pack.id, itemID: installedItem.id)
        )
        XCTAssertEqual(edited.shortcode.rawValue, "pond_frog")
        XCTAssertEqual(
            edited.aliases.map(\.rawValue),
            ["froggo", "green_friend"]
        )
        XCTAssertEqual(edited.tags, ["frog", "pond"])

        viewModel.requestRemoveItem(packID: pack.id, item: edited)
        await viewModel.confirmRemoval()
        XCTAssertTrue(
            try XCTUnwrap(
                viewModel.library.packs.first(where: { $0.id == pack.id })
            ).items.isEmpty
        )
    }

    func testCancelsAsynchronousPreparationImmediately() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let viewModel = LibraryViewModel(
            store: fixture.store,
            paths: fixture.paths,
            importer: SuspendedImporter(),
            builtInLoader: { Self.builtInPack() }
        )
        await viewModel.reload()

        viewModel.prepareImport(.files([], packName: "Waiting"))
        XCTAssertTrue(viewModel.isPreparingImport)
        viewModel.cancelImport()
        XCTAssertFalse(viewModel.isPreparingImport)
        XCTAssertNil(viewModel.importSession)
        await Task.yield()
    }

    private func makeFixture() async throws -> Fixture {
        let workspace = try TestSupport.makeTemporaryDirectory()
        let paths = ApplicationPaths(
            applicationSupportBase: workspace,
            cachesBase: workspace.appendingPathComponent("Caches", isDirectory: true)
        )
        try FileManager.default.createDirectory(
            at: paths.importStagingRoot,
            withIntermediateDirectories: true
        )
        return Fixture(
            workspace: workspace,
            paths: paths,
            store: LibraryStore(rootURL: paths.libraryRoot)
        )
    }

    private func makeViewModel(
        _ fixture: Fixture,
        pasteboard: any PasteboardAccessing = FakePasteboard(),
        onMutation: @escaping LibraryViewModel.MutationCallback = { _ in }
    ) -> LibraryViewModel {
        LibraryViewModel(
            store: fixture.store,
            paths: fixture.paths,
            builtInLoader: { Self.builtInPack() },
            pasteboard: pasteboard,
            onMutation: onMutation
        )
    }

    private func install(
        files: [URL],
        name: String,
        into store: LibraryStore
    ) async throws -> EmojiPack {
        let scan = try ImportScanner().scanFiles(files, packName: name)
        let library = try await store.snapshot()
        let preview = ImportCollisionAnalyzer.makePreview(
            scanResult: scan,
            library: library
        )
        let resolved = try ImportCollisionAnalyzer.resolve(
            preview: preview,
            decisions: [:],
            library: library
        )
        return try await store.install(resolved)
    }

    private func waitForImportPreparation(
        _ viewModel: LibraryViewModel
    ) async {
        for _ in 0..<10_000 {
            if !viewModel.isPreparingImport {
                return
            }
            await Task.yield()
        }
        XCTFail("Import preparation did not finish")
    }

    nonisolated private static func builtInPack() -> EmojiCatalogPack {
        let shortcode = Shortcode(rawValue: "wave")!
        return EmojiCatalogPack(
            id: "builtin.test",
            name: "Built-in Emoji",
            version: "test",
            packDescription: "Test built-in catalog",
            source: .builtIn(dataset: "test", revision: "test"),
            attribution: PackAttribution(
                author: "Test",
                licenseName: "MIT"
            ),
            items: [
                EmojiItem(
                    id: "builtin.test.wave",
                    shortcode: shortcode,
                    name: "waving hand",
                    aliases: ["hello"],
                    keywords: ["greeting"],
                    category: "People",
                    content: .unicode(UnicodeEmojiContent(value: "👋")),
                    packID: "builtin.test",
                    order: 0
                )
            ]
        )
    }

    private struct Fixture {
        let workspace: URL
        let paths: ApplicationPaths
        let store: LibraryStore
    }
}

private struct SuspendedImporter: LibraryImportPreparing {
    func prepare(
        _ request: ImportRequest,
        against library: MojiPondLibrary
    ) async throws -> ImportPreparation {
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
}
