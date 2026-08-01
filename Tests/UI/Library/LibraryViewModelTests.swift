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
        await viewModel.copyToClipboard(wave)

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
        await viewModel.copyToClipboard(frog)

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

    func testFavoritesAndPerEmojiSkinToneAreUserAccessible() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let usageStore = InMemoryEmojiUsageStore()
        var usageMutationCount = 0
        let viewModel = makeViewModel(
            fixture,
            usageStore: usageStore,
            onUsageMutation: {
                usageMutationCount += 1
            }
        )
        await viewModel.reload()
        let wave = try XCTUnwrap(
            viewModel.allDisplayItems.first(where: {
                $0.shortcode == "wave"
            })
        )

        await viewModel.toggleFavorite(wave)
        viewModel.scope = .favorites

        XCTAssertEqual(viewModel.visibleItems.map(\.shortcode), ["wave"])
        XCTAssertTrue(viewModel.isFavorite(wave))
        XCTAssertEqual(
            viewModel.availableSkinTones(for: wave),
            EmojiSkinTone.allCases
        )

        await viewModel.setPreferredSkinTone(.mediumDark, for: wave)
        await viewModel.setCustomAliases("salute, hi-wave", for: wave)
        viewModel.scope = .all
        viewModel.searchText = "salute"

        let snapshot = try await usageStore.snapshot()
        XCTAssertEqual(viewModel.visibleItems.map(\.shortcode), ["wave"])
        XCTAssertEqual(snapshot.favoriteItemIDs, ["builtin.test.wave"])
        XCTAssertEqual(
            snapshot.customAliasesByItemID["builtin.test.wave"],
            ["salute", "hi-wave"]
        )
        XCTAssertEqual(
            snapshot.preferredSkinToneByItemID["builtin.test.wave"],
            .mediumDark
        )
        XCTAssertEqual(usageMutationCount, 3)
    }

    func testAliasesScopeBrowsesAndFiltersAllEmoji() async throws {
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
        let usageStore = InMemoryEmojiUsageStore()
        let viewModel = makeViewModel(fixture, usageStore: usageStore)
        await viewModel.reload()
        let wave = try XCTUnwrap(
            viewModel.allDisplayItems.first(where: { $0.shortcode == "wave" })
        )
        let customFrog = try XCTUnwrap(
            viewModel.allDisplayItems.first(where: { $0.shortcode == "frog" })
        )

        await viewModel.setCustomAliases("salute, hi-wave", for: wave)
        await viewModel.setCustomAliases("toad", for: customFrog)
        viewModel.scope = .custom
        XCTAssertEqual(
            viewModel.selectedScopeSubtitle,
            "1 emoji in 1 installed pack"
        )
        viewModel.scope = .aliases

        XCTAssertEqual(viewModel.personalAliasCount, 3)
        XCTAssertEqual(viewModel.visibleItems.map(\.shortcode), ["wave", "frog"])
        XCTAssertEqual(viewModel.selectedScopeTitle, "Aliases")
        XCTAssertEqual(
            viewModel.selectedScopeSubtitle,
            "3 personal aliases · Choose an emoji to edit"
        )

        let aliasCategories = viewModel.availableCategories
        viewModel.scope = .all
        XCTAssertEqual(aliasCategories, viewModel.availableCategories)

        viewModel.scope = .aliases
        viewModel.searchText = "salute"
        XCTAssertEqual(viewModel.visibleItems.map(\.shortcode), ["wave"])

        viewModel.searchText = ""
        viewModel.contentFilter = .images
        XCTAssertEqual(viewModel.visibleItems.map(\.shortcode), ["frog"])
    }

    func testAliasesScopeUsesSingularSubtitle() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let usageStore = InMemoryEmojiUsageStore(
            initialState: EmojiUsageSnapshot(
                customAliasesByItemID: ["builtin.test.wave": ["salute"]]
            )
        )
        let viewModel = makeViewModel(fixture, usageStore: usageStore)
        await viewModel.reload()

        viewModel.scope = .aliases

        XCTAssertEqual(viewModel.personalAliasCount, 1)
        XCTAssertEqual(
            viewModel.selectedScopeSubtitle,
            "1 personal alias · Choose an emoji to edit"
        )
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

    func testDroppedImportAcceptsOneLocalZIPCaseInsensitively()
        async throws
    {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let viewModel = LibraryViewModel(
            store: fixture.store,
            paths: fixture.paths,
            importer: SuspendedImporter(),
            builtInLoader: { Self.builtInPack() }
        )
        await viewModel.reload()
        let archive = fixture.workspace.appendingPathComponent("Pond.ZIP")
        try Data([0x50, 0x4B]).write(to: archive)

        XCTAssertTrue(viewModel.prepareDroppedURLs([archive]))
        XCTAssertTrue(viewModel.isPreparingImport)

        viewModel.cancelImport()
    }

    func testDroppedImportRejectsNonZIPDirectoriesAndMultipleArchives()
        async throws
    {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let viewModel = makeViewModel(fixture)
        await viewModel.reload()
        let image = fixture.workspace.appendingPathComponent("frog.png")
        let manifest = fixture.workspace.appendingPathComponent("emoji.json")
        let firstArchive = fixture.workspace.appendingPathComponent("one.zip")
        let secondArchive = fixture.workspace.appendingPathComponent("two.zip")
        let directory = fixture.workspace.appendingPathComponent(
            "folder.zip",
            isDirectory: true
        )
        for file in [image, manifest, firstArchive, secondArchive] {
            try Data().write(to: file)
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )

        XCTAssertFalse(viewModel.prepareDroppedURLs([image]))
        XCTAssertFalse(viewModel.prepareDroppedURLs([manifest]))
        XCTAssertFalse(viewModel.prepareDroppedURLs([directory]))
        XCTAssertFalse(
            viewModel.prepareDroppedURLs([firstArchive, secondArchive])
        )
        XCTAssertFalse(viewModel.isPreparingImport)
        XCTAssertNil(viewModel.importSession)
        XCTAssertEqual(
            viewModel.notice?.message,
            "Drop one local ZIP archive."
        )
    }

    func testImportPreviewProtectsBuiltInPrimaryAndAliasClaims()
        async throws
    {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let viewModel = makeViewModel(fixture)
        await viewModel.reload()

        for filename in ["wave.png", "hello.png"] {
            let source = try TestSupport.writeImage(
                to: fixture.workspace.appendingPathComponent(filename)
            )
            viewModel.prepareImport(
                .files([source], packName: "Incoming")
            )
            await waitForImportPreparation(viewModel)
            let collision = try XCTUnwrap(
                viewModel.importSession?.preview.collisions.first
            )
            guard case let .reserved(owner) = collision.existing else {
                return XCTFail("Expected a protected built-in collision")
            }
            XCTAssertEqual(owner.source, .builtIn)
            XCTAssertEqual(
                collision.shortcode.rawValue,
                filename == "wave.png" ? "wave" : "hello"
            )

            viewModel.setConflictChoice(
                .replaceExisting,
                for: collision.id
            )
            XCTAssertEqual(viewModel.unresolvedConflictCount, 1)
            XCTAssertFalse(viewModel.canInstallImport)
            XCTAssertEqual(
                viewModel.notice?.title,
                "Protected shortcode"
            )
            await viewModel.discardImport()
        }
    }

    func testAliasAddedAfterPreviewFailsClosedAndAppearsOnRepreview()
        async throws
    {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let usageStore = InMemoryEmojiUsageStore()
        let viewModel = makeViewModel(
            fixture,
            usageStore: usageStore
        )
        await viewModel.reload()
        let source = try TestSupport.writeImage(
            to: fixture.workspace.appendingPathComponent("frog.png")
        )
        let wave = try XCTUnwrap(
            viewModel.allDisplayItems.first(where: {
                $0.shortcode == "wave"
            })
        )

        viewModel.prepareImport(
            .files([source], packName: "Incoming")
        )
        await waitForImportPreparation(viewModel)
        XCTAssertTrue(
            viewModel.importSession?.preview.collisions.isEmpty
                == true
        )

        await viewModel.setCustomAliases("frog", for: wave)
        await viewModel.installPreparedImport()

        XCTAssertNotNil(viewModel.importSession)
        XCTAssertEqual(
            viewModel.notice?.title,
            "Couldn’t install pack"
        )
        let snapshotAfterRejectedInstall =
            try await fixture.store.snapshot()
        XCTAssertTrue(snapshotAfterRejectedInstall.packs.isEmpty)

        await viewModel.discardImport()
        viewModel.prepareImport(
            .files([source], packName: "Incoming")
        )
        await waitForImportPreparation(viewModel)
        let collision = try XCTUnwrap(
            viewModel.importSession?.preview.collisions.first
        )
        guard case let .reserved(owner) = collision.existing else {
            return XCTFail("Expected a protected user-alias collision")
        }
        XCTAssertEqual(owner.source, .customAlias)
        XCTAssertEqual(owner.shortcode.rawValue, "frog")
    }

    func testCustomAliasesCannotShadowCanonicalOrOtherItemClaims()
        async throws
    {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let frog = try TestSupport.writeImage(
            to: fixture.workspace.appendingPathComponent("frog.png")
        )
        _ = try await install(
            files: [frog],
            name: "Pond",
            into: fixture.store
        )
        let usageStore = InMemoryEmojiUsageStore()
        let viewModel = makeViewModel(
            fixture,
            usageStore: usageStore
        )
        await viewModel.reload()
        let wave = try XCTUnwrap(
            viewModel.allDisplayItems.first(where: {
                $0.shortcode == "wave"
            })
        )

        await viewModel.setCustomAliases("frog", for: wave)
        XCTAssertEqual(
            viewModel.notice?.title,
            "Couldn’t save aliases"
        )
        var usageSnapshot = try await usageStore.snapshot()
        XCTAssertTrue(
            usageSnapshot.customAliasesByItemID.isEmpty
        )

        await viewModel.setCustomAliases("wave", for: wave)
        XCTAssertEqual(
            viewModel.notice?.title,
            "Couldn’t save aliases"
        )
        usageSnapshot = try await usageStore.snapshot()
        XCTAssertTrue(
            usageSnapshot.customAliasesByItemID.isEmpty
        )
    }

    func testDirectCreateAndEditRejectBuiltInClaims() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let pack = try await fixture.store.createPack(name: "Pond")
        let viewModel = makeViewModel(fixture)
        await viewModel.reload()

        var draft = LibraryUnicodeItemDraft(packID: pack.id)
        draft.unicode = "🐸"
        draft.shortcode = "wave"
        let createdReserved =
            await viewModel.createUnicodeItem(draft)
        XCTAssertFalse(createdReserved)

        draft.shortcode = "frog"
        let createdFrog =
            await viewModel.createUnicodeItem(draft)
        XCTAssertTrue(createdFrog)
        let item = try XCTUnwrap(
            viewModel.library.packs.first?
                .items.first
        )
        var edit = LibraryItemDraft(
            packID: pack.id,
            item: item
        )
        edit.aliases = "hello"
        let editedReserved =
            await viewModel.updateItem(edit)
        XCTAssertFalse(editedReserved)
        let snapshotAfterRejectedEdit =
            try await fixture.store.snapshot()
        XCTAssertEqual(
            snapshotAfterRejectedEdit
                .packs.first?.items.first?.aliases,
            []
        )
    }

    func testBuiltInLoadFailureBlocksClaimMutations() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let pack = try await fixture.store.createPack(name: "Pond")
        let viewModel = LibraryViewModel(
            store: fixture.store,
            paths: fixture.paths,
            builtInLoader: {
                throw CocoaError(.fileReadCorruptFile)
            }
        )
        await viewModel.reload()
        let source = try TestSupport.writeImage(
            to: fixture.workspace.appendingPathComponent("frog.png")
        )

        viewModel.prepareImport(
            .files([source], packName: "Incoming")
        )
        XCTAssertFalse(viewModel.isPreparingImport)
        XCTAssertEqual(
            viewModel.notice?.title,
            "Built-in emoji unavailable"
        )

        var draft = LibraryUnicodeItemDraft(packID: pack.id)
        draft.unicode = "🐸"
        draft.shortcode = "frog"
        let created =
            await viewModel.createUnicodeItem(draft)
        XCTAssertFalse(created)
        XCTAssertEqual(
            viewModel.notice?.title,
            "Couldn’t add emoji"
        )
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
        let viewModel = makeViewModel(
            fixture,
            onMutation: { _ in
                callbackCount += 1
            }
        )
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
        let viewModel = makeViewModel(
            fixture,
            onMutation: {
                latestCallback = $0
            }
        )
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

    func testCreatesSearchesAndCopiesUnicodeItemThroughViewModel()
        async throws
    {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let pack = try await fixture.store.createPack(name: "Pond")
        let pasteboard = FakePasteboard()
        let viewModel = makeViewModel(
            fixture,
            pasteboard: pasteboard
        )
        await viewModel.reload()

        var draft = LibraryUnicodeItemDraft(packID: pack.id)
        draft.unicode = "👨🏽‍💻"
        draft.shortcode = ":pond_coder:"
        draft.aliases = "frog_dev, ship_it"
        draft.displayName = "Pond Coder"
        draft.tags = "frog, code"
        draft.category = "Pond"

        let created = await viewModel.createUnicodeItem(draft)
        XCTAssertTrue(created)
        viewModel.scope = .pack(pack.id)
        viewModel.searchText = "frog_dev"
        let displayItem = try XCTUnwrap(viewModel.visibleItems.first)
        XCTAssertEqual(displayItem.unicode, "👨🏽‍💻")
        XCTAssertEqual(displayItem.shortcode, "pond_coder")

        await viewModel.copyToClipboard(displayItem)
        XCTAssertEqual(
            pasteboard.items.first?.representations.first?.data,
            Data("👨🏽‍💻".utf8)
        )

        draft.shortcode = "plain_text"
        draft.unicode = "hello"
        let rejected = await viewModel.createUnicodeItem(draft)
        XCTAssertFalse(rejected)
        XCTAssertEqual(viewModel.notice?.kind, .error)
        let snapshot = try await fixture.store.snapshot()
        XCTAssertEqual(snapshot.packs.first?.items.count, 1)
    }

    func testGitHubRevisionCheckPersistsCheckWithoutDownloadingArchive()
        async throws
    {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let source = PackSource(
            kind: .github,
            displayLocation:
                "https://github.com/knobiknows/all-the-bufo",
            github: GitHubPackSource(
                owner: "knobiknows",
                repository: "all-the-bufo",
                ref: "main"
            )
        )
        let pack = try await fixture.store.createPack(
            name: "All the Bufo",
            source: source
        )
        let installedRevision = String(repeating: "a", count: 40)
        let latestRevision = String(repeating: "b", count: 40)
        try await fixture.store.markPackChecked(
            pack.id,
            sourceRevision: installedRevision
        )
        let resolver = RecordingRevisionResolver(
            result: GitHubResolvedRevision(
                requestedReference: try GitHubRepositoryReference(
                    owner: "knobiknows",
                    repository: "all-the-bufo",
                    ref: "main"
                ),
                commitSHA: latestRevision,
                sourceETag: "\"latest\""
            )
        )
        let viewModel = makeViewModel(
            fixture,
            githubRevisionResolver: resolver
        )
        await viewModel.reload()

        await viewModel.checkGitHubRevision(
            for: pack.id,
            networkAccessGranted: true
        )

        XCTAssertEqual(
            viewModel.githubRevisionState(for: pack.id),
            .updateAvailable(
                installed: installedRevision,
                latest: latestRevision
            )
        )
        let resolverCallCount = await resolver.recordedCallCount()
        XCTAssertEqual(resolverCallCount, 1)
        let updated = try XCTUnwrap(
            viewModel.library.packs.first(where: { $0.id == pack.id })
        )
        XCTAssertEqual(
            updated.updateMetadata.sourceRevision,
            installedRevision
        )
        XCTAssertEqual(updated.updateMetadata.sourceETag, "\"latest\"")
        XCTAssertNotNil(updated.updateMetadata.lastCheckedAt)
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

    func testCanceledPreparationCannotClobberNewerPreparation() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let importer = ControlledImporter()
        let viewModel = LibraryViewModel(
            store: fixture.store,
            paths: fixture.paths,
            importer: importer,
            builtInLoader: { Self.builtInPack() }
        )
        await viewModel.reload()

        viewModel.prepareImport(.files([], packName: "Older"))
        await waitForImporter(importer, toReceive: "Older")
        viewModel.prepareImport(.files([], packName: "Newer"))
        await waitForImporter(importer, toReceive: "Newer")

        let olderPreparation = try makeEmptyPreparation(
            named: "Older",
            in: fixture.workspace
        )
        await importer.resume("Older", returning: olderPreparation)
        await waitForRemoval(of: olderPreparation.workingDirectoryURL)

        XCTAssertTrue(viewModel.isPreparingImport)
        XCTAssertNil(viewModel.importSession)

        let newerPreparation = try makeEmptyPreparation(
            named: "Newer",
            in: fixture.workspace
        )
        await importer.resume("Newer", returning: newerPreparation)
        await waitForImportPreparation(viewModel)

        XCTAssertFalse(viewModel.isPreparingImport)
        XCTAssertEqual(
            viewModel.importSession?.preview.preparedPack.name,
            "Newer"
        )
        XCTAssertNil(viewModel.notice)
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
            store: LibraryStore(
                rootURL: paths.libraryRoot,
                reservedShortcodes:
                    BuiltInShortcodeReservations.shortcodes(
                        in: Self.builtInPack()
                    )
            )
        )
    }

    private func makeViewModel(
        _ fixture: Fixture,
        pasteboard: any PasteboardAccessing = FakePasteboard(),
        usageStore: (any EmojiUsageStore)? = nil,
        githubRevisionResolver:
            (any LibraryGitHubRevisionResolving)? = nil,
        onUsageMutation:
            @escaping LibraryViewModel.UsageMutationCallback = {},
        onMutation: @escaping LibraryViewModel.MutationCallback = { _ in }
    ) -> LibraryViewModel {
        LibraryViewModel(
            store: fixture.store,
            paths: fixture.paths,
            githubRevisionResolver: githubRevisionResolver,
            builtInLoader: { Self.builtInPack() },
            pasteboard: pasteboard,
            usageStore: usageStore,
            onMutation: onMutation,
            onUsageMutation: onUsageMutation
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

    private func waitForImporter(
        _ importer: ControlledImporter,
        toReceive name: String
    ) async {
        for _ in 0..<10_000 {
            if await importer.isWaiting(for: name) {
                return
            }
            await Task.yield()
        }
        XCTFail("Importer did not receive \(name)")
    }

    private func waitForRemoval(of url: URL) async {
        for _ in 0..<10_000 {
            if !FileManager.default.fileExists(atPath: url.path) {
                return
            }
            await Task.yield()
        }
        XCTFail("Stale import preparation was not discarded")
    }

    private func makeEmptyPreparation(
        named name: String,
        in root: URL
    ) throws -> ImportPreparation {
        let workspace = root.appendingPathComponent(
            "Preparation-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: false
        )
        let preparedPack = PreparedPackImport(
            name: name,
            source: PackSource(kind: .individualFiles),
            items: []
        )
        return ImportPreparation(
            preview: ImportPreview(
                preparedPack: preparedPack,
                items: [],
                collisions: [],
                rejections: [],
                ignoredFileCount: 0,
                totalByteCount: 0
            ),
            duplicateContent: [],
            workspaceURL: workspace
        )
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
                    content: .unicode(
                        UnicodeEmojiContent(
                            value: "👋",
                            skinToneVariants: EmojiSkinTone.allCases.map {
                                UnicodeEmojiVariant(
                                    skinTone: $0,
                                    value: "👋\($0.modifier)"
                                )
                            }
                        )
                    ),
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
        against library: MojiPondLibrary,
        reservedShortcodeOwners: [ReservedShortcodeOwner]
    ) async throws -> ImportPreparation {
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
}

private actor ControlledImporter: LibraryImportPreparing {
    private var continuations:
        [String: CheckedContinuation<ImportPreparation, any Error>] = [:]

    func prepare(
        _ request: ImportRequest,
        against library: MojiPondLibrary,
        reservedShortcodeOwners: [ReservedShortcodeOwner]
    ) async throws -> ImportPreparation {
        let name: String
        switch request {
        case let .files(_, packName):
            name = packName
        default:
            throw CancellationError()
        }
        return try await withCheckedThrowingContinuation { continuation in
            continuations[name] = continuation
        }
    }

    func isWaiting(for name: String) -> Bool {
        continuations[name] != nil
    }

    func resume(
        _ name: String,
        returning preparation: ImportPreparation
    ) {
        continuations.removeValue(forKey: name)?.resume(
            returning: preparation
        )
    }
}

private actor RecordingRevisionResolver:
    LibraryGitHubRevisionResolving {
    private let result: GitHubResolvedRevision
    private var callCount = 0

    init(result: GitHubResolvedRevision) {
        self.result = result
    }

    func resolveRevision(
        from repositoryURL: URL,
        ref: String?,
        subdirectory: String?
    ) async throws -> GitHubResolvedRevision {
        callCount += 1
        return result
    }

    func recordedCallCount() -> Int {
        callCount
    }
}
