import ApplicationServices
import CoreGraphics
import Foundation

enum AccessibilityTextError: Error, Equatable {
    case noFocusedElement
    case unsupportedAttribute(String)
    case invalidAttributeValue(String)
    case invalidUTF16Range
    case staleTarget
    case staleSelection
    case tokenChanged
    case secureTextField
    case axFailure(operation: String, code: AXError)
}

final class AccessibilityElementReference: @unchecked Sendable {
    fileprivate let rawValue: AnyObject

    init(rawValue: AnyObject) {
        self.rawValue = rawValue
    }
}

struct AccessibilityTextTarget: @unchecked Sendable {
    let element: AccessibilityElementReference
    let processIdentifier: pid_t
}

struct AccessibilityTextContext: Equatable, Sendable {
    let selection: NSRange
    let caretBounds: CGRect?
    let textFragment: String
    let textFragmentRange: NSRange
    let tokenRange: NSRange?
}

struct AccessibilityReplacementRequest: @unchecked Sendable {
    let target: AccessibilityTextTarget
    let tokenRange: NSRange
    let expectedToken: String
    let expectedSelection: NSRange
}

protocol AccessibilityTextSystem: AnyObject {
    func focusedElement() throws -> AccessibilityElementReference
    func processIdentifier(of element: AccessibilityElementReference) throws -> pid_t
    func elementsAreEqual(
        _ lhs: AccessibilityElementReference,
        _ rhs: AccessibilityElementReference
    ) -> Bool
    func value(of element: AccessibilityElementReference) throws -> String
    func numberOfCharacters(
        in element: AccessibilityElementReference
    ) throws -> Int?
    func string(
        for range: NSRange,
        in element: AccessibilityElementReference
    ) throws -> String?
    func selectedTextRange(of element: AccessibilityElementReference) throws -> NSRange
    func bounds(
        for range: NSRange,
        in element: AccessibilityElementReference
    ) throws -> CGRect?
    func textMarkerBoundsBeforeSelection(
        in element: AccessibilityElementReference
    ) throws -> CGRect?
    func subrole(of element: AccessibilityElementReference) throws -> String?
    func isAttributeSettable(
        _ attribute: String,
        in element: AccessibilityElementReference
    ) throws -> Bool
    func setSelectedTextRange(
        _ range: NSRange,
        in element: AccessibilityElementReference
    ) throws
    func setSelectedText(
        _ text: String,
        in element: AccessibilityElementReference
    ) throws
}

extension AccessibilityTextSystem {
    func textMarkerBoundsBeforeSelection(
        in element: AccessibilityElementReference
    ) throws -> CGRect? {
        _ = element
        return nil
    }
}

final class MacAccessibilityTextSystem: AccessibilityTextSystem {
    private let systemWideElement = AXUIElementCreateSystemWide()

