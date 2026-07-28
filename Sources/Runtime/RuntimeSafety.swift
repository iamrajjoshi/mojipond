import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

struct RuntimePermissionPreflight: Equatable, Sendable {
    let inputMonitoringGranted: Bool
    let accessibilityGranted: Bool

    var canMonitorTyping: Bool {
        inputMonitoringGranted && accessibilityGranted
    }
}

protocol RuntimePermissionChecking: Sendable {
    func currentPermissions() -> RuntimePermissionPreflight
}

struct MacRuntimePermissionChecker: RuntimePermissionChecking {
    func currentPermissions() -> RuntimePermissionPreflight {
        RuntimePermissionPreflight(
            inputMonitoringGranted: CGPreflightListenEventAccess(),
            accessibilityGranted: AXIsProcessTrusted()
        )
    }
}

protocol RuntimeSecureInputChecking: Sendable {
    var secureEventInputEnabled: Bool { get }
}

struct MacRuntimeSecureInputChecker: RuntimeSecureInputChecking {
    var secureEventInputEnabled: Bool {
        IsSecureEventInputEnabled()
    }
}

protocol RuntimeApplicationIdentityProviding: Sendable {
    func bundleIdentifier(for processIdentifier: pid_t) -> String?
}

struct MacRuntimeApplicationIdentityProvider: RuntimeApplicationIdentityProviding {
    func bundleIdentifier(for processIdentifier: pid_t) -> String? {
        NSRunningApplication(processIdentifier: processIdentifier)?
            .bundleIdentifier
    }
}

struct RuntimeSessionSafetyInput: Equatable, Sendable {
    let permissions: RuntimePermissionPreflight
    let secureEventInputEnabled: Bool
    /// `nil` means AX could not prove whether the focused element is secure.
    let focusedElementIsSecure: Bool?
    /// `nil` means the target process could not be mapped to a stable app ID.
    let bundleIdentifier: String?
}

enum RuntimeSessionDenial: Error, Equatable, Sendable {
    case permissionUnavailable
    case secureEventInput
    case secureField
    case secureStatusUnknown
    case applicationUnknown
    case excludedApplication(String)
}

struct RuntimeSessionSafetyPolicy: Sendable {
    var exclusions: ExclusionPreferences

    init(exclusions: ExclusionPreferences = .defaults) {
        self.exclusions = exclusions
    }

    func evaluate(_ input: RuntimeSessionSafetyInput) -> RuntimeSessionDenial? {
        guard input.permissions.canMonitorTyping else {
            return .permissionUnavailable
        }
        guard !input.secureEventInputEnabled else {
            return .secureEventInput
        }
        guard let isSecure = input.focusedElementIsSecure else {
            return .secureStatusUnknown
        }
        guard !isSecure else {
            return .secureField
        }
        guard
            let bundleIdentifier = input.bundleIdentifier?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !bundleIdentifier.isEmpty
        else {
            return .applicationUnknown
        }
        if case let .application(exclusion)? = exclusions.match(
            bundleIdentifier: bundleIdentifier,
            domain: nil
        ) {
            return .excludedApplication(exclusion.bundleIdentifier)
        }
        return nil
    }
}

struct RuntimeTextCapture: @unchecked Sendable {
    let target: AccessibilityTextTarget
    let context: AccessibilityTextContext
}

enum RuntimeTextCaptureError: Error, Equatable, Sendable {
    case denied(RuntimeSessionDenial)
    case inaccessibleTarget
    case invalidTokenContext

    var isTransient: Bool {
        switch self {
        case .inaccessibleTarget, .invalidTokenContext:
            true
        case .denied:
            false
        }
    }
}

protocol RuntimeTextContextCapturing: Sendable {
    func capture(
        expectedToken: String,
        trigger: Character
    ) throws -> RuntimeTextCapture
    func updateExclusions(_ exclusions: ExclusionPreferences)
}

extension RuntimeTextContextCapturing {
    func updateExclusions(_ exclusions: ExclusionPreferences) {
        _ = exclusions
    }
}

