import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

struct RuntimePermissionPreflight: Equatable, Sendable {
    let inputMonitoringGranted: Bool
    let accessibilityGranted: Bool
    let eventPostingGranted: Bool

    init(
        inputMonitoringGranted: Bool,
        accessibilityGranted: Bool,
        eventPostingGranted: Bool = false
    ) {
        self.inputMonitoringGranted = inputMonitoringGranted
        self.accessibilityGranted = accessibilityGranted
        self.eventPostingGranted = eventPostingGranted
    }

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
            accessibilityGranted: AXIsProcessTrusted(),
            eventPostingGranted: CGPreflightPostEventAccess()
        )
    }
}

/// Keeps permission state available to the runtime worker without repeatedly
/// calling macOS privacy preflight APIs while the user is typing.
final class CachedRuntimePermissionChecker:
    RuntimePermissionChecking,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var permissions: RuntimePermissionPreflight

    init(
        permissions: RuntimePermissionPreflight =
            RuntimePermissionPreflight(
                inputMonitoringGranted: false,
                accessibilityGranted: false
            )
    ) {
        self.permissions = permissions
    }

    func update(_ permissions: RuntimePermissionPreflight) {
        lock.withLock {
            self.permissions = permissions
        }
    }

    func currentPermissions() -> RuntimePermissionPreflight {
        lock.withLock {
            permissions
        }
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
    /// `nil` means no supported browser domain could be proven via AX.
    let domain: String?

    init(
        permissions: RuntimePermissionPreflight,
        secureEventInputEnabled: Bool,
        focusedElementIsSecure: Bool?,
        bundleIdentifier: String?,
        domain: String? = nil
    ) {
        self.permissions = permissions
        self.secureEventInputEnabled = secureEventInputEnabled
        self.focusedElementIsSecure = focusedElementIsSecure
        self.bundleIdentifier = bundleIdentifier
        self.domain = domain
    }
}

enum RuntimeSessionDenial: Error, Equatable, Sendable {
    case permissionUnavailable
    case secureEventInput
    case secureField
    case secureStatusUnknown
    case applicationUnknown
    case domainUnknown(String)
    case excludedApplication(String)
    case excludedDomain(String)
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
        switch exclusions.match(
            bundleIdentifier: bundleIdentifier,
            domain: input.domain
        ) {
        case let .application(exclusion):
            return .excludedApplication(exclusion.bundleIdentifier)
        case let .domain(exclusion):
            return .excludedDomain(exclusion.domain)
        case nil:
            return nil
        }
    }
}

struct RuntimeTextCapture: @unchecked Sendable {
    let target: AccessibilityTextTarget
    let context: AccessibilityTextContext
    let bundleIdentifier: String?

    init(
        target: AccessibilityTextTarget,
        context: AccessibilityTextContext,
        bundleIdentifier: String? = nil
    ) {
        self.target = target
        self.context = context
        self.bundleIdentifier = bundleIdentifier
    }

    /// The exact token ending at the captured caret, if the context contains
    /// one. Token ranges are absolute AX offsets while text fragments are
    /// bounded local strings, so keep that conversion in one checked place.
    var token: String? {
        guard
            context.selection.length == 0,
            let tokenRange = context.tokenRange,
            tokenRange.length > 0,
            tokenRange.location + tokenRange.length
                == context.selection.location,
            tokenRange.location >= context.textFragmentRange.location
        else {
            return nil
        }
        let localRange = NSRange(
            location:
                tokenRange.location
                    - context.textFragmentRange.location,
            length: tokenRange.length
        )
        guard
            (try? AccessibilityTextAdapter.validate(
                localRange,
                in: context.textFragment
            )) != nil
        else {
            return nil
        }
        return (context.textFragment as NSString).substring(
            with: localRange
        )
    }
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
    func captureCurrentToken(
        trigger: Character
    ) throws -> RuntimeTextCapture
    func updateExclusions(_ exclusions: ExclusionPreferences)
}

