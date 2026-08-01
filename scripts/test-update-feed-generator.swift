#!/usr/bin/env swift

import CryptoKit
import Darwin
import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private enum SignatureAlgorithm: String, Codable, CaseIterable {
    case ed25519
    case p256SHA256 = "p256-sha256"
}

private enum TestSigningKey {
    case ed25519(Curve25519.Signing.PrivateKey)
    case p256(P256.Signing.PrivateKey)

    static func make(for algorithm: SignatureAlgorithm) -> Self {
        switch algorithm {
        case .ed25519:
            .ed25519(Curve25519.Signing.PrivateKey())
        case .p256SHA256:
            .p256(P256.Signing.PrivateKey())
        }
    }

    var privateKeyData: Data {
        switch self {
        case let .ed25519(key):
            key.rawRepresentation
        case let .p256(key):
            key.rawRepresentation
        }
    }

    var publicKeyData: Data {
        switch self {
        case let .ed25519(key):
            key.publicKey.rawRepresentation
        case let .p256(key):
            key.publicKey.rawRepresentation
        }
    }

    func verifies(signature: Data, payload: Data) -> Bool {
        switch self {
        case let .ed25519(key):
            return key.publicKey.isValidSignature(signature, for: payload)
        case let .p256(key):
            guard let parsedSignature = try? P256.Signing.ECDSASignature(
                rawRepresentation: signature
            ) else {
                return false
            }
            return key.publicKey.isValidSignature(parsedSignature, for: payload)
        }
    }
}

private struct SignedUpdateEnvelope: Codable {
    let schemaVersion: Int
    let algorithm: SignatureAlgorithm
    let payload: String
    let signature: String
}

private struct UpdateManifestPayload: Codable {
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

private struct ProcessResult {
    let status: Int32
    let standardOutput: String
    let standardError: String
}

private let fileManager = FileManager.default
private let generatorURL = URL(
    fileURLWithPath: CommandLine.arguments[0]
).standardizedFileURL
    .deletingLastPathComponent()
    .appendingPathComponent("generate-update-feed.swift")
private let temporaryDirectory = fileManager.temporaryDirectory
    .appendingPathComponent(
        "mojipond-feed-generator-tests-\(UUID().uuidString)",
        isDirectory: true
    )

private func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else {
        throw TestFailure(description: message)
    }
}

private func runGenerator(_ arguments: [String]) throws -> ProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["swift", generatorURL.path] + arguments
    process.currentDirectoryURL = generatorURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let standardOutput = Pipe()
    let standardError = Pipe()
    process.standardOutput = standardOutput
    process.standardError = standardError
    do {
        try process.run()
    } catch {
        throw TestFailure(description: "Could not launch the feed generator.")
    }
    process.waitUntilExit()

    let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
    let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
    return ProcessResult(
        status: process.terminationStatus,
        standardOutput: String(decoding: outputData, as: UTF8.self),
        standardError: String(decoding: errorData, as: UTF8.self)
    )
}

private func generatorArguments(
    algorithm: SignatureAlgorithm,
    keyURL: URL,
    archiveURL: URL,
    outputURL: URL,
    downloadURL: String = "https://updates.example.com/MojiPond-notarized.zip"
) -> [String] {
    [
        "--algorithm", algorithm.rawValue,
        "--private-key", keyURL.path,
        "--archive", archiveURL.path,
        "--version", "0.2.0",
        "--build", "2",
        "--published-at", "2026-07-28T00:00:00Z",
        "--minimum-system-version", "14.0",
        "--download-url", downloadURL,
        "--release-notes-url", "https://updates.example.com/releases/0.2.0",
        "--output", outputURL.path,
    ]
}

private func writePrivateKey(_ key: TestSigningKey, to url: URL) throws {
    let text = key.privateKeyData.base64EncodedString() + "\n"
    try Data(text.utf8).write(to: url, options: .withoutOverwriting)
    guard Darwin.chmod(url.path, mode_t(0o600)) == 0 else {
        throw TestFailure(description: "Could not secure a fixture private key.")
    }
}

private func decodedEnvelope(at url: URL) throws -> SignedUpdateEnvelope {
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(SignedUpdateEnvelope.self, from: data)
}

