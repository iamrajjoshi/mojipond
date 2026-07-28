import Foundation
import XCTest
@testable import MojiPond

final class NativeUpdateInstallerTests: XCTestCase {
    func testRequestRoundTripsAndRejectsInvalidSecurityFields() throws {
        let request = makeRequest()
        let arguments = try request.arguments()

        XCTAssertEqual(
            NativeUpdateInstallRequest.parse(
                arguments: ["MojiPond"] + arguments
            ),
            request
        )

        let invalid = NativeUpdateInstallRequest(
            destinationApplicationPath:
                request.destinationApplicationPath,
            stagingDirectoryPath: request.stagingDirectoryPath,
            parentProcessIdentifier: 1,
            currentVersion: request.currentVersion,
            currentBuild: request.currentBuild,
            updateVersion: request.updateVersion,
            updateBuild: request.updateBuild,
            expectedTeamIdentifier: request.expectedTeamIdentifier,
            assetSHA256: "not-a-digest",
            assetByteCount: request.assetByteCount
        )
        XCTAssertNil(
            NativeUpdateInstallRequest.parse(
                arguments: try invalid.arguments()
            )
        )
        XCTAssertNil(
            NativeUpdateInstallRequest.parse(
                arguments: [
                    NativeUpdateInstallRequest.launchArgument,
                    arguments[1],
                    NativeUpdateInstallRequest.launchArgument,
                    arguments[1]
                ]
            )
        )
    }

    func testSuccessfulInstallVerifiesLaunchesAndCleansArtifacts()
        async throws {
        let fixture = makeFixture()
        let result = try await fixture.engine.install(
            request: fixture.request,
            candidateApplicationURL: fixture.candidateURL
        )

        XCTAssertTrue(result.cleanupWarnings.isEmpty)
        XCTAssertEqual(
            fixture.fileSystem.info(at: fixture.destinationURL)?.build,
            2
        )
        XCTAssertFalse(
            fixture.fileSystem.itemExists(
                at: fixture.stagingURL
            )
        )
        XCTAssertEqual(fixture.fileSystem.archiveVerificationCount, 1)
        XCTAssertEqual(fixture.fileSystem.leaseAcquisitionCount, 1)
        XCTAssertEqual(fixture.fileSystem.staleCleanupCount, 1)
        XCTAssertEqual(fixture.authorizer.consumeCount, 1)
        XCTAssertEqual(fixture.processController.launchCount, 1)
        XCTAssertEqual(fixture.readiness.waitCount, 1)
    }

    func testUnsafePathAndWrongIdentityNeverMutateCurrentApp()
        async {
        let unsafeFixture = makeFixture()
        unsafeFixture.fileSystem.failure = .unsafeLayout
        await assertInstallError(
            .unsafeInstallLayout,
            fixture: unsafeFixture
        )
        XCTAssertEqual(
            unsafeFixture.fileSystem.info(
                at: unsafeFixture.destinationURL
            )?.build,
            1
        )
        XCTAssertEqual(unsafeFixture.fileSystem.moveCount, 0)

        let identityFixture = makeFixture(
            verifierFailure: .wrongTeamForUpdate
        )
        await assertInstallError(
            .identityMismatch,
            fixture: identityFixture
        )
        XCTAssertEqual(
            identityFixture.fileSystem.info(
                at: identityFixture.destinationURL
            )?.build,
            1
        )
        XCTAssertEqual(identityFixture.fileSystem.moveCount, 0)
    }

    func testArchiveLinkageAndParentExitAreRequiredBeforeCopy()
        async {
        let archiveFixture = makeFixture()
        archiveFixture.fileSystem.failure = .archiveLinkage
        await assertInstallError(
            .archiveLinkageMismatch,
            fixture: archiveFixture
        )
        XCTAssertEqual(archiveFixture.fileSystem.copyCount, 0)

        let timeoutFixture = makeFixture(
            processFailure: .parentTimeout
        )
        await assertInstallError(
            .parentExitTimedOut,
            fixture: timeoutFixture
        )
        XCTAssertEqual(timeoutFixture.fileSystem.copyCount, 0)
        XCTAssertEqual(
            timeoutFixture.fileSystem.info(
                at: timeoutFixture.destinationURL
            )?.build,
            1
        )
    }

