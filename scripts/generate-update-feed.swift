#!/usr/bin/env swift

import CryptoKit
import Darwin
import Foundation

private let usageExitCode: Int32 = 64
private let dataErrorExitCode: Int32 = 65
private let missingInputExitCode: Int32 = 66
private let softwareErrorExitCode: Int32 = 70
private let cannotCreateExitCode: Int32 = 73
private let maximumArchiveByteCount: Int64 = 512 * 1_024 * 1_024

private struct GeneratorFailure: Error {
    let message: String
    let exitCode: Int32

    static func usage(_ message: String) -> Self {
        Self(message: message, exitCode: usageExitCode)
    }

    static func invalidInput(_ message: String) -> Self {
        Self(message: message, exitCode: dataErrorExitCode)
    }

    static func missingInput(_ message: String) -> Self {
        Self(message: message, exitCode: missingInputExitCode)
    }

    static func cannotCreate(_ message: String) -> Self {
        Self(message: message, exitCode: cannotCreateExitCode)
    }
}

private enum SignatureAlgorithm: String, Codable {
    case ed25519
    case p256SHA256 = "p256-sha256"
}

private struct CommandOptions {
    let algorithm: SignatureAlgorithm
    let privateKeyURL: URL
    let archiveURL: URL
    let version: String
    let build: Int
    let publishedAt: Date
    let minimumSystemVersion: String?
    let downloadURL: URL
    let releaseNotesURL: URL?
    let outputURL: URL
}

private struct UpdateManifestPayload: Encodable {
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

private struct SignedUpdateEnvelope: Encodable {
    let schemaVersion: Int
    let algorithm: SignatureAlgorithm
    let payload: String
    let signature: String
}

private struct ArchiveIdentity {
    let device: dev_t
    let inode: ino_t
    let byteCount: off_t
    let modificationSeconds: Int
    let modificationNanoseconds: Int
    let statusChangeSeconds: Int
    let statusChangeNanoseconds: Int

    init(_ status: stat) {
        device = status.st_dev
        inode = status.st_ino
        byteCount = status.st_size
        modificationSeconds = status.st_mtimespec.tv_sec
        modificationNanoseconds = status.st_mtimespec.tv_nsec
        statusChangeSeconds = status.st_ctimespec.tv_sec
        statusChangeNanoseconds = status.st_ctimespec.tv_nsec
    }
}

private struct ArchiveDigest {
    let sha256: String
    let byteCount: Int64
}

private struct SigningResult {
    let signature: Data
    let publicKey: Data
}

private let usage = """
Usage:
  xcrun swift scripts/generate-update-feed.swift \\
    --algorithm ed25519|p256-sha256 \\
    --private-key /absolute/path/to/base64-raw-private-key \\
    --archive /absolute/path/to/MojiPond-notarized.zip \\
    --version 0.1.0 \\
    --build 1 \\
    --published-at 2026-07-27T00:00:00Z \\
    [--minimum-system-version 14.0] \\
    --download-url https://updates.example.com/MojiPond-notarized.zip \\
    [--release-notes-url https://updates.example.com/releases/0.1.0] \\
    --output /absolute/path/to/update-feed.json

The private-key file must contain only the Base64-encoded CryptoKit raw private
key representation, may end with whitespace, and must not be accessible by
group or other users. Existing output files are never overwritten.
"""

private func parseArguments(_ arguments: [String]) throws -> CommandOptions {
    if arguments == ["--help"] || arguments == ["-h"] {
        print(usage)
        Darwin.exit(EXIT_SUCCESS)
    }

    let acceptedArguments: Set<String> = [
        "--algorithm",
        "--private-key",
        "--archive",
        "--version",
        "--build",
        "--published-at",
        "--minimum-system-version",
        "--download-url",
        "--release-notes-url",
        "--output",
    ]
    var values: [String: String] = [:]
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        guard acceptedArguments.contains(argument) else {
            throw GeneratorFailure.usage("Unknown argument: \(argument)\n\n\(usage)")
        }
        guard values[argument] == nil else {
            throw GeneratorFailure.usage("Duplicate argument: \(argument)")
        }
        let valueIndex = index + 1
        guard valueIndex < arguments.count,
              !arguments[valueIndex].hasPrefix("--")
        else {
            throw GeneratorFailure.usage("Missing value for \(argument)")
        }
        values[argument] = arguments[valueIndex]
        index += 2
    }

