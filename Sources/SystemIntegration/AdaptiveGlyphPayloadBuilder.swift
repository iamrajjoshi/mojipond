import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum AdaptiveGlyphPayloadError: Error, Equatable {
    case emptyInput
    case inputTooLarge(limit: Int)
    case unsupportedSourceType
    case animatedSource
    case invalidMetadata
    case imageDecodeFailed
    case imageEncodingFailed
    case encodedImageTooLarge(limit: Int)
    case systemRejectedImage
    case richTextSerializationFailed
    case richTextTooLarge(limit: Int)
}

enum AdaptiveGlyphFramePolicy: Hashable, Sendable {
    case requireSingleFrame
    case firstFrame
}

/// Builds the rich pasteboard representation that Messages uses for an
/// inline custom image glyph. The public AppKit type is available on macOS 15,
/// while the app keeps its macOS 14 image-attachment fallback.
///
/// The minimal accepted HEIC metadata layout and the defensive Objective-C
/// initializer path were cross-checked against AdaptiveGlyphKit. See the
/// bundled third-party notices for its MIT attribution.
enum AdaptiveGlyphPayloadBuilder {
    static let maximumInputBytes = 25 * 1_024 * 1_024
    static let maximumPixelDimension = 512
    static let maximumEncodedBytes = 1 * 1_024 * 1_024
    static let maximumRichTextBytes = 2 * 1_024 * 1_024