    func testOneTimeInstallerAuthorizationIsRequiredBeforeParentExit()
        async {
        let fixture = makeFixture(authorizationFailure: true)

        await assertInstallError(
            .unauthorizedInstallerRequest,
            fixture: fixture
        )
        XCTAssertEqual(fixture.authorizer.consumeCount, 1)
        XCTAssertEqual(fixture.processController.waitCount, 0)
        XCTAssertEqual(fixture.fileSystem.copyCount, 0)
    }

    func testCopyAndAtomicExchangeFailuresLeaveCurrentAppUntouched()
        async {
        let copyFixture = makeFixture()
        copyFixture.fileSystem.failure = .copy
        await assertInstallError(.copyFailed, fixture: copyFixture)
        XCTAssertEqual(
            copyFixture.fileSystem.info(
                at: copyFixture.destinationURL
            )?.build,
            1
        )

        let renameFixture = makeFixture()
        renameFixture.fileSystem.failure = .exchange(call: 1)
        await assertInstallError(
            .renameFailed,
            fixture: renameFixture
        )
        XCTAssertEqual(
            renameFixture.fileSystem.info(
                at: renameFixture.destinationURL
            )?.build,
            1
        )
    }

    func testBackupRenameFinalVerifyLaunchAndReadinessFailuresRollback()
        async {
        let backupRename = makeFixture()
        backupRename.fileSystem.failure = .move(call: 1)
        await assertInstallError(.renameFailed, fixture: backupRename)
        assertRestored(backupRename)

        let finalVerify = makeFixture(
            verifierFailure: .verificationCall(4)
        )
        await assertInstallError(
            .finalVerificationFailed,
            fixture: finalVerify
        )
        assertRestored(finalVerify)

        let launch = makeFixture(processFailure: .launch)
        await assertInstallError(.cannotRelaunch, fixture: launch)
        assertRestored(launch)

        let readiness = makeFixture(readinessFailure: true)
        await assertInstallError(
            .readinessTimedOut,
            fixture: readiness
        )
        assertRestored(readiness)
        XCTAssertEqual(
            readiness.processController.terminatedProcessIdentifiers,
            [9001]
        )
    }

    func testRollbackFailureIsReportedExplicitly() async {
        let fixture = makeFixture(processFailure: .launch)
        fixture.fileSystem.failure = .exchange(call: 2)

        await assertInstallError(.rollbackFailed, fixture: fixture)
    }

    func testConcurrentLockAndStaleCleanupFailureDoNotMutate()
        async {
        let lockFixture = makeFixture(lockFailure: true)
        await assertInstallError(
            .installAlreadyRunning,
            fixture: lockFixture
        )
        XCTAssertEqual(lockFixture.fileSystem.moveCount, 0)

        let cleanupFixture = makeFixture()
        cleanupFixture.fileSystem.failure = .staleCleanup
        await assertInstallError(
            .staleCleanupFailed,
            fixture: cleanupFixture
        )
        XCTAssertEqual(cleanupFixture.fileSystem.moveCount, 0)
    }

    func testCleanupFailureAfterReadinessDoesNotRollbackSuccessfulApp()
        async throws {
        let fixture = makeFixture()
        fixture.fileSystem.failure = .removeAll

        let result = try await fixture.engine.install(
            request: fixture.request,
            candidateApplicationURL: fixture.candidateURL
        )

        XCTAssertEqual(result.cleanupWarnings.count, 2)
        XCTAssertEqual(
            fixture.fileSystem.info(at: fixture.destinationURL)?.build,
            2
        )
        XCTAssertTrue(
            fixture.processController.terminatedProcessIdentifiers.isEmpty
        )
    }

