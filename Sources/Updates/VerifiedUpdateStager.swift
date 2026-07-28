import CryptoKit
import Darwin
import Foundation
import Security

struct UpdateAssetResponse: Sendable {
    let data: Data
    let statusCode: Int
    let finalURL: URL

    init(data: Data, statusCode: Int = 200, finalURL: URL) {
        self.data = data
        self.statusCode = statusCode
        self.finalURL = finalURL
    }
}

protocol UpdateAssetFetching: Sendable {
    func fetchUpdateAsset(
        from url: URL,
        maximumBytes: Int
    ) async throws -> UpdateAssetResponse
}

struct URLSessionUpdateAssetFetcher: UpdateAssetFetching {
    private let responseLoader: BoundedHTTPSResponseLoader

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        let session = URLSession(
            configuration: configuration,
            delegate: nil,
            delegateQueue: nil
        )
        responseLoader = BoundedHTTPSResponseLoader(session: session)
    }

    func fetchUpdateAsset(
        from url: URL,
        maximumBytes: Int
    ) async throws -> UpdateAssetResponse {
        let loaded: BoundedHTTPResponse
        do {
            loaded = try await responseLoader.load(
                URLRequest(url: url),
                maximumBytes: maximumBytes,
                redirectPolicy: .anyHTTPSHost
            )
        } catch let error as BoundedHTTPSLoadError {
            switch error {
            case .insecureRequestURL:
                throw VerifiedUpdateStagingError.insecureAssetURL
            case .insecureRedirectURL, .disallowedRedirectHost:
                throw VerifiedUpdateStagingError.insecureAssetRedirect
            case .invalidResponse:
                throw VerifiedUpdateStagingError.assetTransportFailure
            case .responseTooLarge:
                throw VerifiedUpdateStagingError.assetExceededSignedByteCount
            }
        }
        return UpdateAssetResponse(
            data: loaded.data,
            statusCode: loaded.response.statusCode,
            finalURL: loaded.response.url ?? url
        )
    }
}

struct UpdateCodeSignatureIdentity: Equatable, Sendable {
    let bundleIdentifier: String
    let teamIdentifier: String
    let certificateCommonName: String
    let hasSecureTimestamp: Bool
    let usesHardenedRuntime: Bool
    let isDeveloperIDApplication: Bool
    let isGatekeeperAccepted: Bool
}

protocol UpdateApplicationSignatureVerifying: Sendable {
    func verifyApplication(
        at applicationURL: URL,
        expectedBundleIdentifier: String
    ) throws -> UpdateCodeSignatureIdentity
}