private func validateGeneratedFeed(
    at url: URL,
    algorithm: SignatureAlgorithm,
    signingKey: TestSigningKey,
    archiveData: Data,
    processOutput: String
) throws -> Data {
    let feedData = try Data(contentsOf: url)
    try require(feedData.last == 0x0A, "The feed must end with one newline.")

    let envelope = try JSONDecoder().decode(
        SignedUpdateEnvelope.self,
        from: feedData
    )
    try require(envelope.schemaVersion == 1, "Unexpected envelope schema.")
    try require(envelope.algorithm == algorithm, "Unexpected signature algorithm.")
    guard let payloadData = Data(base64Encoded: envelope.payload),
          let signatureData = Data(base64Encoded: envelope.signature)
    else {
        throw TestFailure(description: "The envelope contains invalid Base64.")
    }
    try require(
        signingKey.verifies(signature: signatureData, payload: payloadData),
        "The generated signature did not verify independently."
    )

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let payload = try decoder.decode(UpdateManifestPayload.self, from: payloadData)
    try require(payload.schemaVersion == 1, "Unexpected payload schema.")
    try require(payload.version == "0.2.0", "Unexpected payload version.")
    try require(payload.build == 2, "Unexpected payload build.")
    try require(
        payload.minimumSystemVersion == "14.0",
        "Unexpected minimum system version."
    )
    try require(
        payload.downloadURL.absoluteString
            == "https://updates.example.com/MojiPond-notarized.zip",
        "Unexpected download URL."
    )
    try require(
        payload.releaseNotesURL?.absoluteString
            == "https://updates.example.com/releases/0.2.0",
        "Unexpected release-notes URL."
    )
    try require(
        payload.assetByteCount == Int64(archiveData.count),
        "The generator recorded the wrong archive byte count."
    )
    let expectedDigest = SHA256.hash(data: archiveData)
        .map { String(format: "%02x", $0) }
        .joined()
    try require(
        payload.assetSHA256 == expectedDigest,
        "The generator recorded the wrong archive digest."
    )

    let payloadEncoder = JSONEncoder()
    payloadEncoder.outputFormatting = [.sortedKeys]
    payloadEncoder.dateEncodingStrategy = .iso8601
    let reencodedPayload = try payloadEncoder.encode(payload)
    try require(
        reencodedPayload == payloadData,
        "The payload is not canonical sorted-key JSON."
    )

    let envelopeEncoder = JSONEncoder()
    envelopeEncoder.outputFormatting = [.sortedKeys]
    var expectedFeedData = try envelopeEncoder.encode(envelope)
    expectedFeedData.append(0x0A)
    try require(
        expectedFeedData == feedData,
        "The envelope is not canonical sorted-key JSON."
    )
    try require(
        processOutput.contains(signingKey.publicKeyData.base64EncodedString()),
        "The generator did not print the matching public key."
    )
    var fingerprintInput = Data(
        "mojipond-update-key-v1:\(algorithm.rawValue):".utf8
    )
    fingerprintInput.append(signingKey.publicKeyData)
    let expectedFingerprint = SHA256.hash(data: fingerprintInput)
        .map { String(format: "%02x", $0) }
        .joined()
    try require(
        processOutput.contains(expectedFingerprint),
        "The generator did not print the matching key fingerprint."
    )

    var status = stat()
    let statusResult = url.path.withCString {
        Darwin.lstat($0, &status)
    }
    try require(
        statusResult == 0,
        "Could not inspect the generated feed."
    )
    try require(
        status.st_mode & mode_t(0o777) == mode_t(0o644),
        "The feed must be created with mode 0644."
    )
    return payloadData
}

