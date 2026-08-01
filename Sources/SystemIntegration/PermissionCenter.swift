import ApplicationServices
import AppKit
import Combine
import CoreGraphics
import Foundation
import IOKit.hid

enum SystemPermission: String, CaseIterable, Hashable, Sendable {
    case inputMonitoring
    case accessibility
    case eventPosting
}

enum SystemPermissionStatus: String, Equatable, Sendable {
    case notRequested
    case pending
    case denied
    case granted
    case revoked

    var availableActions: [SystemPermissionAction] {
        switch self {
        case .notRequested, .denied, .revoked:
            [.request, .openSettings]
        case .pending:
            [.openSettings]
        case .granted:
            []
        }
    }
}

enum SystemPermissionAction: Hashable, Sendable {
    case request
    case openSettings
}

protocol SystemPermissionSettingsOpening {
    @discardableResult
    func openSettings(for permission: SystemPermission) -> Bool
}

struct MacSystemPermissionSettingsOpener: SystemPermissionSettingsOpening {
    private let openURL: (URL) -> Bool

    init(workspace: NSWorkspace = .shared) {
        openURL = { workspace.open($0) }
    }

    init(openURL: @escaping (URL) -> Bool) {
        self.openURL = openURL
    }

    @discardableResult
    func openSettings(for permission: SystemPermission) -> Bool {
        for url in Self.candidateURLs(for: permission) where openURL(url) {
            return true
        }
        return false
    }

    static func candidateURLs(
        for permission: SystemPermission
    ) -> [URL] {
        let anchor = switch permission {
        case .inputMonitoring:
            "Privacy_ListenEvent"
        case .accessibility, .eventPosting:
            "Privacy_Accessibility"
        }
        return [
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        ].compactMap(URL.init(string:))
    }
}

struct SystemPermissionSnapshot: Equatable, Sendable {
    var inputMonitoring: SystemPermissionStatus
    var accessibility: SystemPermissionStatus
    var eventPosting: SystemPermissionStatus

    subscript(permission: SystemPermission) -> SystemPermissionStatus {
        get {
            switch permission {
            case .inputMonitoring:
                inputMonitoring
            case .accessibility:
                accessibility
            case .eventPosting:
                eventPosting
            }
        }
        set {
            switch permission {
            case .inputMonitoring:
                inputMonitoring = newValue
            case .accessibility:
                accessibility = newValue
            case .eventPosting:
                eventPosting = newValue
            }
        }
    }
}

protocol SystemPermissionProviding {
    func isGranted(_ permission: SystemPermission) -> Bool
    func request(_ permission: SystemPermission) -> Bool
}

struct MacInputMonitoringPermissionAccess {
    private let checkCoreGraphics: () -> Bool
    private let requestCoreGraphics: () -> Bool
    private let checkIOHID: () -> Bool
    private let requestIOHID: () -> Bool

    init(
        checkCoreGraphics: @escaping () -> Bool = {
            CGPreflightListenEventAccess()
        },
        requestCoreGraphics: @escaping () -> Bool = {
            CGRequestListenEventAccess()
        },
        checkIOHID: @escaping () -> Bool = {
            IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
                == kIOHIDAccessTypeGranted
        },
        requestIOHID: @escaping () -> Bool = {
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
    ) {
        self.checkCoreGraphics = checkCoreGraphics
        self.requestCoreGraphics = requestCoreGraphics
        self.checkIOHID = checkIOHID
        self.requestIOHID = requestIOHID
    }

    func isGranted() -> Bool {
        let coreGraphicsGranted = checkCoreGraphics()
        let ioHIDGranted = checkIOHID()
        return coreGraphicsGranted || ioHIDGranted
    }

    func request() -> Bool {
        _ = requestIOHID()
        _ = requestCoreGraphics()
        return isGranted()
    }
}

struct MacSystemPermissionProvider: SystemPermissionProviding {
    private let inputMonitoring: MacInputMonitoringPermissionAccess

    init(
        inputMonitoring: MacInputMonitoringPermissionAccess =
            MacInputMonitoringPermissionAccess()
    ) {
        self.inputMonitoring = inputMonitoring
    }