/// Performs both the requested command-line strict validation and an explicit
/// Security.framework Developer ID requirement. Gatekeeper assessment is also
/// required before an application can be surfaced as a staged update.
struct SystemUpdateApplicationSignatureVerifier:
    UpdateApplicationSignatureVerifying
{
    private static let toolTimeout: TimeInterval = 30

    func verifyApplication(
        at applicationURL: URL,
        expectedBundleIdentifier: String
    ) throws -> UpdateCodeSignatureIdentity {
        guard Self.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: [
                "--verify",
                "--deep",
                "--strict",
                "--verbose=2",
                applicationURL.path
            ]
        ) else {
            throw SystemUpdateSignatureError.codesignValidationFailed
        }

        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            applicationURL.standardizedFileURL as CFURL,
            [],
            &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else {
            throw SystemUpdateSignatureError.cannotReadSignature
        }

        var rawInformation: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(
                rawValue: kSecCSSigningInformation
                    | kSecCSRequirementInformation
            ),
            &rawInformation
        )
        guard informationStatus == errSecSuccess,
              let information = rawInformation as NSDictionary? else {
            throw SystemUpdateSignatureError.cannotReadSignature
        }

        guard let identifier = information[kSecCodeInfoIdentifier] as? String,
              identifier == expectedBundleIdentifier,
              let teamIdentifier = information[
                  kSecCodeInfoTeamIdentifier
              ] as? String,
              Self.isValidTeamIdentifier(teamIdentifier),
              let certificates = information[
                  kSecCodeInfoCertificates
              ] as? [SecCertificate],
              let leafCertificate = certificates.first,
              let certificateName = SecCertificateCopySubjectSummary(
                  leafCertificate
              ) as String?,
              certificateName.hasPrefix("Developer ID Application: ") else {
            throw SystemUpdateSignatureError.developerIDRequired
        }

        let requirementString = """
        identifier "\(expectedBundleIdentifier)" and anchor apple generic \
        and certificate leaf[subject.OU] = "\(teamIdentifier)" \
        and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
        and certificate leaf[field.1.2.840.113635.100.6.1.13] exists
        """
        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(
            requirementString as CFString,
            [],
            &requirement
        )
        guard requirementStatus == errSecSuccess, let requirement else {
            throw SystemUpdateSignatureError.developerIDRequired
        }

        let validationFlags = SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures
                | kSecCSCheckNestedCode
                | kSecCSStrictValidate
                | kSecCSRestrictSymlinks
                | kSecCSRestrictToAppLike
        )
        guard SecStaticCodeCheckValidity(
            staticCode,
            validationFlags,
            requirement
        ) == errSecSuccess else {
            throw SystemUpdateSignatureError.developerIDRequired
        }

        let signatureFlags = (
            information[kSecCodeInfoFlags] as? NSNumber
        )?.uint32Value ?? 0
        let usesHardenedRuntime =
            signatureFlags & Self.hardenedRuntimeSignatureFlag != 0
        let hasSecureTimestamp =
            information[kSecCodeInfoTimestamp] as? Date != nil
        guard hasSecureTimestamp else {
            throw SystemUpdateSignatureError.secureTimestampRequired
        }
        guard usesHardenedRuntime else {
            throw SystemUpdateSignatureError.hardenedRuntimeRequired
        }

        guard Self.run(
            executableURL: URL(fileURLWithPath: "/usr/sbin/spctl"),
            arguments: [
                "--assess",
                "--type",
                "execute",
                applicationURL.path
            ]
        ) else {
            throw SystemUpdateSignatureError.gatekeeperRejected
        }

        return UpdateCodeSignatureIdentity(
            bundleIdentifier: identifier,
            teamIdentifier: teamIdentifier,
            certificateCommonName: certificateName,
            hasSecureTimestamp: true,
            usesHardenedRuntime: true,
            isDeveloperIDApplication: true,
            isGatekeeperAccepted: true
        )
    }

    private static func isValidTeamIdentifier(_ value: String) -> Bool {
        value.utf8.count == 10
            && value.utf8.allSatisfy {
                (0x30...0x39).contains($0)
                    || (0x41...0x5A).contains($0)
            }
    }

    // Security/CSCommon.h exports this as kSecCodeSignatureRuntime, but that
    // declaration is not imported into Swift.
    private static let hardenedRuntimeSignatureFlag: UInt32 = 0x0001_0000

    private static func run(
        executableURL: URL,
        arguments: [String]
    ) -> Bool {
        BoundedUpdateToolRunner.run(
            executableURL: executableURL,
            arguments: arguments,
            environment: [
                "LANG": "C",
                "LC_ALL": "C"
            ],
            timeout: toolTimeout
        )
    }
}

/// Runs short-lived system tools without allowing a malformed archive or a
/// wedged code-signing service to block update staging indefinitely.
enum BoundedUpdateToolRunner {
    static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> Bool {
        guard timeout > 0,
              FileManager.default.isExecutableFile(
                  atPath: executableURL.path
              ) else {
            return false
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard !process.isRunning else {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning, process.processIdentifier > 1 {
                kill(process.processIdentifier, SIGKILL)
            }
            return false
        }
        return process.terminationReason == .exit
            && process.terminationStatus == 0
    }
}

struct VerifiedUpdateStagingConfiguration: Equatable, Sendable {
    var signedConfiguration: SignedUpdateConfiguration
    var expectedTeamIdentifier: String?
    var currentSystemVersion: UpdateSystemVersion
    var maximumAssetByteCount: Int64
    var temporaryDirectoryURL: URL

    init(
        signedConfiguration: SignedUpdateConfiguration,
        expectedTeamIdentifier: String? = nil,
        currentSystemVersion: UpdateSystemVersion = UpdateSystemVersion(
            ProcessInfo.processInfo.operatingSystemVersion
        ),
        maximumAssetByteCount: Int64 = 512 * 1_024 * 1_024,
        temporaryDirectoryURL: URL = FileManager.default.temporaryDirectory
    ) {
        self.signedConfiguration = signedConfiguration
        self.expectedTeamIdentifier = expectedTeamIdentifier
        self.currentSystemVersion = currentSystemVersion
        self.maximumAssetByteCount = max(1, maximumAssetByteCount)
        self.temporaryDirectoryURL = temporaryDirectoryURL
    }
}

enum VerifiedUpdateInstallationState: Equatable, Sendable {
    case ready(VerifiedUpdateInstallationPlan)
}

struct VerifiedUpdateInstallationPlan: Equatable, Sendable {
    let stagedApplicationURL: URL
    let destinationApplicationURL: URL
    let relaunchBundleIdentifier: String

    /// Installation is available only after a fresh explicit confirmation and
    /// a final revalidation. Automatic replacement means the verified
    /// candidate may run the locked one-executable installer; it never means
    /// an update installs silently.
    let requiresExplicitUserConfirmation = true
    let automaticReplacementAllowed = true
    let relaunchAfterReplacement = true
}

struct VerifiedStagedUpdate: Equatable, Sendable {
    let metadata: VerifiedUpdateMetadata
    let applicationURL: URL
    let stagingDirectoryURL: URL
    let currentIdentity: UpdateCodeSignatureIdentity
    let updateIdentity: UpdateCodeSignatureIdentity
    let installationState: VerifiedUpdateInstallationState

