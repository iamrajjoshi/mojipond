import Foundation

protocol MediaCommandStickerSearching: Sendable {
    func search(_ query: String, limit: Int) async throws -> [RemoteMediaItem]
}

extension NotoStickerClient: MediaCommandStickerSearching {}

actor MediaCommandCoordinator {
    private let offlineCatalog: NotoOfflineCatalog
    private let stickerSearcher: (any MediaCommandStickerSearching)?
    private let assetResolver: MediaCommandAssetResolver

    private var requestCounter: UInt64 = 0
    private var activeRequest: MediaCommandRequest?
    private var activeTask: Task<MediaCommandSearchState, Never>?
    private var state: MediaCommandSearchState = .idle

    init(
        offlineCatalog: NotoOfflineCatalog,
        stickerSearcher: (any MediaCommandStickerSearching)? =
            NotoStickerClient(),
        assetResolver: MediaCommandAssetResolver =
            MediaCommandAssetResolver()
    ) {
        self.offlineCatalog = offlineCatalog
        self.stickerSearcher = stickerSearcher
        self.assetResolver = assetResolver
    }

    static func live(bundle: Bundle = .main) throws -> MediaCommandCoordinator {
        try MediaCommandCoordinator(
            offlineCatalog: NotoOfflineCatalog(
                resourceProvider: BundleNotoOfflineResourceProvider(
                    bundle: bundle
                )
            )
        )
    }

    func currentState() -> MediaCommandSearchState {
        state
    }

    func search(
        command: MediaCommandKind,
        query: String,
        bundleIdentifier: String?,
        networkOptions: MediaCommandNetworkOptions,
        limit: Int = 24
    ) async -> MediaCommandSearchState {
        activeTask?.cancel()

        let request = nextRequest(command: command)
        guard bundleIdentifier == MediaCommandParser.messagesBundleIdentifier else {
            activeRequest = nil
            let cancelled = MediaCommandSearchState.cancelled(request)
            state = cancelled
            return cancelled
        }

        let normalizedQuery = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard
            !normalizedQuery.isEmpty,
            normalizedQuery.count <= command.maximumQueryLength
        else {
            activeRequest = nil
            let failed = MediaCommandSearchState.failed(
                request,
                .invalidQuery
            )
            state = failed
            return failed
        }

        activeRequest = request
        state = .loading(request)

        let boundedLimit = min(max(limit, 1), 60)
        let operation = Task {
            await Self.performSearch(
                request: request,
                query: normalizedQuery,
                networkOptions: networkOptions,
                limit: boundedLimit,
                offlineCatalog: offlineCatalog,
                stickerSearcher: stickerSearcher
            )
        }
        activeTask = operation

        let result = await operation.value
        guard activeRequest == request else {
            return .cancelled(request)
        }
        activeTask = nil
        activeRequest = nil
        state = result
        return result
    }

    @discardableResult
    func cancel() -> MediaCommandSearchState {
        activeTask?.cancel()
        activeTask = nil
        guard let request = activeRequest else {
            state = .idle
            return state
        }
        activeRequest = nil
        state = .cancelled(request)
        return state
    }

    func resolve(_ result: MediaCommandResult) async throws -> MediaCommandDownload {
        try await assetResolver.resolve(result)
    }

    private func nextRequest(command: MediaCommandKind) -> MediaCommandRequest {
        requestCounter = requestCounter == .max ? 1 : requestCounter + 1
        return MediaCommandRequest(id: requestCounter, command: command)
    }

    private static func performSearch(
        request: MediaCommandRequest,
        query: String,
        networkOptions: MediaCommandNetworkOptions,
        limit: Int,
        offlineCatalog: NotoOfflineCatalog,
        stickerSearcher: (any MediaCommandStickerSearching)?
    ) async -> MediaCommandSearchState {
        await searchStickers(
            request: request,
            query: query,
            networkOptions: networkOptions,
            limit: limit,
            offlineCatalog: offlineCatalog,
            stickerSearcher: stickerSearcher
        )
    }

    private static func searchStickers(
        request: MediaCommandRequest,
        query: String,
        networkOptions: MediaCommandNetworkOptions,
        limit: Int,
        offlineCatalog: NotoOfflineCatalog,
        stickerSearcher: (any MediaCommandStickerSearching)?
    ) async -> MediaCommandSearchState {
        let offlineItems: [MediaCommandResult]
        do {
            offlineItems = try offlineCatalog.search(query, limit: limit)
        } catch {
            return state(for: error, request: request, fallback: [])
        }

        guard networkOptions.allowsNotoNetwork else {
            return completedState(
                request: request,
                items: offlineItems,
                isOffline: false
            )
        }
        guard let stickerSearcher else {
            return offlineItems.isEmpty
                ? .failed(request, .providerUnavailable)
                : completedState(
                    request: request,
                    items: offlineItems,
                    isOffline: true
                )
        }

        do {
            let remoteItems = try await stickerSearcher.search(
                query,
                limit: limit
            )
            try Task.checkCancellation()
            let remoteResults = remoteItems.map {
                MediaCommandResult(media: $0, origin: .remote)
            }
            return completedState(
                request: request,
                items: merge(offlineItems, remoteResults, limit: limit),
                isOffline: false
            )
        } catch {
            return state(
                for: error,
                request: request,
                fallback: offlineItems
            )
        }
    }

    private static func completedState(
        request: MediaCommandRequest,
        items: [MediaCommandResult],
        isOffline: Bool
    ) -> MediaCommandSearchState {
        guard !items.isEmpty else {
            return isOffline
                ? .offline(makeResults(request: request, items: []))
                : .empty(request)
        }
        let results = makeResults(request: request, items: items)
        return isOffline ? .offline(results) : .results(results)
    }

    private static func state(
        for error: Error,
        request: MediaCommandRequest,
        fallback: [MediaCommandResult]
    ) -> MediaCommandSearchState {
        if error is CancellationError || isCancellation(error) {
            return .cancelled(request)
        }
        if isOffline(error) {
            return .offline(
                makeResults(request: request, items: fallback)
            )
        }
        if let error = error as? RemoteMediaError {
            switch error {
            case .emptyQuery, .queryTooLong:
                return .failed(request, .invalidQuery)
            case .statusCode(429):
                return .rateLimited(request)
            case .unsupportedContentType, .unsafeImage:
                return .failed(request, .unsupportedMedia)
            case .invalidResponse, .insecureURL,
                 .responseTooLarge, .statusCode:
                return .failed(request, .invalidProviderResponse)
            }
        }
        return .failed(request, .providerUnavailable)
    }

    private static func makeResults(
        request: MediaCommandRequest,
        items: [MediaCommandResult]
    ) -> MediaCommandResults {
        var attributions: [MediaCommandAttribution] = []
        if items.contains(where: { $0.media.provider == .notoAnimatedEmoji }) {
            attributions.append(.notoAnimatedEmoji)
        }
        return MediaCommandResults(
            request: request,
            items: items,
            attributions: attributions
        )
    }

    private static func merge(
        _ bundled: [MediaCommandResult],
        _ remote: [MediaCommandResult],
        limit: Int
    ) -> [MediaCommandResult] {
        var seenIDs = Set<String>()
        return (bundled + remote).filter {
            seenIDs.insert($0.id).inserted
        }.prefix(limit).map { $0 }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSURLErrorDomain &&
            error.code == URLError.cancelled.rawValue
    }

    private static func isOffline(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else {
            return false
        }
        let offlineCodes: Set<Int> = [
            URLError.notConnectedToInternet.rawValue,
            URLError.networkConnectionLost.rawValue,
            URLError.cannotFindHost.rawValue,
            URLError.cannotConnectToHost.rawValue,
            URLError.dnsLookupFailed.rawValue,
            URLError.timedOut.rawValue
        ]
        return offlineCodes.contains(error.code)
    }
}