extension RuntimeTextContextCapturing {
    func captureCurrentToken(
        trigger: Character
    ) throws -> RuntimeTextCapture {
        _ = trigger
        throw RuntimeTextCaptureError.invalidTokenContext
    }

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
    private let browserDomainProvider: any BrowserDomainProviding
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
        browserDomainProvider: any BrowserDomainProviding =
            AXBrowserDomainProvider(),
        exclusions: ExclusionPreferences = .defaults
    ) {
        self.accessibility = accessibility
        self.permissionChecker = permissionChecker
        self.secureInputChecker = secureInputChecker
        self.applicationIdentity = applicationIdentity
        self.browserDomainProvider = browserDomainProvider
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
        let capture = try captureContext(
            trigger: trigger,
            locateShortcodeToken: !expectedToken.isEmpty
        )
        let context = expectedToken.isEmpty
            ? try Self.caretContext(capture.context)
            : capture.context

        guard Self.context(context, containsExactly: expectedToken) else {
            throw RuntimeTextCaptureError.invalidTokenContext
        }
        return RuntimeTextCapture(
            target: capture.target,
            context: context,
            bundleIdentifier: capture.bundleIdentifier
        )
    }

    func captureCurrentToken(
        trigger: Character
    ) throws -> RuntimeTextCapture {
        guard trigger.utf16.count == 1 else {
            throw RuntimeTextCaptureError.invalidTokenContext
        }
        let capture = try captureContext(
            trigger: trigger,
            locateShortcodeToken: true
        )
        guard
            let token = capture.token,
            token.first == trigger,
            token.count == 1 || token.last != trigger
        else {
            throw RuntimeTextCaptureError.invalidTokenContext
        }
        let query = String(token.dropFirst())
        guard
            query.isEmpty || EmojiAliasSyntax.isValidToken(query)
        else {
            throw RuntimeTextCaptureError.invalidTokenContext
        }
        return capture
    }

    private func captureContext(
        trigger: Character,
        locateShortcodeToken: Bool
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
        let safetyInput = RuntimeSessionSafetyInput(
            permissions: permissions,
            secureEventInputEnabled: false,
            focusedElementIsSecure: secureStatus,
            bundleIdentifier: bundleIdentifier
        )
        if let denial = policy.evaluate(safetyInput) {
            throw RuntimeTextCaptureError.denied(denial)
        }

        let domain: String?
        if policy.exclusions.domains.isEmpty {
            domain = nil
        } else if let bundleIdentifier {
            if AXBrowserDomainProvider.supportsDomainLookup(
                for: bundleIdentifier
            ) {
                do {
                    guard let verifiedDomain = try browserDomainProvider.host(
                        for: bundleIdentifier,
                        processIdentifier: target.processIdentifier
                    ) else {
                        throw RuntimeTextCaptureError.denied(
                            .domainUnknown(bundleIdentifier)
                        )
                    }
                    domain = verifiedDomain
                } catch let error as RuntimeTextCaptureError {
                    throw error
                } catch {
                    throw RuntimeTextCaptureError.denied(
                        .domainUnknown(bundleIdentifier)
                    )
                }
            } else {
                domain = nil
            }
        } else {
            domain = nil
        }
        if let denial = policy.evaluate(
            RuntimeSessionSafetyInput(
                permissions: safetyInput.permissions,
                secureEventInputEnabled:
                    safetyInput.secureEventInputEnabled,
                focusedElementIsSecure:
                    safetyInput.focusedElementIsSecure,
                bundleIdentifier: safetyInput.bundleIdentifier,
                domain: domain
            )
        ) {
            throw RuntimeTextCaptureError.denied(denial)
        }

        let context: AccessibilityTextContext
        do {
            context = try accessibility.context(
                for: target,
                trigger: trigger,
                locateShortcodeToken: locateShortcodeToken
            )
        } catch AccessibilityTextError.secureTextField {
            throw RuntimeTextCaptureError.denied(.secureField)
        } catch {
            throw RuntimeTextCaptureError.inaccessibleTarget
        }

        return RuntimeTextCapture(
            target: target,
            context: context,
            bundleIdentifier: bundleIdentifier
        )
    }

    private static func caretContext(
        _ context: AccessibilityTextContext
    ) throws -> AccessibilityTextContext {
        guard
            context.selection.length == 0,
            context.caretBounds != nil
        else {
            throw RuntimeTextCaptureError.invalidTokenContext
        }
        return AccessibilityTextContext(
            selection: context.selection,
            caretBounds: context.caretBounds,
            textFragment: context.textFragment,
            textFragmentRange: NSRange(
                location: context.selection.location,
                length: 0
            ),
            tokenRange: NSRange(
                location: context.selection.location,
                length: 0
            )
        )
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
