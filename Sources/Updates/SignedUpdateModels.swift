import Foundation

enum UpdateSignatureAlgorithm: String, Codable, Equatable, Sendable {
    case ed25519
    case p256SHA256 = "p256-sha256"
}

enum UpdateVerificationKey: Equatable, Sendable {
    case ed25519(rawRepresentation: Data)
    case p256(rawRepresentation: Data)

    var algorithm: UpdateSignatureAlgorithm {
        switch self {
        case .ed25519:
            .ed25519
        case .p256:
            .p256SHA256
        }
    }
}

struct SignedUpdateConfiguration: Equatable, Sendable {
    var feedURL: URL?
    var publicKey: UpdateVerificationKey?
    var automaticChecksEnabled: Bool
    var maximumFeedByteCount: Int

    init(
        feedURL: URL? = nil,
        publicKey: UpdateVerificationKey? = nil,
        automaticChecksEnabled: Bool = false,
        maximumFeedByteCount: Int = 1_048_576
    ) {
        self.feedURL = feedURL
        self.publicKey = publicKey
        self.automaticChecksEnabled = automaticChecksEnabled
        self.maximumFeedByteCount = max(1, maximumFeedByteCount)
    }
}

enum UpdateCheckKind: Equatable, Sendable {
    /// An explicit user action. This is allowed even when scheduled checks are
    /// disabled, provided a feed and public key are configured.
    case manual
    case automatic
}

enum UpdateCheckDisabledReason: Equatable, Sendable {
    case missingFeedURL
    case missingPublicKey
    case automaticChecksNotEnabled
}

enum SignedUpdateCheckResult: Equatable, Sendable {
    case disabled(UpdateCheckDisabledReason)
    case verified(VerifiedUpdateMetadata)
}

/// Metadata requires a proof value whose initializer is file-scoped to the
/// signature verifier. There is intentionally no installation operation in
/// this boundary.
struct VerifiedUpdateMetadata: Equatable, Sendable {
    let version: String
    let build: Int
    let publishedAt: Date
    let minimumSystemVersion: String?
    let downloadURL: URL
    let releaseNotesURL: URL?
    let assetSHA256: String
    let assetByteCount: Int64
    let verificationAlgorithm: UpdateSignatureAlgorithm
    let signedPayloadSHA256: String

    init(
        version: String,
        build: Int,
        publishedAt: Date,
        minimumSystemVersion: String?,
        downloadURL: URL,
        releaseNotesURL: URL?,
        assetSHA256: String,
        assetByteCount: Int64,
        verificationAlgorithm: UpdateSignatureAlgorithm,
        signedPayloadSHA256: String,
        verificationProof: UpdateVerificationProof
    ) {
        _ = verificationProof
        self.version = version
        self.build = build
        self.publishedAt = publishedAt
        self.minimumSystemVersion = minimumSystemVersion
        self.downloadURL = downloadURL
        self.releaseNotesURL = releaseNotesURL
        self.assetSHA256 = assetSHA256
        self.assetByteCount = assetByteCount
        self.verificationAlgorithm = verificationAlgorithm
        self.signedPayloadSHA256 = signedPayloadSHA256
    }
}

enum SignedUpdateCheckError: Error, Equatable, LocalizedError, Sendable {
    case insecureFeedURL
    case insecureRedirectURL
    case unexpectedHTTPStatus(Int)
    case feedTooLarge(limit: Int)
    case malformedEnvelope
    case unsupportedEnvelopeSchema(Int)
    case signatureAlgorithmMismatch
    case invalidPublicKey
    case invalidSignature
    case malformedPayload
    case unsupportedPayloadSchema(Int)
    case invalidVersion
    case invalidBuild
    case invalidDownloadURL
    case invalidReleaseNotesURL
    case invalidAssetDigest
    case invalidAssetByteCount
    case transport(URLError.Code)
    case transportFailure

    var errorDescription: String? {
        switch self {
        case .insecureFeedURL:
            "The update feed must use HTTPS."
        case .insecureRedirectURL:
            "The update request redirected outside HTTPS."
        case let .unexpectedHTTPStatus(status):
            "The update server returned HTTP \(status)."
        case let .feedTooLarge(limit):
            "The update feed exceeds the \(limit)-byte safety limit."
        case .malformedEnvelope:
            "The signed update envelope is malformed."
        case let .unsupportedEnvelopeSchema(schema):
            "Update envelope schema \(schema) is not supported."
        case .signatureAlgorithmMismatch:
            "The update signature algorithm does not match the configured public key."
        case .invalidPublicKey:
            "The configured update public key is invalid."
        case .invalidSignature:
            "The update signature could not be verified."
        case .malformedPayload:
            "The signed update payload is malformed."
        case let .unsupportedPayloadSchema(schema):
            "Update payload schema \(schema) is not supported."
        case .invalidVersion:
            "The update version is invalid."
        case .invalidBuild:
            "The update build number is invalid."
        case .invalidDownloadURL:
            "The update download URL must use HTTPS."
        case .invalidReleaseNotesURL:
            "The release-notes URL must use HTTPS."
        case .invalidAssetDigest:
            "The update asset digest must be a SHA-256 value."
        case .invalidAssetByteCount:
            "The update asset byte count must be positive."
        case .transport:
            "The update feed could not be reached."
        case .transportFailure:
            "The update request failed."
        }
    }
}

struct UpdateFeedResponse: Equatable, Sendable {
    let data: Data
    let statusCode: Int
    let finalURL: URL

    init(data: Data, statusCode: Int = 200, finalURL: URL) {
        self.data = data
        self.statusCode = statusCode
        self.finalURL = finalURL
    }
}

protocol UpdateFeedFetching: Sendable {
    func fetchUpdateFeed(from url: URL) async throws -> UpdateFeedResponse
}
