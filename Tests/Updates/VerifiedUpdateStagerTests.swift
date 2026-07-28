import CryptoKit
import Foundation
import XCTest
@testable import MojiPond

final class VerifiedUpdateStagerTests: XCTestCase {
    private let feedURL = URL(
        string: "https://updates.example.com/feed.json"
    )!
    private let assetURL = URL(
        string: "https://cdn.example.com/MojiPond.zip"
    )!

    func testStagesOnlyVerifiedArchiveAndReturnsExplicitInstallPlan()
        async throws
    {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let currentURL = try makeCurrentApplication(in: root)
        let archive = try makeApplicationArchive()
        let fixture = try await makeVerifiedMetadata(for: archive)
        let fetcher = RecordingUpdateAssetFetcher(
            response: UpdateAssetResponse(
                data: archive,
                finalURL: assetURL
            )
        )
        let stager = makeStager(
            root: root,
            currentURL: currentURL,
            signedConfiguration: fixture.configuration,
            fetcher: fetcher
        )

        let staged = try await stager.stage(metadata: fixture.metadata)
        let requestedMaximumBytes = await fetcher.requestedMaximumBytes()

        XCTAssertEqual(
            staged.metadata.verificationKeySHA256.count,
            64
        )
        XCTAssertEqual(
            requestedMaximumBytes,
            archive.count
        )
        XCTAssertEqual(
            staged.applicationURL.lastPathComponent,
            "MojiPond.app"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: staged.applicationURL.path
            )
        )
        let stagingPermissions = try FileManager.default.attributesOfItem(
            atPath: staged.stagingDirectoryURL.path
        )[.posixPermissions] as? NSNumber
        XCTAssertEqual(stagingPermissions?.intValue, 0o700)
        let executableURL = staged.applicationURL.appendingPathComponent(
            "Contents/MacOS/MojiPond",
            isDirectory: false
        )
        let executablePermissions = try FileManager.default.attributesOfItem(
            atPath: executableURL.path
        )[.posixPermissions] as? NSNumber
        XCTAssertEqual(executablePermissions?.intValue, 0o755)

        guard case let .ready(plan) =
            staged.installationState else {
            return XCTFail("Expected an explicit installation state")
        }
        XCTAssertEqual(plan.stagedApplicationURL, staged.applicationURL)
        XCTAssertEqual(plan.destinationApplicationURL, currentURL)
        XCTAssertTrue(plan.requiresExplicitUserConfirmation)
        XCTAssertTrue(plan.automaticReplacementAllowed)
        XCTAssertTrue(plan.relaunchAfterReplacement)

