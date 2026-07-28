import ApplicationServices
import Carbon.HIToolbox
import Foundation

protocol SecureInputProviding: Sendable {
    var isSecureEventInputEnabled: Bool { get }
}

struct MacSecureInputProvider: SecureInputProviding {
    var isSecureEventInputEnabled: Bool {
        IsSecureEventInputEnabled()
    }
}

struct SecureContextStatus: Equatable, Sendable {
    let secureEventInputEnabled: Bool
    let focusedElementIsSecure: Bool
    let accessibilityStatusKnown: Bool

    var shouldSuspendCapture: Bool {
        secureEventInputEnabled
            || focusedElementIsSecure
            || !accessibilityStatusKnown
    }
}

final class SecureContextDetector {
    private let secureInput: SecureInputProviding
    private let accessibility: AccessibilityTextAdapter

    init(
        secureInput: SecureInputProviding = MacSecureInputProvider(),
        accessibility: AccessibilityTextAdapter = AccessibilityTextAdapter()
    ) {
        self.secureInput = secureInput
        self.accessibility = accessibility
    }

    func currentStatus() -> SecureContextStatus {
        let secureEventInputEnabled = secureInput.isSecureEventInputEnabled
        let focusedElementIsSecure: Bool
        let accessibilityStatusKnown: Bool
        do {
            let target = try accessibility.focusedTarget()
            focusedElementIsSecure = try accessibility.secureStatus(of: target)
            accessibilityStatusKnown = true
        } catch {
            focusedElementIsSecure = false
            accessibilityStatusKnown = false
        }

        return SecureContextStatus(
            secureEventInputEnabled: secureEventInputEnabled,
            focusedElementIsSecure: focusedElementIsSecure,
            accessibilityStatusKnown: accessibilityStatusKnown
        )
    }
}
