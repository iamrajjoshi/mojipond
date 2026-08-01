import Darwin
import CryptoKit
import Foundation

enum NativeUpdateInstallAvailability: Equatable, Sendable {
    case available
    case manualInstallRequired(String)
    case unavailable(String)

    var allowsAutomaticInstall: Bool {
        self == .available
    }
}

struct NativeUpdateInstallerLaunchContext: Equatable, Sendable {
    let stagedApplicationURL: URL
    let stagingDirectoryURL: URL
    let destinationApplicationURL: URL
    let currentVersion: String
    let currentBuild: Int
    let updateVersion: String
    let updateBuild: Int
    let expectedTeamIdentifier: String
    let assetSHA256: String
    let assetByteCount: Int64
    let parentProcessIdentifier: Int32
}

protocol NativeUpdateInstallerLaunching: Sendable {
    func availability(
        for context: NativeUpdateInstallerLaunchContext
    ) -> NativeUpdateInstallAvailability

    func launchInstaller(
        for context: NativeUpdateInstallerLaunchContext
    ) throws
}

struct SystemNativeUpdateInstallerLauncher:
    NativeUpdateInstallerLaunching
{
    private let fileSystem: any NativeUpdateFileOperating
    private let authorizer: any NativeUpdateInstallAuthorizing
    private let runningApplicationURL: URL
    private let currentProcessIdentifier: Int32

    init(
        fileSystem: any NativeUpdateFileOperating =
            SystemNativeUpdateFileOperator(),
        authorizer: any NativeUpdateInstallAuthorizing =
            SystemNativeUpdateInstallAuthorizer(),
        runningApplicationURL: URL = Bundle.main.bundleURL,
        currentProcessIdentifier: Int32 = getpid()
    ) {
        self.fileSystem = fileSystem
        self.authorizer = authorizer
        self.runningApplicationURL = runningApplicationURL
        self.currentProcessIdentifier = currentProcessIdentifier
    }

    func availability(
        for context: NativeUpdateInstallerLaunchContext
    ) -> NativeUpdateInstallAvailability {
        guard
            context.parentProcessIdentifier
                == currentProcessIdentifier,
            context.destinationApplicationURL.standardizedFileURL
                .resolvingSymlinksInPath()
                == runningApplicationURL.standardizedFileURL
                    .resolvingSymlinksInPath()
        else {
            return .unavailable(
                "The installer request is not bound to this running "
                    + "copy of MojiPond."
            )
        }
        do {
            try fileSystem.validateInstallLayout(
                candidateApplicationURL: context.stagedApplicationURL,
                stagingDirectoryURL: context.stagingDirectoryURL,
                destinationApplicationURL:
                    context.destinationApplicationURL
            )
        } catch {
            return .unavailable(
                "The verified update paths changed or are unsafe. "
                    + "Discard this download and try again."
            )
        }
        guard fileSystem.canReplaceItem(
            at: context.destinationApplicationURL
        ) else {
            return .manualInstallRequired(
                "The folder containing MojiPond is not writable. "
                    + "The verified app can still be installed manually."
            )
        }
        return .available
    }

    func launchInstaller(
        for context: NativeUpdateInstallerLaunchContext
    ) throws {
        switch availability(for: context) {
        case .available:
            break
        case .manualInstallRequired:
            throw NativeUpdateInstallError.destinationNotWritable
        case .unavailable:
            throw NativeUpdateInstallError.unsafeInstallLayout
        }

        let executableURL = context.stagedApplicationURL
            .appendingPathComponent(
                "Contents/MacOS/MojiPond",
                isDirectory: false
            )
        try fileSystem.validateInstallerExecutable(
            at: executableURL,
            inside: context.stagedApplicationURL
        )

        let request = NativeUpdateInstallRequest(
            destinationApplicationPath:
                context.destinationApplicationURL.path,
            stagingDirectoryPath: context.stagingDirectoryURL.path,
            parentProcessIdentifier: context.parentProcessIdentifier,
            currentVersion: context.currentVersion,
            currentBuild: context.currentBuild,
            updateVersion: context.updateVersion,
            updateBuild: context.updateBuild,
            expectedTeamIdentifier: context.expectedTeamIdentifier,
            assetSHA256: context.assetSHA256,
            assetByteCount: context.assetByteCount
        )
        do {
            try authorizer.createAuthorization(
                for: request,
                candidateApplicationURL: context.stagedApplicationURL
            )
        } catch {
            throw NativeUpdateInstallError.cannotAuthorizeInstaller
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = try request.arguments()
        process.environment = Self.sanitizedEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            authorizer.discardAuthorization(for: request)
            throw NativeUpdateInstallError.cannotLaunchInstaller
        }
    }

    static var sanitizedEnvironment: [String: String] {
        var environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": FileManager.default.temporaryDirectory.path
        ]
        if let user = ProcessInfo.processInfo.environment["USER"] {
            environment["USER"] = user
        }
        return environment
    }
}

struct NativeUpdateInstallRequest: Codable, Equatable, Sendable {
    static let launchArgument = "--mojipond-complete-update"

    let destinationApplicationPath: String
    let stagingDirectoryPath: String
    let parentProcessIdentifier: Int32
    let currentVersion: String
    let currentBuild: Int
    let updateVersion: String
    let updateBuild: Int
    let expectedTeamIdentifier: String
    let assetSHA256: String
    let assetByteCount: Int64
    let authorizationFilename: String
    let authorizationToken: String

    init(
        destinationApplicationPath: String,
        stagingDirectoryPath: String,
        parentProcessIdentifier: Int32,
        currentVersion: String,
        currentBuild: Int,
        updateVersion: String,
        updateBuild: Int,
        expectedTeamIdentifier: String,
        assetSHA256: String,
        assetByteCount: Int64,
        authorizationFilename: String =
            ".install-authorization-"
                + UUID().uuidString.lowercased(),
        authorizationToken: String =
            UUID().uuidString.lowercased()
    ) {
        self.destinationApplicationPath = destinationApplicationPath
        self.stagingDirectoryPath = stagingDirectoryPath
        self.parentProcessIdentifier = parentProcessIdentifier
        self.currentVersion = currentVersion
        self.currentBuild = currentBuild
        self.updateVersion = updateVersion
        self.updateBuild = updateBuild
        self.expectedTeamIdentifier = expectedTeamIdentifier
        self.assetSHA256 = assetSHA256
        self.assetByteCount = assetByteCount
        self.authorizationFilename = authorizationFilename
        self.authorizationToken = authorizationToken
    }

