import CryptoKit
import Foundation
import XCTest
@testable import MojiPond

final class SignedUpdateCheckerTests: XCTestCase {
    private let feedURL = URL(string: "https://updates.example.com/feed.json")!

    func testManualCheckVerifiesEd25519BeforeSurfacingMetadata() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let payload = try makePayload()
        let signature = try privateKey.signature(for: payload)
        let response = try makeResponse(
            payload: payload,
            signature: signature,
            algorithm: .ed25519
        )
        let checker = SignedUpdateChecker(
            configuration: SignedUpdateConfiguration(
                feedURL: feedURL,
                publicKey: .ed25519(
                    rawRepresentation: privateKey.publicKey.rawRepresentation
                ),
                automaticChecksEnabled: false
            ),
            fetcher: MockUpdateFeedFetcher { _ in response }
        )

        let result = try await checker.check(for: .manual)
        guard case let .verified(metadata) = result else {
            return XCTFail("Expected verified update metadata")
        }

        XCTAssertEqual(metadata.version, "1.2.3")
        XCTAssertEqual(metadata.build, 42)
        XCTAssertEqual(metadata.downloadURL.absoluteString, "https://updates.example.com/MojiPond.zip")
        XCTAssertEqual(metadata.releaseNotesURL?.absoluteString, "https://updates.example.com/notes/1.2.3")
        XCTAssertEqual(metadata.assetSHA256, String(repeating: "a", count: 64))
        XCTAssertEqual(metadata.assetByteCount, 12_345)
        XCTAssertEqual(metadata.verificationAlgorithm, .ed25519)
        XCTAssertEqual(metadata.verificationKeySHA256.count, 64)
        XCTAssertEqual(metadata.signedPayloadSHA256.count, 64)
    }

    func testAutomaticCheckVerifiesP256WhenExplicitlyEnabled() async throws {
        let privateKey = P256.Signing.PrivateKey()
        let payload = try makePayload(version: "2.0.0", build: 100)
        let signature = try privateKey.signature(for: payload).rawRepresentation
        let response = try makeResponse(
            payload: payload,
            signature: signature,
            algorithm: .p256SHA256
        )
        let checker = SignedUpdateChecker(
            configuration: SignedUpdateConfiguration(
                feedURL: feedURL,
                publicKey: .p256(rawRepresentation: privateKey.publicKey.rawRepresentation),
                automaticChecksEnabled: true
            ),
            fetcher: MockUpdateFeedFetcher { _ in response }
        )

        let result = try await checker.check(for: .automatic)
        guard case let .verified(metadata) = result else {
            return XCTFail("Expected verified update metadata")
        }
        XCTAssertEqual(metadata.version, "2.0.0")
        XCTAssertEqual(metadata.build, 100)
        XCTAssertEqual(metadata.verificationAlgorithm, .p256SHA256)
    }

    func testMissingConfigurationAndAutomaticOptOutAreHardDisabledWithoutFetching() async throws {
        let response = UpdateFeedResponse(
            data: Data(),
            finalURL: feedURL
        )
        let fetcher = CountingUpdateFeedFetcher(response: response)
        let privateKey = Curve25519.Signing.PrivateKey()

        let missingFeed = SignedUpdateChecker(
            configuration: SignedUpdateConfiguration(
                publicKey: .ed25519(
                    rawRepresentation: privateKey.publicKey.rawRepresentation
                )
            ),
            fetcher: fetcher
        )
        let missingKey = SignedUpdateChecker(
            configuration: SignedUpdateConfiguration(feedURL: feedURL),
            fetcher: fetcher
        )
        let automaticDisabled = SignedUpdateChecker(
            configuration: SignedUpdateConfiguration(
                feedURL: feedURL,
                publicKey: .ed25519(
                    rawRepresentation: privateKey.publicKey.rawRepresentation
                ),
                automaticChecksEnabled: false
            ),
            fetcher: fetcher
        )

        let missingFeedResult = try await missingFeed.check(for: .manual)
        let missingKeyResult = try await missingKey.check(for: .manual)
        let automaticDisabledResult = try await automaticDisabled.check(for: .automatic)
        let fetchCount = await fetcher.fetchCount()

        XCTAssertEqual(missingFeedResult, .disabled(.missingFeedURL))
        XCTAssertEqual(missingKeyResult, .disabled(.missingPublicKey))
        XCTAssertEqual(
            automaticDisabledResult,
            .disabled(.automaticChecksNotEnabled)
        )
        XCTAssertEqual(fetchCount, 0)
    }

    func testInsecureFeedURLIsRejectedBeforeFetching() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let fetcher = CountingUpdateFeedFetcher(
            response: UpdateFeedResponse(data: Data(), finalURL: feedURL)
        )
        let checker = SignedUpdateChecker(
            configuration: SignedUpdateConfiguration(
                feedURL: URL(string: "http://updates.example.com/feed.json"),
                publicKey: .ed25519(
                    rawRepresentation: privateKey.publicKey.rawRepresentation
                )
            ),
            fetcher: fetcher
        )

        await assertCheckError(.insecureFeedURL) {
            try await checker.check(for: .manual)
        }
        let fetchCount = await fetcher.fetchCount()
        XCTAssertEqual(fetchCount, 0)
    }

    func testOfflineErrorIsMappedWithoutLeakingRequestDetails() async {
        let privateKey = Curve25519.Signing.PrivateKey()
        let checker = SignedUpdateChecker(
            configuration: SignedUpdateConfiguration(
                feedURL: feedURL,
                publicKey: .ed25519(
                    rawRepresentation: privateKey.publicKey.rawRepresentation
                )
            ),
            fetcher: MockUpdateFeedFetcher { _ in
                throw URLError(.notConnectedToInternet)
            }
        )

        await assertCheckError(.transport(.notConnectedToInternet)) {
            try await checker.check(for: .manual)
        }
    }

    func testCancellationPropagatesAsCancellationError() async {
        let privateKey = Curve25519.Signing.PrivateKey()
        let checker = SignedUpdateChecker(
            configuration: SignedUpdateConfiguration(
                feedURL: feedURL,
                publicKey: .ed25519(
                    rawRepresentation: privateKey.publicKey.rawRepresentation
                )
            ),
            fetcher: SuspendingUpdateFeedFetcher()
        )
        let task = Task {
            try await checker.check(for: .manual)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testMalformedFeedIsRejectedBeforePayloadCanSurface() async {
        let privateKey = Curve25519.Signing.PrivateKey()
        let checker = SignedUpdateChecker(
            configuration: SignedUpdateConfiguration(
                feedURL: feedURL,
                publicKey: .ed25519(
                    rawRepresentation: privateKey.publicKey.rawRepresentation
                )
            ),
            fetcher: MockUpdateFeedFetcher { [feedURL] _ in
                UpdateFeedResponse(
                    data: Data("{not-json".utf8),
                    finalURL: feedURL
                )
            }
        )

        await assertCheckError(.malformedEnvelope) {
            try await checker.check(for: .manual)
        }
    }

    func testInvalidSignatureIsRejected() async throws {
        let trustedKey = Curve25519.Signing.PrivateKey()
        let untrustedKey = Curve25519.Signing.PrivateKey()
        let payload = try makePayload()
        let response = try makeResponse(
            payload: payload,
            signature: try untrustedKey.signature(for: payload),
            algorithm: .ed25519
        )
        let checker = SignedUpdateChecker(
            configuration: SignedUpdateConfiguration(
                feedURL: feedURL,
                publicKey: .ed25519(
                    rawRepresentation: trustedKey.publicKey.rawRepresentation
                )
            ),
            fetcher: MockUpdateFeedFetcher { _ in response }
        )

        await assertCheckError(.invalidSignature) {
            try await checker.check(for: .manual)
        }
    }

    func testSignedPayloadStillCannotSurfaceInsecureDownloadURL() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let payload = try makePayload(
            downloadURL: URL(string: "http://updates.example.com/MojiPond.zip")!
        )
        let response = try makeResponse(
            payload: payload,
            signature: try privateKey.signature(for: payload),
            algorithm: .ed25519
        )
        let checker = SignedUpdateChecker(
            configuration: SignedUpdateConfiguration(
                feedURL: feedURL,
                publicKey: .ed25519(
                    rawRepresentation: privateKey.publicKey.rawRepresentation
                )
            ),
            fetcher: MockUpdateFeedFetcher { _ in response }
        )

        await assertCheckError(.invalidDownloadURL) {
            try await checker.check(for: .manual)
        }
    }

    func testSignedPayloadRejectsMalformedMinimumSystemVersion()
        async throws
    {
        let privateKey = Curve25519.Signing.PrivateKey()
        let payload = try makePayload(
            minimumSystemVersion: "14.beta"
        )
        let response = try makeResponse(
            payload: payload,
            signature: try privateKey.signature(for: payload),
            algorithm: .ed25519
        )
        let checker = SignedUpdateChecker(
            configuration: SignedUpdateConfiguration(
                feedURL: feedURL,
                publicKey: .ed25519(
                    rawRepresentation:
                        privateKey.publicKey.rawRepresentation
                )
            ),
            fetcher: MockUpdateFeedFetcher { _ in response }
        )

        await assertCheckError(.invalidMinimumSystemVersion) {
            try await checker.check(for: .manual)
        }
    }

    func testHTTPSRequestCannotRedirectToHTTP() async {
        let privateKey = Curve25519.Signing.PrivateKey()
        let checker = SignedUpdateChecker(
            configuration: SignedUpdateConfiguration(
                feedURL: feedURL,
                publicKey: .ed25519(
                    rawRepresentation: privateKey.publicKey.rawRepresentation
                )
            ),
            fetcher: MockUpdateFeedFetcher { _ in
                UpdateFeedResponse(
                    data: Data(),
                    finalURL: URL(string: "http://updates.example.com/feed.json")!
                )
            }
        )

        await assertCheckError(.insecureRedirectURL) {
            try await checker.check(for: .manual)
        }
    }

    func testOversizedFeedAndBadHTTPStatusAreRejected() async {
        let privateKey = Curve25519.Signing.PrivateKey()
        let key = UpdateVerificationKey.ed25519(
            rawRepresentation: privateKey.publicKey.rawRepresentation
        )
        let oversized = SignedUpdateChecker(
            configuration: SignedUpdateConfiguration(
                feedURL: feedURL,
                publicKey: key,
                maximumFeedByteCount: 4
            ),
            fetcher: MockUpdateFeedFetcher { [feedURL] _ in
                UpdateFeedResponse(data: Data(repeating: 1, count: 5), finalURL: feedURL)
            }
        )
        let badStatus = SignedUpdateChecker(
            configuration: SignedUpdateConfiguration(
                feedURL: feedURL,
                publicKey: key
            ),
            fetcher: MockUpdateFeedFetcher { [feedURL] _ in
                UpdateFeedResponse(data: Data(), statusCode: 503, finalURL: feedURL)
            }
        )

        await assertCheckError(.feedTooLarge(limit: 4)) {
            try await oversized.check(for: .manual)
        }
        await assertCheckError(.unexpectedHTTPStatus(503)) {
            try await badStatus.check(for: .manual)
        }
    }

    private func makePayload(
        version: String = "1.2.3",
        build: Int = 42,
        minimumSystemVersion: String? = "14.0",
        downloadURL: URL = URL(string: "https://updates.example.com/MojiPond.zip")!
    ) throws -> Data {
        let payload = UpdatePayloadFixture(
            schemaVersion: 1,
            version: version,
            build: build,
            publishedAt: Date(timeIntervalSince1970: 1_800_000_000),
            minimumSystemVersion: minimumSystemVersion,
            downloadURL: downloadURL,
            releaseNotesURL: URL(string: "https://updates.example.com/notes/1.2.3"),
            assetSHA256: String(repeating: "a", count: 64),
            assetByteCount: 12_345
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    private func makeResponse(
        payload: Data,
        signature: Data,
        algorithm: UpdateSignatureAlgorithm
    ) throws -> UpdateFeedResponse {
        let envelope = UpdateEnvelopeFixture(
            schemaVersion: 1,
            algorithm: algorithm,
            payload: payload.base64EncodedString(),
            signature: signature.base64EncodedString()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return UpdateFeedResponse(
            data: try encoder.encode(envelope),
            finalURL: feedURL
        )
    }

    private func assertCheckError(
        _ expected: SignedUpdateCheckError,
        operation: () async throws -> SignedUpdateCheckResult
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)")
        } catch let error as SignedUpdateCheckError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Expected SignedUpdateCheckError, got \(error)")
        }
    }
}