        let revalidatedPlan = try stager.revalidateForInstallation(staged)
        XCTAssertEqual(revalidatedPlan, plan)
        try stager.discard(staged)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: staged.stagingDirectoryURL.path
            )
        )
    }

    func testArchiveExtractorAcceptsSanitizedReleaseStyleDittoZIP() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent(
            "Source",
            isDirectory: true
        )
        let applicationURL = sourceRoot.appendingPathComponent(
            "MojiPond.app",
            isDirectory: true
        )
        let executableDirectory = applicationURL.appendingPathComponent(
            "Contents/MacOS",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: executableDirectory,
            withIntermediateDirectories: true
        )
        let infoPlistURL = applicationURL.appendingPathComponent(
            "Contents/Info.plist"
        )
        try makeInfoPlist(version: "2.0.0", build: 2).write(
            to: infoPlistURL
        )
        let executableURL = executableDirectory.appendingPathComponent(
            "MojiPond"
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        let xattrProcess = Process()
        xattrProcess.executableURL = URL(
            fileURLWithPath: "/usr/bin/xattr"
        )
        xattrProcess.arguments = [
            "-w",
            "com.example.mojipond-test",
            "metadata",
            infoPlistURL.path
        ]
        xattrProcess.standardOutput = FileHandle.nullDevice
        xattrProcess.standardError = FileHandle.nullDevice
        try xattrProcess.run()
        xattrProcess.waitUntilExit()
        XCTAssertEqual(xattrProcess.terminationStatus, 0)

        let archiveURL = root.appendingPathComponent("MojiPond.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [
            "-c",
            "-k",
            "--norsrc",
            "--noextattr",
            "--noqtn",
            "--keepParent",
            applicationURL.path,
            archiveURL.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let inspection = try ZipArchiveExtractor(
            limits: .init(
                maximumArchiveBytes: 10 * 1_024 * 1_024,
                maximumEntryCount: 100,
                maximumEntryBytes: 1 * 1_024 * 1_024,
                maximumTotalUncompressedBytes: 10 * 1_024 * 1_024,
                maximumCompressionRatio: 200,
                maximumPathBytes: 1_024,
                maximumPathComponentBytes: 255
            )
        ).inspect(archiveAt: archiveURL)
        XCTAssertFalse(
            inspection.entries.contains {
                $0.path.hasPrefix("__MACOSX/")
            }
        )

        let extractedURL = try VerifiedUpdateArchiveExtractor()
            .extractApplication(
                from: archiveURL,
                to: root.appendingPathComponent(
                    "Expanded",
                    isDirectory: true
                )
            )

        XCTAssertEqual(extractedURL.lastPathComponent, "MojiPond.app")
        XCTAssertTrue(
            FileManager.default.isExecutableFile(
                atPath: extractedURL.appendingPathComponent(
                    "Contents/MacOS/MojiPond"
                ).path
            )
        )
    }

    func testUpdateToolRunnerTimesOutWedgedProcess() {
        let startedAt = Date()
        XCTAssertFalse(
            BoundedUpdateToolRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "while :; do :; done"],
                environment: [
                    "LANG": "C",
                    "LC_ALL": "C"
                ],
                timeout: 0.05
            )
        )
        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt),
            2
        )
    }

    func testRejectsSignedByteCountMismatchAndDigestMismatch()
        async throws
    {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let currentURL = try makeCurrentApplication(in: root)
        let archive = try makeApplicationArchive()

        let wrongCountFixture = try await makeVerifiedMetadata(
            for: archive,
            assetByteCount: Int64(archive.count + 1)
        )
        let wrongCountStager = makeStager(
            root: root,
            currentURL: currentURL,
            signedConfiguration: wrongCountFixture.configuration,
            assetData: archive
        )
        await assertStagingError(
            .assetByteCountMismatch(
                expected: Int64(archive.count + 1),
                actual: Int64(archive.count)
            )
        ) {
            try await wrongCountStager.stage(
                metadata: wrongCountFixture.metadata
            )
        }

        let wrongDigestFixture = try await makeVerifiedMetadata(
            for: archive,
            assetSHA256: String(repeating: "0", count: 64)
        )
        let wrongDigestStager = makeStager(
            root: root,
            currentURL: currentURL,
            signedConfiguration: wrongDigestFixture.configuration,
            assetData: archive
        )
        await assertStagingError(.assetDigestMismatch) {
            try await wrongDigestStager.stage(
                metadata: wrongDigestFixture.metadata
            )
        }
        XCTAssertTrue(try updateStagingDirectories(in: root).isEmpty)
    }

    func testRejectsAssetAboveLocalLimitWithoutDownloading()
        async throws
    {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let currentURL = try makeCurrentApplication(in: root)
        let archive = try makeApplicationArchive()
        let fixture = try await makeVerifiedMetadata(for: archive)
        let fetcher = RecordingUpdateAssetFetcher(
            response: UpdateAssetResponse(
                data: archive,
                finalURL: assetURL
            )
        )
        let stager = makeStager(
            root: root,
            currentURL: currentURL,
            signedConfiguration: fixture.configuration,
            fetcher: fetcher,
            maximumAssetByteCount: Int64(archive.count - 1)
        )

        await assertStagingError(
            .assetTooLarge(
                signedByteCount: Int64(archive.count),
                limit: Int64(archive.count - 1)
            )
        ) {
            try await stager.stage(metadata: fixture.metadata)
        }
        let fetchCount = await fetcher.fetchCount()
        XCTAssertEqual(fetchCount, 0)
    }

    func testRejectsTraversalSymlinkAndUnexpectedRootPayload()
        async throws
    {
        let variants: [Data] = [
            try makeApplicationArchive(
                additionalEntries: [
                    .init(
                        path: "../outside",
                        data: Data("bad".utf8)
                    )
                ]
            ),
            try makeApplicationArchive(
                additionalEntries: [
                    .init(
                        path: "MojiPond.app/Contents/link",
                        data: Data("../../outside".utf8),
                        unixMode: 0o120777
                    )
                ]
            ),
            try makeApplicationArchive(
                additionalEntries: [
                    .init(
                        path: "README.txt",
                        data: Data("unexpected".utf8)
                    )
                ]
            )
        ]

        for archive in variants {
            let root = try TestSupport.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let currentURL = try makeCurrentApplication(in: root)
            let fixture = try await makeVerifiedMetadata(for: archive)
            let stager = makeStager(
                root: root,
                currentURL: currentURL,
                signedConfiguration: fixture.configuration,
                assetData: archive
            )

            await assertStagingError(.unsafeArchive) {
                try await stager.stage(metadata: fixture.metadata)
            }
            XCTAssertTrue(try updateStagingDirectories(in: root).isEmpty)
        }
    }

    func testRejectsArchiveContainingMoreThanOneApplication()
        async throws
    {
        let secondInfo = try makeInfoPlist(version: "2.0.0", build: 2)
        let archive = try makeApplicationArchive(
            additionalEntries: [
                .init(
                    path: "Other/MojiPond.app/",
                    data: Data(),
                    unixMode: 0o040755
                ),
                .init(
                    path: "Other/MojiPond.app/Contents/",
                    data: Data(),
                    unixMode: 0o040755
                ),
                .init(
                    path: "Other/MojiPond.app/Contents/Info.plist",
                    data: secondInfo
                )
            ]
        )
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let currentURL = try makeCurrentApplication(in: root)
        let fixture = try await makeVerifiedMetadata(for: archive)
        let stager = makeStager(
            root: root,
            currentURL: currentURL,
            signedConfiguration: fixture.configuration,
            assetData: archive
        )

        await assertStagingError(.unsafeArchive) {
            try await stager.stage(metadata: fixture.metadata)
        }
    }

    func testRequiresExactBundleMetadata() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let currentURL = try makeCurrentApplication(in: root)
        let wrongVersionArchive = try makeApplicationArchive(
            version: "2.0.1",
            build: 2
        )
        let wrongVersionFixture = try await makeVerifiedMetadata(
            for: wrongVersionArchive,
            version: "2.0.0",
            build: 2
        )
        let wrongVersionStager = makeStager(
            root: root,
            currentURL: currentURL,
            signedConfiguration: wrongVersionFixture.configuration,
            assetData: wrongVersionArchive
        )

        await assertStagingError(.versionMismatch) {
            try await wrongVersionStager.stage(
                metadata: wrongVersionFixture.metadata
            )
        }

        let wrongIdentifierArchive = try makeApplicationArchive(
            bundleIdentifier: "com.attacker.MojiPond"
        )
        let wrongIdentifierFixture = try await makeVerifiedMetadata(
            for: wrongIdentifierArchive
        )
        let wrongIdentifierStager = makeStager(
            root: root,
            currentURL: currentURL,
            signedConfiguration: wrongIdentifierFixture.configuration,
            assetData: wrongIdentifierArchive
        )
        await assertStagingError(.bundleIdentifierMismatch(.candidate)) {
            try await wrongIdentifierStager.stage(
                metadata: wrongIdentifierFixture.metadata
            )
        }
    }

    func testRequiresDeveloperIDSecurityPropertiesAndSameTeam()
        async throws
    {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let currentURL = try makeCurrentApplication(in: root)
        let archive = try makeApplicationArchive()
        let fixture = try await makeVerifiedMetadata(for: archive)

        let adHocStager = makeStager(
            root: root,
            currentURL: currentURL,
            signedConfiguration: fixture.configuration,
            assetData: archive,
            signatureVerifier: MockUpdateSignatureVerifier { url in
                Self.identity(
                    teamIdentifier: "ABCDE12345",
                    isDeveloperIDApplication: url != currentURL
                )
            }
        )
        await assertStagingError(.developerIDRequired(.current)) {
            try await adHocStager.stage(metadata: fixture.metadata)
        }

        let teamMismatchStager = makeStager(
            root: root,
            currentURL: currentURL,
            signedConfiguration: fixture.configuration,
            assetData: archive,
            signatureVerifier: MockUpdateSignatureVerifier { url in
                Self.identity(
                    teamIdentifier: url == currentURL
                        ? "ABCDE12345"
                        : "ZYXWV98765"
                )
            }
        )
        await assertStagingError(.teamIdentifierMismatch) {
            try await teamMismatchStager.stage(
                metadata: fixture.metadata
            )
        }

        let noTimestampStager = makeStager(
            root: root,
            currentURL: currentURL,
            signedConfiguration: fixture.configuration,
            assetData: archive,
            signatureVerifier: MockUpdateSignatureVerifier { url in
                Self.identity(
                    hasSecureTimestamp: url != currentURL
                )
            }
        )
        await assertStagingError(.secureTimestampRequired(.current)) {
            try await noTimestampStager.stage(
                metadata: fixture.metadata
            )
        }
    }

    func testSignedConfigurationIsRequiredForStaging() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let currentURL = try makeCurrentApplication(in: root)
        let archive = try makeApplicationArchive()
        let fixture = try await makeVerifiedMetadata(for: archive)
        let missingKeyConfiguration = SignedUpdateConfiguration(
            feedURL: feedURL
        )
        let stager = makeStager(
            root: root,
            currentURL: currentURL,
            signedConfiguration: missingKeyConfiguration,
            assetData: archive
        )

        await assertStagingError(.missingPublicKey) {
            try await stager.stage(metadata: fixture.metadata)
        }

        let unrelatedKey = Curve25519.Signing.PrivateKey()
        let mismatchedConfiguration = SignedUpdateConfiguration(
            feedURL: feedURL,
            publicKey: .ed25519(
                rawRepresentation:
                    unrelatedKey.publicKey.rawRepresentation
            )
        )
        let mismatchedStager = makeStager(
            root: root,
            currentURL: currentURL,
            signedConfiguration: mismatchedConfiguration,
            assetData: archive
        )
        await assertStagingError(.signatureConfigurationMismatch) {
            try await mismatchedStager.stage(
                metadata: fixture.metadata
            )
        }
    }

    func testRejectsUpdateThatRequiresNewerSystemBeforeDownload()
        async throws
    {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let currentURL = try makeCurrentApplication(in: root)
        let archive = try makeApplicationArchive()
        let fixture = try await makeVerifiedMetadata(
            for: archive,
            minimumSystemVersion: "15.1"
        )
        let fetcher = RecordingUpdateAssetFetcher(
            response: UpdateAssetResponse(
                data: archive,
                finalURL: assetURL
            )
        )
        let stager = makeStager(
            root: root,
            currentURL: currentURL,
            signedConfiguration: fixture.configuration,
            fetcher: fetcher,
            currentSystemVersion: try XCTUnwrap(
                UpdateSystemVersion("15.0")
            )
        )

        await assertStagingError(
            .incompatibleSystemVersion(
                required: "15.1",
                current: "15.0"
            )
        ) {
            try await stager.stage(metadata: fixture.metadata)
        }
        let fetchCount = await fetcher.fetchCount()
        XCTAssertEqual(fetchCount, 0)
    }

    private func makeStager(
        root: URL,
        currentURL: URL,
        signedConfiguration: SignedUpdateConfiguration,
        assetData: Data,
        signatureVerifier: any UpdateApplicationSignatureVerifying =
            MockUpdateSignatureVerifier(),
        maximumAssetByteCount: Int64 = 512 * 1_024 * 1_024
    ) -> VerifiedUpdateStager {
        makeStager(
            root: root,
            currentURL: currentURL,
            signedConfiguration: signedConfiguration,
            fetcher: RecordingUpdateAssetFetcher(
                response: UpdateAssetResponse(
                    data: assetData,
                    finalURL: assetURL
                )
            ),
            signatureVerifier: signatureVerifier,
            maximumAssetByteCount: maximumAssetByteCount
        )
    }

    private func makeStager(
        root: URL,
        currentURL: URL,
        signedConfiguration: SignedUpdateConfiguration,
        fetcher: any UpdateAssetFetching,
        signatureVerifier: any UpdateApplicationSignatureVerifying =
            MockUpdateSignatureVerifier(),
        currentSystemVersion: UpdateSystemVersion = UpdateSystemVersion(
            OperatingSystemVersion(
                majorVersion: 99,
                minorVersion: 0,
                patchVersion: 0
            )
        ),
        maximumAssetByteCount: Int64 = 512 * 1_024 * 1_024
    ) -> VerifiedUpdateStager {
        VerifiedUpdateStager(
            configuration: VerifiedUpdateStagingConfiguration(
                signedConfiguration: signedConfiguration,
                currentSystemVersion: currentSystemVersion,
                maximumAssetByteCount: maximumAssetByteCount,
                temporaryDirectoryURL: root
            ),
            currentApplicationURL: currentURL,
            assetFetcher: fetcher,
            signatureVerifier: signatureVerifier
        )
    }

    private func makeCurrentApplication(in root: URL) throws -> URL {
        let applicationURL = root.appendingPathComponent(
            "Current-MojiPond.app",
            isDirectory: true
        )
        let contentsURL = applicationURL.appendingPathComponent(
            "Contents",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: contentsURL,
            withIntermediateDirectories: true
        )
        try makeInfoPlist(version: "1.0.0", build: 1).write(
            to: contentsURL.appendingPathComponent("Info.plist")
        )
        return applicationURL
    }

    private func makeApplicationArchive(
        bundleIdentifier: String =
            VerifiedUpdateStager.bundleIdentifier,
        version: String = "2.0.0",
        build: Int = 2,
        additionalEntries: [TestZipBuilder.Entry] = []
    ) throws -> Data {
        let info = try makeInfoPlist(
            bundleIdentifier: bundleIdentifier,
            version: version,
            build: build
        )
        let entries: [TestZipBuilder.Entry] = [
            .init(
                path: "MojiPond.app/",
                data: Data(),
                unixMode: 0o040755
            ),
            .init(
                path: "MojiPond.app/Contents/",
                data: Data(),
                unixMode: 0o040755
            ),
            .init(
                path: "MojiPond.app/Contents/Info.plist",
                data: info
            ),
            .init(
                path: "MojiPond.app/Contents/MacOS/",
                data: Data(),
                unixMode: 0o040755
            ),
            .init(
                path: "MojiPond.app/Contents/MacOS/MojiPond",
                data: Data("#!/bin/sh\nexit 0\n".utf8),
                unixMode: 0o100755
            )
        ]
        return TestZipBuilder.archive(
            entries: entries + additionalEntries
        )
    }

    private func makeInfoPlist(
        bundleIdentifier: String =
            VerifiedUpdateStager.bundleIdentifier,
        version: String,
        build: Int
    ) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": bundleIdentifier,
                "CFBundleShortVersionString": version,
                "CFBundleVersion": String(build),
                "CFBundleExecutable": "MojiPond",
                "CFBundlePackageType": "APPL"
            ],
            format: .xml,
            options: 0
        )
    }

    private func makeVerifiedMetadata(
        for archive: Data,
        version: String = "2.0.0",
        build: Int = 2,
        minimumSystemVersion: String? = "14.0",
        assetSHA256: String? = nil,
        assetByteCount: Int64? = nil
    ) async throws -> VerifiedUpdateFixture {
        let privateKey = Curve25519.Signing.PrivateKey()
        let digest = assetSHA256 ?? SHA256.hash(data: archive)
            .map { String(format: "%02x", $0) }
            .joined()
        let payload = UpdateStagingPayloadFixture(
            schemaVersion: 1,
            version: version,
            build: build,
            publishedAt: Date(timeIntervalSince1970: 1_800_000_000),
            minimumSystemVersion: minimumSystemVersion,
            downloadURL: assetURL,
            releaseNotesURL: nil,
            assetSHA256: digest,
            assetByteCount: assetByteCount ?? Int64(archive.count)
        )
        let payloadEncoder = JSONEncoder()
        payloadEncoder.outputFormatting = [.sortedKeys]
        payloadEncoder.dateEncodingStrategy = .iso8601
        let payloadData = try payloadEncoder.encode(payload)
        let envelope = UpdateStagingEnvelopeFixture(
            schemaVersion: 1,
            algorithm: .ed25519,
            payload: payloadData.base64EncodedString(),
            signature: try privateKey.signature(
                for: payloadData
            ).base64EncodedString()
        )
        let envelopeEncoder = JSONEncoder()
        envelopeEncoder.outputFormatting = [.sortedKeys]
        let envelopeData = try envelopeEncoder.encode(envelope)
        let signedConfiguration = SignedUpdateConfiguration(
            feedURL: feedURL,
            publicKey: .ed25519(
                rawRepresentation: privateKey.publicKey.rawRepresentation
            )
        )
        let checker = SignedUpdateChecker(
            configuration: signedConfiguration,
            fetcher: UpdateStagingFeedFetcher(
                response: UpdateFeedResponse(
                    data: envelopeData,
                    finalURL: feedURL
                )
            )
        )
        let result = try await checker.check(for: .manual)
        guard case let .verified(metadata) = result else {
            throw UpdateStagingTestError.metadataWasNotVerified
        }
        return VerifiedUpdateFixture(
            metadata: metadata,
            configuration: signedConfiguration
        )
    }

    private static func identity(
        teamIdentifier: String = "ABCDE12345",
        hasSecureTimestamp: Bool = true,
        usesHardenedRuntime: Bool = true,
        isDeveloperIDApplication: Bool = true,
        isGatekeeperAccepted: Bool = true
    ) -> UpdateCodeSignatureIdentity {
        UpdateCodeSignatureIdentity(
            bundleIdentifier: VerifiedUpdateStager.bundleIdentifier,
            teamIdentifier: teamIdentifier,
            certificateCommonName:
                "Developer ID Application: MojiPond Tests (\(teamIdentifier))",
            hasSecureTimestamp: hasSecureTimestamp,
            usesHardenedRuntime: usesHardenedRuntime,
            isDeveloperIDApplication: isDeveloperIDApplication,
            isGatekeeperAccepted: isGatekeeperAccepted
        )
    }

    private func updateStagingDirectories(
        in root: URL
    ) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(".mojipond-update-")
        }
    }

    private func assertStagingError(
        _ expected: VerifiedUpdateStagingError,
        operation: () async throws -> VerifiedStagedUpdate
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)")
        } catch let error as VerifiedUpdateStagingError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Expected VerifiedUpdateStagingError, got \(error)")
        }
    }
}