    func arguments() throws -> [String] {
        let data = try JSONEncoder().encode(self)
        return [
            Self.launchArgument,
            data.base64EncodedString()
        ]
    }

    static func parse(arguments: [String]) -> NativeUpdateInstallRequest? {
        guard
            let index = arguments.firstIndex(of: launchArgument),
            arguments.filter({ $0 == launchArgument }).count == 1
        else {
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex) else {
            return nil
        }
        let encoded = arguments[valueIndex]
        guard encoded.utf8.count <= 16_384,
              let data = Data(base64Encoded: encoded),
              data.count <= 12_288,
              let request = try? JSONDecoder().decode(
                  NativeUpdateInstallRequest.self,
                  from: data
              ),
              request.parentProcessIdentifier > 1,
              request.currentBuild > 0,
              request.updateBuild > request.currentBuild,
              request.assetByteCount > 0,
              Self.isSHA256(request.assetSHA256),
              Self.isAuthorizationFilename(
                  request.authorizationFilename
              ),
              Self.isLowercaseUUID(request.authorizationToken),
              !request.currentVersion.isEmpty,
              !request.updateVersion.isEmpty,
              Self.isValidTeamIdentifier(
                  request.expectedTeamIdentifier
              ) else {
            return nil
        }
        return request
    }

    private static func isValidTeamIdentifier(_ value: String) -> Bool {
        value.utf8.count == 10
            && value.utf8.allSatisfy {
                (0x30...0x39).contains($0)
                    || (0x41...0x5A).contains($0)
            }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy {
                (0x30...0x39).contains($0)
                    || (0x61...0x66).contains($0)
            }
    }

    private static func isAuthorizationFilename(
        _ value: String
    ) -> Bool {
        let prefix = ".install-authorization-"
        guard value.hasPrefix(prefix) else {
            return false
        }
        return isLowercaseUUID(String(value.dropFirst(prefix.count)))
    }

    private static func isLowercaseUUID(_ value: String) -> Bool {
        value == value.lowercased()
            && UUID(uuidString: value) != nil
    }
}

protocol NativeUpdateInstallAuthorizing: Sendable {
    func createAuthorization(
        for request: NativeUpdateInstallRequest,
        candidateApplicationURL: URL
    ) throws
    func consumeAuthorization(
        for request: NativeUpdateInstallRequest,
        candidateApplicationURL: URL
    ) throws
    func discardAuthorization(for request: NativeUpdateInstallRequest)
}

private struct NativeUpdateInstallAuthorization:
    Codable,
    Equatable
{
    let request: NativeUpdateInstallRequest
    let candidateApplicationPath: String
}

struct SystemNativeUpdateInstallAuthorizer:
    NativeUpdateInstallAuthorizing
{
    private static let maximumAuthorizationBytes = 32 * 1_024

    func createAuthorization(
        for request: NativeUpdateInstallRequest,
        candidateApplicationURL: URL
    ) throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(
                NativeUpdateInstallAuthorization(
                    request: request,
                    candidateApplicationPath:
                        candidateApplicationURL.standardizedFileURL.path
                )
            )
        } catch {
            throw NativeUpdateInstallError.cannotAuthorizeInstaller
        }
        guard data.count <= Self.maximumAuthorizationBytes else {
            throw NativeUpdateInstallError.cannotAuthorizeInstaller
        }

        let directoryDescriptor = try openStagingDirectory(
            for: request
        )
        defer { close(directoryDescriptor) }
        let descriptor = openat(
            directoryDescriptor,
            request.authorizationFilename,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw NativeUpdateInstallError.cannotAuthorizeInstaller
        }
        var shouldUnlink = true
        defer {
            close(descriptor)
            if shouldUnlink {
                unlinkat(
                    directoryDescriptor,
                    request.authorizationFilename,
                    0
                )
            }
        }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & mode_t(0o777) == mode_t(0o600),
              Self.writeAll(data, to: descriptor),
              fsync(descriptor) == 0 else {
            throw NativeUpdateInstallError.cannotAuthorizeInstaller
        }
        shouldUnlink = false
    }

    func consumeAuthorization(
        for request: NativeUpdateInstallRequest,
        candidateApplicationURL: URL
    ) throws {
        let directoryDescriptor = try openStagingDirectory(
            for: request
        )
        defer { close(directoryDescriptor) }
        let descriptor = openat(
            directoryDescriptor,
            request.authorizationFilename,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw NativeUpdateInstallError.unauthorizedInstallerRequest
        }
        defer { close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & mode_t(0o777) == mode_t(0o600),
              metadata.st_size > 0,
              metadata.st_size
                <= Self.maximumAuthorizationBytes,
              let data = Self.readAll(
                  from: descriptor,
                  expectedByteCount: Int(metadata.st_size)
              ),
              let authorization = try? JSONDecoder().decode(
                  NativeUpdateInstallAuthorization.self,
                  from: data
              ),
              authorization.request == request,
              authorization.candidateApplicationPath
                == candidateApplicationURL.standardizedFileURL.path,
              unlinkat(
                  directoryDescriptor,
                  request.authorizationFilename,
                  0
              ) == 0 else {
            throw NativeUpdateInstallError.unauthorizedInstallerRequest
        }
    }

    func discardAuthorization(for request: NativeUpdateInstallRequest) {
        guard let directoryDescriptor = try? openStagingDirectory(
            for: request
        ) else {
            return
        }
        defer { close(directoryDescriptor) }
        unlinkat(
            directoryDescriptor,
            request.authorizationFilename,
            0
        )
    }

    private func openStagingDirectory(
        for request: NativeUpdateInstallRequest
    ) throws -> Int32 {
        guard NativeUpdateInstallRequest.parse(
            arguments: try request.arguments()
        ) == request else {
            throw NativeUpdateInstallError.unauthorizedInstallerRequest
        }
        let stagingURL = URL(
            fileURLWithPath: request.stagingDirectoryPath,
            isDirectory: true
        ).standardizedFileURL
        let descriptor = open(
            stagingURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw NativeUpdateInstallError.unauthorizedInstallerRequest
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == getuid(),
              metadata.st_mode & mode_t(0o777) == mode_t(0o700) else {
            close(descriptor)
            throw NativeUpdateInstallError.unauthorizedInstallerRequest
        }
        return descriptor
    }

    private static func writeAll(
        _ data: Data,
        to descriptor: Int32
    ) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return data.isEmpty
            }
            var offset = 0
            while offset < rawBuffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                guard result > 0 else {
                    return false
                }
                offset += result
            }
            return true
        }
    }

    private static func readAll(
        from descriptor: Int32,
        expectedByteCount: Int
    ) -> Data? {
        var data = Data(count: expectedByteCount)
        let didReadAll = data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return expectedByteCount == 0
            }
            var offset = 0
            while offset < expectedByteCount {
                let result = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    expectedByteCount - offset
                )
                guard result > 0 else {
                    return false
                }
                offset += result
            }
            var extraByte: UInt8 = 0
            return Darwin.read(descriptor, &extraByte, 1) == 0
        }
        return didReadAll ? data : nil
    }
}

