import CryptoKit
import Foundation

struct URLSessionUpdateFeedFetcher: UpdateFeedFetching {
    private let responseLoader: BoundedHTTPSResponseLoader

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(
            configuration: configuration,
            delegate: nil,
            delegateQueue: nil
        )
        responseLoader = BoundedHTTPSResponseLoader(session: session)
    }

    func fetchUpdateFeed(
        from url: URL,
        maximumBytes: Int
    ) async throws -> UpdateFeedResponse {
        let loaded: BoundedHTTPResponse
        do {
            loaded = try await responseLoader.load(
                URLRequest(url: url),
                maximumBytes: maximumBytes
            )
        } catch let error as BoundedHTTPSLoadError {
            switch error {
            case .responseTooLarge:
                throw SignedUpdateCheckError.feedTooLarge(limit: maximumBytes)
            case .insecureRequestURL:
                throw SignedUpdateCheckError.insecureFeedURL
            case .insecureRedirectURL, .disallowedRedirectHost:
                throw SignedUpdateCheckError.insecureRedirectURL
            case .invalidResponse:
                throw SignedUpdateCheckError.transportFailure
            }
        }
        return UpdateFeedResponse(
            data: loaded.data,
            statusCode: loaded.response.statusCode,
            finalURL: loaded.response.url ?? url
        )
    }
}

/// Fetches and verifies signed update metadata. This type cannot download or
/// install an application update and never accepts private-key material.
struct SignedUpdateChecker: Sendable {
    private static let supportedEnvelopeSchema = 1
    private static let supportedPayloadSchema = 1

    let configuration: SignedUpdateConfiguration
    private let fetcher: any UpdateFeedFetching

    init(
        configuration: SignedUpdateConfiguration,
        fetcher: any UpdateFeedFetching = URLSessionUpdateFeedFetcher()
    ) {
        self.configuration = configuration
        self.fetcher = fetcher
    }

    func check(for kind: UpdateCheckKind) async throws -> SignedUpdateCheckResult {
        guard let feedURL = configuration.feedURL else {
            return .disabled(.missingFeedURL)
        }
        guard let publicKey = configuration.publicKey else {
            return .disabled(.missingPublicKey)
        }
        if kind == .automatic, !configuration.automaticChecksEnabled {
            return .disabled(.automaticChecksNotEnabled)
        }
        guard HTTPSURLValidator.isSecure(feedURL) else {
            throw SignedUpdateCheckError.insecureFeedURL
        }

        try Task.checkCancellation()
        let response: UpdateFeedResponse
        do {
            response = try await fetcher.fetchUpdateFeed(
                from: feedURL,
                maximumBytes: configuration.maximumFeedByteCount
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw SignedUpdateCheckError.transport(error.code)
        } catch let error as SignedUpdateCheckError {
            throw error
        } catch {
            throw SignedUpdateCheckError.transportFailure
        }
        try Task.checkCancellation()

        guard HTTPSURLValidator.isSecure(response.finalURL) else {
            throw SignedUpdateCheckError.insecureRedirectURL
        }
        guard response.statusCode == 200 else {
            throw SignedUpdateCheckError.unexpectedHTTPStatus(response.statusCode)
        }
        guard response.data.count <= configuration.maximumFeedByteCount else {
            throw SignedUpdateCheckError.feedTooLarge(
                limit: configuration.maximumFeedByteCount
            )
        }

        let envelope: SignedUpdateEnvelope
        do {
            envelope = try JSONDecoder().decode(SignedUpdateEnvelope.self, from: response.data)
        } catch {
            throw SignedUpdateCheckError.malformedEnvelope
        }
        guard envelope.schemaVersion == Self.supportedEnvelopeSchema else {
            throw SignedUpdateCheckError.unsupportedEnvelopeSchema(envelope.schemaVersion)
        }
        guard envelope.algorithm == publicKey.algorithm else {
            throw SignedUpdateCheckError.signatureAlgorithmMismatch
        }
        guard let payloadData = Data(base64Encoded: envelope.payload),
              !payloadData.isEmpty,
              let signatureData = Data(base64Encoded: envelope.signature),
              !signatureData.isEmpty else {
            throw SignedUpdateCheckError.malformedEnvelope
        }

        try UpdateSignatureVerifier.verify(
            signature: signatureData,
            payload: payloadData,
            using: publicKey
        )

        // Decode and validate metadata only after authenticity is established.
        let payload: UpdateManifestPayload
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            payload = try decoder.decode(UpdateManifestPayload.self, from: payloadData)
        } catch {
            throw SignedUpdateCheckError.malformedPayload
        }
        return .verified(
            try Self.verifiedMetadata(
                from: payload,
                algorithm: envelope.algorithm,
                verificationKey: publicKey,
                signedPayload: payloadData
            )
        )
    }