    func testStaleArtifactsAreRemovedOnlyAfterIdentityValidation()
        async throws {
        let fixture = makeFixture()
        let parent = fixture.destinationURL.deletingLastPathComponent()
        let verifiedArtifact = parent.appendingPathComponent(
            ".MojiPond.backup-\(UUID().uuidString.lowercased()).app",
            isDirectory: true
        )
        let untrustedArtifact = parent.appendingPathComponent(
            ".MojiPond.update-\(UUID().uuidString.lowercased()).app",
            isDirectory: true
        )
        fixture.fileSystem.addStaleArtifact(
            at: verifiedArtifact,
            info: NativeUpdateBundleInfo(
                bundleIdentifier:
                    VerifiedUpdateStager.bundleIdentifier,
                version: "0.9",
                build: 1
            )
        )
        fixture.fileSystem.addStaleArtifact(
            at: untrustedArtifact,
            info: NativeUpdateBundleInfo(
                bundleIdentifier: "invalid.bundle",
                version: "9.9",
                build: 99
            )
        )

        _ = try await fixture.engine.install(
            request: fixture.request,
            candidateApplicationURL: fixture.candidateURL
        )

        XCTAssertFalse(
            fixture.fileSystem.itemExists(at: verifiedArtifact)
        )
        XCTAssertTrue(
            fixture.fileSystem.itemExists(at: untrustedArtifact)
        )
    }

    func testLauncherOffersManualFallbackOnlyForUnwritableDestination() {
        let fixture = makeFixture()
        let context = makeLaunchContext(fixture)
        let launcher = SystemNativeUpdateInstallerLauncher(
            fileSystem: fixture.fileSystem,
            authorizer: fixture.authorizer,
            runningApplicationURL: fixture.destinationURL,
            currentProcessIdentifier: 4321
        )

        fixture.fileSystem.isWritable = false
        guard case .manualInstallRequired =
            launcher.availability(for: context) else {
            return XCTFail("Expected an honest manual fallback.")
        }

        fixture.fileSystem.isWritable = true
        fixture.fileSystem.failure = .unsafeLayout
        guard case .unavailable =
            launcher.availability(for: context) else {
            return XCTFail("Unsafe paths must not become a manual fallback.")
        }
    }

    func testLauncherRejectsRequestForAnotherRunningCopy() {
        let fixture = makeFixture()
        let context = makeLaunchContext(fixture)
        let launcher = SystemNativeUpdateInstallerLauncher(
            fileSystem: fixture.fileSystem,
            authorizer: fixture.authorizer,
            runningApplicationURL: URL(
                fileURLWithPath: "/Applications/Other.app"
            ),
            currentProcessIdentifier: 4321
        )

        guard case .unavailable =
            launcher.availability(for: context) else {
            return XCTFail(
                "The handoff must be bound to the running app."
            )
        }
    }

    func testSystemInstallerAuthorizationIsExactAndOneTime() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent(
            ".mojipond-update-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: staging.path
        )
        let candidate = staging.appendingPathComponent(
            "Expanded/MojiPond.app",
            isDirectory: true
        )
        let request = NativeUpdateInstallRequest(
            destinationApplicationPath: root.appendingPathComponent(
                "MojiPond.app"
            ).path,
            stagingDirectoryPath: staging.path,
            parentProcessIdentifier: 4321,
            currentVersion: "1.0",
            currentBuild: 1,
            updateVersion: "2.0",
            updateBuild: 2,
            expectedTeamIdentifier: "ABCDEFGHIJ",
            assetSHA256: String(repeating: "a", count: 64),
            assetByteCount: 123
        )
        let authorizer = SystemNativeUpdateInstallAuthorizer()
        try authorizer.createAuthorization(
            for: request,
            candidateApplicationURL: candidate
        )