    fileprivate let archiveURL: URL
    private let stagingLease: (any NativeUpdateStagingLease)?

    init(
        metadata: VerifiedUpdateMetadata,
        applicationURL: URL,
        stagingDirectoryURL: URL,
        archiveURL: URL,
        currentIdentity: UpdateCodeSignatureIdentity,
        updateIdentity: UpdateCodeSignatureIdentity,
        installationState: VerifiedUpdateInstallationState,
        stagingLease: (any NativeUpdateStagingLease)? = nil
    ) {
        self.metadata = metadata
        self.applicationURL = applicationURL
        self.stagingDirectoryURL = stagingDirectoryURL
        self.archiveURL = archiveURL
        self.currentIdentity = currentIdentity
        self.updateIdentity = updateIdentity
        self.installationState = installationState
        self.stagingLease = stagingLease
    }

    static func == (
        lhs: VerifiedStagedUpdate,
        rhs: VerifiedStagedUpdate
    ) -> Bool {
        lhs.metadata == rhs.metadata
            && lhs.applicationURL == rhs.applicationURL
            && lhs.stagingDirectoryURL == rhs.stagingDirectoryURL
            && lhs.currentIdentity == rhs.currentIdentity
            && lhs.updateIdentity == rhs.updateIdentity
            && lhs.installationState == rhs.installationState
            && lhs.archiveURL == rhs.archiveURL
    }
}

enum UpdateApplicationRole: Equatable, Sendable {
    case current
    case candidate
}

enum VerifiedUpdateStagingError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case missingFeedURL
    case missingPublicKey
    case insecureFeedURL
    case invalidPublicKey
    case signatureConfigurationMismatch
    case invalidExpectedTeamIdentifier
    case incompatibleSystemVersion(required: String, current: String)
    case insecureAssetURL
    case insecureAssetRedirect
    case unexpectedAssetHTTPStatus(Int)
    case assetTooLarge(signedByteCount: Int64, limit: Int64)
    case assetByteCountUnsupported
    case assetExceededSignedByteCount
    case assetByteCountMismatch(expected: Int64, actual: Int64)
    case assetDigestMismatch
    case assetTransport(URLError.Code)
    case assetTransportFailure
    case cannotCreatePrivateStagingDirectory
    case cannotWriteVerifiedAsset
    case unsafeArchive
    case invalidApplicationBundle(UpdateApplicationRole)
    case bundleIdentifierMismatch(UpdateApplicationRole)
    case versionMismatch
    case buildMismatch
    case updateIsNotNewer(currentBuild: Int)
    case signatureVerificationFailed(UpdateApplicationRole)
    case developerIDRequired(UpdateApplicationRole)
    case secureTimestampRequired(UpdateApplicationRole)
    case hardenedRuntimeRequired(UpdateApplicationRole)
    case gatekeeperApprovalRequired(UpdateApplicationRole)
    case teamIdentifierMismatch
    case unsafeStagingLocation

    var errorDescription: String? {
        switch self {
        case .missingFeedURL:
            "Update staging is disabled until an HTTPS feed is configured."
        case .missingPublicKey:
            "Update staging is disabled until a verification key is configured."
        case .insecureFeedURL:
            "The configured update feed must use HTTPS."
        case .invalidPublicKey:
            "The configured update verification key is invalid."
        case .signatureConfigurationMismatch:
            "The update metadata does not match the configured signature algorithm."
        case .invalidExpectedTeamIdentifier:
            "The configured update Team ID is invalid."
        case let .incompatibleSystemVersion(required, current):
            "The update requires macOS \(required) or later; this Mac is running \(current)."
        case .insecureAssetURL:
            "The update asset must use HTTPS."
        case .insecureAssetRedirect:
            "The update asset redirected outside HTTPS."
        case let .unexpectedAssetHTTPStatus(status):
            "The update asset server returned HTTP \(status)."
        case let .assetTooLarge(byteCount, limit):
            "The signed update is \(byteCount) bytes, above the \(limit)-byte limit."
        case .assetByteCountUnsupported:
            "The signed update size cannot be represented safely on this system."
        case .assetExceededSignedByteCount:
            "The update download exceeded its signed byte count."
        case let .assetByteCountMismatch(expected, actual):
            "The update was expected to be \(expected) bytes but was \(actual) bytes."
        case .assetDigestMismatch:
            "The update asset does not match its signed SHA-256 digest."
        case .assetTransport, .assetTransportFailure:
            "The update asset could not be downloaded."
        case .cannotCreatePrivateStagingDirectory:
            "A private update staging directory could not be created."
        case .cannotWriteVerifiedAsset:
            "The verified update asset could not be staged."
        case .unsafeArchive:
            "The update ZIP failed security validation."
        case let .invalidApplicationBundle(role):
            "\(Self.label(for: role)) is not a valid application bundle."
        case let .bundleIdentifierMismatch(role):
            "\(Self.label(for: role)) has the wrong bundle identifier."
        case .versionMismatch:
            "The staged app version does not match the signed update metadata."
        case .buildMismatch:
            "The staged app build does not match the signed update metadata."
        case let .updateIsNotNewer(currentBuild):
            "The staged update is not newer than build \(currentBuild)."
        case let .signatureVerificationFailed(role):
            "\(Self.label(for: role)) failed strict code-signature validation."
        case let .developerIDRequired(role):
            "\(Self.label(for: role)) must be signed with Developer ID Application."
        case let .secureTimestampRequired(role):
            "\(Self.label(for: role)) must have a secure signing timestamp."
        case let .hardenedRuntimeRequired(role):
            "\(Self.label(for: role)) must enable the hardened runtime."
        case let .gatekeeperApprovalRequired(role):
            "\(Self.label(for: role)) must pass Gatekeeper assessment."
        case .teamIdentifierMismatch:
            "The update Team ID does not match the installed app."
        case .unsafeStagingLocation:
            "The staged update is no longer in its private staging directory."
        }
    }