struct NativeUpdateReadinessRequest: Codable, Equatable, Sendable {
    static let launchArgument = "--mojipond-update-readiness"

    let directoryPath: String
    let token: String
    let destinationApplicationPath: String
    let expectedVersion: String
    let expectedBuild: Int

    var readyFileURL: URL {
        URL(fileURLWithPath: directoryPath, isDirectory: true)
            .appendingPathComponent("ready", isDirectory: false)
    }

    func arguments() throws -> [String] {
        let data = try JSONEncoder().encode(self)
        return [
            Self.launchArgument,
            data.base64EncodedString()
        ]
    }

    static func parse(
        arguments: [String]
    ) -> NativeUpdateReadinessRequest? {
        guard
            let index = arguments.firstIndex(of: launchArgument),
            arguments.filter({ $0 == launchArgument }).count == 1
        else {
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex) else {
            return nil
        }
        let encoded = arguments[valueIndex]
        guard encoded.utf8.count <= 16_384,
              let data = Data(base64Encoded: encoded),
              data.count <= 12_288,
              let request = try? JSONDecoder().decode(
                  NativeUpdateReadinessRequest.self,
                  from: data
              ),
              request.expectedBuild > 0,
              !request.expectedVersion.isEmpty,
              UUID(uuidString: request.token) != nil else {
            return nil
        }
        return request
    }
}

struct NativeUpdateBundleInfo: Equatable, Sendable {
    let bundleIdentifier: String
    let version: String
    let build: Int
}

protocol NativeUpdateBundleInspecting: Sendable {
    func inspectApplication(
        at applicationURL: URL
    ) throws -> NativeUpdateBundleInfo
}

struct SystemNativeUpdateBundleInspector:
    NativeUpdateBundleInspecting
{
    func inspectApplication(
        at applicationURL: URL
    ) throws -> NativeUpdateBundleInfo {
        let applicationValues = try? applicationURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard applicationValues?.isDirectory == true,
              applicationValues?.isSymbolicLink != true else {
            throw NativeUpdateInstallError.invalidApplicationBundle
        }

        let infoURL = applicationURL.appendingPathComponent(
            "Contents/Info.plist",
            isDirectory: false
        )
        let values = try? infoURL.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ]
        )
        guard values?.isRegularFile == true,
              values?.isSymbolicLink != true,
              let size = values?.fileSize,
              (1...1_048_576).contains(size) else {
            throw NativeUpdateInstallError.invalidApplicationBundle
        }

        let propertyList: Any
        do {
            let data = try Data(
                contentsOf: infoURL,
                options: [.mappedIfSafe, .uncached]
            )
            propertyList = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
        } catch {
            throw NativeUpdateInstallError.invalidApplicationBundle
        }
        guard
            let dictionary = propertyList as? [String: Any],
            let bundleIdentifier =
                dictionary["CFBundleIdentifier"] as? String,
            let version =
                dictionary["CFBundleShortVersionString"] as? String,
            !version.isEmpty,
            let buildString = dictionary["CFBundleVersion"] as? String,
            let build = Int(buildString),
            build > 0,
            String(build) == buildString
        else {
            throw NativeUpdateInstallError.invalidApplicationBundle
        }
        return NativeUpdateBundleInfo(
            bundleIdentifier: bundleIdentifier,
            version: version,
            build: build
        )
    }
}

protocol NativeUpdateStagingLease: AnyObject, Sendable {}

enum NativeUpdateStagingLeaseError: Error {
    case missing
    case active
    case unsafe
}

