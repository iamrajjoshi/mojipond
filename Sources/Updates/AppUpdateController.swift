import Combine
import Foundation

protocol SignedUpdateChecking: Sendable {
    func check(
        for kind: UpdateCheckKind
    ) async throws -> SignedUpdateCheckResult
}

extension SignedUpdateChecker: SignedUpdateChecking {}

protocol VerifiedUpdateStaging: Sendable {
    func stage(
        metadata: VerifiedUpdateMetadata
    ) async throws -> VerifiedStagedUpdate
    func revalidateForInstallation(
        _ stagedUpdate: VerifiedStagedUpdate
    ) throws -> VerifiedUpdateInstallationPlan
    func discard(_ stagedUpdate: VerifiedStagedUpdate) throws
}

extension VerifiedUpdateStager: VerifiedUpdateStaging {}

enum AppUpdateState: Equatable, Sendable {
    case unconfigured
    case idle
    case checking
    case current(version: String)
    case available(VerifiedUpdateMetadata)
    case incompatible(
        metadata: VerifiedUpdateMetadata,
        requiredSystemVersion: String
    )
    case staging(VerifiedUpdateMetadata)
    case revalidating(VerifiedUpdateMetadata)
    case launchingInstaller(VerifiedUpdateMetadata)
    case staged(
        metadata: VerifiedUpdateMetadata,
        plan: VerifiedUpdateInstallationPlan
    )
    case disabled(UpdateCheckDisabledReason)
    case failed(String)
}

struct BundledUpdateConfigurationLoader {
    static let feedURLKey = "MojiPondUpdateFeedURL"
    static let publicKeyKey = "MojiPondUpdatePublicKeyBase64"
    static let algorithmKey = "MojiPondUpdateSignatureAlgorithm"
    static let teamIdentifierKey = "MojiPondUpdateTeamIdentifier"

    static func load(
        bundle: Bundle = .main,
        automaticChecksEnabled: Bool
    ) -> SignedUpdateConfiguration {
        load(
            infoDictionary: bundle.infoDictionary ?? [:],
            automaticChecksEnabled: automaticChecksEnabled
        )
    }

    static func expectedTeamIdentifier(
        bundle: Bundle = .main
    ) -> String? {
        nonemptyString(
            bundle.infoDictionary?[teamIdentifierKey]
        )
    }

    static func load(
        infoDictionary: [String: Any],
        automaticChecksEnabled: Bool
    ) -> SignedUpdateConfiguration {
        let feedURL = nonemptyString(
            infoDictionary[feedURLKey]
        ).flatMap(URL.init(string:))
        let keyData = nonemptyString(
            infoDictionary[publicKeyKey]
        ).flatMap { Data(base64Encoded: $0) }
        let algorithm = nonemptyString(
            infoDictionary[algorithmKey]
        ).flatMap(UpdateSignatureAlgorithm.init(rawValue:))

        let publicKey: UpdateVerificationKey?
        switch (algorithm, keyData) {
        case let (.ed25519?, data?):
            publicKey = .ed25519(rawRepresentation: data)
        case let (.p256SHA256?, data?):
            publicKey = .p256(rawRepresentation: data)
        default:
            publicKey = nil
        }

        return SignedUpdateConfiguration(
            feedURL: feedURL,
            publicKey: publicKey,
            automaticChecksEnabled: automaticChecksEnabled
        )
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard
            let string = value as? String,
            !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return string
    }
}

@MainActor
final class AppUpdateController: ObservableObject {
    private typealias OperationID = UInt64

    static let defaultAutomaticCheckInterval: TimeInterval = 24 * 60 * 60

    typealias CheckerFactory = @Sendable (
        SignedUpdateConfiguration
    ) -> any SignedUpdateChecking
    typealias StagerFactory = @Sendable (
        VerifiedUpdateStagingConfiguration
    ) -> any VerifiedUpdateStaging

    @Published private(set) var state: AppUpdateState
    @Published private(set) var installationStatusMessage: String?

