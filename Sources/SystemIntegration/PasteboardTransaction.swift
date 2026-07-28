import AppKit
import Foundation
import UniformTypeIdentifiers

struct PasteboardRepresentation: Equatable, Sendable {
    let typeIdentifier: String
    let data: Data
}

struct PasteboardItemPayload: Equatable, Sendable {
    let representations: [PasteboardRepresentation]

    init(representations: [PasteboardRepresentation]) {
        self.representations = representations
    }

    static func text(_ text: String) -> PasteboardItemPayload {
        PasteboardItemPayload(
            representations: [
                PasteboardRepresentation(
                    typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                    data: Data(text.utf8)
                )
            ]
        )
    }

    /// Keeps the exact source bytes and adds non-destructive image fallbacks.
    ///
    /// In particular, an original GIF remains present as GIF data; its PNG/TIFF
    /// previews are additional representations and never replace the animation.
    static func image(
        originalData: Data,
        type: UTType,
        includeCompatibilityFallbacks: Bool = true
    ) -> PasteboardItemPayload {
        var representations = [
            PasteboardRepresentation(
                typeIdentifier: type.identifier,
                data: originalData
            )
        ]
        guard
            includeCompatibilityFallbacks,
            let image = NSImage(data: originalData),
            let tiffData = image.tiffRepresentation
        else {
            return PasteboardItemPayload(representations: representations)
        }

        if type != .tiff {
            representations.append(
                PasteboardRepresentation(
                    typeIdentifier: UTType.tiff.identifier,
                    data: tiffData
                )
            )
        }
        if
            type != .png,
            let bitmap = NSBitmapImageRep(data: tiffData),
            let pngData = bitmap.representation(using: .png, properties: [:])
        {
            representations.append(
                PasteboardRepresentation(
                    typeIdentifier: UTType.png.identifier,
                    data: pngData
                )
            )
        }
        return PasteboardItemPayload(representations: representations)
    }
}

struct PasteboardSnapshot: Equatable, Sendable {
    let items: [PasteboardItemPayload]
    let changeCount: Int
    let byteCount: Int
}

enum PasteboardTransactionError: Error, Equatable {
    case memoryLimitExceeded(limit: Int)
    case representationUnavailable(item: Int, typeIdentifier: String)
    case unableToWriteTemporaryItems
    case unableToRestore
}

enum PasteboardRestoreOutcome: Equatable, Sendable {
    case restored
    case skippedBecausePasteboardChanged
    case restoreFailed
}

@MainActor
protocol PasteboardAccessing: AnyObject {
    var changeCount: Int { get }
    var itemCount: Int { get }
    func types(forItemAt index: Int) -> [String]
    func data(forType typeIdentifier: String, itemAt index: Int) -> Data?
    @discardableResult
    func replaceContents(with items: [PasteboardItemPayload]) -> Bool
}

@MainActor
final class MacPasteboardAccess: PasteboardAccessing {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int {
        pasteboard.changeCount
    }

    var itemCount: Int {
        pasteboard.pasteboardItems?.count ?? 0
    }

    func types(forItemAt index: Int) -> [String] {
        guard let item = pasteboard.pasteboardItems?[safe: index] else {
            return []
        }
        return item.types.map(\.rawValue)
    }

    func data(forType typeIdentifier: String, itemAt index: Int) -> Data? {
        pasteboard.pasteboardItems?[safe: index]?.data(
            forType: NSPasteboard.PasteboardType(typeIdentifier)
        )
    }

    @discardableResult
    func replaceContents(with items: [PasteboardItemPayload]) -> Bool {
        pasteboard.clearContents()
        guard !items.isEmpty else {
            return true
        }

        let pasteboardItems = items.map { payload in
            let item = NSPasteboardItem()
            for representation in payload.representations {
                item.setData(
                    representation.data,
                    forType: NSPasteboard.PasteboardType(
                        representation.typeIdentifier
                    )
                )
            }
            return item
        }
        return pasteboard.writeObjects(pasteboardItems)
    }
}