    func focusedElement() throws -> AccessibilityElementReference {
        var value: CFTypeRef?
        try check(
            AXUIElementCopyAttributeValue(
                systemWideElement,
                kAXFocusedUIElementAttribute as CFString,
                &value
            ),
            operation: "read focused element"
        )
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw AccessibilityTextError.noFocusedElement
        }
        return AccessibilityElementReference(rawValue: value as AnyObject)
    }

    func processIdentifier(of element: AccessibilityElementReference) throws -> pid_t {
        var processIdentifier: pid_t = 0
        try check(
            AXUIElementGetPid(axElement(element), &processIdentifier),
            operation: "read target process identifier"
        )
        return processIdentifier
    }

    func elementsAreEqual(
        _ lhs: AccessibilityElementReference,
        _ rhs: AccessibilityElementReference
    ) -> Bool {
        CFEqual(lhs.rawValue, rhs.rawValue)
    }

    func value(of element: AccessibilityElementReference) throws -> String {
        let value = try copyAttribute(
            kAXValueAttribute,
            from: element,
            operation: "read text value"
        )
        if let string = value as? String {
            return string
        }
        if let attributedString = value as? NSAttributedString {
            return attributedString.string
        }
        throw AccessibilityTextError.invalidAttributeValue(kAXValueAttribute)
    }

    func numberOfCharacters(
        in element: AccessibilityElementReference
    ) throws -> Int? {
        do {
            let value = try copyAttribute(
                kAXNumberOfCharactersAttribute,
                from: element,
                operation: "read text character count"
            )
            guard let number = value as? NSNumber else {
                throw AccessibilityTextError.invalidAttributeValue(
                    kAXNumberOfCharactersAttribute
                )
            }
            return number.intValue
        } catch AccessibilityTextError.unsupportedAttribute {
            return nil
        } catch AccessibilityTextError.axFailure(_, let code)
            where code == .noValue {
            return nil
        }
    }

    func string(
        for range: NSRange,
        in element: AccessibilityElementReference
    ) throws -> String? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else {
            throw AccessibilityTextError.invalidUTF16Range
        }

        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            axElement(element),
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &value
        )
        if error == .parameterizedAttributeUnsupported
            || error == .attributeUnsupported
            || error == .noValue
        {
            return nil
        }
        try check(error, operation: "read string for text range")
        guard let value else {
            throw AccessibilityTextError.invalidAttributeValue(
                kAXStringForRangeParameterizedAttribute
            )
        }
        if let string = value as? String {
            return string
        }
        if let attributedString = value as? NSAttributedString {
            return attributedString.string
        }
        throw AccessibilityTextError.invalidAttributeValue(
            kAXStringForRangeParameterizedAttribute
        )
    }

    func selectedTextRange(of element: AccessibilityElementReference) throws -> NSRange {
        let value = try copyAttribute(
            kAXSelectedTextRangeAttribute,
            from: element,
            operation: "read selected text range"
        )
        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            throw AccessibilityTextError.invalidAttributeValue(
                kAXSelectedTextRangeAttribute
            )
        }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else {
            throw AccessibilityTextError.invalidAttributeValue(
                kAXSelectedTextRangeAttribute
            )
        }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            throw AccessibilityTextError.invalidAttributeValue(
                kAXSelectedTextRangeAttribute
            )
        }
        return NSRange(location: range.location, length: range.length)
    }

    func bounds(
        for range: NSRange,
        in element: AccessibilityElementReference
    ) throws -> CGRect? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else {
            throw AccessibilityTextError.invalidAttributeValue(
                kAXBoundsForRangeParameterizedAttribute
            )
        }

        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            axElement(element),
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &value
        )
        if error == .parameterizedAttributeUnsupported
            || error == .attributeUnsupported
            || error == .noValue
            || error == .notEnoughPrecision
        {
            return nil
        }
        try check(error, operation: "read bounds for text range")
        guard
            let value,
            CFGetTypeID(value) == AXValueGetTypeID()
        else {
            throw AccessibilityTextError.invalidAttributeValue(
                kAXBoundsForRangeParameterizedAttribute
            )
        }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgRect else {
            throw AccessibilityTextError.invalidAttributeValue(
                kAXBoundsForRangeParameterizedAttribute
            )
        }
        var rectangle = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rectangle) else {
            throw AccessibilityTextError.invalidAttributeValue(
                kAXBoundsForRangeParameterizedAttribute
            )
        }
        return rectangle
    }

    func textMarkerBoundsBeforeSelection(
        in element: AccessibilityElementReference
    ) throws -> CGRect? {
        let selectedMarkerRangeValue: CFTypeRef
        do {
            selectedMarkerRangeValue = try copyAttribute(
                kAXSelectedTextMarkerRangeAttribute,
                from: element,
                operation: "read selected text marker range"
            )
        } catch AccessibilityTextError.unsupportedAttribute {
            return nil
        } catch AccessibilityTextError.axFailure(_, let code)
            where code == .noValue {
            return nil
        }
        guard
            CFGetTypeID(selectedMarkerRangeValue)
                == AXTextMarkerRangeGetTypeID()
        else {
            throw AccessibilityTextError.invalidAttributeValue(
                kAXSelectedTextMarkerRangeAttribute
            )
        }

        let selectedMarkerRange =
            selectedMarkerRangeValue as! AXTextMarkerRange
        let selectionEndMarker = AXTextMarkerRangeCopyEndMarker(
            selectedMarkerRange
        )

        var previousMarkerValue: CFTypeRef?
        let previousMarkerError =
            AXUIElementCopyParameterizedAttributeValue(
                axElement(element),
                kAXPreviousTextMarkerForTextMarkerParameterizedAttribute
                    as CFString,
                selectionEndMarker,
                &previousMarkerValue
            )
        if previousMarkerError == .parameterizedAttributeUnsupported
            || previousMarkerError == .attributeUnsupported
            || previousMarkerError == .noValue
            || previousMarkerError == .notEnoughPrecision
        {
            return nil
        }
        try check(
            previousMarkerError,
            operation: "read text marker before selection"
        )
        guard
            let previousMarkerValue,
            CFGetTypeID(previousMarkerValue) == AXTextMarkerGetTypeID()
        else {
            throw AccessibilityTextError.invalidAttributeValue(
                kAXPreviousTextMarkerForTextMarkerParameterizedAttribute
            )
        }

        let previousMarker = previousMarkerValue as! AXTextMarker
        let characterMarkerRange = AXTextMarkerRangeCreate(
            nil,
            previousMarker,
            selectionEndMarker
        )

        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            axElement(element),
            kAXBoundsForTextMarkerRangeParameterizedAttribute as CFString,
            characterMarkerRange,
            &value
        )
        if error == .parameterizedAttributeUnsupported
            || error == .attributeUnsupported
            || error == .noValue
            || error == .notEnoughPrecision
        {
            return nil
        }
        try check(error, operation: "read text marker bounds before selection")
        guard
            let value,
            CFGetTypeID(value) == AXValueGetTypeID()
        else {
            throw AccessibilityTextError.invalidAttributeValue(
                kAXBoundsForTextMarkerRangeParameterizedAttribute
            )
        }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgRect else {
            throw AccessibilityTextError.invalidAttributeValue(
                kAXBoundsForTextMarkerRangeParameterizedAttribute
            )
        }
        var rectangle = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rectangle) else {
            throw AccessibilityTextError.invalidAttributeValue(
                kAXBoundsForTextMarkerRangeParameterizedAttribute
            )
        }
        return rectangle
    }

    func subrole(of element: AccessibilityElementReference) throws -> String? {
        do {
            let value = try copyAttribute(
                kAXSubroleAttribute,
                from: element,
                operation: "read text target subrole"
            )
            guard let subrole = value as? String else {
                throw AccessibilityTextError.invalidAttributeValue(
                    kAXSubroleAttribute
                )
            }
            return subrole
        } catch AccessibilityTextError.unsupportedAttribute(let attribute)
            where attribute == kAXSubroleAttribute {
            return nil
        } catch AccessibilityTextError.axFailure(_, let code)
            where code == .attributeUnsupported
                || code == .noValue {
            return nil
        }
    }

    func isAttributeSettable(
        _ attribute: String,
        in element: AccessibilityElementReference
    ) throws -> Bool {
        var settable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(
            axElement(element),
            attribute as CFString,
            &settable
        )
        if error == .attributeUnsupported || error == .noValue {
            return false
        }
        try check(error, operation: "check whether \(attribute) is settable")
        return settable.boolValue
    }

    func setSelectedTextRange(
        _ range: NSRange,
        in element: AccessibilityElementReference
    ) throws {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else {
            throw AccessibilityTextError.invalidUTF16Range
        }
        try check(
            AXUIElementSetAttributeValue(
                axElement(element),
                kAXSelectedTextRangeAttribute as CFString,
                value
            ),
            operation: "set selected text range"
        )
    }

    func setSelectedText(
        _ text: String,
        in element: AccessibilityElementReference
    ) throws {
        try check(
            AXUIElementSetAttributeValue(
                axElement(element),
                kAXSelectedTextAttribute as CFString,
                text as CFString
            ),
            operation: "replace selected text"
        )
    }

    private func copyAttribute(
        _ attribute: String,
        from element: AccessibilityElementReference,
        operation: String
    ) throws -> CFTypeRef {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            axElement(element),
            attribute as CFString,
            &value
        )
        if error == .attributeUnsupported {
            throw AccessibilityTextError.unsupportedAttribute(attribute)
        }
        try check(error, operation: operation)
        guard let value else {
            throw AccessibilityTextError.invalidAttributeValue(attribute)
        }
        return value
    }

    private func axElement(_ reference: AccessibilityElementReference) -> AXUIElement {
        reference.rawValue as! AXUIElement
    }

    private func check(_ error: AXError, operation: String) throws {
        guard error == .success else {
            throw AccessibilityTextError.axFailure(
                operation: operation,
                code: error
            )
        }
    }
}

