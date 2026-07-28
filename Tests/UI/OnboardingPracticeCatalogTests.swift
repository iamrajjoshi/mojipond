import XCTest
@testable import MojiPond

final class OnboardingPracticeCatalogTests: XCTestCase {
    func testSuccessfulLoadMakesPracticeCatalogAvailable() {
        let catalog = OnboardingPracticeCatalog.load {
            EmojiSearchIndex(items: [])
        }

        XCTAssertEqual(catalog.availability, .available)
        XCTAssertEqual(catalog.searchIndex?.count, 0)
        XCTAssertEqual(
            catalog.availability.title,
            "Practice suggestions ready"
        )
    }

    func testFailedLoadProvidesRecoverablePracticeState() {
        enum TestError: Error {
            case unavailable
        }

        let catalog = OnboardingPracticeCatalog.load {
            throw TestError.unavailable
        }

        XCTAssertEqual(catalog.availability, .unavailable)
        XCTAssertNil(catalog.searchIndex)
        XCTAssertEqual(
            catalog.availability.title,
            "Practice suggestions unavailable"
        )
        XCTAssertEqual(
            catalog.availability.message,
            "MojiPond could not load its built-in emoji catalog. "
                + "You can try again or continue to the Library."
        )
    }
}