    static func payloadIfSupported(
        sourceData: Data,
        sourceType: UTType,
        contentIdentifier: String,
        accessibilityDescription: String,
        plainTextFallback: String,
        framePolicy: AdaptiveGlyphFramePolicy = .requireSingleFrame
    ) -> PasteboardItemPayload? {
        guard #available(macOS 15.0, *) else {
            return nil
        }
        return try? buildPayload(
            sourceData: sourceData,
            sourceType: sourceType,
            contentIdentifier: contentIdentifier,
            accessibilityDescription: accessibilityDescription,
            plainTextFallback: plainTextFallback,
            framePolicy: framePolicy
        )
    }

    @available(macOS 15.0, *)
    static func buildPayload(
        sourceData: Data,
        sourceType: UTType,
        contentIdentifier: String,
        accessibilityDescription: String,
        plainTextFallback: String,
        framePolicy: AdaptiveGlyphFramePolicy = .requireSingleFrame
    ) throws -> PasteboardItemPayload {
        guard !sourceData.isEmpty else {
            throw AdaptiveGlyphPayloadError.emptyInput
        }
        guard sourceData.count <= maximumInputBytes else {
            throw AdaptiveGlyphPayloadError.inputTooLarge(
                limit: maximumInputBytes
            )
        }
        guard supportedSourceTypes.contains(sourceType) else {
            throw AdaptiveGlyphPayloadError.unsupportedSourceType
        }
        guard
            isValidMetadata(contentIdentifier),
            isValidMetadata(accessibilityDescription),
            isValidFallback(plainTextFallback)
        else {
            throw AdaptiveGlyphPayloadError.invalidMetadata
        }

        let image = try decodeImage(
            sourceData,
            expectedType: sourceType,
            framePolicy: framePolicy
        )
        let encodedImage = try encodeImage(
            image,
            contentIdentifier: contentIdentifier,
            accessibilityDescription: accessibilityDescription
        )
        let glyph = try makeGlyph(
            encodedImage,
            expectedIdentifier: contentIdentifier,
            expectedDescription: accessibilityDescription
        )
        let attributed = NSAttributedString(
            adaptiveImageGlyph: glyph,
            attributes: [:]
        )
        guard
            let richText = attributed.pasteboardPropertyList(
                forType: .rtfd
            ) as? Data,
            !richText.isEmpty
        else {
            throw AdaptiveGlyphPayloadError.richTextSerializationFailed
        }
        guard richText.count <= maximumRichTextBytes else {
            throw AdaptiveGlyphPayloadError.richTextTooLarge(
                limit: maximumRichTextBytes
            )
        }

        // Do not advertise raw PNG/TIFF on this item. Messages may classify
        // those types as a photo before considering the adaptive glyph.
        // RTFD already carries Apple's backwards-compatible image fallback.
        return PasteboardItemPayload(
            representations: [
                PasteboardRepresentation(
                    typeIdentifier:
                        NSPasteboard.PasteboardType.rtfd.rawValue,
                    data: richText
                ),
                PasteboardRepresentation(
                    typeIdentifier:
                        NSPasteboard.PasteboardType.string.rawValue,
                    data: Data(plainTextFallback.utf8)
                )
            ]
        )
    }

    private static let supportedSourceTypes: Set<UTType> = [
        .png,
        .jpeg,
        .gif,
        .webP
    ]

    private static func isValidMetadata(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 255
            && !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func isValidFallback(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 255
            && !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func decodeImage(
        _ data: Data,
        expectedType: UTType,
        framePolicy: AdaptiveGlyphFramePolicy
    ) throws -> CGImage {
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ),
            CGImageSourceGetStatus(source) == .statusComplete,
            let detectedIdentifier = CGImageSourceGetType(source),
            let detectedType = UTType(detectedIdentifier as String),
            detectedType.conforms(to: expectedType),
            CGImageSourceGetCount(source) > 0
        else {
            throw AdaptiveGlyphPayloadError.imageDecodeFailed
        }
        guard
            framePolicy == .firstFrame
                || CGImageSourceGetCount(source) == 1
        else {
            throw AdaptiveGlyphPayloadError.animatedSource
        }
        // Adaptive image glyphs are static. The explicit first-frame policy
        // decodes index zero while leaving the original animation unchanged.
        guard
            let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize:
                        maximumPixelDimension,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary
            ),
            image.width > 0,
            image.height > 0
        else {
            throw AdaptiveGlyphPayloadError.imageDecodeFailed
        }
        // Preserve ImageIO's decoded representation and aspect ratio. Drawing
        // every asset into a fresh square CGContext made macOS route HEIC
        // encoding through a path that can stall for tens of seconds.
        return image
    }

    @available(macOS 15.0, *)
    private static func encodeImage(
        _ image: CGImage,
        contentIdentifier: String,
        accessibilityDescription: String
    ) throws -> Data {
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output,
                UTType.heic.identifier as CFString,
                1,
                nil
            )
        else {
            throw AdaptiveGlyphPayloadError.imageEncodingFailed
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFDocumentName: contentIdentifier,
                kCGImagePropertyTIFFImageDescription:
                    accessibilityDescription
            ],
            kCGImageDestinationLossyCompressionQuality: 1.0
        ]
        CGImageDestinationAddImage(
            destination,
            image,
            properties as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw AdaptiveGlyphPayloadError.imageEncodingFailed
        }

        let data = output as Data
        guard data.count <= maximumEncodedBytes else {
            throw AdaptiveGlyphPayloadError.encodedImageTooLarge(
                limit: maximumEncodedBytes
            )
        }
        return data
    }

    @available(macOS 15.0, *)
    static func makeGlyph(
        _ imageContent: Data,
        expectedIdentifier: String,
        expectedDescription: String
    ) throws -> NSAdaptiveImageGlyph {
        guard
            let allocated = NSAdaptiveImageGlyph.perform(
                NSSelectorFromString("alloc")
            ),
            let initialized = allocated.takeUnretainedValue().perform(
                NSSelectorFromString("initWithImageContent:"),
                with: imageContent as NSData
            ),
            let glyph =
                initialized.takeRetainedValue()
                    as? NSAdaptiveImageGlyph,
            glyph.contentIdentifier == expectedIdentifier,
            glyph.contentDescription == expectedDescription
        else {
            throw AdaptiveGlyphPayloadError.systemRejectedImage
        }
        return glyph
    }

    static func makeEncoderPrewarmPNG() -> Data? {
        let side = 128
        let colorSpace =
            CGColorSpace(name: CGColorSpace.sRGB)
                ?? CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: nil,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: colorSpace,
                bitmapInfo:
                    CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
            )
        else {
            return nil
        }
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(
            red: 0.12,
            green: 0.55,
            blue: 0.45,
            alpha: 0.85
        )
        context.fill(
            CGRect(
                x: 12,
                y: 12,
                width: side - 24,
                height: side - 24
            )
        )
        context.setFillColor(
            red: 0.78,
            green: 0.95,
            blue: 0.74,
            alpha: 1
        )
        context.fill(CGRect(x: 32, y: 32, width: 64, height: 64))
        guard let image = context.makeImage() else {
            return nil
        }

        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return output as Data
    }
}