final class AccessibilityTextAdapter {
    static let defaultMaximumFallbackDocumentLength = 4_096
    static let maximumShortcodeContextLength = 66
    private static let maximumApproximateCaretHeight: CGFloat = 256

    private let system: AccessibilityTextSystem
    private let maximumFallbackDocumentLength: Int

    init(
        system: AccessibilityTextSystem = MacAccessibilityTextSystem(),
        maximumFallbackDocumentLength: Int =
            AccessibilityTextAdapter.defaultMaximumFallbackDocumentLength
    ) {
        self.system = system
        self.maximumFallbackDocumentLength = max(
            0,
            maximumFallbackDocumentLength
        )
    }

    func focusedTarget() throws -> AccessibilityTextTarget {
        let element = try system.focusedElement()
        return AccessibilityTextTarget(
            element: element,
            processIdentifier: try system.processIdentifier(of: element)
        )
    }

    func context(
        for target: AccessibilityTextTarget,
        trigger: Character = ":",
        locateShortcodeToken: Bool = true
    ) throws -> AccessibilityTextContext {
        try rejectSecureTarget(target)
        let selection = try system.selectedTextRange(of: target.element)
        guard selection.location != NSNotFound, selection.location >= 0 else {
            throw AccessibilityTextError.invalidUTF16Range
        }

        let caretBounds = try caretBounds(
            for: selection,
            in: target.element
        )
        let fragment: String
        let fragmentRange: NSRange
        let tokenRange: NSRange?
        if
            locateShortcodeToken,
            selection.length <= Self.maximumShortcodeContextLength,
            selection.length <= Int.max - selection.location
        {
            let selectionEnd = selection.location + selection.length
            let fragmentStart = max(
                0,
                selection.location - Self.maximumShortcodeContextLength
            )
            let fragmentEnd = try boundedShortcodeFragmentEnd(
                after: selectionEnd,
                in: target.element
            )
            guard fragmentEnd >= fragmentStart else {
                throw AccessibilityTextError.invalidUTF16Range
            }
            let requestedFragmentRange = NSRange(
                location: fragmentStart,
                length: fragmentEnd - fragmentStart
            )
            let boundedFragment = try scalarAlignedTextFragment(
                requestedRange: requestedFragmentRange,
                containing: selection,
                in: target.element
            )
            fragmentRange = boundedFragment.range
            fragment = boundedFragment.text
            if let localRange = Self.shortcodeTokenRange(
                in: fragment,
                selection: NSRange(
                    location: selection.location - fragmentRange.location,
                    length: selection.length
                ),
                trigger: trigger
            ) {
                tokenRange = NSRange(
                    location: fragmentRange.location + localRange.location,
                    length: localRange.length
                )
            } else {
                tokenRange = nil
            }
        } else {
            fragment = ""
            fragmentRange = NSRange(
                location: selection.location,
                length: 0
            )
            tokenRange = nil
        }

        return AccessibilityTextContext(
            selection: selection,
            caretBounds: caretBounds,
            textFragment: fragment,
            textFragmentRange: fragmentRange,
            tokenRange: tokenRange
        )
    }