        XCTAssertThrowsError(
            try authorizer.consumeAuthorization(
                for: request,
                candidateApplicationURL:
                    staging.appendingPathComponent("Wrong.app")
            )
        ) { error in
            XCTAssertEqual(
                error as? NativeUpdateInstallError,
                .unauthorizedInstallerRequest
            )
        }
        try authorizer.consumeAuthorization(
            for: request,
            candidateApplicationURL: candidate
        )
        XCTAssertThrowsError(
            try authorizer.consumeAuthorization(
                for: request,
                candidateApplicationURL: candidate
            )
        ) { error in
            XCTAssertEqual(
                error as? NativeUpdateInstallError,
                .unauthorizedInstallerRequest
            )
        }
    }

    func testPOSIXLockRejectsConcurrentInstaller() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent(
            "MojiPond.app",
            isDirectory: true
        )
        let locker = POSIXNativeUpdateInstallLocker()
        var first: (any NativeUpdateInstallLock)? =
            try locker.acquireLock(beside: destination)
        XCTAssertNotNil(first)

        XCTAssertThrowsError(
            try locker.acquireLock(beside: destination)
        ) { error in
            XCTAssertEqual(
                error as? NativeUpdateInstallError,
                .installAlreadyRunning
            )
        }

        first = nil
        let second = try locker.acquireLock(beside: destination)
        _ = second
    }

    func testStagingLeaseRejectsConcurrentOwnerAndSupportsTakeover()
        throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent(
            ".mojipond-update-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var first: POSIXNativeUpdateStagingLease? =
            try POSIXNativeUpdateStagingLease.create(in: staging)
        XCTAssertNotNil(first)
        let fileSystem = SystemNativeUpdateFileOperator()
        XCTAssertThrowsError(
            try fileSystem.acquireStagingLease(in: staging)
        ) { error in
            XCTAssertEqual(
                error as? NativeUpdateInstallError,
                .installAlreadyRunning
            )
        }

        first = nil
        let successor = try fileSystem.acquireStagingLease(
            in: staging
        )
        _ = successor
    }

    func testSystemAtomicExchangeKeepsBothApplicationPathsValid()
        throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent(
            "First.app",
            isDirectory: true
        )
        let second = root.appendingPathComponent(
            "Second.app",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: first,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: second,
            withIntermediateDirectories: false
        )
        let oldMarker = first.appendingPathComponent(
            "old",
            isDirectory: false
        )
        let newMarker = second.appendingPathComponent(
            "new",
            isDirectory: false
        )
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: oldMarker.path,
                contents: Data()
            )
        )
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: newMarker.path,
                contents: Data()
            )
        )

        try SystemNativeUpdateFileOperator().exchangeItem(
            at: first,
            with: second
        )

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: first.appendingPathComponent("new").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: second.appendingPathComponent("old").path
            )
        )
    }

    func testSystemStaleDiscoveryIsDirectChildOnlyAndNeverFollowsSymlinks()
        throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent(
            "MojiPond.app",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: false
        )
        let stale = root.appendingPathComponent(
            ".MojiPond.update-\(UUID().uuidString.lowercased()).app",
            isDirectory: true
        )
        let backup = root.appendingPathComponent(
            ".MojiPond.backup-\(UUID().uuidString.lowercased()).app",
            isDirectory: true
        )
        let unrelated = root.appendingPathComponent(
            "Keep.app",
            isDirectory: true
        )
        let malformed = root.appendingPathComponent(
            ".MojiPond.update-important.app",
            isDirectory: true
        )
        for url in [stale, backup, unrelated, malformed] {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false
            )
        }

        let operatorUnderTest = SystemNativeUpdateFileOperator()
        let artifacts = try operatorUnderTest.staleInstallerArtifacts(
            beside: destination,
            now: Date(),
            minimumAge: 0
        )
        XCTAssertEqual(
            Set(artifacts.map(\.lastPathComponent)),
            Set([stale.lastPathComponent, backup.lastPathComponent])
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: unrelated.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: malformed.path)
        )

        let target = root.appendingPathComponent(
            "SymlinkTarget",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: false
        )
        let symlink = root.appendingPathComponent(
            ".MojiPond.update-\(UUID().uuidString.lowercased()).app",
            isDirectory: false
        )
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: target
        )
        let artifactsAfterSymlink =
            try operatorUnderTest.staleInstallerArtifacts(
                beside: destination,
                now: Date(),
                minimumAge: 0
            )
        XCTAssertFalse(
            artifactsAfterSymlink.contains {
                $0.lastPathComponent == symlink.lastPathComponent
            }
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symlink.path))
    }

    func testStagingScavengerRemovesOnlyExpiredOwnedDirectChildren()
        throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent(
            ".mojipond-update-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        let recent = root.appendingPathComponent(
            ".mojipond-update-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        let active = root.appendingPathComponent(
            ".mojipond-update-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        for url in [old, recent, active] {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: url.path
            )
        }
        var activeLease:
            POSIXNativeUpdateStagingLease? =
                try POSIXNativeUpdateStagingLease.create(in: active)
        XCTAssertNotNil(activeLease)
        let now = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-10_000)],
            ofItemAtPath: old.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-10)],
            ofItemAtPath: recent.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-10_000)],
            ofItemAtPath: active.path
        )

        try VerifiedUpdateStager.scavengeStaleStagingDirectories(
            in: root,
            now: now,
            minimumAge: 1_000
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))

        activeLease = nil
        try VerifiedUpdateStager.scavengeStaleStagingDirectories(
            in: root,
            now: now,
            minimumAge: 1_000
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: active.path))
    }

    private func assertRestored(
        _ fixture: NativeInstallerFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            fixture.fileSystem.info(
                at: fixture.destinationURL
            )?.build,
            1,
            file: file,
            line: line
        )
    }

    private func assertInstallError(
        _ expected: NativeUpdateInstallError,
        fixture: NativeInstallerFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await fixture.engine.install(
                request: fixture.request,
                candidateApplicationURL: fixture.candidateURL
            )
            XCTFail(
                "Expected \(expected).",
                file: file,
                line: line
            )
        } catch {
            XCTAssertEqual(
                error as? NativeUpdateInstallError,
                expected,
                file: file,
                line: line
            )
        }
    }

    private func makeFixture(
        verifierFailure: FakeSignatureVerifier.Failure? = nil,
        processFailure: FakeProcessController.Failure? = nil,
        readinessFailure: Bool = false,
        lockFailure: Bool = false,
        authorizationFailure: Bool = false
    ) -> NativeInstallerFixture {
        let root = URL(
            fileURLWithPath: "/native-update-tests",
            isDirectory: true
        )
        let staging = root.appendingPathComponent(
            ".mojipond-update-fixture",
            isDirectory: true
        )
        let candidate = staging.appendingPathComponent(
            "Expanded/MojiPond.app",
            isDirectory: true
        )
        let destination = root.appendingPathComponent(
            "MojiPond.app",
            isDirectory: true
        )
        let current = NativeUpdateBundleInfo(
            bundleIdentifier: VerifiedUpdateStager.bundleIdentifier,
            version: "1.0",
            build: 1
        )
        let update = NativeUpdateBundleInfo(
            bundleIdentifier: VerifiedUpdateStager.bundleIdentifier,
            version: "2.0",
            build: 2
        )
        let fileSystem = FakeNativeUpdateFileSystem(
            stagingURL: staging,
            candidateURL: candidate,
            destinationURL: destination,
            currentInfo: current,
            candidateInfo: update
        )
        let inspector = FakeBundleInspector(fileSystem: fileSystem)
        let verifier = FakeSignatureVerifier(
            fileSystem: fileSystem,
            failure: verifierFailure
        )
        let processController = FakeProcessController(
            failure: processFailure
        )
        let readiness = FakeReadinessCoordinator(
            shouldFailWait: readinessFailure
        )
        let authorizer = FakeNativeUpdateInstallAuthorizer(
            shouldFailConsume: authorizationFailure
        )
        let engine = NativeUpdateInstallerEngine(
            fileSystem: fileSystem,
            bundleInspector: inspector,
            signatureVerifier: verifier,
            locker: FakeInstallLocker(shouldFail: lockFailure),
            processController: processController,
            readinessCoordinator: readiness,
            authorizer: authorizer,
            parentExitTimeout: .milliseconds(1),
            readinessTimeout: .milliseconds(1)
        )
        let request = NativeUpdateInstallRequest(
            destinationApplicationPath: destination.path,
            stagingDirectoryPath: staging.path,
            parentProcessIdentifier: 4321,
            currentVersion: "1.0",
            currentBuild: 1,
            updateVersion: "2.0",
            updateBuild: 2,
            expectedTeamIdentifier: "ABCDEFGHIJ",
            assetSHA256: String(repeating: "a", count: 64),
            assetByteCount: 123
        )
        return NativeInstallerFixture(
            engine: engine,
            request: request,
            fileSystem: fileSystem,
            processController: processController,
            readiness: readiness,
            authorizer: authorizer,
            stagingURL: staging,
            candidateURL: candidate,
            destinationURL: destination
        )
    }

    private func makeRequest() -> NativeUpdateInstallRequest {
        NativeUpdateInstallRequest(
            destinationApplicationPath: "/Applications/MojiPond.app",
            stagingDirectoryPath:
                "/private/tmp/.mojipond-update-fixture",
            parentProcessIdentifier: 4321,
            currentVersion: "1.0",
            currentBuild: 1,
            updateVersion: "2.0",
            updateBuild: 2,
            expectedTeamIdentifier: "ABCDEFGHIJ",
            assetSHA256: String(repeating: "a", count: 64),
            assetByteCount: 123
        )
    }

    private func makeLaunchContext(
        _ fixture: NativeInstallerFixture
    ) -> NativeUpdateInstallerLaunchContext {
        NativeUpdateInstallerLaunchContext(
            stagedApplicationURL: fixture.candidateURL,
            stagingDirectoryURL: fixture.stagingURL,
            destinationApplicationURL: fixture.destinationURL,
            currentVersion: "1.0",
            currentBuild: 1,
            updateVersion: "2.0",
            updateBuild: 2,
            expectedTeamIdentifier: "ABCDEFGHIJ",
            assetSHA256: String(repeating: "a", count: 64),
            assetByteCount: 123,
            parentProcessIdentifier: 4321
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MojiPond-Native-Update-Tests-"
                    + UUID().uuidString.lowercased(),
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }
}

