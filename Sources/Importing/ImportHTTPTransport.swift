import Foundation

struct ImportHTTPResponse: Equatable, Sendable {
    let data: Data
    let statusCode: Int
    let finalURL: URL
    let headers: [String: String]

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

struct ImportURLPolicy: Equatable, Sendable {
    private let allowedHosts: Set<String>?

    static let githubAPI = Self(allowedHosts: ["api.github.com"])
    static let githubArchive = Self(allowedHosts: ["codeload.github.com"])
    static let slackAsset = Self(allowedHosts: nil)

    private init(allowedHosts: Set<String>?) {
        self.allowedHosts = allowedHosts
    }

    func validate(_ url: URL) throws {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ), let scheme = components.scheme?.lowercased(), !scheme.isEmpty else {
            throw ImportHTTPError.invalidURL
        }
        guard scheme == "https" else {
            throw ImportHTTPError.insecureURL
        }
        guard components.user == nil, components.password == nil else {
            throw ImportHTTPError.credentialBearingURL
        }
        guard components.port == nil else {
            throw ImportHTTPError.unexpectedPort
        }
        guard components.fragment == nil,
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            throw ImportHTTPError.invalidURL
        }
        if let allowedHosts, !allowedHosts.contains(host) {
            throw ImportHTTPError.disallowedHost(host)
        }
    }
}

protocol ImportHTTPTransport: Sendable {
    func fetch(
        _ request: URLRequest,
        policy: ImportURLPolicy,
        maximumBytes: Int64
    ) async throws -> ImportHTTPResponse
}

struct URLSessionImportHTTPTransport: ImportHTTPTransport {
    func fetch(
        _ request: URLRequest,
        policy: ImportURLPolicy,
        maximumBytes: Int64
    ) async throws -> ImportHTTPResponse {
        guard maximumBytes > 0 else {
            throw ImportHTTPError.invalidByteLimit
        }
        guard let url = request.url else {
            throw ImportHTTPError.invalidURL
        }
        try policy.validate(url)

        let operation = BoundedHTTPSRequest(
            policy: policy,
            maximumBytes: maximumBytes
        )
        return try await operation.perform(request)
    }
}

enum ImportHTTPError: Error, Equatable, LocalizedError, Sendable {
    case invalidURL
    case insecureURL
    case credentialBearingURL
    case unexpectedPort
    case disallowedHost(String)
    case invalidByteLimit
    case invalidResponse
    case responseTooLarge(limit: Int64)
    case offline
    case transport(URLError.Code)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The download URL is malformed."
        case .insecureURL:
            "Only HTTPS downloads are allowed."
        case .credentialBearingURL:
            "Download URLs cannot contain embedded credentials."
        case .unexpectedPort:
            "Download URLs cannot use a custom port."
        case let .disallowedHost(host):
            "Downloads from \(host) are not allowed for this import."
        case .invalidByteLimit:
            "The download byte limit is invalid."
        case .invalidResponse:
            "The server returned an invalid response."
        case let .responseTooLarge(limit):
            "The response exceeded the \(limit)-byte download limit."
        case .offline:
            "The network appears to be offline."
        case let .transport(code):
            "The download failed with network error \(code.rawValue)."
        }
    }
}

private final class BoundedHTTPSRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let policy: ImportURLPolicy
    private let maximumBytes: Int64
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ImportHTTPResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var cancellationRequested = false

    init(policy: ImportURLPolicy, maximumBytes: Int64) {
        self.policy = policy
        self.maximumBytes = maximumBytes
    }

    func perform(_ request: URLRequest) async throws -> ImportHTTPResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                start(request, continuation: continuation)
            }
        } onCancel: {
            cancel()
        }
    }

    private func start(
        _ request: URLRequest,
        continuation: CheckedContinuation<ImportHTTPResponse, Error>
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120

        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .utility
        let session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: delegateQueue
        )
        let task = session.dataTask(with: request)

        lock.lock()
        self.continuation = continuation
        self.session = session
        self.task = task
        let wasCancelled = cancellationRequested
        lock.unlock()

        if wasCancelled {
            finish(.failure(CancellationError()))
        } else {
            task.resume()
        }
    }

    private func cancel() {
        lock.lock()
        cancellationRequested = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        _ = session
        _ = task
        _ = response
        do {
            guard let url = request.url else {
                throw ImportHTTPError.invalidURL
            }
            try policy.validate(url)
            completionHandler(request)
        } catch {
            completionHandler(nil)
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        _ = session
        _ = dataTask
        guard let response = response as? HTTPURLResponse,
              let finalURL = response.url else {
            completionHandler(.cancel)
            finish(.failure(ImportHTTPError.invalidResponse))
            return
        }
        do {
            try policy.validate(finalURL)
        } catch {
            completionHandler(.cancel)
            finish(.failure(error))
            return
        }
        if response.expectedContentLength > maximumBytes {
            completionHandler(.cancel)
            finish(.failure(ImportHTTPError.responseTooLarge(limit: maximumBytes)))
            return
        }

        lock.lock()
        self.response = response
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        _ = session
        _ = dataTask

        lock.lock()
        let nextCount = Int64(body.count) + Int64(data.count)
        if nextCount <= maximumBytes {
            body.append(data)
        }
        lock.unlock()

        if nextCount > maximumBytes {
            dataTask.cancel()
            finish(.failure(ImportHTTPError.responseTooLarge(limit: maximumBytes)))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        _ = session
        _ = task
        if let error {
            finish(.failure(Self.mappedTransportError(error)))
            return
        }

        lock.lock()
        let response = response
        let body = body
        lock.unlock()
        guard let response, let finalURL = response.url else {
            finish(.failure(ImportHTTPError.invalidResponse))
            return
        }
        let headers = response.allHeaderFields.reduce(
            into: [String: String]()
        ) { result, pair in
            guard let key = pair.key as? String else {
                return
            }
            result[key.lowercased()] = String(describing: pair.value)
        }
        finish(
            .success(
                ImportHTTPResponse(
                    data: body,
                    statusCode: response.statusCode,
                    finalURL: finalURL,
                    headers: headers
                )
            )
        )
    }

    private func finish(_ result: Result<ImportHTTPResponse, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let session = session
        self.session = nil
        task = nil
        lock.unlock()

        session?.invalidateAndCancel()
        continuation.resume(with: result)
    }

    private static func mappedTransportError(_ error: Error) -> Error {
        if error is CancellationError {
            return CancellationError()
        }
        guard let urlError = error as? URLError else {
            return ImportHTTPError.invalidResponse
        }
        switch urlError.code {
        case .cancelled:
            return CancellationError()
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return ImportHTTPError.offline
        default:
            return ImportHTTPError.transport(urlError.code)
        }
    }
}