private func runAlgorithmFixture(
    _ algorithm: SignatureAlgorithm,
    archiveURL: URL,
    archiveData: Data
) throws {
    let key = TestSigningKey.make(for: algorithm)
    let keyURL = temporaryDirectory.appendingPathComponent(
        "\(algorithm.rawValue).private-key"
    )
    try writePrivateKey(key, to: keyURL)

    let firstOutputURL = temporaryDirectory.appendingPathComponent(
        "\(algorithm.rawValue)-first.json"
    )
    let firstArguments = generatorArguments(
        algorithm: algorithm,
        keyURL: keyURL,
        archiveURL: archiveURL,
        outputURL: firstOutputURL
    )
    let firstResult = try runGenerator(firstArguments)
    try require(
        firstResult.status == 0,
        "Generator failed for \(algorithm.rawValue): \(firstResult.standardError)"
    )
    let firstPayload = try validateGeneratedFeed(
        at: firstOutputURL,
        algorithm: algorithm,
        signingKey: key,
        archiveData: archiveData,
        processOutput: firstResult.standardOutput
    )

    let secondOutputURL = temporaryDirectory.appendingPathComponent(
        "\(algorithm.rawValue)-second.json"
    )
    let secondResult = try runGenerator(
        generatorArguments(
            algorithm: algorithm,
            keyURL: keyURL,
            archiveURL: archiveURL,
            outputURL: secondOutputURL
        )
    )
    try require(
        secondResult.status == 0,
        "Second generator run failed for \(algorithm.rawValue)."
    )
    let secondPayload = try validateGeneratedFeed(
        at: secondOutputURL,
        algorithm: algorithm,
        signingKey: key,
        archiveData: archiveData,
        processOutput: secondResult.standardOutput
    )
    try require(
        firstPayload == secondPayload,
        "Identical inputs must produce identical signed payload bytes."
    )
    // CryptoKit does not guarantee identical signature bytes across runs.
    // The payload is deterministic, so validate each envelope independently.

    let originalOutput = try Data(contentsOf: firstOutputURL)
    let overwriteResult = try runGenerator(firstArguments)
    try require(
        overwriteResult.status == 73,
        "The generator must fail with EX_CANTCREAT before overwriting output."
    )
    let outputAfterOverwriteAttempt = try Data(contentsOf: firstOutputURL)
    try require(
        outputAfterOverwriteAttempt == originalOutput,
        "An overwrite attempt changed the existing feed."
    )

    guard Darwin.chmod(keyURL.path, mode_t(0o644)) == 0 else {
        throw TestFailure(description: "Could not change fixture key permissions.")
    }
    let insecureKeyOutputURL = temporaryDirectory.appendingPathComponent(
        "\(algorithm.rawValue)-insecure-key.json"
    )
    let insecureKeyResult = try runGenerator(
        generatorArguments(
            algorithm: algorithm,
            keyURL: keyURL,
            archiveURL: archiveURL,
            outputURL: insecureKeyOutputURL
        )
    )
    try require(
        insecureKeyResult.status == 65,
        "The generator must reject a group/world-readable private key."
    )
    try require(
        !fileManager.fileExists(atPath: insecureKeyOutputURL.path),
        "A rejected private key must not create a feed."
    )
    guard Darwin.chmod(keyURL.path, mode_t(0o600)) == 0 else {
        throw TestFailure(description: "Could not restore fixture key permissions.")
    }
}

private func runInvalidMetadataFixture(
    archiveURL: URL
) throws {
    let algorithm = SignatureAlgorithm.ed25519
    let key = TestSigningKey.make(for: algorithm)
    let keyURL = temporaryDirectory.appendingPathComponent(
        "invalid-metadata.private-key"
    )
    try writePrivateKey(key, to: keyURL)
    let outputURL = temporaryDirectory.appendingPathComponent(
        "invalid-metadata.json"
    )
    let result = try runGenerator(
        generatorArguments(
            algorithm: algorithm,
            keyURL: keyURL,
            archiveURL: archiveURL,
            outputURL: outputURL,
            downloadURL: "http://updates.example.com/MojiPond.zip"
        )
    )
    try require(
        result.status == 65,
        "The generator must reject an insecure download URL."
    )
    try require(
        !fileManager.fileExists(atPath: outputURL.path),
        "Invalid metadata must not create a feed."
    )
}

do {
    try fileManager.createDirectory(
        at: temporaryDirectory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    defer {
        try? fileManager.removeItem(at: temporaryDirectory)
    }

    let archiveData = Data((0..<8_192).map { UInt8(truncatingIfNeeded: $0) })
    let archiveURL = temporaryDirectory.appendingPathComponent("MojiPond.zip")
    try archiveData.write(to: archiveURL, options: .withoutOverwriting)

    for algorithm in SignatureAlgorithm.allCases {
        try runAlgorithmFixture(
            algorithm,
            archiveURL: archiveURL,
            archiveData: archiveData
        )
        print("PASS: \(algorithm.rawValue) canonical feed and signature")
    }
    try runInvalidMetadataFixture(archiveURL: archiveURL)
    print("PASS: no-overwrite, key-permission, and metadata safety checks")
} catch let failure as TestFailure {
    fputs("FAIL: \(failure.description)\n", stderr)
    Darwin.exit(EXIT_FAILURE)
} catch {
    fputs("FAIL: \(error)\n", stderr)
    Darwin.exit(EXIT_FAILURE)
}