private struct NativeInstallerFixture {
    let engine: NativeUpdateInstallerEngine
    let request: NativeUpdateInstallRequest
    let fileSystem: FakeNativeUpdateFileSystem
    let processController: FakeProcessController
    let readiness: FakeReadinessCoordinator
    let authorizer: FakeNativeUpdateInstallAuthorizer
    let stagingURL: URL
    let candidateURL: URL
    let destinationURL: URL
}

private final class FakeNativeUpdateFileSystem:
    NativeUpdateFileOperating,
    @unchecked Sendable
{
    enum Failure: Equatable {
        case unsafeLayout
        case archiveLinkage
        case staleCleanup
        case copy
        case exchange(call: Int)
        case move(call: Int)
        case removeAll
    }

    var failure: Failure?
    var isWritable = true
    private(set) var copyCount = 0
    private(set) var exchangeCount = 0
    private(set) var moveCount = 0
    private(set) var archiveVerificationCount = 0
    private(set) var staleCleanupCount = 0
    private(set) var leaseAcquisitionCount = 0

    private let stagingURL: URL
    private let candidateURL: URL
    private let destinationURL: URL
    private var existing: Set<String>
    private var infos: [String: NativeUpdateBundleInfo]
    private var staleArtifacts: [URL] = []

    init(
        stagingURL: URL,
        candidateURL: URL,
        destinationURL: URL,
        currentInfo: NativeUpdateBundleInfo,
        candidateInfo: NativeUpdateBundleInfo
    ) {
        self.stagingURL = stagingURL
        self.candidateURL = candidateURL
        self.destinationURL = destinationURL
        existing = [
            stagingURL.path,
            candidateURL.path,
            destinationURL.path
        ]
        infos = [
            candidateURL.path: candidateInfo,
            destinationURL.path: currentInfo
        ]
    }

    func validateInstallLayout(
        candidateApplicationURL: URL,
        stagingDirectoryURL: URL,
        destinationApplicationURL: URL
    ) throws {
        guard failure != .unsafeLayout,
              candidateApplicationURL == candidateURL,
              stagingDirectoryURL == stagingURL,
              destinationApplicationURL == destinationURL else {
            throw NativeUpdateInstallError.unsafeInstallLayout
        }
    }

    func validateInstallerExecutable(
        at executableURL: URL,
        inside candidateApplicationURL: URL
    ) throws {}

    func canReplaceItem(at destinationApplicationURL: URL) -> Bool {
        isWritable
    }

    func acquireStagingLease(
        in stagingDirectoryURL: URL
    ) throws -> any NativeUpdateStagingLease {
        leaseAcquisitionCount += 1
        return FakeNativeUpdateStagingLease()
    }

    func verifyStagedArchive(
        in stagingDirectoryURL: URL,
        expectedSHA256: String,
        expectedByteCount: Int64
    ) throws {
        archiveVerificationCount += 1
        if failure == .archiveLinkage {
            throw NativeUpdateInstallError.archiveLinkageMismatch
        }
    }

    func itemExists(at url: URL) -> Bool {
        existing.contains(url.path)
    }

    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        copyCount += 1
        if failure == .copy {
            throw NativeUpdateInstallError.copyFailed
        }
        existing.insert(destinationURL.path)
        infos[destinationURL.path] = infos[sourceURL.path]
    }

    func exchangeItem(at firstURL: URL, with secondURL: URL) throws {
        exchangeCount += 1
        if failure == .exchange(call: exchangeCount) {
            throw NativeUpdateInstallError.renameFailed
        }
        guard existing.contains(firstURL.path),
              existing.contains(secondURL.path) else {
            throw NativeUpdateInstallError.renameFailed
        }
        let firstInfo = infos[firstURL.path]
        infos[firstURL.path] = infos[secondURL.path]
        infos[secondURL.path] = firstInfo
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        moveCount += 1
        if failure == .move(call: moveCount) {
            throw NativeUpdateInstallError.renameFailed
        }
        guard existing.remove(sourceURL.path) != nil else {
            throw NativeUpdateInstallError.renameFailed
        }
        existing.insert(destinationURL.path)
        infos[destinationURL.path] = infos.removeValue(
            forKey: sourceURL.path
        )
    }

    func removeItem(at url: URL) throws {
        if failure == .removeAll {
            throw NativeUpdateInstallError.cleanupFailed
        }
        existing = existing.filter {
            $0 != url.path && !$0.hasPrefix(url.path + "/")
        }
        infos = infos.filter {
            $0.key != url.path
                && !$0.key.hasPrefix(url.path + "/")
        }
    }

    func staleInstallerArtifacts(
        beside destinationApplicationURL: URL,
        now: Date,
        minimumAge: TimeInterval
    ) throws -> [URL] {
        staleCleanupCount += 1
        if failure == .staleCleanup {
            throw NativeUpdateInstallError.staleCleanupFailed
        }
        return staleArtifacts
    }

    func info(at url: URL) -> NativeUpdateBundleInfo? {
        infos[url.path]
    }

    func addStaleArtifact(
        at url: URL,
        info: NativeUpdateBundleInfo
    ) {
        staleArtifacts.append(url)
        existing.insert(url.path)
        infos[url.path] = info
    }
}