    private static func label(for role: UpdateApplicationRole) -> String {
        switch role {
        case .current:
            "The current app"
        case .candidate:
            "The staged app"
        }
    }
}

struct VerifiedUpdateStager: Sendable {
    static let bundleIdentifier = "com.rajjoshi.MojiPond"

    private let configuration: VerifiedUpdateStagingConfiguration
    private let currentApplicationURL: URL
    private let assetFetcher: any UpdateAssetFetching
    private let archiveExtractor: any VerifiedUpdateArchiveExtracting
    private let signatureVerifier:
        any UpdateApplicationSignatureVerifying

    init(
        configuration: VerifiedUpdateStagingConfiguration,
        currentApplicationURL: URL = Bundle.main.bundleURL,
        assetFetcher: any UpdateAssetFetching =
            URLSessionUpdateAssetFetcher(),
        archiveExtractor: any VerifiedUpdateArchiveExtracting =
            VerifiedUpdateArchiveExtractor(),
        signatureVerifier: any UpdateApplicationSignatureVerifying =
            SystemUpdateApplicationSignatureVerifier()
    ) {
        self.configuration = configuration
        self.currentApplicationURL = currentApplicationURL
        self.assetFetcher = assetFetcher
        self.archiveExtractor = archiveExtractor
        self.signatureVerifier = signatureVerifier
    }

