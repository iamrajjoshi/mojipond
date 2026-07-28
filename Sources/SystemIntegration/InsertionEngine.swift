import CoreGraphics
import Foundation

enum SyntheticEventPostingError: Error, Equatable {
    case permissionUnavailable
    case eventCreationFailed
}

protocol SyntheticEventPosting: Sendable {
    var canPostEvents: Bool { get }
    func postPasteShortcut(to processIdentifier: pid_t) throws
}

struct MacSyntheticEventPoster: SyntheticEventPosting, @unchecked Sendable {
    private let permissionProvider: SystemPermissionProviding

    init(
        permissionProvider: SystemPermissionProviding = MacSystemPermissionProvider()
    ) {
        self.permissionProvider = permissionProvider
    }

    var canPostEvents: Bool {
        permissionProvider.isGranted(.eventPosting)
    }

    func postPasteShortcut(to processIdentifier: pid_t) throws {
        guard canPostEvents else {
            throw SyntheticEventPostingError.permissionUnavailable
        }

        let source = CGEventSource(stateID: .hidSystemState)
        guard
            let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: 9,
                keyDown: true
            ),
            let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: 9,
                keyDown: false
            )
        else {
            throw SyntheticEventPostingError.eventCreationFailed
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        SessionEventTapService.tagAsSynthetic(keyDown)
        SessionEventTapService.tagAsSynthetic(keyUp)
        keyDown.postToPid(processIdentifier)
        keyUp.postToPid(processIdentifier)
    }
}

enum InsertionPayload: Equatable, Sendable {
    case unicode(String)
    case media(PasteboardItemPayload)

    fileprivate var pasteboardItems: [PasteboardItemPayload] {
        switch self {
        case .unicode(let text):
            [PasteboardItemPayload.text(text)]
        case .media(let item):
            [item]
        }
    }
}

enum InsertionMethod: Equatable, Sendable {
    case directAccessibility
    case temporaryPasteboard(PasteboardRestoreOutcome)
}

enum InsertionFailureReason: Equatable, Sendable {
    case targetChanged
    case secureOrUnsupportedTarget
    case eventPostingUnavailable
    case unsafeClipboardSnapshot
    case clipboardWriteFailed
    case unknown
}

enum InsertionResult: Equatable, Sendable {
    case inserted(InsertionMethod)
    /// The engine leaves both the token and clipboard untouched in this state.
    case copyFallbackAvailable(InsertionFailureReason)
}

/// Applies the safest available insertion path:
///
/// 1. Direct AX replacement for Unicode (no clipboard).
/// 2. A completely snapshotted temporary pasteboard, freshly revalidated AX
///    token selection, and a tagged Command-V.
/// 3. A non-mutating result that lets the UI explicitly offer "Copy instead".
@MainActor
final class InsertionEngine {
    private let accessibility: AccessibilityTextAdapter
    private let pasteboard: PasteboardTransactionCoordinator
    private let eventPoster: SyntheticEventPosting
    private let restorationDelay: Duration

    init(
        accessibility: AccessibilityTextAdapter = AccessibilityTextAdapter(),
        pasteboard: PasteboardTransactionCoordinator =
            PasteboardTransactionCoordinator(),
        eventPoster: SyntheticEventPosting = MacSyntheticEventPoster(),
        restorationDelay: Duration = .milliseconds(180)
    ) {
        self.accessibility = accessibility
        self.pasteboard = pasteboard
        self.eventPoster = eventPoster
        self.restorationDelay = restorationDelay
    }

    func insert(
        _ payload: InsertionPayload,
        replacing request: AccessibilityReplacementRequest
    ) async -> InsertionResult {
        if case .unicode(let text) = payload {
            do {
                try accessibility.replaceUnicode(text, request: request)
                return .inserted(.directAccessibility)
            } catch {
                // Continue to the rich-editor-compatible path below.
            }
        }

        guard eventPoster.canPostEvents else {
            return .copyFallbackAvailable(.eventPostingUnavailable)
        }

        do {
            let outcome = try await pasteboard.performTemporaryWrite(
                payload.pasteboardItems,
                restorationDelay: restorationDelay
            ) { [accessibility, eventPoster] in
                do {
                    try accessibility.selectValidatedToken(for: request)
                    try eventPoster.postPasteShortcut(
                        to: request.target.processIdentifier
                    )
                } catch {
                    accessibility.restoreExpectedSelection(for: request)
                    throw error
                }
            }
            return .inserted(.temporaryPasteboard(outcome))
        } catch let error as AccessibilityTextError {
            return .copyFallbackAvailable(Self.mapAccessibilityError(error))
        } catch let error as PasteboardTransactionError {
            return .copyFallbackAvailable(Self.mapPasteboardError(error))
        } catch is SyntheticEventPostingError {
            return .copyFallbackAvailable(.eventPostingUnavailable)
        } catch {
            return .copyFallbackAvailable(.unknown)
        }
    }

    @discardableResult
    func copyForManualPaste(_ payload: InsertionPayload) async -> Bool {
        await pasteboard.writePermanently(payload.pasteboardItems)
    }

    private static func mapAccessibilityError(
        _ error: AccessibilityTextError
    ) -> InsertionFailureReason {
        switch error {
        case .staleTarget, .staleSelection, .tokenChanged:
            .targetChanged
        case .secureTextField, .unsupportedAttribute, .noFocusedElement:
            .secureOrUnsupportedTarget
        default:
            .unknown
        }
    }

    private static func mapPasteboardError(
        _ error: PasteboardTransactionError
    ) -> InsertionFailureReason {
        switch error {
        case .memoryLimitExceeded, .representationUnavailable:
            .unsafeClipboardSnapshot
        case .unableToWriteTemporaryItems, .unableToRestore:
            .clipboardWriteFailed
        }
    }
}
