import Foundation
import XCTest
@testable import MojiPond

final class ImportHTTPTransportTests: XCTestCase {
    func testSlackPolicyRejectsPrivateAndReservedIPLiterals() throws {
        let unsafeURLs = [
            "https://127.0.0.1/emoji.png",
            "https://10.0.0.1/emoji.png",
            "https://100.64.0.1/emoji.png",
            "https://169.254.1.1/emoji.png",
            "https://172.16.0.1/emoji.png",
            "https://192.168.0.1/emoji.png",
            "https://192.0.2.1/emoji.png",
            "https://198.51.100.1/emoji.png",
            "https://203.0.113.1/emoji.png",
            "https://224.0.0.1/emoji.png",
            "https://[::1]/emoji.png",
            "https://[::]/emoji.png",
            "https://[fc00::1]/emoji.png",
            "https://[fe80::1]/emoji.png",
            "https://[2001:db8::1]/emoji.png",
            "https://[::ffff:127.0.0.1]/emoji.png"
        ]

        for value in unsafeURLs {
            let url = try ImportingTestSupport.unwrappedURL(value)
            XCTAssertThrowsError(
                try ImportURLPolicy.slackAsset.validate(url),
                "Expected rejection for \(value)"
            ) {
                guard case .unsafeNetworkDestination =
                    $0 as? ImportHTTPError else {
                    return XCTFail("Unexpected error for \(value): \($0)")
                }
            }
        }
    }

    func testSlackPolicyAllowsPublicIPv4AndIPv6Literals() throws {
        for value in [
            "https://8.8.8.8/emoji.png",
            "https://[2606:4700:4700::1111]/emoji.png"
        ] {
            try ImportURLPolicy.slackAsset.validate(
                ImportingTestSupport.unwrappedURL(value)
            )
        }
    }

    func testTransportRejectsHostnameResolvingToPrivateAddress() async throws {
        let resolver = StaticImportHostResolver(
            addresses: [.ipv4([192, 168, 1, 20])]
        )
        let transport = URLSessionImportHTTPTransport(resolver: resolver)
        let url = try ImportingTestSupport.unwrappedURL(
            "https://emoji.example/frog.png"
        )

        do {
            _ = try await transport.fetch(
                URLRequest(url: url),
                policy: .slackAsset,
                maximumBytes: 1_024
            )
            XCTFail("Expected resolved private-address rejection")
        } catch {
            XCTAssertEqual(
                error as? ImportHTTPError,
                .unsafeNetworkDestination("emoji.example")
            )
        }
    }

    func testSlackPolicyRejectsHostileRedirectToLoopback() async throws {
        let transport = MockImportHTTPTransport()
        await transport.enqueue(
            host: "emoji.example",
            outcome: .redirect(
                try ImportingTestSupport.unwrappedURL(
                    "https://[::1]/private.png"
                )
            )
        )
        let request = URLRequest(
            url: try ImportingTestSupport.unwrappedURL(
                "https://emoji.example/frog.png"
            )
        )

        do {
            _ = try await transport.fetch(
                request,
                policy: .slackAsset,
                maximumBytes: 1_024
            )
            XCTFail("Expected hostile redirect rejection")
        } catch {
            XCTAssertEqual(
                error as? ImportHTTPError,
                .unsafeNetworkDestination("::1")
            )
        }
    }
}

private struct StaticImportHostResolver: ImportHostResolving {
    let addresses: [ImportResolvedAddress]

    func resolve(host: String) throws -> [ImportResolvedAddress] {
        _ = host
        return addresses
    }
}
