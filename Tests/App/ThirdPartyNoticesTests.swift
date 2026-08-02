import Foundation
import XCTest

final class ThirdPartyNoticesTests: XCTestCase {
    func testDistributableBundleContainsRequiredNotices() throws {
        let noticeURL = try XCTUnwrap(
            Bundle.main.url(
                forResource: "THIRD-PARTY-NOTICES",
                withExtension: "txt"
            )
        )
        let notice = try String(contentsOf: noticeURL, encoding: .utf8)

        XCTAssertTrue(notice.contains("Copyright (c) 2019 GitHub, Inc."))
        XCTAssertTrue(
            notice.contains("Copyright (c) 2026 Josh LaCalamito")
        )
        XCTAssertTrue(notice.contains("Copyright (c) 2015 Sentry"))
        XCTAssertTrue(
            notice.contains("Creative Commons Attribution 4.0")
        )
    }

    func testDistributableBundleContainsSentryTransitiveNotices() throws {
        let noticeURL = try XCTUnwrap(
            Bundle.main.url(
                forResource: "SENTRY-THIRD-PARTY-NOTICES",
                withExtension: "txt"
            )
        )
        let notice = try String(contentsOf: noticeURL, encoding: .utf8)

        for marker in [
            "Karl Stenerud",
            "YANDEX LLC",
            "Facebook, Inc.",
            "Apple Public Source License",
        ] {
            XCTAssertTrue(
                notice.contains(marker),
                "Missing Sentry transitive notice marker: \(marker)"
            )
        }
    }

    func testGemojiProvenanceNamesBundledNotice() throws {
        let provenanceURL = try XCTUnwrap(
            Bundle.main.url(
                forResource: "gemoji.provenance",
                withExtension: "json"
            )
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: provenanceURL)
            ) as? [String: Any]
        )

        XCTAssertEqual(
            object["bundledNotice"] as? String,
            "THIRD-PARTY-NOTICES.txt"
        )
    }
}
