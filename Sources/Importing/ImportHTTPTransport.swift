import Foundation
import Darwin

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
    private let requiresPublicNetworkAddress: Bool

    static let githubAPI = Self(
        allowedHosts: ["api.github.com"],
        requiresPublicNetworkAddress: false
    )
    static let githubArchive = Self(
        allowedHosts: ["codeload.github.com"],
        requiresPublicNetworkAddress: false
    )
    static let slackAsset = Self(
        allowedHosts: nil,
        requiresPublicNetworkAddress: true
    )

    private init(
        allowedHosts: Set<String>?,
        requiresPublicNetworkAddress: Bool
    ) {
        self.allowedHosts = allowedHosts
        self.requiresPublicNetworkAddress = requiresPublicNetworkAddress
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
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            throw ImportHTTPError.invalidURL
        }
        if let allowedHosts, !allowedHosts.contains(host) {
            throw ImportHTTPError.disallowedHost(host)
        }
        if requiresPublicNetworkAddress {
            let normalizedHost = host.hasSuffix(".")
                ? String(host.dropLast())
                : host
            guard normalizedHost != "localhost",
                  !normalizedHost.hasSuffix(".localhost"),
                  normalizedHost != "local",
                  !normalizedHost.hasSuffix(".local"),
                  !normalizedHost.contains("%") else {
                throw ImportHTTPError.unsafeNetworkDestination(host)
            }
            if let address = ImportResolvedAddress(ipLiteral: normalizedHost),
               !address.isPubliclyRoutable {
                throw ImportHTTPError.unsafeNetworkDestination(host)
            }
        }
    }

    func validateForConnection(
        _ url: URL,
        resolver: any ImportHostResolving
    ) throws {
        try validate(url)
        guard requiresPublicNetworkAddress,
              let host = url.host?.lowercased() else {
            return
        }
        let addresses = try resolver.resolve(host: host)
        guard !addresses.isEmpty,
              addresses.allSatisfy(\.isPubliclyRoutable) else {
            throw ImportHTTPError.unsafeNetworkDestination(host)
        }
    }
}

protocol ImportHostResolving: Sendable {
    func resolve(host: String) throws -> [ImportResolvedAddress]
}

struct SystemImportHostResolver: ImportHostResolving {
    func resolve(host: String) throws -> [ImportResolvedAddress] {
        var hints = addrinfo()
        hints.ai_flags = AI_ADDRCONFIG | AI_NUMERICSERV
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, "443", &hints, &result)
        guard status == 0, let first = result else {
            throw ImportHTTPError.hostResolutionFailed(host)
        }
        defer {
            freeaddrinfo(first)
        }

        var addresses = Set<ImportResolvedAddress>()
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor?.pointee {
            if info.ai_family == AF_INET,
               let socketAddress = info.ai_addr {
                var address = socketAddress
                    .withMemoryRebound(
                        to: sockaddr_in.self,
                        capacity: 1
                    ) { $0.pointee.sin_addr }
                addresses.insert(
                    .ipv4(withUnsafeBytes(of: &address) { Array($0) })
                )
            } else if info.ai_family == AF_INET6,
                      let socketAddress = info.ai_addr {
                var address = socketAddress
                    .withMemoryRebound(
                        to: sockaddr_in6.self,
                        capacity: 1
                    ) { $0.pointee.sin6_addr }
                addresses.insert(
                    .ipv6(withUnsafeBytes(of: &address) { Array($0) })
                )
            }
            cursor = info.ai_next
        }
        guard !addresses.isEmpty else {
            throw ImportHTTPError.hostResolutionFailed(host)
        }
        return addresses.sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }
    }
}

struct ImportResolvedAddress: Hashable, Sendable {
    enum Family: Hashable, Sendable {
        case ipv4
        case ipv6
    }

    let family: Family
    let bytes: [UInt8]

    private init(family: Family, bytes: [UInt8]) {
        self.family = family
        self.bytes = bytes
    }