    func replaceUnicode(
        _ replacement: String,
        request: AccessibilityReplacementRequest
    ) throws {
        let currentElement = try validateCurrentElement(for: request)
        guard
            try system.isAttributeSettable(
                kAXSelectedTextRangeAttribute,
                in: currentElement
            ),
            try system.isAttributeSettable(
                kAXSelectedTextAttribute,
                in: currentElement
            )
        else {
            throw AccessibilityTextError.unsupportedAttribute(
                kAXSelectedTextAttribute
            )
        }

        try system.setSelectedTextRange(request.tokenRange, in: currentElement)
        do {
            try system.setSelectedText(replacement, in: currentElement)
        } catch {
            try? system.setSelectedTextRange(
                request.expectedSelection,
                in: currentElement
            )
            throw error
        }
    }

    /// Revalidates focus, selection, and the exact token immediately before a
    /// media/clipboard insertion, then selects precisely that token.
    func selectValidatedToken(
        for request: AccessibilityReplacementRequest
    ) throws {
        let currentElement = try validateCurrentElement(for: request)
        guard
            try system.isAttributeSettable(
                kAXSelectedTextRangeAttribute,
                in: currentElement
            )
        else {
            throw AccessibilityTextError.unsupportedAttribute(
                kAXSelectedTextRangeAttribute
            )
        }
        try system.setSelectedTextRange(request.tokenRange, in: currentElement)
    }