struct AdaptiveGlyphPayloadCacheKey: Hashable, Sendable {
    private static let currentSchemaVersion = 2

    private let schemaVersion: Int
    private let sourceTypeIdentifier: String
    private let contentIdentifier: String
    private let accessibilityDescription: String
    private let plainTextFallback: String
    private let framePolicy: AdaptiveGlyphFramePolicy

    init(
        sourceType: UTType,
        contentIdentifier: String,
        accessibilityDescription: String,
        plainTextFallback: String,
        framePolicy: AdaptiveGlyphFramePolicy = .requireSingleFrame
    ) {
        schemaVersion = Self.currentSchemaVersion
        sourceTypeIdentifier = sourceType.identifier
        self.contentIdentifier = contentIdentifier
        self.accessibilityDescription = accessibilityDescription
        self.plainTextFallback = plainTextFallback
        self.framePolicy = framePolicy
    }
}

struct AdaptiveGlyphPayloadCache {
    private struct Entry {
        let payload: PasteboardItemPayload
        let cost: Int
    }

    static let defaultCountLimit = 64
    static let defaultByteLimit = 8 * 1_024 * 1_024

    private let countLimit: Int
    private let byteLimit: Int
    private var entries: [AdaptiveGlyphPayloadCacheKey: Entry] = [:]
    private var keysByRecency: [AdaptiveGlyphPayloadCacheKey] = []
    private var totalCost = 0

    init(
        countLimit: Int = defaultCountLimit,
        byteLimit: Int = defaultByteLimit
    ) {
        self.countLimit = max(0, countLimit)
        self.byteLimit = max(0, byteLimit)
    }

    mutating func payload(
        for key: AdaptiveGlyphPayloadCacheKey,
        build: () -> PasteboardItemPayload?
    ) -> PasteboardItemPayload? {
        if let entry = entries[key] {
            markMostRecent(key)
            return entry.payload
        }

        guard let payload = build() else {
            return nil
        }
        let cost = payload.representations.reduce(into: 0) {
            $0 += $1.data.count
        }
        guard
            countLimit > 0,
            cost <= byteLimit
        else {
            return payload
        }

        while
            entries.count >= countLimit
                || totalCost + cost > byteLimit
        {
            evictLeastRecent()
        }
        entries[key] = Entry(payload: payload, cost: cost)
        keysByRecency.append(key)
        totalCost += cost
        return payload
    }

    private mutating func markMostRecent(
        _ key: AdaptiveGlyphPayloadCacheKey
    ) {
        keysByRecency.removeAll { $0 == key }
        keysByRecency.append(key)
    }

    private mutating func evictLeastRecent() {
        guard !keysByRecency.isEmpty else {
            return
        }
        let key = keysByRecency.removeFirst()
        guard let entry = entries.removeValue(forKey: key) else {
            return
        }
        totalCost -= entry.cost
    }
}

struct AdaptiveGlyphPayloadRequest: Sendable {
    let sourceData: Data
    let sourceType: UTType
    let contentIdentifier: String
    let accessibilityDescription: String
    let plainTextFallback: String
    let framePolicy: AdaptiveGlyphFramePolicy

    init(
        sourceData: Data,
        sourceType: UTType,
        contentIdentifier: String,
        accessibilityDescription: String,
        plainTextFallback: String,
        framePolicy: AdaptiveGlyphFramePolicy = .requireSingleFrame
    ) {
        self.sourceData = sourceData
        self.sourceType = sourceType
        self.contentIdentifier = contentIdentifier
        self.accessibilityDescription = accessibilityDescription
        self.plainTextFallback = plainTextFallback
        self.framePolicy = framePolicy
    }

