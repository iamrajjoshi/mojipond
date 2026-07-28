import Foundation
import XCTest
@testable import MojiPond

final class ApplicationPathsTests: XCTestCase {
    func testDerivesStableSeparatedDataAndCacheLocations() {
        let paths = ApplicationPaths(
            applicationSupportBase: URL(fileURLWithPath: "/data", isDirectory: true),
            cachesBase: URL(fileURLWithPath: "/cache", isDirectory: true)
        )

        XCTAssertEqual(paths.applicationSupportRoot.path, "/data/MojiPond")
        XCTAssertEqual(paths.libraryRoot.path, "/data/MojiPond/Library")
        XCTAssertEqual(paths.usageFile.path, "/data/MojiPond/usage.json")
        XCTAssertEqual(
            paths.importStagingRoot.path,
            "/data/MojiPond/Import Staging"
        )
        XCTAssertEqual(paths.cachesRoot.path, "/cache/MojiPond")
        XCTAssertEqual(paths.mediaCacheRoot.path, "/cache/MojiPond/Media")
    }
}