    /// Best-effort cleanup when event creation/posting fails after selection.
    func restoreExpectedSelection(
        for request: AccessibilityReplacementRequest
    ) {
        guard
            let currentElement = try? system.focusedElement(),
            (try? system.processIdentifier(of: currentElement))
                == request.target.processIdentifier,
            system.elementsAreEqual(currentElement, request.target.element)
        else {
            return
        }
        try? system.setSelectedTextRange(
            request.expectedSelection,
            in: currentElement
        )
    }

    func isFocused(_ target: AccessibilityTextTarget) -> Bool {
        guard
            let currentElement = try? system.focusedElement(),
            (try? system.processIdentifier(of: currentElement))
                == target.processIdentifier
        else {
            return false
        }
        return system.elementsAreEqual(currentElement, target.element)
    }

    func representsSameTarget(
        _ lhs: AccessibilityTextTarget,
        _ rhs: AccessibilityTextTarget
    ) -> Bool {
        lhs.processIdentifier == rhs.processIdentifier
            && system.elementsAreEqual(lhs.element, rhs.element)
    }

    func insertionWasAcknowledged(
        for request: AccessibilityReplacementRequest
    ) -> Bool {
        guard
            let currentElement = try? system.focusedElement(),
            (try? system.processIdentifier(of: currentElement))
                == request.target.processIdentifier,
            system.elementsAreEqual(
                currentElement,
                request.target.element
            ),
            let selection = try? system.selectedTextRange(
                of: currentElement
            )
        else {
            return false
        }

        let isZeroLengthInsertion =
            request.tokenRange.length == 0
                && request.expectedToken.isEmpty
        if isZeroLengthInsertion {
            return selection.length == 0
                && selection.location > request.tokenRange.location
        }

        do {
            if
                let currentToken = try system.string(
                    for: request.tokenRange,
                    in: currentElement
                )
            {
                return currentToken != request.expectedToken
            }
        } catch AccessibilityTextError.invalidUTF16Range {
            return selection.length == 0
        } catch {
            // Some rich text fields do not expose ranged strings after a
            // paste.
        }

        let nearbyUpperBound = request.expectedSelection.location + 2
        return selection.length == 0
            && selection != request.tokenRange
            && selection.location >= request.tokenRange.location
            && selection.location <= nearbyUpperBound
    }

    func secureStatus(of target: AccessibilityTextTarget) throws -> Bool {
        try subrole(of: target) == kAXSecureTextFieldSubrole
    }

    static func validate(_ range: NSRange, in string: String) throws {
        let utf16 = string.utf16
        guard
            range.location != NSNotFound,
            range.location >= 0,
            range.length >= 0,
            range.location <= utf16.count,
            range.length <= utf16.count - range.location
        else {
            throw AccessibilityTextError.invalidUTF16Range
        }

        let utf16Start = utf16.index(
            utf16.startIndex,
            offsetBy: range.location
        )
        let utf16End = utf16.index(utf16Start, offsetBy: range.length)
        guard
            String.Index(utf16Start, within: string) != nil,
            String.Index(utf16End, within: string) != nil
        else {
            throw AccessibilityTextError.invalidUTF16Range
        }
    }