    var cacheKey: AdaptiveGlyphPayloadCacheKey {
        AdaptiveGlyphPayloadCacheKey(
            sourceType: sourceType,
            contentIdentifier: contentIdentifier,
            accessibilityDescription: accessibilityDescription,
            plainTextFallback: plainTextFallback,
            framePolicy: framePolicy
        )
    }
}

final class AdaptiveGlyphPayloadService: @unchecked Sendable {
    typealias Builder = @Sendable (
        AdaptiveGlyphPayloadRequest
    ) -> PasteboardItemPayload?
    typealias Loader = @Sendable () -> AdaptiveGlyphPayloadRequest?
    typealias PayloadCompletion =
        @Sendable (PasteboardItemPayload?) -> Void
    typealias PreparationCompletion = @Sendable () -> Void

    private enum WorkLane {
        case explicit
        case preparation
    }

    private struct ExplicitWork {
        let request: AdaptiveGlyphPayloadRequest
        let arrivalSequence: UInt64
    }

    private struct InFlightRequest {
        var lane: WorkLane
        var payloadCompletions: [PayloadCompletion]
        var preparationCompletions: [PreparationCompletion]
        var explicitRetryWork: ExplicitWork?
    }

    private struct PendingExplicit {
        let key: AdaptiveGlyphPayloadCacheKey
        let work: ExplicitWork
    }

    private struct PendingPreparation {
        let key: AdaptiveGlyphPayloadCacheKey
        let loader: Loader
        var completions: [PreparationCompletion]
    }

    static let shared = AdaptiveGlyphPayloadService()

    private let coordinationQueue: DispatchQueue
    private let explicitQueue: DispatchQueue
    private let preparationQueue: DispatchQueue
    private let builder: Builder
    private var cache: AdaptiveGlyphPayloadCache
    private var inFlightRequests:
        [AdaptiveGlyphPayloadCacheKey: InFlightRequest] = [:]
    private var runningExplicitKey: AdaptiveGlyphPayloadCacheKey?
    private var pendingExplicit: PendingExplicit?
    private var nextExplicitArrivalSequence: UInt64 = 0
    private var preparationIsRunning = false
    private var pendingPreparation: PendingPreparation?

    init(
        countLimit: Int = AdaptiveGlyphPayloadCache.defaultCountLimit,
        byteLimit: Int = AdaptiveGlyphPayloadCache.defaultByteLimit,
        queueLabel: String = "com.rajjoshi.MojiPond.adaptive-glyph-forge",
        builder: @escaping Builder = { request in
            AdaptiveGlyphPayloadBuilder.payloadIfSupported(
                sourceData: request.sourceData,
                sourceType: request.sourceType,
                contentIdentifier: request.contentIdentifier,
                accessibilityDescription:
                    request.accessibilityDescription,
                plainTextFallback: request.plainTextFallback,
                framePolicy: request.framePolicy
            )
        }
    ) {
        cache = AdaptiveGlyphPayloadCache(
            countLimit: countLimit,
            byteLimit: byteLimit
        )
        coordinationQueue = DispatchQueue(
            label: "\(queueLabel).coordination",
            qos: .userInitiated
        )
        explicitQueue = DispatchQueue(
            label: "\(queueLabel).explicit",
            qos: .userInitiated
        )
        preparationQueue = DispatchQueue(
            label: "\(queueLabel).preparation",
            qos: .utility
        )
        self.builder = builder
    }

