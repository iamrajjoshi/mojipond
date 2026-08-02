import Foundation

enum EmojiSearchMatchKind: Int, Codable, Comparable, Sendable {
    case exactShortcode
    case exactAlias
    case shortcodePrefix
    case aliasPrefix
    case namePrefix
    case keyword
    case substring
    case fuzzy
    case browse

    static func < (lhs: EmojiSearchMatchKind, rhs: EmojiSearchMatchKind) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct EmojiSearchResult: Equatable, Sendable {
    let item: EmojiItem
    let matchKind: EmojiSearchMatchKind
    let matchedTerm: String
    /// A lower value is a tighter match within the same match kind.
    let matchDistance: Int
}

/// An immutable local index. Replacing the value rebuilds the index
/// deterministically, making it safe to hand across the serial coordinator.
struct EmojiSearchIndex: Sendable {
    private let entries: [IndexedEntry]

    var count: Int {
        entries.count
    }

    func exactTokens(
        usage: EmojiUsageSnapshot = EmojiUsageSnapshot()
    ) -> Set<String> {
        var tokens = Set<String>()
        for entry in entries {
            tokens.insert(entry.shortcode.normalized)
            tokens.formUnion(entry.aliases.map(\.normalized))
            let customAliases =
                usage.customAliasesByItemID[entry.item.id, default: []]
            tokens.formUnion(
                customAliases
                    .filter(EmojiAliasSyntax.isValidToken)
                    .map(EmojiAliasSyntax.normalizedToken)
            )
        }
        return tokens
    }

    init(items: [EmojiItem]) {
        entries = items
            .map(IndexedEntry.init)
            .sorted {
                if $0.item.id != $1.item.id {
                    return $0.item.id < $1.item.id
                }
                if $0.item.shortcode != $1.item.shortcode {
                    return $0.item.shortcode < $1.item.shortcode
                }
                if $0.item.packPriority != $1.item.packPriority {
                    return $0.item.packPriority > $1.item.packPriority
                }
                return $0.item.packID < $1.item.packID
            }
    }

    init(packs: [EmojiCatalogPack]) {
        let items = packs
            .filter(\.isEnabled)
            .flatMap { pack in
                pack.items.map { item in
                    var item = item
                    item.packPriority = pack.priority
                    return item
                }
            }
        self.init(items: items)
    }