    /// Returns the active `:shortcode` or complete `:shortcode:` surrounding a
    /// collapsed caret or wholly-contained selection. The returned locations
    /// are UTF-16 offsets, matching AX APIs.
    static func shortcodeTokenRange(
        in string: String,
        selection: NSRange,
        trigger: Character = ":"
    ) -> NSRange? {
        guard (try? validate(selection, in: string)) != nil else {
            return nil
        }

        let utf16 = string as NSString
        guard trigger.utf16.count == 1, let trigger = trigger.utf16.first else {
            return nil
        }
        let selectionEnd = selection.location + selection.length
        if selection.length == 0,
           selection.location > 0,
           utf16.character(at: selection.location - 1) == trigger,
           selection.location > 1,
           (
               utf16.character(at: selection.location - 2) == trigger
                   || isShortcodeCharacter(
                       utf16.character(at: selection.location - 2)
                   )
           ) {
            let closingTriggerLocation = selection.location - 1
            var candidateStart = closingTriggerLocation
            while candidateStart > 0,
                  isShortcodeCharacter(
                      utf16.character(at: candidateStart - 1)
                  ) {
                candidateStart -= 1
            }
            let range: NSRange
            if candidateStart > 0,
               utf16.character(at: candidateStart - 1) == trigger {
                range = NSRange(
                    location: candidateStart - 1,
                    length: selection.location - candidateStart + 1
                )
            } else {
                range = NSRange(
                    location: closingTriggerLocation,
                    length: 1
                )
            }
            return hasValidShortcodeBoundaries(range, in: utf16)
                ? range
                : nil
        }

        let start: Int
        if
            selection.length > 0,
            selection.location < utf16.length,
            utf16.character(at: selection.location) == trigger
        {
            start = selection.location
        } else {
            var candidateStart = selection.location
            while candidateStart > 0 {
                let character = utf16.character(at: candidateStart - 1)
                if character == trigger {
                    candidateStart -= 1
                    break
                }
                guard isShortcodeCharacter(character) else {
                    return nil
                }
                candidateStart -= 1
            }

            guard
                candidateStart < selection.location,
                utf16.character(at: candidateStart) == trigger
            else {
                return nil
            }
            start = candidateStart
        }

        var selectedCharacterLocation = start + 1
        while selectedCharacterLocation < selectionEnd {
            let character = utf16.character(at: selectedCharacterLocation)
            guard isShortcodeCharacter(character) else {
                return nil
            }
            selectedCharacterLocation += 1
        }

        var end = selectionEnd
        while end < utf16.length,
              isShortcodeCharacter(utf16.character(at: end)) {
            end += 1
        }
        if end < utf16.length,
           utf16.character(at: end) == trigger {
            end += 1
        }
        let range = NSRange(location: start, length: end - start)
        return hasValidShortcodeBoundaries(range, in: utf16)
            ? range
            : nil
    }

    private static func hasValidShortcodeBoundaries(
        _ range: NSRange,
        in string: NSString
    ) -> Bool {
        if
            range.location > 0,
            isShortcodeCharacter(
                string.character(at: range.location - 1)
            )
        {
            return false
        }

        let end = range.location + range.length
        if
            end < string.length,
            isShortcodeCharacter(string.character(at: end))
        {
            return false
        }
        return true
    }

    private static func isShortcodeCharacter(_ character: unichar) -> Bool {
        switch character {
        case 48 ... 57, 65 ... 90, 97 ... 122:
            true
        case Character("_").utf16.first,
             Character("+").utf16.first,
             Character("-").utf16.first:
            true
        default:
            false
        }
    }

    private func boundedShortcodeFragmentEnd(
        after selectionEnd: Int,
        in element: AccessibilityElementReference
    ) throws -> Int {
        let characterCount: Int?
        do {
            characterCount = try system.numberOfCharacters(in: element)
        } catch AccessibilityTextError.axFailure(_, let code)
            where code == .noValue {
            characterCount = nil
        }
        guard let characterCount else {
            var fragmentEnd = selectionEnd
            while
                fragmentEnd - selectionEnd
                    < Self.maximumShortcodeContextLength
            {
                let nextCharacter: String?
                do {
                    nextCharacter = try system.string(
                        for: NSRange(location: fragmentEnd, length: 1),
                        in: element
                    )
                } catch AccessibilityTextError.invalidUTF16Range {
                    return fragmentEnd
                } catch AccessibilityTextError.axFailure(_, let code)
                    where code == .illegalArgument || code == .noValue {
                    return fragmentEnd
                }
                guard
                    let nextCharacter,
                    nextCharacter.utf16.count == 1,
                    let codeUnit = nextCharacter.utf16.first
                else {
                    return fragmentEnd
                }
                fragmentEnd += 1
                if !Self.isShortcodeCharacter(codeUnit) {
                    return fragmentEnd
                }
            }
            return fragmentEnd
        }
        guard selectionEnd <= characterCount else {
            throw AccessibilityTextError.invalidUTF16Range
        }
        return selectionEnd + min(
            characterCount - selectionEnd,
            Self.maximumShortcodeContextLength
        )
    }