    func stage(
        metadata: VerifiedUpdateMetadata
    ) async throws -> VerifiedStagedUpdate {
        try Task.checkCancellation()
        try validateSignedConfiguration(for: metadata)
        let currentBundle = try inspectBundle(
            at: currentApplicationURL,
            role: .current
        )
        guard metadata.build > currentBundle.build else {
            throw VerifiedUpdateStagingError.updateIsNotNewer(
                currentBuild: currentBundle.build
            )
        }
        let currentIdentity = try verifySignature(
            at: currentApplicationURL,
            role: .current
        )
        try validateIdentity(currentIdentity, role: .current)

        let assetData = try await downloadAndVerifyAsset(for: metadata)
        try Task.checkCancellation()

        let staging = try makePrivateStagingDirectory()
        let stagingDirectory = staging.directoryURL
        var shouldCleanUp = true
        defer {
            if shouldCleanUp {
                try? FileManager.default.removeItem(at: stagingDirectory)
            }
        }

        let archiveURL = stagingDirectory.appendingPathComponent(
            "update.zip",
            isDirectory: false
        )
        do {
            try assetData.write(to: archiveURL, options: .withoutOverwriting)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o400],
                ofItemAtPath: archiveURL.path
            )
        } catch {
            throw VerifiedUpdateStagingError.cannotWriteVerifiedAsset
        }

        let applicationURL: URL
        do {
            applicationURL = try archiveExtractor.extractApplication(
                from: archiveURL,
                to: stagingDirectory.appendingPathComponent(
                    "Expanded",
                    isDirectory: true
                )
            )
        } catch {
            throw VerifiedUpdateStagingError.unsafeArchive
        }
        try Task.checkCancellation()

        let candidateBundle = try inspectBundle(
            at: applicationURL,
            role: .candidate
        )
        guard candidateBundle.version == metadata.version else {
            throw VerifiedUpdateStagingError.versionMismatch
        }
        guard candidateBundle.build == metadata.build else {
            throw VerifiedUpdateStagingError.buildMismatch
        }
        let updateIdentity = try verifySignature(
            at: applicationURL,
            role: .candidate
        )
        try validateIdentity(updateIdentity, role: .candidate)
        guard updateIdentity.teamIdentifier
            == currentIdentity.teamIdentifier else {
            throw VerifiedUpdateStagingError.teamIdentifierMismatch
        }
        try Task.checkCancellation()

        let plan = VerifiedUpdateInstallationPlan(
            stagedApplicationURL: applicationURL,
            destinationApplicationURL: currentApplicationURL,
            relaunchBundleIdentifier: Self.bundleIdentifier
        )
        shouldCleanUp = false
        return VerifiedStagedUpdate(
            metadata: metadata,
            applicationURL: applicationURL,
            stagingDirectoryURL: stagingDirectory,
            archiveURL: archiveURL,
            currentIdentity: currentIdentity,
            updateIdentity: updateIdentity,
            installationState: .ready(plan),
            stagingLease: staging.lease
        )
    }

    /// Rechecks the immutable metadata digest, both application signatures,
    /// and same-team policy immediately before any install handoff.
    func revalidateForInstallation(
        _ stagedUpdate: VerifiedStagedUpdate
    ) throws -> VerifiedUpdateInstallationPlan {
        try validateStagingLocation(stagedUpdate)
        let archiveData: Data
        do {
            archiveData = try Data(
                contentsOf: stagedUpdate.archiveURL,
                options: [.mappedIfSafe, .uncached]
            )
        } catch {
            throw VerifiedUpdateStagingError.unsafeStagingLocation
        }
        try verifyAssetData(
            archiveData,
            metadata: stagedUpdate.metadata
        )

        let currentBundle = try inspectBundle(
            at: currentApplicationURL,
            role: .current
        )
        guard stagedUpdate.metadata.build > currentBundle.build else {
            throw VerifiedUpdateStagingError.updateIsNotNewer(
                currentBuild: currentBundle.build
            )
        }
        let candidateBundle = try inspectBundle(
            at: stagedUpdate.applicationURL,
            role: .candidate
        )
        guard candidateBundle.version == stagedUpdate.metadata.version else {
            throw VerifiedUpdateStagingError.versionMismatch
        }
        guard candidateBundle.build == stagedUpdate.metadata.build else {
            throw VerifiedUpdateStagingError.buildMismatch
        }

        let currentIdentity = try verifySignature(
            at: currentApplicationURL,
            role: .current
        )
        let updateIdentity = try verifySignature(
            at: stagedUpdate.applicationURL,
            role: .candidate
        )
        try validateIdentity(currentIdentity, role: .current)
        try validateIdentity(updateIdentity, role: .candidate)
        guard currentIdentity.teamIdentifier == updateIdentity.teamIdentifier,
              currentIdentity == stagedUpdate.currentIdentity,
              updateIdentity == stagedUpdate.updateIdentity else {
            throw VerifiedUpdateStagingError.teamIdentifierMismatch
        }

        return VerifiedUpdateInstallationPlan(
            stagedApplicationURL: stagedUpdate.applicationURL,
            destinationApplicationURL: currentApplicationURL,
            relaunchBundleIdentifier: Self.bundleIdentifier
        )
    }

    func discard(_ stagedUpdate: VerifiedStagedUpdate) throws {
        try validateStagingLocation(stagedUpdate)
        do {
            try FileManager.default.removeItem(
                at: stagedUpdate.stagingDirectoryURL
            )
        } catch {
            throw VerifiedUpdateStagingError.unsafeStagingLocation
        }
    }

    private func validateSignedConfiguration(
        for metadata: VerifiedUpdateMetadata
    ) throws {
        guard let feedURL = configuration.signedConfiguration.feedURL else {
            throw VerifiedUpdateStagingError.missingFeedURL
        }
        guard Self.isSecureHTTPSURL(feedURL) else {
            throw VerifiedUpdateStagingError.insecureFeedURL
        }
        guard let publicKey = configuration.signedConfiguration.publicKey else {
            throw VerifiedUpdateStagingError.missingPublicKey
        }
        guard Self.isValid(publicKey: publicKey) else {
            throw VerifiedUpdateStagingError.invalidPublicKey
        }
        guard publicKey.algorithm == metadata.verificationAlgorithm else {
            throw VerifiedUpdateStagingError.signatureConfigurationMismatch
        }
        guard Self.verificationKeyFingerprint(publicKey)
            == metadata.verificationKeySHA256 else {
            throw VerifiedUpdateStagingError.signatureConfigurationMismatch
        }
        if let expectedTeamIdentifier =
            configuration.expectedTeamIdentifier,
           !Self.isValidTeamIdentifier(expectedTeamIdentifier) {
            throw VerifiedUpdateStagingError.invalidExpectedTeamIdentifier
        }
        if let minimumSystemVersion = metadata.minimumSystemVersion {
            guard let required = UpdateSystemVersion(
                minimumSystemVersion
            ) else {
                throw VerifiedUpdateStagingError
                    .incompatibleSystemVersion(
                        required: minimumSystemVersion,
                        current:
                            configuration.currentSystemVersion.displayString
                    )
            }
            guard required <= configuration.currentSystemVersion else {
                throw VerifiedUpdateStagingError
                    .incompatibleSystemVersion(
                        required: required.displayString,
                        current:
                            configuration.currentSystemVersion.displayString
                    )
            }
        }
        guard Self.isSecureHTTPSURL(metadata.downloadURL) else {
            throw VerifiedUpdateStagingError.insecureAssetURL
        }
    }

    private func downloadAndVerifyAsset(
        for metadata: VerifiedUpdateMetadata
    ) async throws -> Data {
        guard metadata.assetByteCount
            <= configuration.maximumAssetByteCount else {
            throw VerifiedUpdateStagingError.assetTooLarge(
                signedByteCount: metadata.assetByteCount,
                limit: configuration.maximumAssetByteCount
            )
        }
        guard metadata.assetByteCount <= Int64(Int.max) else {
            throw VerifiedUpdateStagingError.assetByteCountUnsupported
        }

        let response: UpdateAssetResponse
        do {
            response = try await assetFetcher.fetchUpdateAsset(
                from: metadata.downloadURL,
                maximumBytes: Int(metadata.assetByteCount)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw VerifiedUpdateStagingError.assetTransport(error.code)
        } catch let error as VerifiedUpdateStagingError {
            throw error
        } catch {
            throw VerifiedUpdateStagingError.assetTransportFailure
        }
        try Task.checkCancellation()

        guard Self.isSecureHTTPSURL(response.finalURL) else {
            throw VerifiedUpdateStagingError.insecureAssetRedirect
        }
        guard response.statusCode == 200 else {
            throw VerifiedUpdateStagingError.unexpectedAssetHTTPStatus(
                response.statusCode
            )
        }
        try verifyAssetData(response.data, metadata: metadata)
        return response.data
    }

    private func verifyAssetData(
        _ data: Data,
        metadata: VerifiedUpdateMetadata
    ) throws {
        guard Int64(data.count) == metadata.assetByteCount else {
            throw VerifiedUpdateStagingError.assetByteCountMismatch(
                expected: metadata.assetByteCount,
                actual: Int64(data.count)
            )
        }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest == metadata.assetSHA256 else {
            throw VerifiedUpdateStagingError.assetDigestMismatch
        }
    }

    private func makePrivateStagingDirectory() throws -> (
        directoryURL: URL,
        lease: any NativeUpdateStagingLease
    ) {
        let fileManager = FileManager.default
        let temporaryRoot =
            configuration.temporaryDirectoryURL.standardizedFileURL
        let values = try? temporaryRoot.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ]
        )
        guard values?.isDirectory == true,
              values?.isSymbolicLink != true else {
            throw VerifiedUpdateStagingError
                .cannotCreatePrivateStagingDirectory
        }
        let resolvedRoot = temporaryRoot.resolvingSymlinksInPath()
        try? Self.scavengeStaleStagingDirectories(
            in: resolvedRoot
        )
        let directory = resolvedRoot.appendingPathComponent(
            ".mojipond-update-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            let attributes = try fileManager.attributesOfItem(
                atPath: directory.path
            )
            let permissions = (
                attributes[.posixPermissions] as? NSNumber
            )?.intValue
            guard permissions == 0o700 else {
                throw VerifiedUpdateStagingError
                    .cannotCreatePrivateStagingDirectory
            }
            let lease = try POSIXNativeUpdateStagingLease.create(
                in: directory
            )
            return (directory, lease)
        } catch let error as VerifiedUpdateStagingError {
            throw error
        } catch {
            try? fileManager.removeItem(at: directory)
            throw VerifiedUpdateStagingError
                .cannotCreatePrivateStagingDirectory
        }
    }

    /// Removes only expired, direct-child staging directories created by this
    /// updater. Symlinks, malformed names, non-owned directories, and recent
    /// handoffs are never followed or removed.
    static func scavengeStaleStagingDirectories(
        in temporaryRootURL: URL,
        now: Date = Date(),
        minimumAge: TimeInterval = 7 * 24 * 60 * 60
    ) throws {
        let root = temporaryRootURL.standardizedFileURL
            .resolvingSymlinksInPath()
        let rootValues = try root.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .fileResourceIdentifierKey
            ]
        )
        guard rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true,
              let rootIdentifier = rootValues.fileResourceIdentifier else {
            throw VerifiedUpdateStagingError
                .cannotCreatePrivateStagingDirectory
        }
        let children = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey
            ],
            options: [.skipsSubdirectoryDescendants]
        )
        for child in children {
            let name = child.lastPathComponent
            let childParentIdentifier = try? child
                .deletingLastPathComponent()
                .resourceValues(
                    forKeys: [.fileResourceIdentifierKey]
                )
                .fileResourceIdentifier
            guard isStagingDirectoryName(name),
                  let childParentIdentifier,
                  rootIdentifier.isEqual(childParentIdentifier) else {
                continue
            }
            let values = try? child.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .contentModificationDateKey
                ]
            )
            guard values?.isDirectory == true,
                  values?.isSymbolicLink != true,
                  let modificationDate =
                    values?.contentModificationDate,
                  now.timeIntervalSince(modificationDate) >= minimumAge else {
                continue
            }
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: child.path
            )
            let permissions = (
                attributes?[.posixPermissions] as? NSNumber
            )?.intValue
            let owner = (
                attributes?[.ownerAccountID] as? NSNumber
            )?.uint32Value
            guard permissions == 0o700, owner == getuid() else {
                continue
            }
            let recoveryLease:
                POSIXNativeUpdateStagingLease?
            do {
                recoveryLease = try POSIXNativeUpdateStagingLease
                    .acquireExisting(in: child)
            } catch NativeUpdateStagingLeaseError.missing {
                recoveryLease = nil
            } catch NativeUpdateStagingLeaseError.active {
                continue
            } catch {
                continue
            }
            try withExtendedLifetime(recoveryLease) {
                try FileManager.default.removeItem(at: child)
            }
        }
    }

    static func isStagingDirectoryName(_ name: String) -> Bool {
        let prefix = ".mojipond-update-"
        guard name.hasPrefix(prefix) else {
            return false
        }
        return UUID(
            uuidString: String(name.dropFirst(prefix.count))
        ) != nil
    }

    private func inspectBundle(
        at applicationURL: URL,
        role: UpdateApplicationRole
    ) throws -> UpdateApplicationBundleInfo {
        let applicationValues = try? applicationURL.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ]
        )
        guard applicationValues?.isDirectory == true,
              applicationValues?.isSymbolicLink != true else {
            throw VerifiedUpdateStagingError.invalidApplicationBundle(role)
        }
        let infoURL = applicationURL.appendingPathComponent(
            "Contents/Info.plist",
            isDirectory: false
        )
        let infoValues = try? infoURL.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ]
        )
        guard infoValues?.isRegularFile == true,
              infoValues?.isSymbolicLink != true,
              let fileSize = infoValues?.fileSize,
              fileSize > 0,
              fileSize <= 1_048_576 else {
            throw VerifiedUpdateStagingError.invalidApplicationBundle(role)
        }

        let data: Data
        let propertyList: Any
        do {
            data = try Data(contentsOf: infoURL, options: [.mappedIfSafe])
            propertyList = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
        } catch {
            throw VerifiedUpdateStagingError.invalidApplicationBundle(role)
        }
        guard let dictionary = propertyList as? [String: Any],
              let identifier = dictionary[
                  "CFBundleIdentifier"
              ] as? String else {
            throw VerifiedUpdateStagingError.invalidApplicationBundle(role)
        }
        guard identifier == Self.bundleIdentifier else {
            throw VerifiedUpdateStagingError.bundleIdentifierMismatch(role)
        }
        guard let version = dictionary[
                  "CFBundleShortVersionString"
              ] as? String,
              !version.isEmpty,
              let buildString = dictionary["CFBundleVersion"] as? String,
              let build = Int(buildString),
              build > 0,
              String(build) == buildString else {
            throw VerifiedUpdateStagingError.invalidApplicationBundle(role)
        }
        return UpdateApplicationBundleInfo(
            version: version,
            build: build
        )
    }

    private func verifySignature(
        at applicationURL: URL,
        role: UpdateApplicationRole
    ) throws -> UpdateCodeSignatureIdentity {
        do {
            return try signatureVerifier.verifyApplication(
                at: applicationURL,
                expectedBundleIdentifier: Self.bundleIdentifier
            )
        } catch {
            throw VerifiedUpdateStagingError.signatureVerificationFailed(role)
        }
    }

    private func validateIdentity(
        _ identity: UpdateCodeSignatureIdentity,
        role: UpdateApplicationRole
    ) throws {
        guard identity.bundleIdentifier == Self.bundleIdentifier else {
            throw VerifiedUpdateStagingError.bundleIdentifierMismatch(role)
        }
        guard identity.isDeveloperIDApplication,
              identity.certificateCommonName.hasPrefix(
                  "Developer ID Application: "
              ),
              Self.isValidTeamIdentifier(identity.teamIdentifier) else {
            throw VerifiedUpdateStagingError.developerIDRequired(role)
        }
        guard identity.hasSecureTimestamp else {
            throw VerifiedUpdateStagingError.secureTimestampRequired(role)
        }
        guard identity.usesHardenedRuntime else {
            throw VerifiedUpdateStagingError.hardenedRuntimeRequired(role)
        }
        guard identity.isGatekeeperAccepted else {
            throw VerifiedUpdateStagingError
                .gatekeeperApprovalRequired(role)
        }
        if let expectedTeamIdentifier =
            configuration.expectedTeamIdentifier,
           identity.teamIdentifier != expectedTeamIdentifier {
            throw VerifiedUpdateStagingError.teamIdentifierMismatch
        }
    }

    private func validateStagingLocation(
        _ stagedUpdate: VerifiedStagedUpdate
    ) throws {
        let resolvedRoot = configuration.temporaryDirectoryURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let stagingDirectory = stagedUpdate.stagingDirectoryURL
            .standardizedFileURL
        let rootIdentifier = try? resolvedRoot.resourceValues(
            forKeys: [.fileResourceIdentifierKey]
        ).fileResourceIdentifier
        let stagingParentIdentifier = try? stagingDirectory
            .deletingLastPathComponent()
            .resourceValues(
                forKeys: [.fileResourceIdentifierKey]
            )
            .fileResourceIdentifier
        guard
            Self.isStagingDirectoryName(
                stagingDirectory.lastPathComponent
            ),
            let rootIdentifier,
            let stagingParentIdentifier,
            rootIdentifier.isEqual(stagingParentIdentifier)
        else {
            throw VerifiedUpdateStagingError.unsafeStagingLocation
        }
        let values = try? stagingDirectory.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ]
        )
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: stagingDirectory.path
        )
        let permissions = (
            attributes?[.posixPermissions] as? NSNumber
        )?.intValue
        let owner = (
            attributes?[.ownerAccountID] as? NSNumber
        )?.uint32Value
        let applicationValues = try? stagedUpdate.applicationURL
            .resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey
                ]
            )
        let archiveValues = try? stagedUpdate.archiveURL.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ]
        )
        guard values?.isDirectory == true,
              values?.isSymbolicLink != true,
              permissions == 0o700,
              owner == getuid(),
              applicationValues?.isDirectory == true,
              applicationValues?.isSymbolicLink != true,
              archiveValues?.isRegularFile == true,
              archiveValues?.isSymbolicLink != true,
              archiveValues?.fileSize
                  == Int(stagedUpdate.metadata.assetByteCount),
              stagedUpdate.applicationURL.standardizedFileURL.path.hasPrefix(
                  stagingDirectory.path + "/"
              ),
              stagedUpdate.applicationURL.resolvingSymlinksInPath().path
                  .hasPrefix(stagingDirectory.path + "/"),
              stagedUpdate.archiveURL.standardizedFileURL.path.hasPrefix(
                  stagingDirectory.path + "/"
              ),
              stagedUpdate.archiveURL.resolvingSymlinksInPath().path
                  .hasPrefix(stagingDirectory.path + "/") else {
            throw VerifiedUpdateStagingError.unsafeStagingLocation
        }
    }

    private static func isSecureHTTPSURL(_ url: URL) -> Bool {
        url.scheme?.lowercased(with: Locale(identifier: "en_US_POSIX"))
            == "https"
            && !(url.host?.isEmpty ?? true)
            && url.user == nil
            && url.password == nil
    }

    private static func isValid(
        publicKey: UpdateVerificationKey
    ) -> Bool {
        switch publicKey {
        case let .ed25519(rawRepresentation):
            return (try? Curve25519.Signing.PublicKey(
                rawRepresentation: rawRepresentation
            )) != nil
        case let .p256(rawRepresentation):
            return (try? P256.Signing.PublicKey(
                rawRepresentation: rawRepresentation
            )) != nil
        }
    }

    private static func verificationKeyFingerprint(
        _ key: UpdateVerificationKey
    ) -> String {
        var fingerprintInput = Data(
            "mojipond-update-key-v1:\(key.algorithm.rawValue):".utf8
        )
        switch key {
        case let .ed25519(rawRepresentation),
             let .p256(rawRepresentation):
            fingerprintInput.append(rawRepresentation)
        }
        return SHA256.hash(data: fingerprintInput)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isValidTeamIdentifier(_ value: String) -> Bool {
        value.utf8.count == 10
            && value.utf8.allSatisfy {
                (0x30...0x39).contains($0)
                    || (0x41...0x5A).contains($0)
            }
    }
}

private struct UpdateApplicationBundleInfo {
    let version: String
    let build: Int
}

private enum SystemUpdateSignatureError: Error {
    case codesignValidationFailed
    case cannotReadSignature
    case developerIDRequired
    case secureTimestampRequired
    case hardenedRuntimeRequired
    case gatekeeperRejected
}