/// Serializes temporary clipboard ownership, restores every captured item and
/// representation, and yields if another process changes the pasteboard.
@MainActor
final class PasteboardTransactionCoordinator {
    static let defaultMemoryLimit = 32 * 1_024 * 1_024

    private let pasteboard: PasteboardAccessing
    private let memoryLimit: Int
    private var transactionInProgress = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(
        pasteboard: PasteboardAccessing = MacPasteboardAccess(),
        memoryLimit: Int = defaultMemoryLimit
    ) {
        self.pasteboard = pasteboard
        self.memoryLimit = max(0, memoryLimit)
    }

    func captureSnapshot() throws -> PasteboardSnapshot {
        let initialChangeCount = pasteboard.changeCount
        var byteCount = 0
        var items: [PasteboardItemPayload] = []
        items.reserveCapacity(pasteboard.itemCount)

        for itemIndex in 0 ..< pasteboard.itemCount {
            var representations: [PasteboardRepresentation] = []
            for typeIdentifier in pasteboard.types(forItemAt: itemIndex) {
                guard
                    let data = pasteboard.data(
                        forType: typeIdentifier,
                        itemAt: itemIndex
                    )
                else {
                    throw PasteboardTransactionError.representationUnavailable(
                        item: itemIndex,
                        typeIdentifier: typeIdentifier
                    )
                }
                guard data.count <= memoryLimit - byteCount else {
                    throw PasteboardTransactionError.memoryLimitExceeded(
                        limit: memoryLimit
                    )
                }
                byteCount += data.count
                representations.append(
                    PasteboardRepresentation(
                        typeIdentifier: typeIdentifier,
                        data: data
                    )
                )
            }
            items.append(
                PasteboardItemPayload(representations: representations)
            )
        }

        // A copy racing the snapshot means it was never a coherent snapshot.
        guard pasteboard.changeCount == initialChangeCount else {
            throw PasteboardTransactionError.representationUnavailable(
                item: -1,
                typeIdentifier: "pasteboard changed while snapshotting"
            )
        }
        return PasteboardSnapshot(
            items: items,
            changeCount: initialChangeCount,
            byteCount: byteCount
        )
    }

    func performTemporaryWrite(
        _ items: [PasteboardItemPayload],
        restorationDelay: Duration = .milliseconds(180),
        action: @MainActor () async throws -> Void
    ) async throws -> PasteboardRestoreOutcome {
        await acquireTransaction()
        defer {
            releaseTransaction()
        }

        // Capture must succeed completely before MojiPond changes the clipboard.
        let snapshot = try captureSnapshot()
        guard pasteboard.replaceContents(with: items) else {
            let failedWriteChangeCount = pasteboard.changeCount
            if pasteboard.changeCount == failedWriteChangeCount {
                _ = pasteboard.replaceContents(with: snapshot.items)
            }
            throw PasteboardTransactionError.unableToWriteTemporaryItems
        }
        let transactionChangeCount = pasteboard.changeCount

        var capturedActionError: Error?
        do {
            try await action()
        } catch {
            capturedActionError = error
        }

        if restorationDelay > .zero {
            try? await Task.sleep(for: restorationDelay)
        }

        let restoreOutcome: PasteboardRestoreOutcome
        if pasteboard.changeCount != transactionChangeCount {
            restoreOutcome = .skippedBecausePasteboardChanged
        } else {
            restoreOutcome = pasteboard.replaceContents(with: snapshot.items)
                ? .restored
                : .restoreFailed
        }

        if let capturedActionError {
            throw capturedActionError
        }
        return restoreOutcome
    }

    /// Used by the explicit "Copy image instead" fallback.
    @discardableResult
    func writePermanently(_ items: [PasteboardItemPayload]) async -> Bool {
        await acquireTransaction()
        defer {
            releaseTransaction()
        }
        return pasteboard.replaceContents(with: items)
    }

    private func acquireTransaction() async {
        if !transactionInProgress {
            transactionInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func releaseTransaction() {
        if waiters.isEmpty {
            transactionInProgress = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