    /// AX ranges use UTF-16 offsets. A bounded window endpoint can land
    /// between a surrogate pair even when the editor's selection is valid, so
    /// retry the four possible one-unit endpoint alignments before failing.
    private func scalarAlignedTextFragment(
        requestedRange: NSRange,
        containing selection: NSRange,
        in element: AccessibilityElementReference
    ) throws -> (text: String, range: NSRange) {
        let selectionEnd = selection.location + selection.length
        var candidates = [requestedRange]
        if requestedRange.length > 0 {
            candidates.append(
                NSRange(
                location: requestedRange.location + 1,
                    length: requestedRange.length - 1
                )
            )
            candidates.append(
                NSRange(
                    location: requestedRange.location,
                    length: requestedRange.length - 1
                )
            )
        }
        if requestedRange.length > 1 {
            candidates.append(
                NSRange(
                    location: requestedRange.location + 1,
                    length: requestedRange.length - 2
                )
            )
        }
        var lastRangeError: AccessibilityTextError?
        for candidate in candidates where
            candidate.location <= selection.location
                && candidate.location + candidate.length >= selectionEnd
        {
            do {
                return (
                    try text(in: candidate, from: element),
                    candidate
                )
            } catch let error as AccessibilityTextError {
                switch error {
                case .invalidUTF16Range:
                    lastRangeError = error
                case .axFailure(_, let code) where code == .illegalArgument:
                    lastRangeError = error
                default:
                    throw error
                }
            }
        }
        throw lastRangeError ?? AccessibilityTextError.invalidUTF16Range
    }

    private func rejectSecureTarget(_ target: AccessibilityTextTarget) throws {
        if try subrole(of: target) == kAXSecureTextFieldSubrole {
            throw AccessibilityTextError.secureTextField
        }
    }

    private func subrole(of target: AccessibilityTextTarget) throws -> String? {
        do {
            return try system.subrole(of: target.element)
        } catch AccessibilityTextError.unsupportedAttribute(let attribute)
            where attribute == kAXSubroleAttribute {
            // AXSubrole is optional on ordinary editable controls, including
            // the Messages composer. Its absence proves only that the control
            // has no specialized subrole; it is not an unknown security state.
            return nil
        } catch AccessibilityTextError.axFailure(_, let code)
            where code == .attributeUnsupported
                || code == .noValue {
            return nil
        }
    }

    private func caretBounds(
        for selection: NSRange,
        in element: AccessibilityElementReference
    ) throws -> CGRect? {
        let collapsedRange = NSRange(
            location: selection.location,
            length: 0
        )
        if let bounds = try optionalBounds(
            for: collapsedRange,
            in: element
        ), Self.isUsableCaretGeometry(bounds) {
            return bounds
        }

        guard selection.length == 0, selection.location > 0 else {
            return nil
        }

        let previousCharacterRange = NSRange(
            location: selection.location - 1,
            length: 1
        )
        if
            let previousBounds = try optionalBounds(
                for: previousCharacterRange,
                in: element
            ),
            Self.isUsableCaretGeometry(previousBounds)
        {
            return Self.caretAfter(previousBounds)
        }

        guard
            let markerBounds = try system.textMarkerBoundsBeforeSelection(
                in: element
            ),
            let markerCaret = Self.caretFromTextMarkerBounds(markerBounds)
        else {
            return nil
        }
        return markerCaret
    }