private struct VerifiedUpdateFixture {
    let metadata: VerifiedUpdateMetadata
    let configuration: SignedUpdateConfiguration
}

private struct UpdateStagingPayloadFixture: Encodable {
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

private struct UpdateStagingEnvelopeFixture: Encodable {
    let schemaVersion: Int
    let algorithm: UpdateSignatureAlgorithm
    let payload: String
    let signature: String
}

private struct UpdateStagingFeedFetcher: UpdateFeedFetching {
    let response: UpdateFeedResponse

    func fetchUpdateFeed(
        from url: URL,
        maximumBytes: Int
    ) async throws -> UpdateFeedResponse {
        _ = url
        _ = maximumBytes
        return response
    }
}

private actor RecordingUpdateAssetFetcher: UpdateAssetFetching {
    let response: UpdateAssetResponse
    private var requestedMaximumByteCounts: [Int] = []

    init(response: UpdateAssetResponse) {
        self.response = response
    }

    func fetchUpdateAsset(
        from url: URL,
        maximumBytes: Int
    ) async throws -> UpdateAssetResponse {
        _ = url
        requestedMaximumByteCounts.append(maximumBytes)
        return response
    }

    func requestedMaximumBytes() -> Int? {
        requestedMaximumByteCounts.last
    }

    func fetchCount() -> Int {
        requestedMaximumByteCounts.count
    }
}

private struct MockUpdateSignatureVerifier:
    UpdateApplicationSignatureVerifying
{
    private let handler: @Sendable (
        URL
    ) throws -> UpdateCodeSignatureIdentity

    init(
        handler: @escaping @Sendable (
            URL
        ) throws -> UpdateCodeSignatureIdentity = { _ in
            UpdateCodeSignatureIdentity(
                bundleIdentifier: VerifiedUpdateStager.bundleIdentifier,
                teamIdentifier: "ABCDE12345",
                certificateCommonName:
                    "Developer ID Application: MojiPond Tests (ABCDE12345)",
                hasSecureTimestamp: true,
                usesHardenedRuntime: true,
                isDeveloperIDApplication: true,
                isGatekeeperAccepted: true
            )
        }
    ) {
        self.handler = handler
    }

    func verifyApplication(
        at applicationURL: URL,
        expectedBundleIdentifier: String
    ) throws -> UpdateCodeSignatureIdentity {
        _ = expectedBundleIdentifier
        return try handler(applicationURL)
    }
}

private enum UpdateStagingTestError: Error {
    case metadataWasNotVerified
}
