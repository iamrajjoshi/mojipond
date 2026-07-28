import XCTest
@testable import MojiPond

@MainActor
final class GiphyKeySettingsModelTests: XCTestCase {
    func testRefreshReportsPresenceWithoutExposingStoredKey() {
        let store = GiphyKeyStoreStub(value: "secret-value")
        let model = GiphyKeySettingsModel(store: store)

        model.refresh()

        XCTAssertEqual(model.status, .stored)
        XCTAssertTrue(model.hasStoredKey)
        XCTAssertTrue(model.draftKey.isEmpty)
        XCTAssertFalse(model.statusTitle.contains("secret-value"))
    }

    func testSaveTrimsAndClearsDraft() {
        let store = GiphyKeyStoreStub()
        let model = GiphyKeySettingsModel(store: store)
        model.draftKey = "  development-key  "

        model.save()

        XCTAssertEqual(store.value, "development-key")
        XCTAssertTrue(model.draftKey.isEmpty)
        XCTAssertEqual(model.status, .stored)
    }

    func testRemoveDeletesStoredKey() {
        let store = GiphyKeyStoreStub(value: "key")
        let model = GiphyKeySettingsModel(store: store)
        model.refresh()

        model.remove()

        XCTAssertNil(store.value)
        XCTAssertEqual(model.status, .missing)
    }

    func testStoreFailureDoesNotExposeSecret() {
        let store = GiphyKeyStoreStub(
            value: nil,
            error: GiphyKeyStoreStubError.unavailable
        )
        let model = GiphyKeySettingsModel(store: store)
        model.draftKey = "secret-value"

        model.save()

        guard case let .failed(message) = model.status else {
            return XCTFail("Expected a safe failure state.")
        }
        XCTAssertFalse(message.contains("secret-value"))
    }
}

private enum GiphyKeyStoreStubError: Error, LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Keychain is unavailable."
    }
}

private final class GiphyKeyStoreStub:
    GiphyAPIKeyStoring,
    @unchecked Sendable
{
    var value: String?
    let error: Error?

    init(value: String? = nil, error: Error? = nil) {
        self.value = value
        self.error = error
    }

    func apiKey() throws -> String {
        if let error {
            throw error
        }
        guard let value else {
            throw RemoteMediaError.missingAPIKey
        }
        return value
    }

    func save(_ value: String) throws {
        if let error {
            throw error
        }
        self.value = value
    }

    func delete() throws {
        if let error {
            throw error
        }
        value = nil
    }
}