    func requiredValue(_ name: String) throws -> String {
        guard let value = values[name], !value.isEmpty else {
            throw GeneratorFailure.usage("Missing required argument: \(name)\n\n\(usage)")
        }
        return value
    }

    let algorithmValue = try requiredValue("--algorithm")
    guard let algorithm = SignatureAlgorithm(rawValue: algorithmValue) else {
        throw GeneratorFailure.invalidInput(
            "--algorithm must be ed25519 or p256-sha256."
        )
    }

    let version = try validatedVersion(requiredValue("--version"))
    let build = try validatedBuild(requiredValue("--build"))
    let publishedAt = try validatedPublishedAt(requiredValue("--published-at"))
    let minimumSystemVersion = try values["--minimum-system-version"].map(
        validatedMinimumSystemVersion
    )
    let downloadURL = try validatedHTTPSURL(
        requiredValue("--download-url"),
        argument: "--download-url"
    )
    let releaseNotesURL = try values["--release-notes-url"].map {
        try validatedHTTPSURL($0, argument: "--release-notes-url")
    }

    return CommandOptions(
        algorithm: algorithm,
        privateKeyURL: try absoluteFileURL(
            requiredValue("--private-key"),
            argument: "--private-key"
        ),
        archiveURL: try absoluteFileURL(
            requiredValue("--archive"),
            argument: "--archive"
        ),
        version: version,
        build: build,
        publishedAt: publishedAt,
        minimumSystemVersion: minimumSystemVersion,
        downloadURL: downloadURL,
        releaseNotesURL: releaseNotesURL,
        outputURL: try absoluteFileURL(
            requiredValue("--output"),
            argument: "--output"
        )
    )
}

private func validatedVersion(_ value: String) throws -> String {
    guard !value.isEmpty,
          value.utf8.count <= 64,
          value.utf8.allSatisfy({
              (0x30...0x39).contains($0)
                  || (0x41...0x5A).contains($0)
                  || (0x61...0x7A).contains($0)
                  || $0 == 0x2D
                  || $0 == 0x2B
                  || $0 == 0x2E
          })
    else {
        throw GeneratorFailure.invalidInput(
            "--version must be 1-64 ASCII letters, numbers, periods, pluses, or hyphens."
        )
    }
    return value
}

private func validatedBuild(_ value: String) throws -> Int {
    guard !value.isEmpty,
          value.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
          let build = Int(value),
          build > 0
    else {
        throw GeneratorFailure.invalidInput("--build must be a positive integer.")
    }
    return build
}

private func validatedPublishedAt(_ value: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    guard value.utf8.count == 20,
          let date = formatter.date(from: value),
          formatter.string(from: date) == value
    else {
        throw GeneratorFailure.invalidInput(
            "--published-at must be an exact UTC timestamp such as 2026-07-27T00:00:00Z."
        )
    }
    return date
}

private func validatedMinimumSystemVersion(_ value: String) throws -> String {
    let components = value.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...3).contains(components.count),
          components.allSatisfy({
              !$0.isEmpty
                  && $0.utf8.allSatisfy({ (0x30...0x39).contains($0) })
                  && Int($0) != nil
          })
    else {
        throw GeneratorFailure.invalidInput(
            "--minimum-system-version must contain one to three numeric components."
        )
    }
    return value
}

private func validatedHTTPSURL(
    _ value: String,
    argument: String
) throws -> URL {
    guard let url = URL(string: value),
          url.absoluteString == value,
          url.scheme?.lowercased(with: Locale(identifier: "en_US_POSIX")) == "https",
          !(url.host?.isEmpty ?? true),
          url.user == nil,
          url.password == nil
    else {
        throw GeneratorFailure.invalidInput(
            "\(argument) must be an absolute HTTPS URL without credentials."
        )
    }
    return url
}

