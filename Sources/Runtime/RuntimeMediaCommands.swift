enum RuntimeMediaInsertionSource: Equatable, Sendable {
    case customEmoji(shortcode: String)
}

enum RuntimeMediaCopyFallbackReason: Equatable, Sendable {
    case notMessages
    case managedLibraryUnavailable
    case invalidManagedAsset
    case animatedWebPExperimental
    case insertionFailed(InsertionFailureReason)
}

struct RuntimeMediaCopyFallbackDiagnostic: Equatable, Sendable {
    let source: RuntimeMediaInsertionSource
    let reason: RuntimeMediaCopyFallbackReason
    let payload: PasteboardItemPayload?

    init(
        source: RuntimeMediaInsertionSource,
        reason: RuntimeMediaCopyFallbackReason,
        payload: PasteboardItemPayload? = nil
    ) {
        self.source = source
        self.reason = reason
        self.payload = payload
    }
}
