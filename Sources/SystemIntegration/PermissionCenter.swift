import ApplicationServices
import AppKit
import Combine
import CoreGraphics
import Foundation

enum SystemPermission: String, CaseIterable, Sendable {
    case inputMonitoring
    case accessibility
    case eventPosting
}

enum SystemPermissionStatus: String, Equatable, Sendable {
    case notRequested
    case denied
    case granted
    case revoked
}

struct SystemPermissionSnapshot: Equatable, Sendable {
    var inputMonitoring: SystemPermissionStatus
    var accessibility: SystemPermissionStatus
    var eventPosting: SystemPermissionStatus

    subscript(permission: SystemPermission) -> SystemPermissionStatus {
        switch permission {
        case .inputMonitoring:
            inputMonitoring
        case .accessibility:
            accessibility
        case .eventPosting:
            eventPosting
        }
    }
}

protocol SystemPermissionProviding {
    func isGranted(_ permission: SystemPermission) -> Bool
    func request(_ permission: SystemPermission) -> Bool
}

struct MacSystemPermissionProvider: SystemPermissionProviding {
    func isGranted(_ permission: SystemPermission) -> Bool {
        switch permission {
        case .inputMonitoring:
            CGPreflightListenEventAccess()
        case .accessibility:
            AXIsProcessTrusted()
        case .eventPosting:
            CGPreflightPostEventAccess()
        }
    }

    func request(_ permission: SystemPermission) -> Bool {
        switch permission {
        case .inputMonitoring:
            return CGRequestListenEventAccess()
        case .accessibility:
            let options = [
                "AXTrustedCheckOptionPrompt": true
            ] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        case .eventPosting:
            return CGRequestPostEventAccess()
        }
    }
}

protocol PermissionHistoryStoring: AnyObject {
    func hasRequested(_ permission: SystemPermission) -> Bool
    func wasEverGranted(_ permission: SystemPermission) -> Bool
    func setRequested(_ requested: Bool, for permission: SystemPermission)
    func setEverGranted(_ granted: Bool, for permission: SystemPermission)
}

final class UserDefaultsPermissionHistoryStore: PermissionHistoryStoring {
    private let defaults: UserDefaults
    private let keyPrefix: String

    init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "com.rajjoshi.MojiPond.permissions"
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    func hasRequested(_ permission: SystemPermission) -> Bool {
        defaults.bool(forKey: key(permission, suffix: "requested"))
    }

    func wasEverGranted(_ permission: SystemPermission) -> Bool {
        defaults.bool(forKey: key(permission, suffix: "everGranted"))
    }

    func setRequested(_ requested: Bool, for permission: SystemPermission) {
        defaults.set(requested, forKey: key(permission, suffix: "requested"))
    }

    func setEverGranted(_ granted: Bool, for permission: SystemPermission) {
        defaults.set(granted, forKey: key(permission, suffix: "everGranted"))
    }

    private func key(_ permission: SystemPermission, suffix: String) -> String {
        "\(keyPrefix).\(permission.rawValue).\(suffix)"
    }
}

/// Publishes a current view of macOS privacy permissions without prompting.
///
/// macOS exposes a Boolean preflight result rather than separate "not decided" and
/// "denied" states. MojiPond records only whether it previously made an explicit
/// request and whether access was previously granted so the UI can distinguish
/// those user-relevant states without probing or resetting TCC.
@MainActor
final class SystemPermissionCenter: ObservableObject {
    @Published private(set) var snapshot: SystemPermissionSnapshot

    private let provider: SystemPermissionProviding
    private let history: PermissionHistoryStoring
    private var activationObserver: NSObjectProtocol?
    private var pollingTimer: Timer?

    init(
        provider: SystemPermissionProviding = MacSystemPermissionProvider(),
        history: PermissionHistoryStoring = UserDefaultsPermissionHistoryStore()
    ) {
        self.provider = provider
        self.history = history
        snapshot = Self.readSnapshot(provider: provider, history: history)
    }

    func refresh() {
        snapshot = Self.readSnapshot(provider: provider, history: history)
    }

    /// Starts preflight-only updates. This never displays a system consent prompt.
    func startLiveUpdates(interval: TimeInterval = 1.0) {
        guard activationObserver == nil, pollingTimer == nil else {
            return
        }

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }

        pollingTimer = Timer.scheduledTimer(
            withTimeInterval: max(0.25, interval),
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    func stopLiveUpdates() {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    /// This is the only path in this type that may ask macOS for consent.
    @discardableResult
    func request(_ permission: SystemPermission) -> SystemPermissionStatus {
        history.setRequested(true, for: permission)
        let granted = provider.request(permission)
        if granted {
            history.setEverGranted(true, for: permission)
        }
        refresh()
        return snapshot[permission]
    }

    @discardableResult
    func requestInputMonitoring() -> SystemPermissionStatus {
        request(.inputMonitoring)
    }

    @discardableResult
    func requestAccessibility() -> SystemPermissionStatus {
        request(.accessibility)
    }

    @discardableResult
    func requestEventPosting() -> SystemPermissionStatus {
        request(.eventPosting)
    }

    private static func readSnapshot(
        provider: SystemPermissionProviding,
        history: PermissionHistoryStoring
    ) -> SystemPermissionSnapshot {
        for permission in SystemPermission.allCases where provider.isGranted(permission) {
            history.setEverGranted(true, for: permission)
        }

        return SystemPermissionSnapshot(
            inputMonitoring: status(
                for: .inputMonitoring,
                provider: provider,
                history: history
            ),
            accessibility: status(
                for: .accessibility,
                provider: provider,
                history: history
            ),
            eventPosting: status(
                for: .eventPosting,
                provider: provider,
                history: history
            )
        )
    }

    private static func status(
        for permission: SystemPermission,
        provider: SystemPermissionProviding,
        history: PermissionHistoryStoring
    ) -> SystemPermissionStatus {
        if provider.isGranted(permission) {
            return .granted
        }
        if history.wasEverGranted(permission) {
            return .revoked
        }
        if history.hasRequested(permission) {
            return .denied
        }
        return .notRequested
    }
}