    private static func verifiedMetadata(
        from payload: UpdateManifestPayload,
        algorithm: UpdateSignatureAlgorithm,
        verificationKey: UpdateVerificationKey,
        signedPayload: Data
    ) throws -> VerifiedUpdateMetadata {
        guard payload.schemaVersion == supportedPayloadSchema else {
            throw SignedUpdateCheckError.unsupportedPayloadSchema(payload.schemaVersion)
        }
        let version = payload.version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty,
              version.utf8.count <= 64,
              version.utf8.allSatisfy({
                  (0x30...0x39).contains($0)
                      || (0x41...0x5A).contains($0)
                      || (0x61...0x7A).contains($0)
                      || $0 == 0x2D
                      || $0 == 0x2B
                      || $0 == 0x2E
              }) else {
            throw SignedUpdateCheckError.invalidVersion
        }
        guard payload.build > 0 else {
            throw SignedUpdateCheckError.invalidBuild
        }
        if let minimumSystemVersion = payload.minimumSystemVersion,
           UpdateSystemVersion(minimumSystemVersion) == nil {
            throw SignedUpdateCheckError.invalidMinimumSystemVersion
        }
        guard HTTPSURLValidator.isSecure(payload.downloadURL) else {
            throw SignedUpdateCheckError.invalidDownloadURL
        }
        if let releaseNotesURL = payload.releaseNotesURL,
           !HTTPSURLValidator.isSecure(releaseNotesURL) {
            throw SignedUpdateCheckError.invalidReleaseNotesURL
        }
        let digest = payload.assetSHA256.lowercased(with: Locale(identifier: "en_US_POSIX"))
        guard digest.utf8.count == 64,
              digest.utf8.allSatisfy({
                  (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
              }) else {
            throw SignedUpdateCheckError.invalidAssetDigest
        }
        guard payload.assetByteCount > 0 else {
            throw SignedUpdateCheckError.invalidAssetByteCount
        }

        return VerifiedUpdateMetadata(
            version: version,
            build: payload.build,
            publishedAt: payload.publishedAt,
            minimumSystemVersion: payload.minimumSystemVersion,
            downloadURL: payload.downloadURL,
            releaseNotesURL: payload.releaseNotesURL,
            assetSHA256: digest,
            assetByteCount: payload.assetByteCount,
            verificationAlgorithm: algorithm,
            verificationKeySHA256: verificationKeyFingerprint(
                verificationKey
            ),
            signedPayloadSHA256: SHA256.hash(data: signedPayload)
                .map { String(format: "%02x", $0) }
                .joined(),
            verificationProof: UpdateVerificationProof()
        )
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
}

struct UpdateVerificationProof: Sendable {
    fileprivate init() {}
}

private struct SignedUpdateEnvelope: Decodable {
    let schemaVersion: Int
    let algorithm: UpdateSignatureAlgorithm
    let payload: String
    let signature: String
}

private struct UpdateManifestPayload: Decodable {
    let schemaVersion: Int
    let version: String
    let build: Int
    let publishedAt: Date
    let minimumSystemVersion: String?
    let downloadURL: URL
    let releaseNotesURL: URL?
    let assetSHA256: String
    let assetByteCount: Int64
}

private enum UpdateSignatureVerifier {
    static func verify(
        signature: Data,
        payload: Data,
        using key: UpdateVerificationKey
    ) throws {
        switch key {
        case let .ed25519(rawRepresentation):
            let publicKey: Curve25519.Signing.PublicKey
            do {
                publicKey = try Curve25519.Signing.PublicKey(
                    rawRepresentation: rawRepresentation
                )
            } catch {
                throw SignedUpdateCheckError.invalidPublicKey
            }
            guard publicKey.isValidSignature(signature, for: payload) else {
                throw SignedUpdateCheckError.invalidSignature
            }

        case let .p256(rawRepresentation):
            let publicKey: P256.Signing.PublicKey
            do {
                publicKey = try P256.Signing.PublicKey(rawRepresentation: rawRepresentation)
            } catch {
                throw SignedUpdateCheckError.invalidPublicKey
            }
            let parsedSignature: P256.Signing.ECDSASignature
            do {
                parsedSignature = try P256.Signing.ECDSASignature(
                    rawRepresentation: signature
                )
            } catch {
                throw SignedUpdateCheckError.invalidSignature
            }
            guard publicKey.isValidSignature(parsedSignature, for: payload) else {
                throw SignedUpdateCheckError.invalidSignature
            }
        }
    }
}

private enum HTTPSURLValidator {
    static func isSecure(_ url: URL) -> Bool {
        url.scheme?.lowercased(with: Locale(identifier: "en_US_POSIX")) == "https"
            && !(url.host?.isEmpty ?? true)
            && url.user == nil
            && url.password == nil
    }
}