private final class FakeNativeUpdateStagingLease:
    NativeUpdateStagingLease,
    @unchecked Sendable
{}

private final class FakeNativeUpdateInstallAuthorizer:
    NativeUpdateInstallAuthorizing,
    @unchecked Sendable
{
    private let shouldFailConsume: Bool
    private(set) var consumeCount = 0

    init(shouldFailConsume: Bool) {
        self.shouldFailConsume = shouldFailConsume
    }

    func createAuthorization(
        for request: NativeUpdateInstallRequest,
        candidateApplicationURL: URL
    ) throws {}

    func consumeAuthorization(
        for request: NativeUpdateInstallRequest,
        candidateApplicationURL: URL
    ) throws {
        consumeCount += 1
        if shouldFailConsume {
            throw NativeUpdateInstallError.unauthorizedInstallerRequest
        }
    }

    func discardAuthorization(
        for request: NativeUpdateInstallRequest
    ) {}
}

private struct FakeBundleInspector: NativeUpdateBundleInspecting {
    let fileSystem: FakeNativeUpdateFileSystem

    func inspectApplication(
        at applicationURL: URL
    ) throws -> NativeUpdateBundleInfo {
        guard let info = fileSystem.info(at: applicationURL) else {
            throw NativeUpdateInstallError.invalidApplicationBundle
        }
        return info
    }
}