    static func ipv4(_ bytes: [UInt8]) -> Self {
        Self(family: .ipv4, bytes: bytes)
    }

    static func ipv6(_ bytes: [UInt8]) -> Self {
        Self(family: .ipv6, bytes: bytes)
    }

    init?(ipLiteral: String) {
        var ipv4Address = in_addr()
        if ipLiteral.withCString({
            inet_pton(AF_INET, $0, &ipv4Address)
        }) == 1 {
            var address = ipv4Address
            self = .ipv4(withUnsafeBytes(of: &address) { Array($0) })
            return
        }

        var ipv6Address = in6_addr()
        if ipLiteral.withCString({
            inet_pton(AF_INET6, $0, &ipv6Address)
        }) == 1 {
            var address = ipv6Address
            self = .ipv6(withUnsafeBytes(of: &address) { Array($0) })
            return
        }
        return nil
    }

    var isPubliclyRoutable: Bool {
        switch family {
        case .ipv4:
            guard bytes.count == 4 else {
                return false
            }
            let first = bytes[0]
            let second = bytes[1]
            if first == 0 || first == 10 || first == 127 || first >= 224 {
                return false
            }
            if first == 100, (64...127).contains(second) {
                return false
            }
            if first == 169, second == 254 {
                return false
            }
            if first == 172, (16...31).contains(second) {
                return false
            }
            if first == 192,
               (
                   second == 0
                       || second == 88 && bytes[2] == 99
                       || second == 168
               ) {
                return false
            }
            if first == 198, (second == 18 || second == 19) {
                return false
            }
            if first == 198, second == 51, bytes[2] == 100 {
                return false
            }
            if first == 203, second == 0, bytes[2] == 113 {
                return false
            }
            return true
        case .ipv6:
            guard bytes.count == 16 else {
                return false
            }
            if bytes.allSatisfy({ $0 == 0 }) {
                return false
            }
            if bytes.dropLast().allSatisfy({ $0 == 0 }),
               bytes.last == 1 {
                return false
            }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }),
               bytes[10] == 0xFF,
               bytes[11] == 0xFF {
                return Self.ipv4(Array(bytes.suffix(4))).isPubliclyRoutable
            }
            if bytes.prefix(12).allSatisfy({ $0 == 0 }) {
                return Self.ipv4(Array(bytes.suffix(4))).isPubliclyRoutable
            }
            guard bytes[0] & 0xE0 == 0x20 else {
                return false
            }
            if bytes[0] == 0x20, bytes[1] == 0x02 {
                return false
            }
            if bytes[0] == 0x20, bytes[1] == 0x01 {
                if bytes[2] == 0x00, bytes[3] == 0x02 {
                    return false
                }
                if bytes[2] == 0x0D, bytes[3] == 0xB8 {
                    return false
                }
                if bytes[2] == 0x00, bytes[3] & 0xF0 == 0x10 {
                    return false
                }
                if bytes[2] == 0x00, bytes[3] & 0xF0 == 0x20 {
                    return false
                }
            }
            return true
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
    let resolver: any ImportHostResolving

    init(resolver: any ImportHostResolving = SystemImportHostResolver()) {
        self.resolver = resolver
    }

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
        try await Task.detached(priority: .utility) {
            try policy.validateForConnection(url, resolver: resolver)
        }.value

        let operation = BoundedHTTPSRequest(
            policy: policy,
            resolver: resolver,
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
    case unsafeNetworkDestination(String)
    case hostResolutionFailed(String)
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
        case let .unsafeNetworkDestination(host):
            "Downloads from the non-public network destination \(host) are not allowed."
        case let .hostResolutionFailed(host):
            "Could not resolve the download host \(host)."
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
    private let resolver: any ImportHostResolving
    private let maximumBytes: Int64
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ImportHTTPResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var cancellationRequested = false

    init(
        policy: ImportURLPolicy,
        resolver: any ImportHostResolving,
        maximumBytes: Int64
    ) {
        self.policy = policy
        self.resolver = resolver
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
            try policy.validateForConnection(url, resolver: resolver)
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
