import AppKit
import Foundation
import ImageIO
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
        let limits = AssetValidationLimits.default
        guard
            includeCompatibilityFallbacks,
            (try? AssetValidator(limits: limits).validate(
                data: originalData
            )) != nil,
            let source = CGImageSourceCreateWithData(
                originalData as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ),
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1_024,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary
            ),
            let tiffData = NSBitmapImageRep(
                cgImage: thumbnail
            ).tiffRepresentation
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
        var pasteboardItems: [NSPasteboardItem] = []
        pasteboardItems.reserveCapacity(items.count)
        for payload in items {
            let item = NSPasteboardItem()
            for representation in payload.representations {
                let typeIdentifier = representation.typeIdentifier
                guard
                    !typeIdentifier.isEmpty,
                    typeIdentifier.utf8.count <= 255,
                    typeIdentifier.unicodeScalars.allSatisfy({
                        !CharacterSet.controlCharacters.contains($0)
                    }),
                    item.setData(
                        representation.data,
                        forType: NSPasteboard.PasteboardType(typeIdentifier)
                    )
                else {
                    return false
                }
            }
            pasteboardItems.append(item)
        }

        pasteboard.clearContents()
        guard !pasteboardItems.isEmpty else {
            return true
        }
        return pasteboard.writeObjects(pasteboardItems)
    }
}

/// Serializes temporary clipboard ownership, restores every captured item and
/// representation, and yields if another process changes the pasteboard.
@MainActor
final class PasteboardTransactionCoordinator {
    static let defaultMemoryLimit = 32 * 1_024 * 1_024
    private static let ownershipTypeIdentifier =
        "com.rajjoshi.MojiPond.temporary-pasteboard-owner"

    private struct TransactionWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let pasteboard: PasteboardAccessing
    private let memoryLimit: Int
    private var transactionInProgress = false
    private var waiters: [TransactionWaiter] = []

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
        try await acquireTransaction()
        defer {
            releaseTransaction()
        }

        try Task.checkCancellation()
        // Capture must succeed completely before MojiPond changes the clipboard.
        let snapshot = try captureSnapshot()
        try Task.checkCancellation()
        let ownershipToken = UUID().uuidString
        let temporaryItems = addingOwnershipMarker(
            to: items,
            token: ownershipToken
        )
        guard pasteboard.replaceContents(with: temporaryItems) else {
            if
                pasteboardContainsOwnershipToken(ownershipToken)
                    || pasteboardReflectsOwnedClear(after: snapshot)
            {
                _ = pasteboard.replaceContents(with: snapshot.items)
            }
            throw PasteboardTransactionError.unableToWriteTemporaryItems
        }
        let transactionChangeCount = pasteboard.changeCount

        var capturedActionError: Error?
        var actionCompleted = false
        do {
            try Task.checkCancellation()
            try await action()
            actionCompleted = true
        } catch {
            capturedActionError = error
        }

        if actionCompleted, restorationDelay > .zero {
            await Self.waitWithoutInheritingCancellation(
                for: restorationDelay
            )
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

    private static func waitWithoutInheritingCancellation(
        for duration: Duration
    ) async {
        let sleeper = Task.detached(priority: .userInitiated) {
            try? await Task.sleep(for: duration)
        }
        await sleeper.value
    }

    /// Used by the explicit "Copy image instead" fallback.
    @discardableResult
    func writePermanently(_ items: [PasteboardItemPayload]) async -> Bool {
        do {
            try await acquireTransaction()
        } catch {
            return false
        }
        defer {
            releaseTransaction()
        }
        guard !Task.isCancelled else {
            return false
        }
        return pasteboard.replaceContents(with: items)
    }

    private func addingOwnershipMarker(
        to items: [PasteboardItemPayload],
        token: String
    ) -> [PasteboardItemPayload] {
        let marker = PasteboardRepresentation(
            typeIdentifier: Self.ownershipTypeIdentifier,
            data: Data(token.utf8)
        )
        guard let first = items.first else {
            return [PasteboardItemPayload(representations: [marker])]
        }
        var marked = items
        marked[0] = PasteboardItemPayload(
            representations: first.representations + [marker]
        )
        return marked
    }

    private func pasteboardContainsOwnershipToken(_ token: String) -> Bool {
        guard
            pasteboard.itemCount > 0,
            pasteboard.types(forItemAt: 0).contains(
                Self.ownershipTypeIdentifier
            ),
            pasteboard.data(
                forType: Self.ownershipTypeIdentifier,
                itemAt: 0
            ) == Data(token.utf8)
        else {
            return false
        }
        return true
    }

    private func pasteboardReflectsOwnedClear(
        after snapshot: PasteboardSnapshot
    ) -> Bool {
        pasteboard.itemCount == 0
            && pasteboard.changeCount == snapshot.changeCount + 1
    }

    private func acquireTransaction() async throws {
        try Task.checkCancellation()
        if !transactionInProgress {
            transactionInProgress = true
            return
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append(
                    TransactionWaiter(
                        id: waiterID,
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(waiterID)
            }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func releaseTransaction() {
        if waiters.isEmpty {
            transactionInProgress = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