    func payload(
        for request: AdaptiveGlyphPayloadRequest,
        completion: @escaping PayloadCompletion
    ) {
        coordinationQueue.async { [self] in
            let key = request.cacheKey
            let explicitWork = makeExplicitWork(request)
            refreshOrDiscardPendingExplicit(
                with: explicitWork,
                for: key
            )
            if let payload = cachedPayload(for: key) {
                completion(payload)
                return
            }
            if var inFlight = inFlightRequests[key] {
                inFlight.payloadCompletions.append(completion)
                if case .preparation = inFlight.lane {
                    inFlight.explicitRetryWork = explicitWork
                } else if pendingExplicit?.key == key {
                    pendingExplicit = PendingExplicit(
                        key: key,
                        work: explicitWork
                    )
                } else if runningExplicitKey == key {
                    // This new call is now the newest actual request and can
                    // share the running build. Any different-key pending work
                    // predates it and must not start afterward.
                    discardPendingExplicit()
                }
                inFlightRequests[key] = inFlight
                return
            }

            var preparationCompletions: [PreparationCompletion] = []
            if pendingPreparation?.key == key {
                preparationCompletions =
                    pendingPreparation?.completions ?? []
                pendingPreparation = nil
            }
            inFlightRequests[key] = InFlightRequest(
                lane: .explicit,
                payloadCompletions: [completion],
                preparationCompletions: preparationCompletions,
                explicitRetryWork: nil
            )
            scheduleExplicit(explicitWork, for: key)
        }
    }

    func prepare(
        _ request: AdaptiveGlyphPayloadRequest,
        completion: @escaping PreparationCompletion = {}
    ) {
        prepare(
            for: request.cacheKey,
            loader: { request },
            completion: completion
        )
    }

    /// Schedules speculative work without requiring the caller to load or
    /// retain source bytes. At most one not-yet-started preparation is kept;
    /// newer work replaces older pending work.
    func prepare(
        for key: AdaptiveGlyphPayloadCacheKey,
        loader: @escaping Loader,
        completion: @escaping PreparationCompletion = {}
    ) {
        coordinationQueue.async { [self] in
            if cachedPayload(for: key) != nil {
                completion()
                return
            }
            if var inFlight = inFlightRequests[key] {
                inFlight.preparationCompletions.append(completion)
                inFlightRequests[key] = inFlight
                return
            }

            let preparation = PendingPreparation(
                key: key,
                loader: loader,
                completions: [completion]
            )
            guard preparationIsRunning else {
                start(preparation)
                return
            }

            if var pendingPreparation {
                if pendingPreparation.key == key {
                    pendingPreparation.completions.append(completion)
                    self.pendingPreparation = pendingPreparation
                } else {
                    self.pendingPreparation = preparation
                    for completion in pendingPreparation.completions {
                        completion()
                    }
                }
            } else {
                pendingPreparation = preparation
            }
        }
    }