private func absoluteFileURL(
    _ value: String,
    argument: String
) throws -> URL {
    guard value.hasPrefix("/"), !value.contains("\0") else {
        throw GeneratorFailure.invalidInput("\(argument) must be an absolute file path.")
    }
    let url = URL(fileURLWithPath: value).standardizedFileURL
    guard url.path != "/" else {
        throw GeneratorFailure.invalidInput("\(argument) cannot be the filesystem root.")
    }
    return url
}

private func generateFeed(using options: CommandOptions) throws {
    let keyData = try readPrivateKey(from: options.privateKeyURL)
    let archiveDigest = try hashArchive(at: options.archiveURL)
    let payload = UpdateManifestPayload(
        schemaVersion: 1,
        version: options.version,
        build: options.build,
        publishedAt: options.publishedAt,
        minimumSystemVersion: options.minimumSystemVersion,
        downloadURL: options.downloadURL,
        releaseNotesURL: options.releaseNotesURL,
        assetSHA256: archiveDigest.sha256,
        assetByteCount: archiveDigest.byteCount
    )

    let payloadData: Data
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        payloadData = try encoder.encode(payload)
    } catch {
        throw GeneratorFailure.invalidInput("Could not encode the update payload.")
    }

    let signingResult = try sign(
        payloadData,
        algorithm: options.algorithm,
        privateKeyData: keyData
    )
    let envelope = SignedUpdateEnvelope(
        schemaVersion: 1,
        algorithm: options.algorithm,
        payload: payloadData.base64EncodedString(),
        signature: signingResult.signature.base64EncodedString()
    )
    let envelopeData: Data
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        envelopeData = try encoder.encode(envelope)
    } catch {
        throw GeneratorFailure.invalidInput("Could not encode the signed envelope.")
    }

    var outputData = envelopeData
    outputData.append(0x0A)
    try writeWithoutOverwriting(outputData, to: options.outputURL)

    let payloadSHA256 = hexadecimalSHA256(of: payloadData)
    print("Wrote signed update feed: \(options.outputURL.path)")
    print("Algorithm: \(options.algorithm.rawValue)")
    print("Archive SHA-256: \(archiveDigest.sha256)")
    print("Archive bytes: \(archiveDigest.byteCount)")
    print("Payload SHA-256: \(payloadSHA256)")
    print(
        "Verification key SHA-256: "
            + verificationKeySHA256(
                algorithm: options.algorithm,
                publicKey: signingResult.publicKey
            )
    )
    print(
        "Public key (Base64 raw representation): "
            + signingResult.publicKey.base64EncodedString()
    )
}

private func readPrivateKey(from url: URL) throws -> Data {
    let descriptor = try openReadOnlyFile(
        at: url,
        label: "private-key",
        missingMessage: "The private-key file does not exist."
    )
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer {
        try? handle.close()
    }

    let initialStatus = try fileStatus(
        descriptor: descriptor,
        label: "private-key"
    )
    guard isRegularFile(initialStatus) else {
        throw GeneratorFailure.invalidInput("The private-key path must be a regular file.")
    }
    guard initialStatus.st_size > 0, initialStatus.st_size <= 4_096 else {
        throw GeneratorFailure.invalidInput(
            "The private-key file must contain 1-4096 bytes."
        )
    }
    guard initialStatus.st_mode & mode_t(0o077) == 0 else {
        throw GeneratorFailure.invalidInput(
            "The private-key file must not be accessible by group or other users; use chmod 600."
        )
    }

    let encodedData: Data
    do {
        encodedData = try handle.readToEnd() ?? Data()
    } catch {
        throw GeneratorFailure.invalidInput("Could not read the private-key file.")
    }
    let finalStatus = try fileStatus(
        descriptor: descriptor,
        label: "private-key"
    )
    guard ArchiveIdentity(initialStatus) == ArchiveIdentity(finalStatus),
          Int64(encodedData.count) == initialStatus.st_size
    else {
        throw GeneratorFailure.invalidInput(
            "The private-key file changed while it was being read."
        )
    }

    guard let encodedKey = String(data: encodedData, encoding: .utf8) else {
        throw GeneratorFailure.invalidInput(
            "The private-key file must contain UTF-8 Base64 text."
        )
    }
    let trimmedKey = encodedKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedKey.isEmpty,
          let privateKeyData = Data(base64Encoded: trimmedKey)
    else {
        throw GeneratorFailure.invalidInput(
            "The private-key file does not contain valid Base64."
        )
    }
    return privateKeyData
}

