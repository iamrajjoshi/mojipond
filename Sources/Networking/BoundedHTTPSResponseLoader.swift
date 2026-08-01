import Foundation

enum HTTPSRedirectPolicy: Equatable, Sendable {
    case anyHTTPSHost
    case sameHost
}

enum HTTPSURLValidator {
    static func isSecure(_ url: URL) -> Bool {
        url.scheme?.lowercased(
            with: Locale(identifier: "en_US_POSIX")
        ) == "https"
            && !(url.host?.isEmpty ?? true)
            && url.user == nil
            && url.password == nil
    }
}

enum BoundedHTTPSLoadError: Error, Equatable, Sendable {
    case insecureRequestURL
    case insecureRedirectURL
    case disallowedRedirectHost
    case invalidResponse
    case responseTooLarge(limit: Int)
}

struct BoundedHTTPResponse: Sendable {
    let data: Data
    let response: HTTPURLResponse
}

struct BoundedHTTPSResponseLoader: Sendable {
    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    func load(
        _ request: URLRequest,
        maximumBytes: Int,
        redirectPolicy: HTTPSRedirectPolicy = .anyHTTPSHost
    ) async throws -> BoundedHTTPResponse {
        let maximumBytes = max(0, maximumBytes)
        guard
            let requestURL = request.url,
            HTTPSURLValidator.isSecure(requestURL)
        else {
            throw BoundedHTTPSLoadError.insecureRequestURL
        }

        let redirectDelegate = HTTPSRedirectDelegate(
            originalHost: requestURL.host,
            policy: redirectPolicy
        )
        let (bytes, rawResponse) = try await session.bytes(
            for: request,
            delegate: redirectDelegate
        )

        if let violation = redirectDelegate.violation {
            bytes.task.cancel()
            throw violation
        }
        guard
            let response = rawResponse as? HTTPURLResponse,
            let finalURL = response.url,
            HTTPSURLValidator.isSecure(finalURL)
        else {
            bytes.task.cancel()
            throw BoundedHTTPSLoadError.invalidResponse
        }

        let expectedLength = response.expectedContentLength
        if expectedLength > Int64(maximumBytes) {
            bytes.task.cancel()
            throw BoundedHTTPSLoadError.responseTooLarge(limit: maximumBytes)
        }

        var data = Data()
        if expectedLength > 0 {
            data.reserveCapacity(Int(expectedLength))
        }
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximumBytes else {
                    bytes.task.cancel()
                    throw BoundedHTTPSLoadError.responseTooLarge(
                        limit: maximumBytes
                    )
                }
                data.append(byte)
            }
        } catch {
            bytes.task.cancel()
            throw error
        }

        return BoundedHTTPResponse(data: data, response: response)
    }
}

private final class HTTPSRedirectDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    private let originalHost: String?
    private let policy: HTTPSRedirectPolicy
    private let lock = NSLock()
    private var storedViolation: BoundedHTTPSLoadError?

    init(originalHost: String?, policy: HTTPSRedirectPolicy) {
        self.originalHost = originalHost?.lowercased(
            with: Locale(identifier: "en_US_POSIX")
        )
        self.policy = policy
    }

    var violation: BoundedHTTPSLoadError? {
        lock.lock()
        defer { lock.unlock() }
        return storedViolation
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

        guard
            let url = request.url,
            HTTPSURLValidator.isSecure(url)
        else {
            record(.insecureRedirectURL)
            completionHandler(nil)
            return
        }
        if policy == .sameHost {
            let redirectedHost = url.host?.lowercased(
                with: Locale(identifier: "en_US_POSIX")
            )
            guard redirectedHost == originalHost else {
                record(.disallowedRedirectHost)
                completionHandler(nil)
                return
            }
        }
        completionHandler(request)
    }

    private func record(_ violation: BoundedHTTPSLoadError) {
        lock.lock()
        if storedViolation == nil {
            storedViolation = violation
        }
        lock.unlock()
    }
}