    private let baseConfiguration: SignedUpdateConfiguration
    private let expectedTeamIdentifier: String?
    private let currentVersion: String
    private let currentBuild: Int
    private let currentSystemVersion: UpdateSystemVersion
    private let checkerFactory: CheckerFactory
    private let stagerFactory: StagerFactory
    private let nativeInstallerLauncher:
        any NativeUpdateInstallerLaunching
    private let automaticCheckInterval: TimeInterval
    private let currentDate: () -> Date
    private let checkHistoryStore: any UpdateCheckHistoryStoring
    private let automaticCheckScheduler:
        any AutomaticUpdateCheckScheduling
    private var checkTask: Task<Void, Never>?
    private var activeCheckKind: UpdateCheckKind?
    private var activeCheckOperationID: OperationID?
    private var stagingTask: Task<Void, Never>?
    private var activeStagingOperationID: OperationID?
    private var revalidationTask:
        Task<VerifiedUpdateInstallationPlan, Error>?
    private var activeRevalidationOperationID: OperationID?
    private var stagedUpdate: VerifiedStagedUpdate?
    private var activeStager: (any VerifiedUpdateStaging)?
    private var activeStagerOperationID: OperationID?
    private var lastAvailableMetadata: VerifiedUpdateMetadata?
    private var lastOperationID: OperationID = 0
    private var installerHandoffCompleted = false
    private var automaticChecksEnabled = false

    init(
        configuration: SignedUpdateConfiguration =
            BundledUpdateConfigurationLoader.load(
                automaticChecksEnabled: false
            ),
        currentVersion: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "Development",
        currentBuild: Int = Int(
            Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? ""
        ) ?? 0,
        currentSystemVersion: UpdateSystemVersion = UpdateSystemVersion(
            ProcessInfo.processInfo.operatingSystemVersion
        ),
        expectedTeamIdentifier: String? =
            BundledUpdateConfigurationLoader.expectedTeamIdentifier(),
        checkerFactory: @escaping CheckerFactory = {
            SignedUpdateChecker(configuration: $0)
        },
        stagerFactory: @escaping StagerFactory = {
            VerifiedUpdateStager(configuration: $0)
        },
        nativeInstallerLauncher:
            any NativeUpdateInstallerLaunching =
                SystemNativeUpdateInstallerLauncher(),
        automaticCheckInterval: TimeInterval =
            AppUpdateController.defaultAutomaticCheckInterval,
        currentDate: @escaping () -> Date = Date.init,
        checkHistoryStore: any UpdateCheckHistoryStoring =
            UserDefaultsUpdateCheckHistoryStore(),
        automaticCheckScheduler:
            any AutomaticUpdateCheckScheduling =
                TaskAutomaticUpdateCheckScheduler()
    ) {
        precondition(
            automaticCheckInterval.isFinite
                && automaticCheckInterval > 0
        )
        baseConfiguration = configuration
        self.expectedTeamIdentifier = expectedTeamIdentifier
        self.currentVersion = currentVersion
        self.currentBuild = currentBuild
        self.currentSystemVersion = currentSystemVersion
        self.checkerFactory = checkerFactory
        self.stagerFactory = stagerFactory
        self.nativeInstallerLauncher = nativeInstallerLauncher
        self.automaticCheckInterval = automaticCheckInterval
        self.currentDate = currentDate
        self.checkHistoryStore = checkHistoryStore
        self.automaticCheckScheduler = automaticCheckScheduler
        installationStatusMessage = nil
        state = configuration.feedURL == nil || configuration.publicKey == nil
            ? .unconfigured
            : .idle
    }

    deinit {
        checkTask?.cancel()
        stagingTask?.cancel()
        revalidationTask?.cancel()
    }

    var isChecking: Bool {
        state == .checking
    }

    var isStaging: Bool {
        switch state {
        case .staging, .revalidating, .launchingInstaller:
            true
        default:
            false
        }
    }

    var isBusy: Bool {
        isChecking || isStaging
    }

    var availableMetadata: VerifiedUpdateMetadata? {
        switch state {
        case let .available(metadata),
             let .staging(metadata),
             let .revalidating(metadata),
             let .launchingInstaller(metadata):
            metadata
        case let .staged(metadata, _):
            metadata
        default:
            nil
        }
    }

