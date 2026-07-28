import Foundation

struct GitHubRepositoryReference: Codable, Equatable, Sendable {
    let owner: String
    let repository: String
    let ref: String
    let subdirectory: String?

    init(
        owner: String,
        repository: String,
        ref: String = "HEAD",
        subdirectory: String? = nil
    ) throws {
        guard Self.isValidOwner(owner) else {
            throw GitHubReferenceError.invalidOwner(owner)
        }
        guard Self.isValidRepository(repository) else {
            throw GitHubReferenceError.invalidRepository(repository)
        }
        try Self.validate(ref: ref)
        if let subdirectory {
            try Self.validate(subdirectory: subdirectory)
        }

        self.owner = owner
        self.repository = repository
        self.ref = ref
        self.subdirectory = subdirectory
    }

    static func parse(
        _ url: URL,
        ref explicitRef: String? = nil,
        subdirectory explicitSubdirectory: String? = nil
    ) throws -> Self {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              host == "github.com" || host == "www.github.com",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil else {
            throw GitHubReferenceError.invalidURL
        }

        let encodedPath = components.percentEncodedPath
        guard !encodedPath.contains("//"),
              !encodedPath.contains("\\"),
              !encodedPath.unicodeScalars.contains(where: { $0.value == 0 || $0.value < 0x20 }) else {
            throw GitHubReferenceError.invalidPath
        }
        let encodedComponents = encodedPath.split(separator: "/", omittingEmptySubsequences: true)
        let pathComponents = try encodedComponents.map { component -> String in
            guard let decoded = String(component).removingPercentEncoding,
                  !decoded.isEmpty,
                  !decoded.contains("/"),
                  !decoded.contains("\\"),
                  decoded != ".",
                  decoded != ".." else {
                throw GitHubReferenceError.invalidPath
            }
            return decoded
        }

        guard pathComponents.count >= 2 else {
            throw GitHubReferenceError.invalidPath
        }
        guard pathComponents.count == 2 || (
            pathComponents.count >= 4 && pathComponents[2] == "tree"
        ) else {
            throw GitHubReferenceError.unsupportedGitHubURL
        }

        let owner = pathComponents[0]
        var repository = pathComponents[1]
        if repository.hasSuffix(".git") {
            repository.removeLast(4)
        }

        let urlRef: String?
        let urlSubdirectory: String?
        if pathComponents.count >= 4 {
            urlRef = pathComponents[3]
            urlSubdirectory = pathComponents.count > 4
                ? pathComponents.dropFirst(4).joined(separator: "/")
                : nil
        } else {
            urlRef = nil
            urlSubdirectory = nil
        }

        return try Self(
            owner: owner,
            repository: repository,
            ref: explicitRef ?? urlRef ?? "HEAD",
            subdirectory: explicitSubdirectory ?? urlSubdirectory
        )
    }

    var canonicalRepositoryURL: URL {
        // Values are strictly ASCII-validated, so construction cannot fail.
        URL(string: "https://github.com/\(owner)/\(repository)")!
    }

    var archiveURL: URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%")
        let encodedRef = ref.addingPercentEncoding(withAllowedCharacters: allowed)!
        return URL(
            string: "https://codeload.github.com/\(owner)/\(repository)/zip/\(encodedRef)"
        )!
    }

    var packSource: PackSource {
        PackSource(
            kind: .github,
            displayLocation: "\(owner)/\(repository)",
            github: GitHubPackSource(
                owner: owner,
                repository: repository,
                ref: ref,
                subdirectory: subdirectory
            )
        )
    }

    private static func isValidOwner(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 39,
              isAlphaNumeric(bytes[0]),
              isAlphaNumeric(bytes[bytes.count - 1]) else {
            return false
        }
        var previousWasHyphen = false
        for byte in bytes {
            guard isAlphaNumeric(byte) || byte == 0x2D else {
                return false
            }
            if byte == 0x2D, previousWasHyphen {
                return false
            }
            previousWasHyphen = byte == 0x2D
        }
        return true
    }

    private static func isValidRepository(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 100, isAlphaNumeric(bytes[0]) else {
            return false
        }
        return bytes.allSatisfy {
            isAlphaNumeric($0) || $0 == 0x2D || $0 == 0x5F || $0 == 0x2E
        } && value != "." && value != ".."
    }

    private static func validate(ref: String) throws {
        let bytes = Array(ref.utf8)
        guard !bytes.isEmpty,
              bytes.count <= 255,
              ref != "@",
              !ref.hasPrefix("/"),
              !ref.hasSuffix("/"),
              !ref.hasPrefix("."),
              !ref.hasSuffix("."),
              !ref.contains(".."),
              !ref.contains("@{"),
              !ref.contains("//"),
              !ref.contains("\\"),
              !ref.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
              !ref.contains(where: { " ~^:?*[".contains($0) }) else {
            throw GitHubReferenceError.invalidRef(ref)
        }
        let components = ref.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasSuffix(".lock")
        }) else {
            throw GitHubReferenceError.invalidRef(ref)
        }
    }

    private static func validate(subdirectory: String) throws {
        guard !subdirectory.isEmpty,
              !subdirectory.hasPrefix("/"),
              !subdirectory.hasSuffix("/"),
              !subdirectory.contains("\\"),
              !subdirectory.contains("//"),
              subdirectory.utf8.count <= 1_024,
              !subdirectory.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else {
            throw GitHubReferenceError.invalidSubdirectory(subdirectory)
        }
        let components = subdirectory.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255
        }) else {
            throw GitHubReferenceError.invalidSubdirectory(subdirectory)
        }
    }

    private static func isAlphaNumeric(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
            || (0x41...0x5A).contains(byte)
            || (0x61...0x7A).contains(byte)
    }
}

enum GitHubReferenceError: Error, Equatable, LocalizedError, Sendable {
    case invalidURL
    case invalidPath
    case unsupportedGitHubURL
    case invalidOwner(String)
    case invalidRepository(String)
    case invalidRef(String)
    case invalidSubdirectory(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Only public HTTPS github.com repository URLs are supported."
        case .invalidPath:
            "The GitHub URL contains an unsafe path."
        case .unsupportedGitHubURL:
            "Use a GitHub repository URL or a /tree/<ref>/<folder> URL."
        case let .invalidOwner(owner):
            "GitHub owner \(owner) is invalid."
        case let .invalidRepository(repository):
            "GitHub repository \(repository) is invalid."
        case let .invalidRef(ref):
            "Git ref \(ref) is invalid or unsafe."
        case let .invalidSubdirectory(subdirectory):
            "GitHub subdirectory \(subdirectory) is invalid or unsafe."
        }
    }
}
