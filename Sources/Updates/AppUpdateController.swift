import Combine
import Foundation

protocol SignedUpdateChecking: Sendable {
    func check(
        for kind: UpdateCheckKind
    ) async throws -> SignedUpdateCheckResult
}

extension SignedUpdateChecker: SignedUpdateChecking {}

enum AppUpdateState: Equatable, Sendable {
    case unconfigured
    case idle
    case checking
    case current(version: String)
    case available(VerifiedUpdateMetadata)
    case disabled(UpdateCheckDisabledReason)
    case failed(String)
}

struct BundledUpdateConfigurationLoader {
    static let feedURLKey = "MojiPondUpdateFeedURL"
    static let publicKeyKey = "MojiPondUpdatePublicKeyBase64"
    static let algorithmKey = "MojiPondUpdateSignatureAlgorithm"

    static func load(
        bundle: Bundle = .main,
        automaticChecksEnabled: Bool
    ) -> SignedUpdateConfiguration {
        load(
            infoDictionary: bundle.infoDictionary ?? [:],
            automaticChecksEnabled: automaticChecksEnabled
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
    typealias CheckerFactory = @Sendable (
        SignedUpdateConfiguration
    ) -> any SignedUpdateChecking

    @Published private(set) var state: AppUpdateState

    private let baseConfiguration: SignedUpdateConfiguration
    private let currentVersion: String
    private let currentBuild: Int
    private let checkerFactory: CheckerFactory
    private var checkTask: Task<Void, Never>?

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
        checkerFactory: @escaping CheckerFactory = {
            SignedUpdateChecker(configuration: $0)
        }
    ) {
        baseConfiguration = configuration
        self.currentVersion = currentVersion
        self.currentBuild = currentBuild
        self.checkerFactory = checkerFactory
        state = configuration.feedURL == nil || configuration.publicKey == nil
            ? .unconfigured
            : .idle
    }

    deinit {
        checkTask?.cancel()
    }

    var isChecking: Bool {
        state == .checking
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
        case let .disabled(reason):
            Self.disabledSummary(reason)
        case .failed:
            "Check failed"
        }
    }

    func start(automaticChecksEnabled: Bool) {
        guard automaticChecksEnabled else {
            return
        }
        check(
            kind: .automatic,
            automaticChecksEnabled: automaticChecksEnabled
        )
    }

    func checkManually(automaticChecksEnabled: Bool) {
        check(
            kind: .manual,
            automaticChecksEnabled: automaticChecksEnabled
        )
    }

    func cancel() {
        checkTask?.cancel()
        checkTask = nil
        state = isConfigured ? .idle : .unconfigured
    }

    private var isConfigured: Bool {
        baseConfiguration.feedURL != nil
            && baseConfiguration.publicKey != nil
    }

    private func check(
        kind: UpdateCheckKind,
        automaticChecksEnabled: Bool
    ) {
        checkTask?.cancel()

        var configuration = baseConfiguration
        configuration.automaticChecksEnabled = automaticChecksEnabled
        let checker = checkerFactory(configuration)
        state = .checking

        checkTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            do {
                let result = try await checker.check(for: kind)
                try Task.checkCancellation()
                apply(result)
            } catch is CancellationError {
                state = isConfigured ? .idle : .unconfigured
            } catch {
                state = .failed(
                    (error as? LocalizedError)?.errorDescription
                        ?? "The update check failed."
                )
            }
            checkTask = nil
        }
    }

    private func apply(_ result: SignedUpdateCheckResult) {
        switch result {
        case let .disabled(reason):
            state = .disabled(reason)
        case let .verified(metadata):
            state = metadata.build > currentBuild
                ? .available(metadata)
                : .current(version: currentVersion)
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