final class POSIXNativeUpdateStagingLease:
    NativeUpdateStagingLease,
    @unchecked Sendable
{
    static let filename = ".lease"

    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func create(
        in stagingDirectoryURL: URL
    ) throws -> POSIXNativeUpdateStagingLease {
        try openAndLock(
            in: stagingDirectoryURL,
            flags: O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW,
            requiresExistingPermissions: false
        )
    }

    static func acquireExisting(
        in stagingDirectoryURL: URL
    ) throws -> POSIXNativeUpdateStagingLease {
        try openAndLock(
            in: stagingDirectoryURL,
            flags: O_RDWR | O_NOFOLLOW,
            requiresExistingPermissions: true
        )
    }

    private static func openAndLock(
        in stagingDirectoryURL: URL,
        flags: Int32,
        requiresExistingPermissions: Bool
    ) throws -> POSIXNativeUpdateStagingLease {
        let leaseURL = stagingDirectoryURL.appendingPathComponent(
            filename,
            isDirectory: false
        )
        let descriptor = open(
            leaseURL.path,
            flags,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            if errno == ENOENT {
                throw NativeUpdateStagingLeaseError.missing
            }
            throw NativeUpdateStagingLeaseError.unsafe
        }

        var leaseStatus = stat()
        guard fstat(descriptor, &leaseStatus) == 0,
              leaseStatus.st_mode & S_IFMT == S_IFREG,
              leaseStatus.st_uid == getuid(),
              leaseStatus.st_nlink == 1 else {
            close(descriptor)
            throw NativeUpdateStagingLeaseError.unsafe
        }
        let permissions = leaseStatus.st_mode & mode_t(0o777)
        guard (!requiresExistingPermissions
                || permissions == mode_t(0o600)),
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            close(descriptor)
            throw NativeUpdateStagingLeaseError.unsafe
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            close(descriptor)
            if lockError == EWOULDBLOCK {
                throw NativeUpdateStagingLeaseError.active
            }
            throw NativeUpdateStagingLeaseError.unsafe
        }
        return POSIXNativeUpdateStagingLease(
            descriptor: descriptor
        )
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

protocol NativeUpdateFileOperating: Sendable {
    func validateInstallLayout(
        candidateApplicationURL: URL,
        stagingDirectoryURL: URL,
        destinationApplicationURL: URL
    ) throws
    func validateInstallerExecutable(
        at executableURL: URL,
        inside candidateApplicationURL: URL
    ) throws
    func canReplaceItem(at destinationApplicationURL: URL) -> Bool
    func acquireStagingLease(
        in stagingDirectoryURL: URL
    ) throws -> any NativeUpdateStagingLease
    func verifyStagedArchive(
        in stagingDirectoryURL: URL,
        expectedSHA256: String,
        expectedByteCount: Int64
    ) throws
    func itemExists(at url: URL) -> Bool
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws
    func exchangeItem(at firstURL: URL, with secondURL: URL) throws
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws
    func removeItem(at url: URL) throws
    func staleInstallerArtifacts(
        beside destinationApplicationURL: URL,
        now: Date,
        minimumAge: TimeInterval
    ) throws -> [URL]
}

struct SystemNativeUpdateFileOperator: NativeUpdateFileOperating {
    private static let temporaryPrefix = ".MojiPond.update-"
    private static let backupPrefix = ".MojiPond.backup-"

    private var fileManager: FileManager { .default }

    func validateInstallLayout(
        candidateApplicationURL: URL,
        stagingDirectoryURL: URL,
        destinationApplicationURL: URL
    ) throws {
        let candidate = try Self.validatedExistingURL(
            candidateApplicationURL,
            directory: true
        )
        let staging = try Self.validatedExistingURL(
            stagingDirectoryURL,
            directory: true
        )
        let destination = try Self.validatedExistingURL(
            destinationApplicationURL,
            directory: true
        )
        let parent = try Self.validatedExistingURL(
            destination.deletingLastPathComponent(),
            directory: true
        )

        guard candidate.lastPathComponent == "MojiPond.app",
              destination.lastPathComponent == "MojiPond.app",
              VerifiedUpdateStager.isStagingDirectoryName(
                  staging.lastPathComponent
              ),
              candidate.path.hasPrefix(staging.path + "/"),
              candidate.resolvingSymlinksInPath() == candidate,
              destination.resolvingSymlinksInPath() == destination,
              parent.resolvingSymlinksInPath() == parent else {
            throw NativeUpdateInstallError.unsafeInstallLayout
        }
        let attributes = try fileManager.attributesOfItem(
            atPath: staging.path
        )
        let permissions = (
            attributes[.posixPermissions] as? NSNumber
        )?.intValue
        let owner = (
            attributes[.ownerAccountID] as? NSNumber
        )?.uint32Value
        guard permissions == 0o700,
              owner == getuid() else {
            throw NativeUpdateInstallError.unsafeInstallLayout
        }
    }

    func validateInstallerExecutable(
        at executableURL: URL,
        inside candidateApplicationURL: URL
    ) throws {
        let executable = try Self.validatedExistingURL(
            executableURL,
            directory: false
        )
        let candidate = candidateApplicationURL.standardizedFileURL
        guard executable.path.hasPrefix(candidate.path + "/"),
              executable.resolvingSymlinksInPath() == executable,
              fileManager.isExecutableFile(atPath: executable.path) else {
            throw NativeUpdateInstallError.unsafeInstallLayout
        }
    }

    func canReplaceItem(at destinationApplicationURL: URL) -> Bool {
        let parent = destinationApplicationURL.standardizedFileURL
            .deletingLastPathComponent()
        guard access(parent.path, W_OK | X_OK) == 0 else {
            return false
        }
        let probe = parent.appendingPathComponent(
            ".MojiPond.update-write-probe-\(UUID().uuidString.lowercased())",
            isDirectory: false
        )
        let descriptor = open(
            probe.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            return false
        }
        close(descriptor)
        return unlink(probe.path) == 0
    }

    func acquireStagingLease(
        in stagingDirectoryURL: URL
    ) throws -> any NativeUpdateStagingLease {
        do {
            return try POSIXNativeUpdateStagingLease.acquireExisting(
                in: stagingDirectoryURL
            )
        } catch NativeUpdateStagingLeaseError.active {
            throw NativeUpdateInstallError.installAlreadyRunning
        } catch {
            throw NativeUpdateInstallError.unsafeInstallLayout
        }
    }

    func verifyStagedArchive(
        in stagingDirectoryURL: URL,
        expectedSHA256: String,
        expectedByteCount: Int64
    ) throws {
        guard expectedByteCount > 0,
              expectedByteCount <= Int64(Int.max) else {
            throw NativeUpdateInstallError.archiveLinkageMismatch
        }
        let archiveURL = stagingDirectoryURL.appendingPathComponent(
            "update.zip",
            isDirectory: false
        )
        let values = try? archiveURL.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ]
        )
        guard values?.isRegularFile == true,
              values?.isSymbolicLink != true,
              values?.fileSize == Int(expectedByteCount),
              archiveURL.standardizedFileURL.deletingLastPathComponent()
                == stagingDirectoryURL.standardizedFileURL else {
            throw NativeUpdateInstallError.archiveLinkageMismatch
        }
        let data: Data
        do {
            data = try Data(
                contentsOf: archiveURL,
                options: [.mappedIfSafe, .uncached]
            )
        } catch {
            throw NativeUpdateInstallError.archiveLinkageMismatch
        }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest == expectedSHA256 else {
            throw NativeUpdateInstallError.archiveLinkageMismatch
        }
    }

    func itemExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            if Self.isPermissionFailure(error),
               !canReplaceItem(at: destinationURL) {
                throw NativeUpdateInstallError.destinationNotWritable
            }
            throw NativeUpdateInstallError.copyFailed
        }
    }

    func exchangeItem(at firstURL: URL, with secondURL: URL) throws {
        let firstValues = try? firstURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        let secondValues = try? secondURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        let firstParentIdentifier = try? firstURL
            .deletingLastPathComponent()
            .resourceValues(
                forKeys: [.fileResourceIdentifierKey]
            )
            .fileResourceIdentifier
        let secondParentIdentifier = try? secondURL
            .deletingLastPathComponent()
            .resourceValues(
                forKeys: [.fileResourceIdentifierKey]
            )
            .fileResourceIdentifier
        guard firstValues?.isDirectory == true,
              firstValues?.isSymbolicLink != true,
              secondValues?.isDirectory == true,
              secondValues?.isSymbolicLink != true,
              let firstParentIdentifier,
              let secondParentIdentifier,
              firstParentIdentifier.isEqual(secondParentIdentifier) else {
            throw NativeUpdateInstallError.renameFailed
        }

        let status = firstURL.path.withCString { firstPath in
            secondURL.path.withCString { secondPath in
                renameatx_np(
                    AT_FDCWD,
                    firstPath,
                    AT_FDCWD,
                    secondPath,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        guard status == 0 else {
            let failure = POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
            if Self.isPermissionFailure(failure),
               !canReplaceItem(at: secondURL) {
                throw NativeUpdateInstallError.destinationNotWritable
            }
            throw NativeUpdateInstallError.renameFailed
        }
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            if Self.isPermissionFailure(error),
               !canReplaceItem(at: destinationURL) {
                throw NativeUpdateInstallError.destinationNotWritable
            }
            throw NativeUpdateInstallError.renameFailed
        }
    }

    func removeItem(at url: URL) throws {
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw NativeUpdateInstallError.cleanupFailed
        }
    }

    func staleInstallerArtifacts(
        beside destinationApplicationURL: URL,
        now: Date = Date(),
        minimumAge: TimeInterval = 7 * 24 * 60 * 60
    ) throws -> [URL] {
        let parent = destinationApplicationURL.standardizedFileURL
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
        let parentIdentifier = try? parent.resourceValues(
            forKeys: [.fileResourceIdentifierKey]
        ).fileResourceIdentifier
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .contentModificationDateKey
                ],
                options: [.skipsSubdirectoryDescendants]
            )
        } catch {
            throw NativeUpdateInstallError.staleCleanupFailed
        }
        var artifacts: [URL] = []
        for child in children {
            let name = child.lastPathComponent
            guard Self.isInstallerArtifactName(name) else {
                continue
            }
            let values = try? child.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .contentModificationDateKey
                ]
            )
            let childParentIdentifier = try? child
                .deletingLastPathComponent()
                .resourceValues(
                    forKeys: [.fileResourceIdentifierKey]
                )
                .fileResourceIdentifier
            let attributes = try? fileManager.attributesOfItem(
                atPath: child.path
            )
            let owner = (
                attributes?[.ownerAccountID] as? NSNumber
            )?.uint32Value
            guard values?.isDirectory == true,
                  values?.isSymbolicLink != true,
                  let modificationDate =
                    values?.contentModificationDate,
                  now.timeIntervalSince(modificationDate) >= minimumAge,
                  let parentIdentifier,
                  let childParentIdentifier,
                  parentIdentifier.isEqual(childParentIdentifier),
                  owner == getuid() else {
                continue
            }
            artifacts.append(child)
        }
        return artifacts
    }

    static func temporarySibling(
        of destinationApplicationURL: URL,
        identifier: UUID = UUID()
    ) -> URL {
        destinationApplicationURL.deletingLastPathComponent()
            .appendingPathComponent(
                temporaryPrefix
                    + identifier.uuidString.lowercased()
                    + ".app",
                isDirectory: true
            )
    }

    static func backupSibling(
        of destinationApplicationURL: URL,
        identifier: UUID = UUID()
    ) -> URL {
        destinationApplicationURL.deletingLastPathComponent()
            .appendingPathComponent(
                backupPrefix
                    + identifier.uuidString.lowercased()
                    + ".app",
                isDirectory: true
            )
    }

    private static func isInstallerArtifactName(_ name: String) -> Bool {
        for prefix in [temporaryPrefix, backupPrefix] {
            guard name.hasPrefix(prefix),
                  name.hasSuffix(".app") else {
                continue
            }
            let identifierStart = name.index(
                name.startIndex,
                offsetBy: prefix.count
            )
            let identifierEnd = name.index(
                name.endIndex,
                offsetBy: -".app".count
            )
            guard identifierStart < identifierEnd else {
                continue
            }
            let identifier = String(
                name[identifierStart..<identifierEnd]
            )
            if UUID(uuidString: identifier) != nil {
                return true
            }
        }
        return false
    }

    private static func isPermissionFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EACCES)
            || nsError.code == Int(EPERM) {
            return true
        }
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileWriteNoPermissionError
            || nsError.code == NSFileReadNoPermissionError {
            return true
        }
        guard let underlying = nsError.userInfo[
            NSUnderlyingErrorKey
        ] as? Error else {
            return false
        }
        return isPermissionFailure(underlying)
    }

    private static func validatedExistingURL(
        _ url: URL,
        directory: Bool
    ) throws -> URL {
        guard url.isFileURL else {
            throw NativeUpdateInstallError.unsafeInstallLayout
        }
        let standardized = url.standardizedFileURL
        guard standardized.path.hasPrefix("/"),
              standardized.resolvingSymlinksInPath() == standardized else {
            throw NativeUpdateInstallError.unsafeInstallLayout
        }
        let values = try? standardized.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ]
        )
        guard values?.isSymbolicLink != true,
              directory
                ? values?.isDirectory == true
                : values?.isRegularFile == true else {
            throw NativeUpdateInstallError.unsafeInstallLayout
        }
        return standardized
    }
}