    func isGranted(_ permission: SystemPermission) -> Bool {
        switch permission {
        case .inputMonitoring:
            inputMonitoring.isGranted()
        case .accessibility:
            AXIsProcessTrusted()
        case .eventPosting:
            CGPreflightPostEventAccess()
        }
    }

    func request(_ permission: SystemPermission) -> Bool {
        switch permission {
        case .inputMonitoring:
            return inputMonitoring.request()
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
    private let notificationCenter: NotificationCenter
    private let grantObservationInterval: Duration
    private let grantObservationAttemptLimit: Int
    private var activationObserver: NSObjectProtocol?
    private var grantObservationTasks:
        [SystemPermission: Task<Void, Never>] = [:]

    init(
        provider: SystemPermissionProviding = MacSystemPermissionProvider(),
        history: PermissionHistoryStoring = UserDefaultsPermissionHistoryStore(),
        notificationCenter: NotificationCenter = .default,
        grantObservationInterval: Duration = .milliseconds(750),
        grantObservationAttemptLimit: Int = 40
    ) {
        self.provider = provider
        self.history = history
        self.notificationCenter = notificationCenter
        self.grantObservationInterval = grantObservationInterval
        self.grantObservationAttemptLimit = max(
            1,
            grantObservationAttemptLimit
        )
        snapshot = Self.readSnapshot(provider: provider, history: history)
    }

    func refresh() {
        snapshot = Self.readSnapshot(provider: provider, history: history)
    }

    /// Refreshes preflight state when the app becomes active again.
    ///
    /// This never displays a consent prompt and deliberately avoids polling
    /// macOS privacy services while the app is idle.
    func startLiveUpdates() {
        guard activationObserver == nil else {
            return
        }

        activationObserver = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    func stopLiveUpdates() {
        if let activationObserver {
            notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        for task in grantObservationTasks.values {
            task.cancel()
        }
        grantObservationTasks.removeAll()
    }

    /// This is the only path in this type that may ask macOS for consent.
    @discardableResult
    func request(_ permission: SystemPermission) -> SystemPermissionStatus {
        history.setRequested(true, for: permission)
        let granted = provider.request(permission)
            || provider.isGranted(permission)
        if granted {
            history.setEverGranted(true, for: permission)
            grantObservationTasks[permission]?.cancel()
            grantObservationTasks[permission] = nil
            refresh()
        } else {
            snapshot[permission] = .pending
            observeGrant(for: permission)
        }
        return snapshot[permission]
    }

    /// Rechecks only while the user is actively resolving a permission.
    /// Observation stops on grant or after a bounded 30-second window.
    func observeGrant(for permission: SystemPermission) {
        guard snapshot[permission] != .granted else {
            return
        }
        grantObservationTasks[permission]?.cancel()
        let interval = grantObservationInterval
        let attemptLimit = grantObservationAttemptLimit
        grantObservationTasks[permission] = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            for _ in 0 ..< attemptLimit {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else {
                    return
                }
                if provider.isGranted(permission) {
                    history.setEverGranted(true, for: permission)
                    refresh()
                    grantObservationTasks[permission] = nil
                    return
                }
            }
            refresh()
            grantObservationTasks[permission] = nil
        }
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
        let grants = Dictionary(
            uniqueKeysWithValues: SystemPermission.allCases.map {
                ($0, provider.isGranted($0))
            }
        )
        for permission in SystemPermission.allCases
        where grants[permission] == true {
            history.setEverGranted(true, for: permission)
        }

        return SystemPermissionSnapshot(
            inputMonitoring: status(
                for: .inputMonitoring,
                isGranted: grants[.inputMonitoring] == true,
                history: history
            ),
            accessibility: status(
                for: .accessibility,
                isGranted: grants[.accessibility] == true,
                history: history
            ),
            eventPosting: status(
                for: .eventPosting,
                isGranted: grants[.eventPosting] == true,
                history: history
            )
        )
    }

    private static func status(
        for permission: SystemPermission,
        isGranted: Bool,
        history: PermissionHistoryStoring
    ) -> SystemPermissionStatus {
        if isGranted {
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