private func hashArchive(at url: URL) throws -> ArchiveDigest {
    let descriptor = try openReadOnlyFile(
        at: url,
        label: "archive",
        missingMessage: "The release archive does not exist."
    )
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer {
        try? handle.close()
    }

    let initialStatus = try fileStatus(descriptor: descriptor, label: "archive")
    guard isRegularFile(initialStatus) else {
        throw GeneratorFailure.invalidInput("The archive path must be a regular file.")
    }
    guard initialStatus.st_size > 0 else {
        throw GeneratorFailure.invalidInput("The release archive must not be empty.")
    }
    guard initialStatus.st_size <= maximumArchiveByteCount else {
        throw GeneratorFailure.invalidInput(
            "The release archive exceeds MojiPond's 512 MiB updater limit."
        )
    }

    var hasher = SHA256()
    var byteCount: Int64 = 0
    do {
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
            byteCount += Int64(chunk.count)
        }
    } catch {
        throw GeneratorFailure.invalidInput("Could not read the release archive.")
    }

    let finalStatus = try fileStatus(descriptor: descriptor, label: "archive")
    guard ArchiveIdentity(initialStatus) == ArchiveIdentity(finalStatus),
          byteCount == initialStatus.st_size
    else {
        throw GeneratorFailure.invalidInput(
            "The release archive changed while it was being hashed."
        )
    }

    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return ArchiveDigest(sha256: digest, byteCount: byteCount)
}

private func sign(
    _ payload: Data,
    algorithm: SignatureAlgorithm,
    privateKeyData: Data
) throws -> SigningResult {
    switch algorithm {
    case .ed25519:
        let privateKey: Curve25519.Signing.PrivateKey
        do {
            privateKey = try Curve25519.Signing.PrivateKey(
                rawRepresentation: privateKeyData
            )
        } catch {
            throw GeneratorFailure.invalidInput(
                "The private key is not a valid Ed25519 CryptoKit raw private key."
            )
        }
        let signature: Data
        do {
            signature = try privateKey.signature(for: payload)
        } catch {
            throw GeneratorFailure.invalidInput("Ed25519 signing failed.")
        }
        guard privateKey.publicKey.isValidSignature(signature, for: payload) else {
            throw GeneratorFailure.invalidInput(
                "The generated Ed25519 signature did not verify."
            )
        }
        return SigningResult(
            signature: signature,
            publicKey: privateKey.publicKey.rawRepresentation
        )

    case .p256SHA256:
        let privateKey: P256.Signing.PrivateKey
        do {
            privateKey = try P256.Signing.PrivateKey(
                rawRepresentation: privateKeyData
            )
        } catch {
            throw GeneratorFailure.invalidInput(
                "The private key is not a valid P-256 CryptoKit raw private key."
            )
        }
        let signature: P256.Signing.ECDSASignature
        do {
            signature = try privateKey.signature(for: payload)
        } catch {
            throw GeneratorFailure.invalidInput("P-256 signing failed.")
        }
        guard privateKey.publicKey.isValidSignature(signature, for: payload) else {
            throw GeneratorFailure.invalidInput(
                "The generated P-256 signature did not verify."
            )
        }
        return SigningResult(
            signature: signature.rawRepresentation,
            publicKey: privateKey.publicKey.rawRepresentation
        )
    }
}

private func openReadOnlyFile(
    at url: URL,
    label: String,
    missingMessage: String
) throws -> Int32 {
    let descriptor = url.path.withCString {
        Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
        switch errno {
        case ENOENT:
            throw GeneratorFailure.missingInput(missingMessage)
        case ELOOP:
            throw GeneratorFailure.invalidInput(
                "The \(label) path must not be a symbolic link."
            )
        default:
            throw GeneratorFailure.invalidInput("Could not open the \(label) file.")
        }
    }
    return descriptor
}