/// Performs the slow fail-closed checks on the serial runtime queue. It never
/// runs from the event-tap callback and never asks macOS for a permission.
final class RuntimeAccessibilityTextContextProvider:
    RuntimeTextContextCapturing,
    @unchecked Sendable
{
    private let accessibility: AccessibilityTextAdapter
    private let permissionChecker: any RuntimePermissionChecking
    private let secureInputChecker: any RuntimeSecureInputChecking
    private let applicationIdentity: any RuntimeApplicationIdentityProviding
    private var safetyPolicy: RuntimeSessionSafetyPolicy
    private let lock = NSLock()

    init(
        accessibility: AccessibilityTextAdapter,
        permissionChecker: any RuntimePermissionChecking =
            MacRuntimePermissionChecker(),
        secureInputChecker: any RuntimeSecureInputChecking =
            MacRuntimeSecureInputChecker(),
        applicationIdentity: any RuntimeApplicationIdentityProviding =
            MacRuntimeApplicationIdentityProvider(),
        exclusions: ExclusionPreferences = .defaults
    ) {
        self.accessibility = accessibility
        self.permissionChecker = permissionChecker
        self.secureInputChecker = secureInputChecker
        self.applicationIdentity = applicationIdentity
        safetyPolicy = RuntimeSessionSafetyPolicy(exclusions: exclusions)
    }

    func updateExclusions(_ exclusions: ExclusionPreferences) {
        lock.withLock {
            safetyPolicy.exclusions = exclusions
        }
    }

    func capture(
        expectedToken: String,
        trigger: Character
    ) throws -> RuntimeTextCapture {
        let permissions = permissionChecker.currentPermissions()
        guard permissions.canMonitorTyping else {
            throw RuntimeTextCaptureError.denied(.permissionUnavailable)
        }
        guard !secureInputChecker.secureEventInputEnabled else {
            throw RuntimeTextCaptureError.denied(.secureEventInput)
        }

        let target: AccessibilityTextTarget
        do {
            target = try accessibility.focusedTarget()
        } catch {
            throw RuntimeTextCaptureError.inaccessibleTarget
        }

        let secureStatus: Bool?
        do {
            secureStatus = try accessibility.secureStatus(of: target)
        } catch {
            secureStatus = nil
        }
        let bundleIdentifier = applicationIdentity.bundleIdentifier(
            for: target.processIdentifier
        )
        let policy = lock.withLock {
            safetyPolicy
        }
        if let denial = policy.evaluate(
            RuntimeSessionSafetyInput(
                permissions: permissions,
                secureEventInputEnabled: false,
                focusedElementIsSecure: secureStatus,
                bundleIdentifier: bundleIdentifier
            )
        ) {
            throw RuntimeTextCaptureError.denied(denial)
        }

        let context: AccessibilityTextContext
        do {
            context = try accessibility.context(
                for: target,
                trigger: trigger,
                locateShortcodeToken: true
            )
        } catch AccessibilityTextError.secureTextField {
            throw RuntimeTextCaptureError.denied(.secureField)
        } catch {
            throw RuntimeTextCaptureError.inaccessibleTarget
        }

        guard Self.context(context, containsExactly: expectedToken) else {
            throw RuntimeTextCaptureError.invalidTokenContext
        }
        return RuntimeTextCapture(target: target, context: context)
    }

    private static func context(
        _ context: AccessibilityTextContext,
        containsExactly expectedToken: String
    ) -> Bool {
        guard
            context.selection.length == 0,
            let tokenRange = context.tokenRange,
            tokenRange.length == expectedToken.utf16.count,
            tokenRange.location + tokenRange.length == context.selection.location,
            tokenRange.location >= context.textFragmentRange.location
        else {
            return false
        }

        let localRange = NSRange(
            location: tokenRange.location - context.textFragmentRange.location,
            length: tokenRange.length
        )
        guard
            (try? AccessibilityTextAdapter.validate(
                localRange,
                in: context.textFragment
            )) != nil
        else {
            return false
        }
        return (context.textFragment as NSString).substring(with: localRange)
            == expectedToken
    }
}

enum RuntimeReplacementRequestFactory {
    static func make(
        sessionTarget: AccessibilityTextTarget,
        capture: RuntimeTextCapture,
        expectedToken: String
    ) -> AccessibilityReplacementRequest? {
        guard
            sessionTarget.processIdentifier == capture.target.processIdentifier,
            let tokenRange = capture.context.tokenRange,
            tokenRange.length == expectedToken.utf16.count,
            tokenRange.location + tokenRange.length
                == capture.context.selection.location
        else {
            return nil
        }
        return AccessibilityReplacementRequest(
            target: sessionTarget,
            tokenRange: tokenRange,
            expectedToken: expectedToken,
            expectedSelection: capture.context.selection
        )
    }
}