    private func optionalBounds(
        for range: NSRange,
        in element: AccessibilityElementReference
    ) throws -> CGRect? {
        do {
            return try system.bounds(for: range, in: element)
        } catch AccessibilityTextError.axFailure(_, let code)
            where code == .noValue
                || code == .notEnoughPrecision {
            return nil
        }
    }

    private static func isUsableCaretGeometry(_ bounds: CGRect) -> Bool {
        bounds.origin.x.isFinite
            && bounds.origin.y.isFinite
            && bounds.width.isFinite
            && bounds.height.isFinite
            && bounds.width >= 0
            && bounds.height > 0
    }

    private static func caretFromTextMarkerBounds(
        _ bounds: CGRect
    ) -> CGRect? {
        guard
            isUsableCaretGeometry(bounds),
            bounds.height <= maximumApproximateCaretHeight
        else {
            return nil
        }
        if bounds.width <= max(1, bounds.height * 2) {
            return caretAfter(bounds)
        }

        // Chromium can return the entire editable composer for a one-character
        // marker range. Its leading edge is a stable approximate anchor and is
        // preferable to suppressing autocomplete or clamping it to the screen.
        return CGRect(
            x: bounds.minX,
            y: bounds.minY,
            width: 0,
            height: bounds.height
        )
    }

    private static func caretAfter(_ bounds: CGRect) -> CGRect {
        CGRect(
            x: bounds.maxX,
            y: bounds.minY,
            width: 0,
            height: bounds.height
        )
    }

    private func validateCurrentElement(
        for request: AccessibilityReplacementRequest
    ) throws -> AccessibilityElementReference {
        let currentElement = try system.focusedElement()
        let currentProcessIdentifier = try system.processIdentifier(of: currentElement)
        guard
            currentProcessIdentifier == request.target.processIdentifier,
            system.elementsAreEqual(currentElement, request.target.element)
        else {
            throw AccessibilityTextError.staleTarget
        }

        let currentTarget = AccessibilityTextTarget(
            element: currentElement,
            processIdentifier: currentProcessIdentifier
        )
        try rejectSecureTarget(currentTarget)

        let selection = try system.selectedTextRange(of: currentElement)
        guard selection == request.expectedSelection else {
            throw AccessibilityTextError.staleSelection
        }
        guard
            selection.length == 0,
            request.tokenRange.location != NSNotFound,
            request.tokenRange.location >= 0,
            request.tokenRange.length >= 0,
            request.tokenRange.location <= selection.location,
            request.tokenRange.length
                == selection.location - request.tokenRange.location
        else {
            throw AccessibilityTextError.invalidUTF16Range
        }

        let token = try text(in: request.tokenRange, from: currentElement)
        guard token == request.expectedToken else {
            throw AccessibilityTextError.tokenChanged
        }
        return currentElement
    }

    private func text(
        in range: NSRange,
        from element: AccessibilityElementReference
    ) throws -> String {
        let rangedString: String?
        do {
            rangedString = try system.string(for: range, in: element)
        } catch AccessibilityTextError.axFailure(_, let code)
            where code == .noValue {
            rangedString = nil
        }
        if let rangedString {
            guard rangedString.utf16.count == range.length else {
                throw AccessibilityTextError.invalidAttributeValue(
                    kAXStringForRangeParameterizedAttribute
                )
            }
            return rangedString
        }

        // Some controls do not implement AXStringForRange. Only fall back to
        // AXValue after proving the control is small, avoiding full-document
        // reads from browsers, editors, and message histories.
        let characterCount: Int?
        do {
            characterCount = try system.numberOfCharacters(in: element)
        } catch AccessibilityTextError.axFailure(_, let code)
            where code == .noValue {
            characterCount = nil
        }
        guard
            let characterCount,
            characterCount <= maximumFallbackDocumentLength
        else {
            throw AccessibilityTextError.unsupportedAttribute(
                kAXStringForRangeParameterizedAttribute
            )
        }
        let value = try system.value(of: element)
        guard value.utf16.count == characterCount else {
            throw AccessibilityTextError.invalidAttributeValue(kAXValueAttribute)
        }
        try Self.validate(range, in: value)
        return (value as NSString).substring(with: range)
    }
}