    func prewarmEncoder() {
        guard #available(macOS 15.0, *) else {
            return
        }
        let contentIdentifier = "mojipond:encoder-prewarm:1"
        let accessibilityDescription = "MojiPond emoji"
        let plainTextFallback = ":mojipond:"
        let key = AdaptiveGlyphPayloadCacheKey(
            sourceType: .png,
            contentIdentifier: contentIdentifier,
            accessibilityDescription: accessibilityDescription,
            plainTextFallback: plainTextFallback
        )
        prepare(for: key) {
            guard
                let sourceData =
                    AdaptiveGlyphPayloadBuilder.makeEncoderPrewarmPNG()
            else {
                return nil
            }
            return AdaptiveGlyphPayloadRequest(
                sourceData: sourceData,
                sourceType: .png,
                contentIdentifier: contentIdentifier,
                accessibilityDescription: accessibilityDescription,
                plainTextFallback: plainTextFallback
            )
        }
    }

    private func cachedPayload(
        for key: AdaptiveGlyphPayloadCacheKey
    ) -> PasteboardItemPayload? {
        cache.payload(for: key) {
            nil
        }
    }

    private func start(_ preparation: PendingPreparation) {
        preparationIsRunning = true
        inFlightRequests[preparation.key] = InFlightRequest(
            lane: .preparation,
            payloadCompletions: [],
            preparationCompletions: preparation.completions,
            explicitRetryWork: nil
        )
        preparationQueue.async { [self] in
            let request = preparation.loader()
            let payload: PasteboardItemPayload?
            if
                let request,
                request.cacheKey == preparation.key
            {
                payload = builder(request)
            } else {
                payload = nil
            }
            coordinationQueue.async { [self] in
                finish(
                    key: preparation.key,
                    payload: payload,
                    lane: .preparation
                )
            }
        }
    }

    private func refreshOrDiscardPendingExplicit(
        with work: ExplicitWork,
        for key: AdaptiveGlyphPayloadCacheKey
    ) {
        guard let pendingExplicit else {
            return
        }
        guard pendingExplicit.key != key else {
            self.pendingExplicit = PendingExplicit(
                key: key,
                work: work
            )
            return
        }
        guard
            work.arrivalSequence >
                pendingExplicit.work.arrivalSequence
        else {
            return
        }
        discardPendingExplicit()
    }

    private func scheduleExplicit(
        _ work: ExplicitWork,
        for key: AdaptiveGlyphPayloadCacheKey
    ) {
        guard runningExplicitKey != nil else {
            startExplicit(work, for: key)
            return
        }

        guard let pendingExplicit else {
            self.pendingExplicit = PendingExplicit(
                key: key,
                work: work
            )
            return
        }

        if work.arrivalSequence > pendingExplicit.work.arrivalSequence {
            discardPendingExplicit()
            self.pendingExplicit = PendingExplicit(
                key: key,
                work: work
            )
        } else {
            let discardedInFlight = inFlightRequests.removeValue(
                forKey: key
            )
            if let discardedInFlight {
                completeDiscardedExplicit(discardedInFlight)
            }
        }
    }

    private func discardPendingExplicit() {
        guard let pendingExplicit else {
            return
        }
        self.pendingExplicit = nil
        guard
            let discardedInFlight = inFlightRequests.removeValue(
                forKey: pendingExplicit.key
            )
        else {
            return
        }
        completeDiscardedExplicit(discardedInFlight)
    }

    private func startExplicit(
        _ work: ExplicitWork,
        for key: AdaptiveGlyphPayloadCacheKey
    ) {
        runningExplicitKey = key
        explicitQueue.async { [self] in
            let payload = builder(work.request)
            coordinationQueue.async { [self] in
                finish(
                    key: key,
                    payload: payload,
                    lane: .explicit
                )
            }
        }
    }

    private func finish(
        key: AdaptiveGlyphPayloadCacheKey,
        payload: PasteboardItemPayload?,
        lane: WorkLane
    ) {
        guard var inFlight = inFlightRequests.removeValue(forKey: key) else {
            return
        }

        if
            case .preparation = lane,
            payload == nil,
            let explicitRetryWork = inFlight.explicitRetryWork
        {
            preparationIsRunning = false
            inFlight.lane = .explicit
            inFlight.explicitRetryWork = nil
            inFlightRequests[key] = inFlight
            scheduleExplicit(explicitRetryWork, for: key)
            startPendingPreparationIfNeeded()
            return
        }

        let resolvedPayload: PasteboardItemPayload?
        if let payload {
            resolvedPayload = cache.payload(for: key) {
                payload
            }
        } else {
            resolvedPayload = nil
        }

        switch lane {
        case .explicit:
            runningExplicitKey = nil
            startPendingExplicitIfNeeded()
        case .preparation:
            preparationIsRunning = false
            startPendingPreparationIfNeeded()
        }

        for completion in inFlight.payloadCompletions {
            completion(resolvedPayload)
        }
        for completion in inFlight.preparationCompletions {
            completion()
        }
    }

    private func startPendingExplicitIfNeeded() {
        guard let pendingExplicit else {
            return
        }
        self.pendingExplicit = nil
        startExplicit(
            pendingExplicit.work,
            for: pendingExplicit.key
        )
    }

    private func startPendingPreparationIfNeeded() {
        guard let pendingPreparation else {
            return
        }
        self.pendingPreparation = nil
        start(pendingPreparation)
    }

    private func completeDiscardedExplicit(
        _ inFlight: InFlightRequest
    ) {
        for completion in inFlight.payloadCompletions {
            completion(nil)
        }
        for completion in inFlight.preparationCompletions {
            completion()
        }
    }

    private func makeExplicitWork(
        _ request: AdaptiveGlyphPayloadRequest
    ) -> ExplicitWork {
        defer {
            nextExplicitArrivalSequence &+= 1
        }
        return ExplicitWork(
            request: request,
            arrivalSequence: nextExplicitArrivalSequence
        )
    }
}
