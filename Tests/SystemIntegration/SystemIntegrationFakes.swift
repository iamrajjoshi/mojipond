import Foundation
@testable import MojiPond

final class FakePermissionProvider: SystemPermissionProviding {
    var granted = Dictionary(
        uniqueKeysWithValues: SystemPermission.allCases.map { ($0, false) }
    )
    var requestResults = Dictionary(
        uniqueKeysWithValues: SystemPermission.allCases.map { ($0, false) }
    )
    private(set) var requests: [SystemPermission] = []
    private(set) var preflights: [SystemPermission] = []

    func isGranted(_ permission: SystemPermission) -> Bool {
        preflights.append(permission)
        return granted[permission, default: false]
    }

    func request(_ permission: SystemPermission) -> Bool {
        requests.append(permission)
        let result = requestResults[permission, default: false]
        granted[permission] = result
        return result
    }

    func resetPreflights() {
        preflights.removeAll()
    }
}

final class FakePermissionHistory: PermissionHistoryStoring {
    var requested: Set<SystemPermission> = []
    var everGranted: Set<SystemPermission> = []

    func hasRequested(_ permission: SystemPermission) -> Bool {
        requested.contains(permission)
    }

    func wasEverGranted(_ permission: SystemPermission) -> Bool {
        everGranted.contains(permission)
    }

    func setRequested(_ requested: Bool, for permission: SystemPermission) {
        if requested {
            self.requested.insert(permission)
        } else {
            self.requested.remove(permission)
        }
    }

    func setEverGranted(_ granted: Bool, for permission: SystemPermission) {
        if granted {
            everGranted.insert(permission)
        } else {
            everGranted.remove(permission)
        }
    }
}

final class FakeAccessibilityTextSystem: AccessibilityTextSystem {
    let primaryElement = AccessibilityElementReference(rawValue: NSObject())
    let alternateElement = AccessibilityElementReference(rawValue: NSObject())

    var focusedElementReference: AccessibilityElementReference
    var processIdentifier: pid_t = 42
    var text = ""
    var selection = NSRange(location: 0, length: 0)
    var caretBounds: CGRect? = CGRect(x: 20, y: 30, width: 1, height: 18)
    var textMarkerBounds: CGRect?
    var boundsByRange: [NSRange: CGRect] = [:]
    var missingBoundsRanges: Set<NSRange> = []
    var boundsErrorsByRange: [NSRange: AccessibilityTextError] = [:]
    var subrole: String?
    var subroleError: Error?
    var supportsRangedStrings = true
    var rangedStringError: AccessibilityTextError?
    var reportedCharacterCount: Int?
    var characterCountError: AccessibilityTextError?
    var settableAttributes: Set<String> = [
        "AXSelectedTextRange",
        "AXSelectedText"
    ]
    var focusedElementError: Error?
    private(set) var selectedRangesSet: [NSRange] = []
    private(set) var replacements: [String] = []
    private(set) var fullValueReadCount = 0
    private(set) var rangedStringReads: [NSRange] = []
    private(set) var boundsReads: [NSRange] = []

    init() {
        focusedElementReference = primaryElement
    }

    func focusedElement() throws -> AccessibilityElementReference {
        if let focusedElementError {
            throw focusedElementError
        }
        return focusedElementReference
    }

    func processIdentifier(
        of element: AccessibilityElementReference
    ) throws -> pid_t {
        processIdentifier
    }

    func elementsAreEqual(
        _ lhs: AccessibilityElementReference,
        _ rhs: AccessibilityElementReference
    ) -> Bool {
        lhs === rhs
    }

    func value(of element: AccessibilityElementReference) throws -> String {
        fullValueReadCount += 1
        return text
    }

    func numberOfCharacters(
        in element: AccessibilityElementReference
    ) throws -> Int? {
        if let characterCountError {
            throw characterCountError
        }
        return reportedCharacterCount ?? text.utf16.count
    }

    func string(
        for range: NSRange,
        in element: AccessibilityElementReference
    ) throws -> String? {
        if let rangedStringError {
            throw rangedStringError
        }
        guard supportsRangedStrings else {
            return nil
        }
        rangedStringReads.append(range)
        try AccessibilityTextAdapter.validate(range, in: text)
        return (text as NSString).substring(with: range)
    }