    func search(
        _ query: String,
        usage: EmojiUsageSnapshot = EmojiUsageSnapshot(),
        limit: Int = 10
    ) -> [EmojiSearchResult] {
        guard limit > 0 else {
            return []
        }

        let normalizedQuery = SearchNormalizer.normalize(query)
        let results = entries.compactMap { entry -> EmojiSearchResult? in
            if normalizedQuery.isEmpty {
                return EmojiSearchResult(
                    item: entry.item,
                    matchKind: .browse,
                    matchedTerm: entry.item.shortcode.rawValue,
                    matchDistance: 0
                )
            }

            let customAliases = usage.customAliasesByItemID[entry.item.id, default: []]
                .map(SearchNormalizer.normalize)
            guard let match = entry.bestMatch(
                query: normalizedQuery,
                customAliases: customAliases
            ) else {
                return nil
            }
            return EmojiSearchResult(
                item: entry.item,
                matchKind: match.kind,
                matchedTerm: match.originalTerm,
                matchDistance: match.distance
            )
        }

        return results
            .sorted { lhs, rhs in
                Self.isOrderedBefore(lhs, rhs, usage: usage)
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Resolves only a full canonical shortcode or alias. Prefixes and fuzzy
    /// candidates are deliberately excluded so closing-trigger replacement can
    /// never auto-fire a prefix.
    func exactMatch(
        for shortcode: String,
        usage: EmojiUsageSnapshot = EmojiUsageSnapshot()
    ) -> EmojiSearchResult? {
        let query = SearchNormalizer.normalize(shortcode)
        guard !query.isEmpty else {
            return nil
        }

        return search(query, usage: usage, limit: entries.count)
            .first { $0.matchKind == .exactShortcode || $0.matchKind == .exactAlias }
    }

    private static func isOrderedBefore(
        _ lhs: EmojiSearchResult,
        _ rhs: EmojiSearchResult,
        usage: EmojiUsageSnapshot
    ) -> Bool {
        let lhsIsExact = lhs.matchKind == .exactShortcode
            || lhs.matchKind == .exactAlias
        let rhsIsExact = rhs.matchKind == .exactShortcode
            || rhs.matchKind == .exactAlias
        if
            (lhsIsExact || rhsIsExact),
            lhs.matchKind != rhs.matchKind
        {
            return lhs.matchKind < rhs.matchKind
        }

        let lhsFavorite = usage.isFavorite(lhs.item.id)
        let rhsFavorite = usage.isFavorite(rhs.item.id)
        if lhsFavorite != rhsFavorite {
            return lhsFavorite
        }

        let lhsStatistics = usage.statistics(for: lhs.item.id)
        let rhsStatistics = usage.statistics(for: rhs.item.id)
        if lhsStatistics.lastUsedAt != rhsStatistics.lastUsedAt {
            return (lhsStatistics.lastUsedAt ?? .distantPast)
                > (rhsStatistics.lastUsedAt ?? .distantPast)
        }
        if lhsStatistics.useCount != rhsStatistics.useCount {
            return lhsStatistics.useCount > rhsStatistics.useCount
        }
        if lhs.matchKind != rhs.matchKind {
            return lhs.matchKind < rhs.matchKind
        }
        if lhs.matchDistance != rhs.matchDistance {
            return lhs.matchDistance < rhs.matchDistance
        }
        if lhs.item.packPriority != rhs.item.packPriority {
            return lhs.item.packPriority > rhs.item.packPriority
        }

        let lhsOrder = lhs.item.order ?? .max
        let rhsOrder = rhs.item.order ?? .max
        if lhsOrder != rhsOrder {
            return lhsOrder < rhsOrder
        }
        if lhs.item.shortcode != rhs.item.shortcode {
            return lhs.item.shortcode < rhs.item.shortcode
        }
        if lhs.item.packID != rhs.item.packID {
            return lhs.item.packID < rhs.item.packID
        }
        return lhs.item.id < rhs.item.id
    }
}

private struct IndexedEntry: Sendable {
    let item: EmojiItem
    let shortcode: IndexedTerm
    let aliases: [IndexedTerm]
    let name: IndexedTerm
    let keywords: [IndexedTerm]

    init(_ item: EmojiItem) {
        self.item = item
        shortcode = IndexedTerm(original: item.shortcode.rawValue)
        aliases = item.aliases.map(IndexedTerm.init)
        name = IndexedTerm(original: item.name)
        keywords = item.keywords.map(IndexedTerm.init)
    }

    func bestMatch(query: String, customAliases: [String]) -> SearchMatch? {
        let allAliases = aliases + customAliases.map(IndexedTerm.init)
        var candidates: [SearchMatch] = []

        if shortcode.normalized == query {
            candidates.append(.init(kind: .exactShortcode, term: shortcode, distance: 0))
        }
        candidates.append(contentsOf: allAliases.compactMap { term -> SearchMatch? in
            guard term.normalized == query else {
                return nil
            }
            return SearchMatch(kind: .exactAlias, term: term, distance: 0)
        })

        if shortcode.normalized.hasPrefix(query), shortcode.normalized != query {
            candidates.append(
                .init(
                    kind: .shortcodePrefix,
                    term: shortcode,
                    distance: shortcode.normalized.count - query.count
                )
            )
        }
        candidates.append(contentsOf: allAliases.compactMap { term in
            guard term.normalized.hasPrefix(query), term.normalized != query else {
                return nil
            }
            return .init(
                kind: .aliasPrefix,
                term: term,
                distance: term.normalized.count - query.count
            )
        })
        if name.normalized.hasPrefix(query) {
            candidates.append(
                .init(
                    kind: .namePrefix,
                    term: name,
                    distance: name.normalized.count - query.count
                )
            )
        }
        candidates.append(contentsOf: keywords.compactMap { term in
            guard term.normalized == query || term.normalized.hasPrefix(query) else {
                return nil
            }
            return .init(
                kind: .keyword,
                term: term,
                distance: term.normalized.count - query.count
            )
        })

        let searchableTerms = [shortcode] + allAliases + [name] + keywords
        candidates.append(contentsOf: searchableTerms.compactMap { term in
            guard term.normalized != query,
                  !term.normalized.hasPrefix(query),
                  let range = term.normalized.range(of: query) else {
                return nil
            }
            let leadingDistance = term.normalized.distance(
                from: term.normalized.startIndex,
                to: range.lowerBound
            )
            return .init(
                kind: .substring,
                term: term,
                distance: leadingDistance + term.normalized.count - query.count
            )
        })
        candidates.append(contentsOf: searchableTerms.compactMap { term in
            guard let distance = FuzzyMatcher.distance(
                query: query,
                candidate: term.normalized
            ) else {
                return nil
            }
            return .init(kind: .fuzzy, term: term, distance: distance)
        })

        return candidates.min()
    }
}

private struct IndexedTerm: Equatable, Sendable {
    let original: String
    let normalized: String

    init(original: String) {
        self.original = original
        normalized = SearchNormalizer.normalize(original)
    }
}

private struct SearchMatch: Comparable, Sendable {
    let kind: EmojiSearchMatchKind
    let term: IndexedTerm
    let distance: Int

    var originalTerm: String {
        term.original
    }

    static func < (lhs: SearchMatch, rhs: SearchMatch) -> Bool {
        if lhs.kind != rhs.kind {
            return lhs.kind < rhs.kind
        }
        if lhs.distance != rhs.distance {
            return lhs.distance < rhs.distance
        }
        return lhs.term.normalized < rhs.term.normalized
    }
}

private enum SearchNormalizer {
    static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}

private enum FuzzyMatcher {
    static func distance(query: String, candidate: String) -> Int? {
        let queryScalars = Array(query.unicodeScalars)
        let candidateScalars = Array(candidate.unicodeScalars)
        guard !queryScalars.isEmpty, queryScalars.count <= candidateScalars.count else {
            return nil
        }

        var queryIndex = 0
        var firstMatch: Int?
        var lastMatch: Int?
        var internalGaps = 0

        for (candidateIndex, scalar) in candidateScalars.enumerated()
        where queryIndex < queryScalars.count && scalar == queryScalars[queryIndex] {
            if firstMatch == nil {
                firstMatch = candidateIndex
            }
            if let lastMatch {
                internalGaps += candidateIndex - lastMatch - 1
            }
            lastMatch = candidateIndex
            queryIndex += 1
        }

        guard queryIndex == queryScalars.count, let firstMatch, let lastMatch else {
            return nil
        }
        let trailing = candidateScalars.count - lastMatch - 1
        return firstMatch + internalGaps * 2 + trailing
    }
}