protocol NativeUpdateInstallLocking: Sendable {
    func acquireLock(
        beside destinationApplicationURL: URL
    ) throws -> any NativeUpdateInstallLock
}

protocol NativeUpdateInstallLock: AnyObject, Sendable {}

struct POSIXNativeUpdateInstallLocker: NativeUpdateInstallLocking {
    func acquireLock(
        beside destinationApplicationURL: URL
    ) throws -> any NativeUpdateInstallLock {
        let lockURL = destinationApplicationURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".MojiPond.update.lock",
                isDirectory: false
            )
        let descriptor = open(
            lockURL.path,
            O_RDWR | O_CREAT | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw NativeUpdateInstallError.cannotAcquireLock
        }
        var lockStatus = stat()
        guard fstat(descriptor, &lockStatus) == 0,
              lockStatus.st_mode & S_IFMT == S_IFREG,
              lockStatus.st_uid == getuid(),
              lockStatus.st_nlink == 1,
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            close(descriptor)
            throw NativeUpdateInstallError.cannotAcquireLock
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw NativeUpdateInstallError.installAlreadyRunning
        }
        return POSIXNativeUpdateInstallLock(descriptor: descriptor)
    }
}

private final class POSIXNativeUpdateInstallLock:
    NativeUpdateInstallLock,
    @unchecked Sendable
{
    private let descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

protocol NativeUpdateProcessControlling: Sendable {
    func waitForExit(
        processIdentifier: Int32,
        timeout: Duration
    ) async throws
    func launchApplication(
        at applicationURL: URL,
        arguments: [String]
    ) throws -> Int32
    func terminateApplication(
        processIdentifier: Int32
    ) async
}

struct SystemNativeUpdateProcessController:
    NativeUpdateProcessControlling
{
    func waitForExit(
        processIdentifier: Int32,
        timeout: Duration
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while Self.isRunning(processIdentifier) {
            guard clock.now < deadline else {
                throw NativeUpdateInstallError.parentExitTimedOut
            }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func launchApplication(
        at applicationURL: URL,
        arguments: [String]
    ) throws -> Int32 {
        let executableURL = applicationURL.appendingPathComponent(
            "Contents/MacOS/MojiPond",
            isDirectory: false
        )
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment =
            SystemNativeUpdateInstallerLauncher.sanitizedEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw NativeUpdateInstallError.cannotRelaunch
        }
        return process.processIdentifier
    }

    func terminateApplication(
        processIdentifier: Int32
    ) async {
        guard processIdentifier > 1 else {
            return
        }
        kill(processIdentifier, SIGTERM)
        for _ in 0..<20 {
            guard Self.isRunning(processIdentifier) else {
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        kill(processIdentifier, SIGKILL)
    }

    private static func isRunning(_ processIdentifier: Int32) -> Bool {
        guard processIdentifier > 1 else {
            return false
        }
        if kill(processIdentifier, 0) == 0 {
            return true
        }
        return errno != ESRCH
    }
}

protocol NativeUpdateReadinessCoordinating: Sendable {
    func makeRequest(
        destinationApplicationURL: URL,
        expectedVersion: String,
        expectedBuild: Int
    ) throws -> NativeUpdateReadinessRequest
    func waitForReadiness(
        _ request: NativeUpdateReadinessRequest,
        timeout: Duration
    ) async throws
    func cleanup(_ request: NativeUpdateReadinessRequest)
}

struct SystemNativeUpdateReadinessCoordinator:
    NativeUpdateReadinessCoordinating
{
    private let temporaryDirectoryURL: URL
    private var fileManager: FileManager { .default }

    init(
        temporaryDirectoryURL: URL =
            FileManager.default.temporaryDirectory
    ) {
        self.temporaryDirectoryURL = temporaryDirectoryURL
    }

    func makeRequest(
        destinationApplicationURL: URL,
        expectedVersion: String,
        expectedBuild: Int
    ) throws -> NativeUpdateReadinessRequest {
        let root = temporaryDirectoryURL.standardizedFileURL
            .resolvingSymlinksInPath()
        let directory = root.appendingPathComponent(
            ".mojipond-update-readiness-"
                + UUID().uuidString.lowercased(),
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        } catch {
            try? fileManager.removeItem(at: directory)
            throw NativeUpdateInstallError.cannotCreateReadinessChannel
        }
        return NativeUpdateReadinessRequest(
            directoryPath: directory.path,
            token: UUID().uuidString.lowercased(),
            destinationApplicationPath:
                destinationApplicationURL.standardizedFileURL.path,
            expectedVersion: expectedVersion,
            expectedBuild: expectedBuild
        )
    }

    func waitForReadiness(
        _ request: NativeUpdateReadinessRequest,
        timeout: Duration
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        let expectedData = Data(request.token.utf8)
        while clock.now < deadline {
            try Task.checkCancellation()
            if let data = try? Data(
                contentsOf: request.readyFileURL,
                options: [.uncached]
            ), data == expectedData {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NativeUpdateInstallError.readinessTimedOut
    }

    func cleanup(_ request: NativeUpdateReadinessRequest) {
        try? fileManager.removeItem(
            at: URL(
                fileURLWithPath: request.directoryPath,
                isDirectory: true
            )
        )
    }

    static func signal(
        _ request: NativeUpdateReadinessRequest,
        applicationURL: URL,
        temporaryDirectoryURL: URL =
            FileManager.default.temporaryDirectory,
        bundleInspector: any NativeUpdateBundleInspecting =
            SystemNativeUpdateBundleInspector()
    ) throws {
        let actualApplication = applicationURL.standardizedFileURL
        let expectedApplication = URL(
            fileURLWithPath: request.destinationApplicationPath,
            isDirectory: true
        ).standardizedFileURL
        guard actualApplication == expectedApplication,
              actualApplication.resolvingSymlinksInPath()
                == actualApplication else {
            throw NativeUpdateInstallError.unsafeReadinessRequest
        }
        let info = try bundleInspector.inspectApplication(
            at: actualApplication
        )
        guard info.bundleIdentifier == VerifiedUpdateStager.bundleIdentifier,
              info.version == request.expectedVersion,
              info.build == request.expectedBuild else {
            throw NativeUpdateInstallError.unsafeReadinessRequest
        }

        let root = temporaryDirectoryURL.standardizedFileURL
            .resolvingSymlinksInPath()
        let directory = URL(
            fileURLWithPath: request.directoryPath,
            isDirectory: true
        ).standardizedFileURL
        guard directory.deletingLastPathComponent() == root,
              directory.lastPathComponent.hasPrefix(
                  ".mojipond-update-readiness-"
              ),
              directory.resolvingSymlinksInPath() == directory else {
            throw NativeUpdateInstallError.unsafeReadinessRequest
        }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.path
        )
        let permissions = (
            attributes[.posixPermissions] as? NSNumber
        )?.intValue
        let owner = (
            attributes[.ownerAccountID] as? NSNumber
        )?.uint32Value
        guard permissions == 0o700, owner == getuid() else {
            throw NativeUpdateInstallError.unsafeReadinessRequest
        }
        do {
            try Data(request.token.utf8).write(
                to: request.readyFileURL,
                options: .withoutOverwriting
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: request.readyFileURL.path
            )
        } catch {
            throw NativeUpdateInstallError.cannotSignalReadiness
        }
    }
}

struct NativeUpdateInstallResult: Equatable, Sendable {
    let cleanupWarnings: [String]
}

enum NativeUpdateInstallError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case unsafeInstallLayout
    case destinationNotWritable
    case cannotAuthorizeInstaller
    case unauthorizedInstallerRequest
    case cannotLaunchInstaller
    case cannotAcquireLock
    case installAlreadyRunning
    case parentExitTimedOut
    case archiveLinkageMismatch
    case invalidApplicationBundle
    case bundleIdentifierMismatch
    case versionMismatch
    case buildMismatch
    case updateIsNotNewer
    case signatureVerificationFailed
    case identityMismatch
    case copyFailed
    case renameFailed
    case finalVerificationFailed
    case cannotCreateReadinessChannel
    case cannotRelaunch
    case readinessTimedOut
    case unsafeReadinessRequest
    case cannotSignalReadiness
    case cleanupFailed
    case staleCleanupFailed
    case rollbackFailed

    var errorDescription: String? {
        switch self {
        case .unsafeInstallLayout:
            "The update paths are unsafe or changed after verification."
        case .destinationNotWritable:
            "MojiPond cannot replace the installed app without permission."
        case .cannotAuthorizeInstaller:
            "MojiPond could not create a private installer handoff."
        case .unauthorizedInstallerRequest:
            "The installer request was not authorized by the running app."
        case .cannotLaunchInstaller:
            "The verified updater process could not be started."
        case .cannotAcquireLock:
            "The update lock could not be created safely."
        case .installAlreadyRunning:
            "Another MojiPond installation is already running."
        case .parentExitTimedOut:
            "The previous MojiPond process did not quit in time."
        case .archiveLinkageMismatch:
            "The staged app is no longer linked to its signed update archive."
        case .invalidApplicationBundle:
            "An app involved in the update has invalid bundle metadata."
        case .bundleIdentifierMismatch:
            "An app involved in the update has the wrong bundle identifier."
        case .versionMismatch:
            "An app involved in the update has the wrong version."
        case .buildMismatch:
            "An app involved in the update has the wrong build number."
        case .updateIsNotNewer:
            "The staged app is not newer than the installed app."
        case .signatureVerificationFailed:
            "An app involved in the update failed code-signature verification."
        case .identityMismatch:
            "The staged and installed apps do not share the same trusted identity."
        case .copyFailed:
            "The verified app could not be copied beside the installed app."
        case .renameFailed:
            "The app bundles could not be atomically exchanged."
        case .finalVerificationFailed:
            "The installed result failed its final verification."
        case .cannotCreateReadinessChannel:
            "A private relaunch readiness channel could not be created."
        case .cannotRelaunch:
            "The updated app could not be relaunched."
        case .readinessTimedOut:
            "The updated app did not become ready in time."
        case .unsafeReadinessRequest:
            "The update readiness request was unsafe."
        case .cannotSignalReadiness:
            "The updated app could not confirm that it was ready."
        case .cleanupFailed:
            "An update artifact could not be cleaned up."
        case .staleCleanupFailed:
            "A stale update artifact could not be cleaned up safely."
        case .rollbackFailed:
            "The update failed and the previous app could not be restored automatically."
        }
    }
}

struct NativeUpdateInstallerEngine: Sendable {
    private let fileSystem: any NativeUpdateFileOperating
    private let bundleInspector: any NativeUpdateBundleInspecting
    private let signatureVerifier:
        any UpdateApplicationSignatureVerifying
    private let locker: any NativeUpdateInstallLocking
    private let processController:
        any NativeUpdateProcessControlling
    private let readinessCoordinator:
        any NativeUpdateReadinessCoordinating
    private let authorizer: any NativeUpdateInstallAuthorizing
    private let parentExitTimeout: Duration
    private let readinessTimeout: Duration

    init(
        fileSystem: any NativeUpdateFileOperating =
            SystemNativeUpdateFileOperator(),
        bundleInspector: any NativeUpdateBundleInspecting =
            SystemNativeUpdateBundleInspector(),
        signatureVerifier: any UpdateApplicationSignatureVerifying =
            SystemUpdateApplicationSignatureVerifier(),
        locker: any NativeUpdateInstallLocking =
            POSIXNativeUpdateInstallLocker(),
        processController: any NativeUpdateProcessControlling =
            SystemNativeUpdateProcessController(),
        readinessCoordinator: any NativeUpdateReadinessCoordinating =
            SystemNativeUpdateReadinessCoordinator(),
        authorizer: any NativeUpdateInstallAuthorizing =
            SystemNativeUpdateInstallAuthorizer(),
        parentExitTimeout: Duration = .seconds(30),
        readinessTimeout: Duration = .seconds(15)
    ) {
        self.fileSystem = fileSystem
        self.bundleInspector = bundleInspector
        self.signatureVerifier = signatureVerifier
        self.locker = locker
        self.processController = processController
        self.readinessCoordinator = readinessCoordinator
        self.authorizer = authorizer
        self.parentExitTimeout = parentExitTimeout
        self.readinessTimeout = readinessTimeout
    }

    func install(
        request: NativeUpdateInstallRequest,
        candidateApplicationURL: URL
    ) async throws -> NativeUpdateInstallResult {
        let destinationURL = URL(
            fileURLWithPath: request.destinationApplicationPath,
            isDirectory: true
        ).standardizedFileURL
        let stagingURL = URL(
            fileURLWithPath: request.stagingDirectoryPath,
            isDirectory: true
        ).standardizedFileURL
        try fileSystem.validateInstallLayout(
            candidateApplicationURL: candidateApplicationURL,
            stagingDirectoryURL: stagingURL,
            destinationApplicationURL: destinationURL
        )
        guard fileSystem.canReplaceItem(at: destinationURL) else {
            throw NativeUpdateInstallError.destinationNotWritable
        }

        let lock = try locker.acquireLock(beside: destinationURL)
        _ = lock
        try authorizer.consumeAuthorization(
            for: request,
            candidateApplicationURL: candidateApplicationURL
        )
        try await processController.waitForExit(
            processIdentifier: request.parentProcessIdentifier,
            timeout: parentExitTimeout
        )
        let stagingLease = try fileSystem.acquireStagingLease(
            in: stagingURL
        )
        defer { _ = stagingLease }
        try fileSystem.verifyStagedArchive(
            in: stagingURL,
            expectedSHA256: request.assetSHA256,
            expectedByteCount: request.assetByteCount
        )

        let currentIdentity = try verifyApplication(
            at: destinationURL,
            expectedVersion: request.currentVersion,
            expectedBuild: request.currentBuild,
            expectedTeamIdentifier: request.expectedTeamIdentifier
        )
        let candidateIdentity = try verifyApplication(
            at: candidateApplicationURL,
            expectedVersion: request.updateVersion,
            expectedBuild: request.updateBuild,
            expectedTeamIdentifier: request.expectedTeamIdentifier
        )
        guard request.updateBuild > request.currentBuild else {
            throw NativeUpdateInstallError.updateIsNotNewer
        }
        guard currentIdentity == candidateIdentity else {
            throw NativeUpdateInstallError.identityMismatch
        }
        try cleanVerifiedStaleArtifacts(
            beside: destinationURL,
            currentIdentity: currentIdentity,
            expectedTeamIdentifier: request.expectedTeamIdentifier
        )

        let temporaryURL =
            SystemNativeUpdateFileOperator.temporarySibling(
                of: destinationURL
            )
        let backupURL =
            SystemNativeUpdateFileOperator.backupSibling(
                of: destinationURL
            )
        var destinationMoved = false
        var launchedProcessIdentifier: Int32?
        var readinessRequest: NativeUpdateReadinessRequest?
        defer {
            if fileSystem.itemExists(at: temporaryURL) {
                try? fileSystem.removeItem(at: temporaryURL)
            }
            if let readinessRequest {
                readinessCoordinator.cleanup(readinessRequest)
            }
        }

        do {
            try fileSystem.copyItem(
                at: candidateApplicationURL,
                to: temporaryURL
            )
            let copiedIdentity = try verifyApplication(
                at: temporaryURL,
                expectedVersion: request.updateVersion,
                expectedBuild: request.updateBuild,
                expectedTeamIdentifier: request.expectedTeamIdentifier
            )
            guard copiedIdentity == candidateIdentity else {
                throw NativeUpdateInstallError.identityMismatch
            }

            let requestChannel = try readinessCoordinator.makeRequest(
                destinationApplicationURL: destinationURL,
                expectedVersion: request.updateVersion,
                expectedBuild: request.updateBuild
            )
            readinessRequest = requestChannel

            try fileSystem.exchangeItem(
                at: temporaryURL,
                with: destinationURL
            )
            destinationMoved = true
            try fileSystem.moveItem(
                at: temporaryURL,
                to: backupURL
            )

            let finalIdentity: UpdateCodeSignatureIdentity
            do {
                finalIdentity = try verifyApplication(
                    at: destinationURL,
                    expectedVersion: request.updateVersion,
                    expectedBuild: request.updateBuild,
                    expectedTeamIdentifier:
                        request.expectedTeamIdentifier
                )
            } catch {
                throw NativeUpdateInstallError.finalVerificationFailed
            }
            guard finalIdentity == candidateIdentity else {
                throw NativeUpdateInstallError.finalVerificationFailed
            }
            try fileSystem.validateInstallerExecutable(
                at: destinationURL.appendingPathComponent(
                    "Contents/MacOS/MojiPond",
                    isDirectory: false
                ),
                inside: destinationURL
            )

            let finalArguments = try requestChannel.arguments()
            launchedProcessIdentifier =
                try processController.launchApplication(
                    at: destinationURL,
                    arguments: finalArguments
                )
            try await readinessCoordinator.waitForReadiness(
                requestChannel,
                timeout: readinessTimeout
            )

            var cleanupWarnings: [String] = []
            do {
                try fileSystem.removeItem(at: backupURL)
            } catch {
                cleanupWarnings.append(
                    "The previous app backup could not be removed."
                )
            }
            do {
                try fileSystem.removeItem(at: stagingURL)
            } catch {
                cleanupWarnings.append(
                    "The verified staging folder could not be removed."
                )
            }
            destinationMoved = false
            return NativeUpdateInstallResult(
                cleanupWarnings: cleanupWarnings
            )
        } catch {
            if let launchedProcessIdentifier {
                await processController.terminateApplication(
                    processIdentifier: launchedProcessIdentifier
                )
            }
            if destinationMoved {
                do {
                    let rollbackURL = fileSystem.itemExists(
                        at: backupURL
                    )
                        ? backupURL
                        : temporaryURL
                    try fileSystem.exchangeItem(
                        at: rollbackURL,
                        with: destinationURL
                    )
                    let restoredIdentity = try verifyApplication(
                        at: destinationURL,
                        expectedVersion: request.currentVersion,
                        expectedBuild: request.currentBuild,
                        expectedTeamIdentifier:
                            request.expectedTeamIdentifier
                    )
                    guard restoredIdentity == currentIdentity else {
                        throw NativeUpdateInstallError.identityMismatch
                    }
                    destinationMoved = false
                    try? fileSystem.removeItem(at: rollbackURL)
                } catch {
                    throw NativeUpdateInstallError.rollbackFailed
                }
            }
            if let installError = error as? NativeUpdateInstallError {
                throw installError
            }
            throw NativeUpdateInstallError.finalVerificationFailed
        }
    }

    private func verifyApplication(
        at applicationURL: URL,
        expectedVersion: String,
        expectedBuild: Int,
        expectedTeamIdentifier: String
    ) throws -> UpdateCodeSignatureIdentity {
        let info = try bundleInspector.inspectApplication(
            at: applicationURL
        )
        guard info.bundleIdentifier
            == VerifiedUpdateStager.bundleIdentifier else {
            throw NativeUpdateInstallError.bundleIdentifierMismatch
        }
        guard info.version == expectedVersion else {
            throw NativeUpdateInstallError.versionMismatch
        }
        guard info.build == expectedBuild else {
            throw NativeUpdateInstallError.buildMismatch
        }

        let identity: UpdateCodeSignatureIdentity
        do {
            identity = try signatureVerifier.verifyApplication(
                at: applicationURL,
                expectedBundleIdentifier:
                    VerifiedUpdateStager.bundleIdentifier
            )
        } catch {
            throw NativeUpdateInstallError.signatureVerificationFailed
        }
        guard
            identity.bundleIdentifier
                == VerifiedUpdateStager.bundleIdentifier,
            identity.teamIdentifier == expectedTeamIdentifier,
            identity.certificateCommonName.hasPrefix(
                "Developer ID Application: "
            ),
            identity.isDeveloperIDApplication,
            identity.hasSecureTimestamp,
            identity.usesHardenedRuntime,
            identity.isGatekeeperAccepted
        else {
            throw NativeUpdateInstallError.identityMismatch
        }
        return identity
    }

    private func cleanVerifiedStaleArtifacts(
        beside destinationURL: URL,
        currentIdentity: UpdateCodeSignatureIdentity,
        expectedTeamIdentifier: String
    ) throws {
        let artifacts = try fileSystem.staleInstallerArtifacts(
            beside: destinationURL,
            now: Date(),
            minimumAge: 7 * 24 * 60 * 60
        )
        for artifactURL in artifacts {
            guard
                let info = try? bundleInspector.inspectApplication(
                    at: artifactURL
                ),
                info.bundleIdentifier
                    == VerifiedUpdateStager.bundleIdentifier,
                info.build > 0,
                let identity = try? signatureVerifier.verifyApplication(
                    at: artifactURL,
                    expectedBundleIdentifier:
                        VerifiedUpdateStager.bundleIdentifier
                ),
                identity == currentIdentity,
                identity.teamIdentifier == expectedTeamIdentifier
            else {
                continue
            }
            try? fileSystem.removeItem(at: artifactURL)
        }
    }
}