    func selectedTextRange(
        of element: AccessibilityElementReference
    ) throws -> NSRange {
        selection
    }

    func bounds(
        for range: NSRange,
        in element: AccessibilityElementReference
    ) throws -> CGRect? {
        boundsReads.append(range)
        if let error = boundsErrorsByRange[range] {
            throw error
        }
        if missingBoundsRanges.contains(range) {
            return nil
        }
        if let bounds = boundsByRange[range] {
            return bounds
        }
        return caretBounds
    }

    func textMarkerBoundsBeforeSelection(
        in element: AccessibilityElementReference
    ) throws -> CGRect? {
        textMarkerBounds
    }

    func subrole(
        of element: AccessibilityElementReference
    ) throws -> String? {
        if let subroleError {
            throw subroleError
        }
        return subrole
    }

    func isAttributeSettable(
        _ attribute: String,
        in element: AccessibilityElementReference
    ) throws -> Bool {
        settableAttributes.contains(attribute)
    }

    func setSelectedTextRange(
        _ range: NSRange,
        in element: AccessibilityElementReference
    ) throws {
        selectedRangesSet.append(range)
        selection = range
    }

    func setSelectedText(
        _ replacement: String,
        in element: AccessibilityElementReference
    ) throws {
        let mutable = NSMutableString(string: text)
        mutable.replaceCharacters(in: selection, with: replacement)
        text = mutable as String
        selection = NSRange(
            location: selection.location + replacement.utf16.count,
            length: 0
        )
        replacements.append(replacement)
    }
}

@MainActor
final class FakePasteboard: PasteboardAccessing {
    private(set) var changeCount = 0
    var items: [PasteboardItemPayload]
    var writesSucceed = true
    var failingWriteAttempts: Set<Int> = []
    var failedWriteClearsContents = false
    var failedWriteKeepsAttemptedContents = false
    var failedWriteReplacement: [PasteboardItemPayload]?
    private(set) var writeAttempts = 0
    private(set) var successfulWrites: [[PasteboardItemPayload]] = []

    init(items: [PasteboardItemPayload] = []) {
        self.items = items
    }

    var itemCount: Int {
        items.count
    }

    func types(forItemAt index: Int) -> [String] {
        guard items.indices.contains(index) else {
            return []
        }
        return items[index].representations.map(\.typeIdentifier)
    }

    func data(forType typeIdentifier: String, itemAt index: Int) -> Data? {
        guard items.indices.contains(index) else {
            return nil
        }
        return items[index].representations.first {
            $0.typeIdentifier == typeIdentifier
        }?.data
    }

    @discardableResult
    func replaceContents(with items: [PasteboardItemPayload]) -> Bool {
        writeAttempts += 1
        guard writesSucceed, !failingWriteAttempts.contains(writeAttempts) else {
            if let failedWriteReplacement {
                self.items = failedWriteReplacement
                changeCount += 1
            } else if failedWriteKeepsAttemptedContents {
                self.items = items
                changeCount += 1
            } else if failedWriteClearsContents {
                self.items = []
                changeCount += 1
            }
            return false
        }
        successfulWrites.append(items)
        self.items = items
        changeCount += 1
        return true
    }

    func simulateExternalCopy(_ items: [PasteboardItemPayload]) {
        self.items = items
        changeCount += 1
    }
}

final class FakeEventPoster: SyntheticEventPosting, @unchecked Sendable {
    var canPostEvents: Bool
    var error: Error?
    var onPaste: (() -> Void)?
    private(set) var pasteCount = 0
    private(set) var returnCount = 0
    private(set) var targetProcessIdentifiers: [pid_t] = []

    init(canPostEvents: Bool = true) {
        self.canPostEvents = canPostEvents
    }

    func postPasteShortcut(to processIdentifier: pid_t) throws {
        if let error {
            throw error
        }
        pasteCount += 1
        targetProcessIdentifiers.append(processIdentifier)
        onPaste?()
    }

    func postReturnKey(to processIdentifier: pid_t) throws {
        if let error {
            throw error
        }
        returnCount += 1
        targetProcessIdentifiers.append(processIdentifier)
    }
}

struct FakeSecureInputProvider: SecureInputProviding {
    let isSecureEventInputEnabled: Bool
}
