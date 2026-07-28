import Foundation

protocol GitHubAccessTokenProviding: Sendable {
    func accessToken() async throws -> String?
}

struct AnonymousGitHubAccessTokenProvider: GitHubAccessTokenProviding {
    func accessToken() async throws -> String? {
        nil
    }
}

struct GitHubImportLimits: Equatable, Sendable {
    var maximumAPIResponseBytes: Int64 = 1 * 1_024 * 1_024
    var maximumArchiveBytes: Int64 = 100 * 1_024 * 1_024

    static let `default` = Self()
}

struct GitHubFetchedArchive: Equatable, Sendable {
    let requestedReference: GitHubRepositoryReference
    let commitSHA: String
    let archiveData: Data
    let sourceETag: String?
}

struct GitHubImportClient: Sendable {
    let transport: any ImportHTTPTransport
    let tokenProvider: any GitHubAccessTokenProviding
    let limits: GitHubImportLimits

    init(
        transport: any ImportHTTPTransport = URLSessionImportHTTPTransport(),
        tokenProvider: any GitHubAccessTokenProviding =
            AnonymousGitHubAccessTokenProvider(),
        limits: GitHubImportLimits = .default
    ) {
        self.transport = transport
        self.tokenProvider = tokenProvider
        self.limits = limits
    }

    func fetchArchive(
        from repositoryURL: URL,
        ref explicitRef: String? = nil,
        subdirectory explicitSubdirectory: String? = nil
    ) async throws -> GitHubFetchedArchive {
        try Task.checkCancellation()
        let reference = try GitHubRepositoryReference.parse(
            repositoryURL,
            ref: explicitRef,
            subdirectory: explicitSubdirectory
        )
        let commitURL = try Self.commitAPIURL(for: reference)
        var commitRequest = URLRequest(url: commitURL)
        commitRequest.httpMethod = "GET"
        commitRequest.setValue(
            "application/vnd.github+json",
            forHTTPHeaderField: "Accept"
        )
        commitRequest.setValue(
            "2022-11-28",
            forHTTPHeaderField: "X-GitHub-Api-Version"
        )
        commitRequest.setValue("MojiPond/0.1", forHTTPHeaderField: "User-Agent")

        if let token = try await tokenProvider.accessToken() {
            guard Self.isSafeToken(token) else {
                throw GitHubImportError.invalidAccessToken
            }
            commitRequest.setValue(
                "Bearer \(token)",
                forHTTPHeaderField: "Authorization"
            )
        }

        let commitResponse = try await transport.fetch(
            commitRequest,
            policy: .githubAPI,
            maximumBytes: limits.maximumAPIResponseBytes
        )
        try ImportURLPolicy.githubAPI.validate(commitResponse.finalURL)
        guard Int64(commitResponse.data.count) <= limits.maximumAPIResponseBytes else {
            throw ImportHTTPError.responseTooLarge(
                limit: limits.maximumAPIResponseBytes
            )
        }
        switch commitResponse.statusCode {
        case 200:
            break
        case 404:
            throw GitHubImportError.repositoryOrRefNotFound
        case 403, 429:
            throw GitHubImportError.rateLimited
        default:
            throw GitHubImportError.apiHTTPStatus(commitResponse.statusCode)
        }

        let payload: CommitResponse
        do {
            payload = try JSONDecoder().decode(
                CommitResponse.self,
                from: commitResponse.data
            )
        } catch {
            throw GitHubImportError.malformedCommitResponse
        }
        let commitSHA = payload.sha.lowercased()
        guard Self.isValidCommitSHA(commitSHA) else {
            throw GitHubImportError.invalidCommitSHA
        }

        try Task.checkCancellation()
        let resolvedReference = try GitHubRepositoryReference(
            owner: reference.owner,
            repository: reference.repository,
            ref: commitSHA,
            subdirectory: reference.subdirectory
        )
        var archiveRequest = URLRequest(url: resolvedReference.archiveURL)
        archiveRequest.httpMethod = "GET"
        archiveRequest.setValue("application/zip", forHTTPHeaderField: "Accept")
        archiveRequest.setValue("MojiPond/0.1", forHTTPHeaderField: "User-Agent")
        let archiveResponse = try await transport.fetch(
            archiveRequest,
            policy: .githubArchive,
            maximumBytes: limits.maximumArchiveBytes
        )
        try ImportURLPolicy.githubArchive.validate(archiveResponse.finalURL)
        guard Int64(archiveResponse.data.count) <= limits.maximumArchiveBytes else {
            throw ImportHTTPError.responseTooLarge(limit: limits.maximumArchiveBytes)
        }
        guard archiveResponse.statusCode == 200 else {
            throw GitHubImportError.archiveHTTPStatus(
                archiveResponse.statusCode
            )
        }
        guard !archiveResponse.data.isEmpty else {
            throw GitHubImportError.emptyArchive
        }
        try Task.checkCancellation()

        return GitHubFetchedArchive(
            requestedReference: reference,
            commitSHA: commitSHA,
            archiveData: archiveResponse.data,
            sourceETag: commitResponse.header("etag")
        )
    }

    private static func commitAPIURL(
        for reference: GitHubRepositoryReference
    ) throws -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encodedRef = reference.ref.addingPercentEncoding(
            withAllowedCharacters: allowed
        ), let url = URL(
            string: [
                "https://api.github.com/repos",
                reference.owner,
                reference.repository,
                "commits",
                encodedRef
            ].joined(separator: "/")
        ) else {
            throw GitHubImportError.cannotBuildAPIURL
        }
        return url
    }

    private static func isSafeToken(_ token: String) -> Bool {
        !token.isEmpty
            && token.utf8.count <= 512
            && !token.unicodeScalars.contains {
                $0.value < 0x21 || $0.value == 0x7F
            }
    }

    private static func isValidCommitSHA(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64)
            && value.utf8.allSatisfy {
                (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
            }
    }

    private struct CommitResponse: Decodable {
        let sha: String
    }
}

enum GitHubImportError: Error, Equatable, LocalizedError, Sendable {
    case invalidAccessToken
    case cannotBuildAPIURL
    case repositoryOrRefNotFound
    case rateLimited
    case apiHTTPStatus(Int)
    case malformedCommitResponse
    case invalidCommitSHA
    case archiveHTTPStatus(Int)
    case emptyArchive

    var errorDescription: String? {
        switch self {
        case .invalidAccessToken:
            "The GitHub access token contains unsafe characters."
        case .cannotBuildAPIURL:
            "The GitHub commit API URL could not be built."
        case .repositoryOrRefNotFound:
            "The public GitHub repository or ref could not be found."
        case .rateLimited:
            "GitHub rate-limited the import request."
        case let .apiHTTPStatus(status):
            "GitHub’s commit API returned HTTP \(status)."
        case .malformedCommitResponse:
            "GitHub’s commit response was malformed."
        case .invalidCommitSHA:
            "GitHub returned an invalid commit identifier."
        case let .archiveHTTPStatus(status):
            "GitHub’s archive server returned HTTP \(status)."
        case .emptyArchive:
            "GitHub returned an empty archive."
        }
    }
}
