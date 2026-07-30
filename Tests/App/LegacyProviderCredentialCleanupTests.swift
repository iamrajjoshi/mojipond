import Security
import XCTest
@testable import MojiPond

final class LegacyProviderCredentialCleanupTests: XCTestCase {
    func testDeletesOnlyTheLegacyGenericPasswordIdentity() throws {
        var capturedQuery: [String: Any]?
        let cleaner = KeychainLegacyProviderCredentialCleaner {
            capturedQuery = $0 as? [String: Any]
            return errSecSuccess
        }

        try cleaner.removeLegacyCredential()

        let query = try XCTUnwrap(capturedQuery)
        XCTAssertEqual(
            query[kSecClass as String] as? String,
            kSecClassGenericPassword as String
        )
        XCTAssertEqual(
            query[kSecAttrService as String] as? String,
            "com.rajjoshi.MojiPond"
        )
        XCTAssertEqual(
            query[kSecAttrAccount as String] as? String,
            "giphy-api-key"
        )
        XCTAssertEqual(query.count, 3)
    }

    func testSuccessAndMissingItemAreIdempotentSuccesses() {
        for status in [errSecSuccess, errSecItemNotFound] {
            let cleaner = KeychainLegacyProviderCredentialCleaner {
                _ in status
            }
            XCTAssertNoThrow(try cleaner.removeLegacyCredential())
        }
    }

    func testOtherKeychainFailureIsRetriable() {
        let cleaner = KeychainLegacyProviderCredentialCleaner {
            _ in errSecNotAvailable
        }

        XCTAssertThrowsError(
            try cleaner.removeLegacyCredential()
        ) { error in
            XCTAssertEqual(
                error as? LegacyProviderCredentialCleanupError,
                LegacyProviderCredentialCleanupError(
                    status: errSecNotAvailable
                )
            )
        }
    }
}
