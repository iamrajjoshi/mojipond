import Foundation
import XCTest

final class ThirdPartyNoticesTests: XCTestCase {
    func testDistributableBundleContainsMojiPondLicense() throws {
        let licenseURL = try XCTUnwrap(
            Bundle.main.url(
                forResource: "MOJIPOND-LICENSE",
                withExtension: "txt"
            )
        )
        let license = try String(contentsOf: licenseURL, encoding: .utf8)

        XCTAssertTrue(license.contains("MIT License"))
        XCTAssertTrue(license.contains("Copyright (c) 2026 Raj Joshi"))
        XCTAssertTrue(
            license.contains("Permission is hereby granted, free of charge")
        )
    }

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
        XCTAssertTrue(notice.contains("Pinned version: 2.9.5"))
    }

    func testDistributableBundleContainsSparkleNotices() throws {
        let noticeURL = try XCTUnwrap(
            Bundle.main.url(
                forResource: "SPARKLE-LICENSE",
                withExtension: "txt"
            )
        )
        let notice = try String(contentsOf: noticeURL, encoding: .utf8)

        for marker in [
            "Copyright (c) 2006-2013 Andy Matuschak",
            "Copyright 2003-2005 Colin Percival",
            "Copyright (c) 2008-2010 Yuta Mori",
            "Copyright (c) 2015 Orson Peters",
        ] {
            XCTAssertTrue(
                notice.contains(marker),
                "Missing Sparkle notice marker: \(marker)"
            )
        }
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