private final class FakeSignatureVerifier:
    UpdateApplicationSignatureVerifying,
    @unchecked Sendable
{
    enum Failure: Equatable {
        case wrongTeamForUpdate
        case verificationCall(Int)
    }

    private let fileSystem: FakeNativeUpdateFileSystem
    private let failure: Failure?
    private var callCount = 0

    init(
        fileSystem: FakeNativeUpdateFileSystem,
        failure: Failure?
    ) {
        self.fileSystem = fileSystem
        self.failure = failure
    }

    func verifyApplication(
        at applicationURL: URL,
        expectedBundleIdentifier: String
    ) throws -> UpdateCodeSignatureIdentity {
        callCount += 1
        if failure == .verificationCall(callCount) {
            throw NativeUpdateInstallError.signatureVerificationFailed
        }
        let isUpdate = fileSystem.info(at: applicationURL)?.build == 2
        let team = failure == .wrongTeamForUpdate && isUpdate
            ? "ZZZZZZZZZZ"
            : "ABCDEFGHIJ"
        return UpdateCodeSignatureIdentity(
            bundleIdentifier: expectedBundleIdentifier,
            teamIdentifier: team,
            certificateCommonName:
                "Developer ID Application: Test (\(team))",
            hasSecureTimestamp: true,
            usesHardenedRuntime: true,
            isDeveloperIDApplication: true,
            isGatekeeperAccepted: true
        )
    }
}

