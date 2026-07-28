import Foundation
@testable import MojiPond

actor MockImportHTTPTransport: ImportHTTPTransport {
    enum Outcome: Sendable {
        case response(ImportHTTPResponse)
        case redirect(URL)
        case networkError(ImportHTTPError)
        case waitForCancellation
    }

    struct Call: Equatable, Sendable {
        let url: URL
        let policy: ImportURLPolicy
        let maximumBytes: Int64
        let authorization: String?
    }

    private var outcomesByHost: [String: [Outcome]] = [:]
    private var calls: [Call] = []

    func enqueue(host: String, outcome: Outcome) {
        outcomesByHost[host, default: []].append(outcome)
    }

    func recordedCalls() -> [Call] {
        calls
    }

    func fetch(
        _ request: URLRequest,
        policy: ImportURLPolicy,
        maximumBytes: Int64
    ) async throws -> ImportHTTPResponse {
        guard let url = request.url, let host = url.host?.lowercased() else {
            throw ImportHTTPError.invalidURL
        }
        try policy.validate(url)
        calls.append(
            Call(
                url: url,
                policy: policy,
                maximumBytes: maximumBytes,
                authorization: request.value(
                    forHTTPHeaderField: "Authorization"
                )
            )
        )
        guard var outcomes = outcomesByHost[host], !outcomes.isEmpty else {
            throw ImportHTTPError.transport(.resourceUnavailable)
        }
        let outcome = outcomes.removeFirst()
        outcomesByHost[host] = outcomes

        switch outcome {
        case let .response(response):
            try policy.validate(response.finalURL)
            guard Int64(response.data.count) <= maximumBytes else {
                throw ImportHTTPError.responseTooLarge(limit: maximumBytes)
            }
            return response
        case let .redirect(url):
            try policy.validate(url)
            throw ImportHTTPError.invalidResponse
        case let .networkError(error):
            throw error
        case .waitForCancellation:
            try await Task.sleep(for: .seconds(3_600))
            throw ImportHTTPError.invalidResponse
        }
    }
}

struct StaticGitHubTokenProvider: GitHubAccessTokenProviding {
    let token: String?

    func accessToken() async throws -> String? {
        token
    }
}

enum ImportingTestSupport {
    static func response(
        url: String,
        statusCode: Int = 200,
        data: Data,
        headers: [String: String] = [:]
    ) throws -> ImportHTTPResponse {
        ImportHTTPResponse(
            data: data,
            statusCode: statusCode,
            finalURL: try unwrappedURL(url),
            headers: Dictionary(
                uniqueKeysWithValues: headers.map {
                    ($0.key.lowercased(), $0.value)
                }
            )
        )
    }

    static func unwrappedURL(_ value: String) throws -> URL {
        guard let url = URL(string: value) else {
            throw ImportingTestSupportError.invalidURL
        }
        return url
    }

    static func makeWorkspace() throws -> (
        root: URL,
        temporaryRoot: URL
    ) {
        let root = try TestSupport.makeTemporaryDirectory()
        let temporaryRoot = root.appendingPathComponent(
            "Temporary",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: false
        )
        return (root, temporaryRoot)
    }
}

enum ImportingTestSupportError: Error {
    case invalidURL
}