    var statusSummary: String {
        switch state {
        case .unconfigured:
            "Disabled until a signed feed is configured"
        case .idle:
            "Ready to check"
        case .checking:
            "Checking…"
        case let .current(version):
            "MojiPond \(version) is current"
        case let .available(metadata):
            "MojiPond \(metadata.version) is available"
        case let .incompatible(_, requiredSystemVersion):
            "Requires macOS \(requiredSystemVersion) or later"
        case let .staging(metadata):
            "Downloading and verifying MojiPond \(metadata.version)…"
        case let .revalidating(metadata):
            "Revalidating MojiPond \(metadata.version)…"
        case let .launchingInstaller(metadata):
            "Starting the verified MojiPond \(metadata.version) installer…"
        case let .staged(metadata, _):
            if let installationStatusMessage {
                installationStatusMessage
            } else {
                "MojiPond \(metadata.version) is verified and ready"
            }
        case let .disabled(reason):
            Self.disabledSummary(reason)
        case .failed:
            "Check failed"
        }
    }

    func start(automaticChecksEnabled: Bool) {
        configureAutomaticChecks(
            enabled: automaticChecksEnabled
        )
    }

    func automaticChecksPreferenceDidChange(enabled: Bool) {
        configureAutomaticChecks(enabled: enabled)
    }

    private func configureAutomaticChecks(enabled: Bool) {
        automaticChecksEnabled = enabled
        automaticCheckScheduler.cancel()

        guard enabled else {
            guard activeCheckKind == .automatic else {
                return
            }
            cancelCheckOperation()
            restoreAvailableOrIdleState()
            return
        }

        guard canCheckForUpdates else {
            return
        }
        checkAutomaticallyIfDue()
    }

    func checkManually(automaticChecksEnabled: Bool) {
        self.automaticChecksEnabled = automaticChecksEnabled
        if automaticChecksEnabled, canCheckForUpdates {
            recordAutomaticCheck(at: currentDate())
            scheduleAutomaticCheck(
                after: automaticCheckInterval
            )
        } else {
            automaticCheckScheduler.cancel()
        }
        check(
            kind: .manual,
            automaticChecksEnabled: automaticChecksEnabled
        )
    }

