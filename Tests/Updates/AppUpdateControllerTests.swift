import Foundation
import XCTest
@testable import MojiPond

@MainActor
final class AppUpdateControllerTests: XCTestCase {
    func testBundleConfigurationRequiresMatchingAlgorithmAndBase64Key() {
        let keyData = Data([1, 2, 3, 4])
        let configuration = BundledUpdateConfigurationLoader.load(
            infoDictionary: [
                BundledUpdateConfigurationLoader.feedURLKey:
                    "https://updates.example.com/feed.json",
                BundledUpdateConfigurationLoader.publicKeyKey:
                    keyData.base64EncodedString(),
                BundledUpdateConfigurationLoader.algorithmKey:
                    UpdateSignatureAlgorithm.ed25519.rawValue
            ],
            automaticChecksEnabled: true
        )

        XCTAssertEqual(
            configuration.feedURL?.absoluteString,
            "https://updates.example.com/feed.json"
        )
        XCTAssertEqual(
            configuration.publicKey,
            .ed25519(rawRepresentation: keyData)
        )
        XCTAssertTrue(configuration.automaticChecksEnabled)

        let malformed = BundledUpdateConfigurationLoader.load(
            infoDictionary: [
                BundledUpdateConfigurationLoader.feedURLKey:
                    "https://updates.example.com/feed.json",
                BundledUpdateConfigurationLoader.publicKeyKey:
                    "not base64",
                BundledUpdateConfigurationLoader.algorithmKey:
                    UpdateSignatureAlgorithm.ed25519.rawValue
            ],
            automaticChecksEnabled: false
        )
        XCTAssertNil(malformed.publicKey)
    }

    func testManualCheckReportsMissingSignedConfigurationWithoutFetching()
        async
    {
        let controller = AppUpdateController(
            configuration: SignedUpdateConfiguration()
        )

        controller.checkManually(automaticChecksEnabled: false)
        await waitForCheckToFinish(controller)

        XCTAssertEqual(controller.state, .disabled(.missingFeedURL))
        XCTAssertEqual(
            controller.statusSummary,
            "Disabled until a signed feed is configured"
        )
    }

    func testAutomaticOptOutDoesNotStartACheck() {
        let configuration = SignedUpdateConfiguration(
            feedURL: URL(
                string: "https://updates.example.com/feed.json"
            ),
            publicKey: .ed25519(rawRepresentation: Data([1]))
        )
        let controller = AppUpdateController(
            configuration: configuration
        )

        controller.start(automaticChecksEnabled: false)

        XCTAssertEqual(controller.state, .idle)
    }

    func testVerificationFailureSurfacesWithoutFeedContents() async {
        let configuration = SignedUpdateConfiguration(
            feedURL: URL(
                string: "https://updates.example.com/feed.json"
            ),
            publicKey: .ed25519(rawRepresentation: Data([1]))
        )
        let controller = AppUpdateController(
            configuration: configuration,
            checkerFactory: { _ in
                FailingUpdateChecker(error: .invalidSignature)
            }
        )

        controller.checkManually(automaticChecksEnabled: false)
        await waitForCheckToFinish(controller)

        XCTAssertEqual(
            controller.state,
            .failed(
                SignedUpdateCheckError.invalidSignature.errorDescription!
            )
        )
    }

    private func waitForCheckToFinish(
        _ controller: AppUpdateController
    ) async {
        for _ in 0..<100 where controller.isChecking {
            await Task.yield()
        }
    }
}

private struct FailingUpdateChecker: SignedUpdateChecking {
    let error: SignedUpdateCheckError

    func check(
        for kind: UpdateCheckKind
    ) async throws -> SignedUpdateCheckResult {
        _ = kind
        throw error
    }
}