private func fileStatus(
    descriptor: Int32,
    label: String
) throws -> stat {
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0 else {
        throw GeneratorFailure.invalidInput("Could not inspect the \(label) file.")
    }
    return status
}

private func isRegularFile(_ status: stat) -> Bool {
    status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
}

private func hexadecimalSHA256(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func verificationKeySHA256(
    algorithm: SignatureAlgorithm,
    publicKey: Data
) -> String {
    var fingerprintInput = Data(
        "mojipond-update-key-v1:\(algorithm.rawValue):".utf8
    )
    fingerprintInput.append(publicKey)
    return hexadecimalSHA256(of: fingerprintInput)
}

private func writeWithoutOverwriting(
    _ data: Data,
    to outputURL: URL
) throws {
    let parentURL = outputURL.deletingLastPathComponent()
    var parentStatus = stat()
    let parentResult = parentURL.path.withCString {
        Darwin.lstat($0, &parentStatus)
    }
    guard parentResult == 0,
          parentStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    else {
        throw GeneratorFailure.cannotCreate(
            "The output parent must be an existing directory, not a symbolic link."
        )
    }

    let temporaryURL = parentURL.appendingPathComponent(
        ".\(outputURL.lastPathComponent).tmp.\(UUID().uuidString)",
        isDirectory: false
    )
    let descriptor = temporaryURL.path.withCString {
        Darwin.open(
            $0,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
    }
    guard descriptor >= 0 else {
        throw GeneratorFailure.cannotCreate(
            "Could not create a temporary feed beside the output path."
        )
    }

    var temporaryFileExists = true
    defer {
        if temporaryFileExists {
            temporaryURL.path.withCString { _ = Darwin.unlink($0) }
        }
    }

    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer {
        try? handle.close()
    }
    do {
        try handle.write(contentsOf: data)
    } catch {
        throw GeneratorFailure.cannotCreate("Could not write the signed feed.")
    }
    guard Darwin.fsync(descriptor) == 0,
          Darwin.fchmod(descriptor, mode_t(0o644)) == 0
    else {
        throw GeneratorFailure.cannotCreate("Could not finalize the signed feed.")
    }
    do {
        try handle.close()
    } catch {
        throw GeneratorFailure.cannotCreate("Could not close the signed feed.")
    }

    let linkResult = temporaryURL.path.withCString { temporaryPath in
        outputURL.path.withCString { outputPath in
            Darwin.link(temporaryPath, outputPath)
        }
    }
    guard linkResult == 0 else {
        if errno == EEXIST {
            throw GeneratorFailure.cannotCreate(
                "Refusing to overwrite the existing output path."
            )
        }
        throw GeneratorFailure.cannotCreate(
            "Could not publish the signed feed at the output path."
        )
    }

    let unlinkResult = temporaryURL.path.withCString {
        Darwin.unlink($0)
    }
    if unlinkResult == 0 {
        temporaryFileExists = false
    }
}

extension ArchiveIdentity: Equatable {
    static func == (lhs: ArchiveIdentity, rhs: ArchiveIdentity) -> Bool {
        lhs.device == rhs.device
            && lhs.inode == rhs.inode
            && lhs.byteCount == rhs.byteCount
            && lhs.modificationSeconds == rhs.modificationSeconds
            && lhs.modificationNanoseconds == rhs.modificationNanoseconds
            && lhs.statusChangeSeconds == rhs.statusChangeSeconds
            && lhs.statusChangeNanoseconds == rhs.statusChangeNanoseconds
    }
}

do {
    let options = try parseArguments(Array(CommandLine.arguments.dropFirst()))
    try generateFeed(using: options)
} catch let failure as GeneratorFailure {
    fputs("error: \(failure.message)\n", stderr)
    Darwin.exit(failure.exitCode)
} catch {
    fputs("error: Unexpected update-feed generator failure.\n", stderr)
    Darwin.exit(softwareErrorExitCode)
}