private struct UpdatePayloadFixture: Encodable {
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

private struct UpdateEnvelopeFixture: Encodable {
    let schemaVersion: Int
    let algorithm: UpdateSignatureAlgorithm
    let payload: String
    let signature: String
}

private struct MockUpdateFeedFetcher: UpdateFeedFetching {
    let handler: @Sendable (URL) async throws -> UpdateFeedResponse

    init(handler: @escaping @Sendable (URL) async throws -> UpdateFeedResponse) {
        self.handler = handler
    }

    func fetchUpdateFeed(
        from url: URL,
        maximumBytes: Int
    ) async throws -> UpdateFeedResponse {
        _ = maximumBytes
        return try await handler(url)
    }
}

private actor CountingUpdateFeedFetcher: UpdateFeedFetching {
    private var count = 0
    private let response: UpdateFeedResponse

    init(response: UpdateFeedResponse) {
        self.response = response
    }

    func fetchUpdateFeed(
        from url: URL,
        maximumBytes: Int
    ) async throws -> UpdateFeedResponse {
        _ = url
        _ = maximumBytes
        count += 1
        return response
    }

    func fetchCount() -> Int {
        count
    }
}

private struct SuspendingUpdateFeedFetcher: UpdateFeedFetching {
    func fetchUpdateFeed(
        from url: URL,
        maximumBytes: Int
    ) async throws -> UpdateFeedResponse {
        _ = maximumBytes
        try await Task.sleep(for: .seconds(30))
        return UpdateFeedResponse(data: Data(), finalURL: url)
    }
}