    func stageAvailableUpdate() {
        guard
            case let .available(metadata) = state,
            canCheckForUpdates
        else {
            return
        }

        cancelStagingOperation()
        cancelRevalidationOperation()
        discardStagedUpdateKeepingAvailability()
        installationStatusMessage = nil
        let stagingConfiguration =
            VerifiedUpdateStagingConfiguration(
                signedConfiguration: baseConfiguration,
                expectedTeamIdentifier: expectedTeamIdentifier,
                currentSystemVersion: currentSystemVersion
            )
        let stager = stagerFactory(stagingConfiguration)
        let operationID = makeOperationID()
        activeStagingOperationID = operationID
        activeStager = stager
        activeStagerOperationID = operationID
        state = .staging(metadata)

        stagingTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            var unownedStagedUpdate: VerifiedStagedUpdate?
            defer {
                if let unownedStagedUpdate {
                    try? stager.discard(unownedStagedUpdate)
                }
                self.finishStagingOperation(operationID)
            }
            do {
                let staged = try await stager.stage(metadata: metadata)
                unownedStagedUpdate = staged
                try Task.checkCancellation()
                guard
                    self.activeStagingOperationID == operationID,
                    self.activeStagerOperationID == operationID
                else {
                    return
                }
                guard case let .ready(plan) =
                    staged.installationState else {
                    state = .failed(
                        "The verified update did not provide a safe installation plan."
                    )
                    self.clearStagerOwned(by: operationID)
                    return
                }
                stagedUpdate = staged
                lastAvailableMetadata = metadata
                state = .staged(metadata: metadata, plan: plan)
                installationStatusMessage = nil
                unownedStagedUpdate = nil
            } catch is CancellationError {
                guard self.activeStagingOperationID == operationID else {
                    return
                }
                state = .available(metadata)
                self.clearStagerOwned(by: operationID)
            } catch {
                guard self.activeStagingOperationID == operationID else {
                    return
                }
                self.clearStagerOwned(by: operationID)
                state = .failed(
                    (error as? LocalizedError)?.errorDescription
                        ?? "The update could not be downloaded and verified."
                )
            }
        }
    }

    func revalidateInstallation()
        async -> VerifiedUpdateInstallationPlan? {
        guard
            let stagedUpdate,
            let activeStager,
            let stagerOperationID = activeStagerOperationID,
            case let .staged(metadata, _) = state
        else {
            return nil
        }

        cancelRevalidationOperation()
        let operationID = makeOperationID()
        activeRevalidationOperationID = operationID
        let task = Task.detached {
            let plan = try activeStager.revalidateForInstallation(
                stagedUpdate
            )
            try Task.checkCancellation()
            return plan
        }
        revalidationTask = task
        state = .revalidating(metadata)
        defer {
            finishRevalidationOperation(operationID)
        }
        do {
            let plan = try await task.value
            guard ownsRevalidationOperation(
                operationID,
                stagerOperationID: stagerOperationID,
                stagedUpdate: stagedUpdate
            ) else {
                return nil
            }
            state = .staged(metadata: metadata, plan: plan)
            return plan
        } catch {
            guard ownsRevalidationOperation(
                operationID,
                stagerOperationID: stagerOperationID,
                stagedUpdate: stagedUpdate
            ) else {
                return nil
            }
            try? activeStager.discard(stagedUpdate)
            self.stagedUpdate = nil
            clearStagerOwned(by: stagerOperationID)
            state = .failed(
                (error as? LocalizedError)?.errorDescription
                    ?? "The staged update failed its final verification."
            )
            return nil
        }
    }

    var nativeInstallAvailability: NativeUpdateInstallAvailability? {
        guard let context = nativeInstallerContext() else {
            return nil
        }
        return nativeInstallerLauncher.availability(for: context)
    }

    /// Revalidates the signed ZIP linkage and both app identities immediately
    /// before starting the verified candidate in its installer-only mode.
    /// Returning true means the caller should terminate this process so the
    /// candidate can acquire the destination lock and perform the swap.
    func installAndRelaunch() async -> Bool {
        installerHandoffCompleted = false
        guard let plan = await revalidateInstallation(),
              let stagedUpdate,
              let context = nativeInstallerContext(
                  stagedUpdate: stagedUpdate,
                  plan: plan
              ) else {
            return false
        }

        switch nativeInstallerLauncher.availability(for: context) {
        case .available:
            break
        case let .manualInstallRequired(reason),
             let .unavailable(reason):
            installationStatusMessage = reason
            state = .staged(
                metadata: stagedUpdate.metadata,
                plan: plan
            )
            return false
        }

        state = .launchingInstaller(stagedUpdate.metadata)
        do {
            try nativeInstallerLauncher.launchInstaller(for: context)
            installationStatusMessage =
                "Installer started; MojiPond is quitting to finish the update."
            installerHandoffCompleted = true
            return true
        } catch {
            installationStatusMessage =
                (error as? LocalizedError)?.errorDescription
                    ?? "The verified installer could not be started."
            state = .staged(
                metadata: stagedUpdate.metadata,
                plan: plan
            )
            return false
        }
    }

    func discardStagedUpdate() {
        cancelStagingOperation()
        cancelRevalidationOperation()
        discardStagedUpdateKeepingAvailability()
        installationStatusMessage = nil
        if let lastAvailableMetadata {
            state = .available(lastAvailableMetadata)
        } else {
            state = canCheckForUpdates ? .idle : .unconfigured
        }
    }

    /// Cancels the active update operation without changing the user's
    /// background-check preference or its next scheduled check.
    func cancelCurrentOperation() {
        cancelCheckOperation()
        cancelStagingOperation()
        cancelRevalidationOperation()
        discardStagedUpdateKeepingAvailability()
        installationStatusMessage = nil
        state = canCheckForUpdates ? .idle : .unconfigured
    }

    /// Stops background work. Only a candidate process that was successfully
    /// launched owns a persistent staging handoff; an ordinary quit removes a
    /// merely staged download.
    func prepareForTermination() {
        automaticCheckScheduler.cancel()
        cancelCheckOperation()
        cancelStagingOperation()
        cancelRevalidationOperation()
        if !installerHandoffCompleted {
            discardStagedUpdateKeepingAvailability()
            if let lastAvailableMetadata {
                state = .available(lastAvailableMetadata)
            } else {
                state = canCheckForUpdates ? .idle : .unconfigured
            }
        }
    }

    var canCheckForUpdates: Bool {
        baseConfiguration.feedURL != nil
            && baseConfiguration.publicKey != nil
    }

    private func checkAutomaticallyIfDue() {
        let now = currentDate()
        guard checkHistoryStore.lastSuccessfulAutomaticCheckOutcome
            == .noActionableUpdate else {
            performAutomaticCheck(at: now)
            return
        }
        guard let lastCheckDate =
            checkHistoryStore.lastAutomaticCheckDate else {
            performAutomaticCheck(at: now)
            return
        }

        let elapsed = max(
            0,
            now.timeIntervalSince(lastCheckDate)
        )
        let remaining = max(
            0,
            automaticCheckInterval - elapsed
        )
        if remaining > 0 {
            scheduleAutomaticCheck(after: remaining)
        } else {
            performAutomaticCheck(at: now)
        }
    }

    private func performAutomaticCheck(at date: Date) {
        guard automaticChecksEnabled, canCheckForUpdates else {
            return
        }

        guard !isBusy, !hasStagedUpdate else {
            scheduleAutomaticCheck(
                after: automaticCheckInterval
            )
            return
        }

        recordAutomaticCheck(at: date)
        check(
            kind: .automatic,
            automaticChecksEnabled: true
        )
        scheduleAutomaticCheck(after: automaticCheckInterval)
    }

    private func recordAutomaticCheck(at date: Date) {
        checkHistoryStore.lastAutomaticCheckDate = date
    }

    private func scheduleAutomaticCheck(after delay: TimeInterval) {
        guard automaticChecksEnabled, canCheckForUpdates else {
            return
        }
        automaticCheckScheduler.schedule(after: delay) {
            [weak self] in
            guard let self else {
                return
            }
            self.performAutomaticCheck(at: self.currentDate())
        }
    }

    private var hasStagedUpdate: Bool {
        if case .staged = state {
            return true
        }
        return false
    }

    private func makeOperationID() -> OperationID {
        precondition(
            lastOperationID < .max,
            "Update operation identifier exhausted."
        )
        lastOperationID += 1
        return lastOperationID
    }

    private func cancelCheckOperation() {
        checkTask?.cancel()
        checkTask = nil
        activeCheckKind = nil
        activeCheckOperationID = nil
    }

    private func finishCheckOperation(_ operationID: OperationID) {
        guard activeCheckOperationID == operationID else {
            return
        }
        checkTask = nil
        activeCheckKind = nil
        activeCheckOperationID = nil
    }

    private func cancelStagingOperation() {
        stagingTask?.cancel()
        stagingTask = nil
        activeStagingOperationID = nil
    }

    private func finishStagingOperation(
        _ operationID: OperationID
    ) {
        guard activeStagingOperationID == operationID else {
            return
        }
        stagingTask = nil
        activeStagingOperationID = nil
    }

    private func cancelRevalidationOperation() {
        revalidationTask?.cancel()
        revalidationTask = nil
        activeRevalidationOperationID = nil
    }

    private func finishRevalidationOperation(
        _ operationID: OperationID
    ) {
        guard activeRevalidationOperationID == operationID else {
            return
        }
        revalidationTask = nil
        activeRevalidationOperationID = nil
    }

    private func ownsRevalidationOperation(
        _ operationID: OperationID,
        stagerOperationID: OperationID,
        stagedUpdate: VerifiedStagedUpdate
    ) -> Bool {
        activeRevalidationOperationID == operationID
            && activeStagerOperationID == stagerOperationID
            && self.stagedUpdate == stagedUpdate
    }

    private func clearStagerOwned(
        by operationID: OperationID
    ) {
        guard activeStagerOperationID == operationID else {
            return
        }
        stagedUpdate = nil
        activeStager = nil
        activeStagerOperationID = nil
    }

    private func nativeInstallerContext()
        -> NativeUpdateInstallerLaunchContext? {
        guard
            let stagedUpdate,
            case let .ready(plan) =
                stagedUpdate.installationState
        else {
            return nil
        }
        return nativeInstallerContext(
            stagedUpdate: stagedUpdate,
            plan: plan
        )
    }

    private func nativeInstallerContext(
        stagedUpdate: VerifiedStagedUpdate,
        plan: VerifiedUpdateInstallationPlan
    ) -> NativeUpdateInstallerLaunchContext? {
        guard stagedUpdate.updateIdentity.teamIdentifier
            == stagedUpdate.currentIdentity.teamIdentifier else {
            return nil
        }
        return NativeUpdateInstallerLaunchContext(
            stagedApplicationURL: plan.stagedApplicationURL,
            stagingDirectoryURL:
                stagedUpdate.stagingDirectoryURL,
            destinationApplicationURL:
                plan.destinationApplicationURL,
            currentVersion: currentVersion,
            currentBuild: currentBuild,
            updateVersion: stagedUpdate.metadata.version,
            updateBuild: stagedUpdate.metadata.build,
            expectedTeamIdentifier:
                stagedUpdate.currentIdentity.teamIdentifier,
            assetSHA256: stagedUpdate.metadata.assetSHA256,
            assetByteCount: stagedUpdate.metadata.assetByteCount,
            parentProcessIdentifier:
                ProcessInfo.processInfo.processIdentifier
        )
    }

    private func check(
        kind: UpdateCheckKind,
        automaticChecksEnabled: Bool
    ) {
        let verifiedFallback: VerifiedUpdateMetadata?
        if kind == .automatic,
           case let .available(metadata) = state {
            verifiedFallback = metadata
        } else {
            verifiedFallback = nil
        }

        cancelCheckOperation()
        cancelStagingOperation()
        cancelRevalidationOperation()
        discardStagedUpdateKeepingAvailability()

        var configuration = baseConfiguration
        configuration.automaticChecksEnabled = automaticChecksEnabled
        let checker = checkerFactory(configuration)
        let operationID = makeOperationID()
        activeCheckOperationID = operationID
        activeCheckKind = kind
        state = .checking

        checkTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                self.finishCheckOperation(operationID)
            }
            do {
                let result = try await checker.check(for: kind)
                try Task.checkCancellation()
                guard self.activeCheckOperationID == operationID else {
                    return
                }
                recordSuccessfulAutomaticCheckOutcome(
                    from: result,
                    whenEnabled: automaticChecksEnabled
                )
                apply(result)
            } catch is CancellationError {
                guard self.activeCheckOperationID == operationID else {
                    return
                }
                if let verifiedFallback {
                    state = .available(verifiedFallback)
                } else {
                    state = canCheckForUpdates ? .idle : .unconfigured
                }
            } catch {
                guard self.activeCheckOperationID == operationID else {
                    return
                }
                if let verifiedFallback {
                    state = .available(verifiedFallback)
                } else {
                    state = .failed(
                        (error as? LocalizedError)?.errorDescription
                            ?? "The update check failed."
                    )
                }
            }
        }
    }

    private func apply(_ result: SignedUpdateCheckResult) {
        switch result {
        case let .disabled(reason):
            state = .disabled(reason)
        case let .verified(metadata):
            if metadata.build > currentBuild {
                if
                    let minimum = metadata.minimumSystemVersion,
                    let required = UpdateSystemVersion(minimum),
                    required > currentSystemVersion
                {
                    lastAvailableMetadata = nil
                    state = .incompatible(
                        metadata: metadata,
                        requiredSystemVersion: required.displayString
                    )
                } else {
                    lastAvailableMetadata = metadata
                    state = .available(metadata)
                }
            } else {
                lastAvailableMetadata = nil
                state = .current(version: currentVersion)
            }
        }
    }

    private func recordSuccessfulAutomaticCheckOutcome(
        from result: SignedUpdateCheckResult,
        whenEnabled: Bool
    ) {
        guard whenEnabled, case let .verified(metadata) = result else {
            return
        }
        checkHistoryStore.lastSuccessfulAutomaticCheckOutcome =
            isActionableUpdate(metadata)
                ? .updateAvailable
                : .noActionableUpdate
    }

    private func isActionableUpdate(
        _ metadata: VerifiedUpdateMetadata
    ) -> Bool {
        guard metadata.build > currentBuild else {
            return false
        }
        guard
            let minimum = metadata.minimumSystemVersion,
            let required = UpdateSystemVersion(minimum)
        else {
            return true
        }
        return required <= currentSystemVersion
    }

    private func discardStagedUpdateKeepingAvailability() {
        if let stagedUpdate, let activeStager {
            try? activeStager.discard(stagedUpdate)
        }
        stagedUpdate = nil
        activeStager = nil
        activeStagerOperationID = nil
        installerHandoffCompleted = false
    }

    private func restoreAvailableOrIdleState() {
        if let lastAvailableMetadata {
            state = .available(lastAvailableMetadata)
        } else {
            state = canCheckForUpdates ? .idle : .unconfigured
        }
    }

    private static func disabledSummary(
        _ reason: UpdateCheckDisabledReason
    ) -> String {
        switch reason {
        case .missingFeedURL, .missingPublicKey:
            "Disabled until a signed feed is configured"
        case .automaticChecksNotEnabled:
            "Automatic checks are off"
        }
    }
}