private final class FakeProcessController:
    NativeUpdateProcessControlling,
    @unchecked Sendable
{
    enum Failure {
        case parentTimeout
        case launch
    }

    private let failure: Failure?
    private(set) var launchCount = 0
    private(set) var waitCount = 0
    private(set) var terminatedProcessIdentifiers: [Int32] = []

    init(failure: Failure?) {
        self.failure = failure
    }

    func waitForExit(
        processIdentifier: Int32,
        timeout: Duration
    ) async throws {
        waitCount += 1
        if failure == .parentTimeout {
            throw NativeUpdateInstallError.parentExitTimedOut
        }
    }

    func launchApplication(
        at applicationURL: URL,
        arguments: [String]
    ) throws -> Int32 {
        launchCount += 1
        if failure == .launch {
            throw NativeUpdateInstallError.cannotRelaunch
        }
        return 9001
    }

    func terminateApplication(
        processIdentifier: Int32
    ) async {
        terminatedProcessIdentifiers.append(processIdentifier)
    }
}

private final class FakeReadinessCoordinator:
    NativeUpdateReadinessCoordinating,
    @unchecked Sendable
{
    let shouldFailWait: Bool
    private(set) var waitCount = 0

    init(shouldFailWait: Bool) {
        self.shouldFailWait = shouldFailWait
    }

    func makeRequest(
        destinationApplicationURL: URL,
        expectedVersion: String,
        expectedBuild: Int
    ) throws -> NativeUpdateReadinessRequest {
        NativeUpdateReadinessRequest(
            directoryPath: "/native-update-tests/readiness",
            token: UUID().uuidString.lowercased(),
            destinationApplicationPath: destinationApplicationURL.path,
            expectedVersion: expectedVersion,
            expectedBuild: expectedBuild
        )
    }

    func waitForReadiness(
        _ request: NativeUpdateReadinessRequest,
        timeout: Duration
    ) async throws {
        waitCount += 1
        if shouldFailWait {
            throw NativeUpdateInstallError.readinessTimedOut
        }
    }

    func cleanup(_ request: NativeUpdateReadinessRequest) {}
}

private struct FakeInstallLocker: NativeUpdateInstallLocking {
    let shouldFail: Bool

    func acquireLock(
        beside destinationApplicationURL: URL
    ) throws -> any NativeUpdateInstallLock {
        if shouldFail {
            throw NativeUpdateInstallError.installAlreadyRunning
        }
        return FakeInstallLock()
    }
}

private final class FakeInstallLock:
    NativeUpdateInstallLock,
    @unchecked Sendable
{}
