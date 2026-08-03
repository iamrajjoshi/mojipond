import Foundation

enum EmojiSearchMatchKind: Int, Codable, Comparable, Sendable {
    case exactShortcode
    case exactAlias
    case separatorEquivalent
    case tokenExact
    case tokenPrefix
    case allTokens
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
    fileprivate let matchField: EmojiSearchMatchField
}

fileprivate enum EmojiSearchMatchField: Int, Comparable, Sendable {
    case shortcode
    case alias
    case name
    case keyword

    static func < (
        lhs: EmojiSearchMatchField,
        rhs: EmojiSearchMatchField
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
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

        let normalizedQuery = SearchQuery(query)
        if normalizedQuery.isEmpty {
            return entries.map { entry in
                EmojiSearchResult(
                    item: entry.item,
                    matchKind: .browse,
                    matchedTerm: entry.item.shortcode.rawValue,
                    matchDistance: 0,
                    matchField: .shortcode
                )
            }
            .sorted { lhs, rhs in
                Self.isOrderedBefore(lhs, rhs, usage: usage)
            }
            .prefix(limit)
            .map { $0 }
        }

        let strongResults = entries.compactMap { entry -> EmojiSearchResult? in
            let customAliases = usage.customAliasesByItemID[entry.item.id, default: []]
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
                matchDistance: match.distance,
                matchField: match.field
            )
        }
        var results = strongResults
        let queryCharacterCount = normalizedQuery.tokens.reduce(0) {
            $0 + $1.count
        }
        let hasHighConfidenceResult = strongResults.contains {
            $0.matchKind <= .tokenExact
        }
        let hasOnlyWeakSubstringResults = !strongResults.isEmpty
            && strongResults.allSatisfy { $0.matchKind == .substring }
        let shouldIncludeTypoResults = strongResults.isEmpty || (
            strongResults.count < limit
                && !hasHighConfidenceResult
                && (queryCharacterCount >= 4 || hasOnlyWeakSubstringResults)
        )
        if shouldIncludeTypoResults {
            let strongItemIDs = Set(strongResults.map(\.item.id))
            results.append(contentsOf: entries.compactMap { entry -> EmojiSearchResult? in
                guard !strongItemIDs.contains(entry.item.id) else {
                    return nil
                }
                let customAliases = usage.customAliasesByItemID[entry.item.id, default: []]
                guard let match = entry.typoMatch(
                    query: normalizedQuery,
                    customAliases: customAliases
                ) else {
                    return nil
                }
                return EmojiSearchResult(
                    item: entry.item,
                    matchKind: match.kind,
                    matchedTerm: match.originalTerm,
                    matchDistance: match.distance,
                    matchField: match.field
                )
            })
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
        guard EmojiAliasSyntax.isValidToken(shortcode) else {
            return nil
        }
        let literal = EmojiAliasSyntax.normalizedToken(shortcode)

        return entries.compactMap { entry -> EmojiSearchResult? in
            let customAliases = usage.customAliasesByItemID[entry.item.id, default: []]
            guard let match = entry.exactMatch(
                literal: literal,
                customAliases: customAliases
            ) else {
                return nil
            }
            return EmojiSearchResult(
                item: entry.item,
                matchKind: match.kind,
                matchedTerm: match.originalTerm,
                matchDistance: match.distance,
                matchField: match.field
            )
        }
        .sorted { lhs, rhs in
            Self.isOrderedBefore(lhs, rhs, usage: usage)
        }
        .first
    }

    private static func isOrderedBefore(
        _ lhs: EmojiSearchResult,
        _ rhs: EmojiSearchResult,
        usage: EmojiUsageSnapshot
    ) -> Bool {
        // Textual relevance is a hard boundary. Personalization may reorder
        // equally relevant candidates, but can never promote a loose or typo
        // match above an exact, token, or prefix match.
        if lhs.matchKind != rhs.matchKind {
            return lhs.matchKind < rhs.matchKind
        }
        if lhs.matchField != rhs.matchField {
            return lhs.matchField < rhs.matchField
        }
        if lhs.matchDistance != rhs.matchDistance {
            return lhs.matchDistance < rhs.matchDistance
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

    func exactMatch(literal: String, customAliases: [String]) -> SearchMatch? {
        let allAliases = aliases + customAliases.map(IndexedTerm.init)

        if shortcode.normalized == literal {
            return .init(
                kind: .exactShortcode,
                field: .shortcode,
                term: shortcode,
                distance: 0
            )
        }
        if let alias = allAliases.first(where: { $0.normalized == literal }) {
            return .init(
                kind: .exactAlias,
                field: .alias,
                term: alias,
                distance: 0
            )
        }
        return nil
    }

    func bestMatch(query: SearchQuery, customAliases: [String]) -> SearchMatch? {
        let allAliases = aliases + customAliases.map(IndexedTerm.init)
        if let exact = exactMatch(
            literal: query.literal,
            customAliases: customAliases
        ) {
            return exact
        }

        let identifierTerms = [
            SearchableTerm(term: shortcode, field: .shortcode)
        ] + allAliases.map {
            SearchableTerm(term: $0, field: .alias)
        }
        if let separatorMatch = identifierTerms.compactMap({ searchableTerm -> SearchMatch? in
            let term = searchableTerm.term
            guard term.normalized != query.literal,
                  !query.key.isEmpty,
                  term.key == query.key else {
                return nil
            }
            return .init(
                kind: .separatorEquivalent,
                field: searchableTerm.field,
                term: term,
                distance: 0
            )
        }).min() {
            return separatorMatch
        }

        let searchableTerms = searchableTerms(with: allAliases)
        if let tokenMatch = searchableTerms.compactMap({ searchableTerm -> SearchMatch? in
            let term = searchableTerm.term
            guard let tokenMatch = TokenMatcher.match(query: query, candidate: term) else {
                return nil
            }
            return .init(
                kind: tokenMatch.kind,
                field: searchableTerm.field,
                term: term,
                distance: tokenMatch.distance
            )
        }).min() {
            return tokenMatch
        }
        if let substringMatch = searchableTerms.compactMap({ searchableTerm -> SearchMatch? in
            let term = searchableTerm.term
            guard let distance = SubstringMatcher.distance(
                query: query,
                candidate: term
            ) else {
                return nil
            }
            return .init(
                kind: .substring,
                field: searchableTerm.field,
                term: term,
                distance: distance
            )
        }).min() {
            return substringMatch
        }
        return nil
    }

    func typoMatch(query: SearchQuery, customAliases: [String]) -> SearchMatch? {
        let allAliases = aliases + customAliases.map(IndexedTerm.init)
        return searchableTerms(with: allAliases).compactMap { searchableTerm in
            let term = searchableTerm.term
            guard let distance = TypoMatcher.distance(query: query, candidate: term) else {
                return nil
            }
            return .init(
                kind: .fuzzy,
                field: searchableTerm.field,
                term: term,
                distance: distance
            )
        }
        .min()
    }

    private func searchableTerms(
        with allAliases: [IndexedTerm]
    ) -> [SearchableTerm] {
        var seenTerms = Set<String>()
        return (
            [SearchableTerm(term: shortcode, field: .shortcode)]
                + allAliases.map {
                    SearchableTerm(term: $0, field: .alias)
                }
                + [SearchableTerm(term: name, field: .name)]
                + keywords.map {
                    SearchableTerm(term: $0, field: .keyword)
                }
        ).filter { seenTerms.insert($0.term.normalized).inserted }
    }
}

private struct SearchableTerm: Sendable {
    let term: IndexedTerm
    let field: EmojiSearchMatchField
}

private struct IndexedTerm: Equatable, Sendable {
    let original: String
    let normalized: String
    let key: String
    let tokens: [String]

    init(original: String) {
        self.original = original
        normalized = SearchNormalizer.normalizeLiteral(original)
        tokens = SearchNormalizer.tokens(fromNormalized: normalized)
        key = tokens.joined(separator: " ")
    }
}

private struct SearchQuery: Sendable {
    let literal: String
    let key: String
    let tokens: [String]

    init(_ value: String) {
        literal = SearchNormalizer.normalizeLiteral(value)
        tokens = SearchNormalizer.tokens(fromNormalized: literal)
        key = tokens.joined(separator: " ")
    }

    var isEmpty: Bool {
        literal.isEmpty
    }
}

private struct SearchMatch: Comparable, Sendable {
    let kind: EmojiSearchMatchKind
    let field: EmojiSearchMatchField
    let term: IndexedTerm
    let distance: Int

    var originalTerm: String {
        term.original
    }

    static func < (lhs: SearchMatch, rhs: SearchMatch) -> Bool {
        if lhs.kind != rhs.kind {
            return lhs.kind < rhs.kind
        }
        if lhs.field != rhs.field {
            return lhs.field < rhs.field
        }
        if lhs.distance != rhs.distance {
            return lhs.distance < rhs.distance
        }
        return lhs.term.normalized < rhs.term.normalized
    }
}

private enum SearchNormalizer {
    static func normalizeLiteral(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    static func tokens(fromNormalized value: String) -> [String] {
        value.split { character in
            !character.isLetter && !character.isNumber && character != "+"
        }
        .map(String.init)
    }
}

private enum TokenMatcher {
    struct Match {
        let kind: EmojiSearchMatchKind
        let distance: Int
    }

    static func match(query: SearchQuery, candidate: IndexedTerm) -> Match? {
        guard !query.tokens.isEmpty,
              query.tokens.count <= candidate.tokens.count else {
            return nil
        }

        if let start = contiguousMatchStart(
            queryTokens: query.tokens,
            candidateTokens: candidate.tokens,
            requiresExactTokens: true
        ) {
            return Match(
                kind: .tokenExact,
                distance: sequenceDistance(
                    start: start,
                    queryTokens: query.tokens,
                    candidateTokens: candidate.tokens
                )
            )
        }

        if let start = contiguousMatchStart(
            queryTokens: query.tokens,
            candidateTokens: candidate.tokens,
            requiresExactTokens: false
        ) {
            let expansion = zip(
                query.tokens,
                candidate.tokens[start ..< start + query.tokens.count]
            ).reduce(into: 0) { total, pair in
                total += pair.1.count - pair.0.count
            }
            return Match(
                kind: .tokenPrefix,
                distance: sequenceDistance(
                    start: start,
                    queryTokens: query.tokens,
                    candidateTokens: candidate.tokens
                ) + expansion
            )
        }

        if let distance = unorderedTokenDistance(
            queryTokens: query.tokens,
            candidateTokens: candidate.tokens
        ) {
            return Match(kind: .allTokens, distance: distance)
        }
        return nil
    }

    private static func contiguousMatchStart(
        queryTokens: [String],
        candidateTokens: [String],
        requiresExactTokens: Bool
    ) -> Int? {
        let finalStart = candidateTokens.count - queryTokens.count
        for start in 0 ... finalStart {
            let isMatch = queryTokens.indices.allSatisfy { index in
                let queryToken = queryTokens[index]
                let candidateToken = candidateTokens[start + index]
                if requiresExactTokens {
                    return candidateToken == queryToken
                }
                return candidateToken.hasPrefix(queryToken)
            }
            if isMatch {
                return start
            }
        }
        return nil
    }

    private static func sequenceDistance(
        start: Int,
        queryTokens: [String],
        candidateTokens: [String]
    ) -> Int {
        start * 16 + candidateTokens.count - queryTokens.count
    }

    private static func unorderedTokenDistance(
        queryTokens: [String],
        candidateTokens: [String]
    ) -> Int? {
        var unusedIndices = Set(candidateTokens.indices)
        var distance = 0

        // Match the most specific query tokens first so a short prefix cannot
        // consume the only token that satisfies a longer one.
        for queryToken in queryTokens.sorted(by: { $0.count > $1.count }) {
            let match = unusedIndices
                .compactMap { index -> (index: Int, expansion: Int)? in
                    let candidateToken = candidateTokens[index]
                    guard candidateToken.hasPrefix(queryToken) else {
                        return nil
                    }
                    return (index, candidateToken.count - queryToken.count)
                }
                .min { lhs, rhs in
                    if lhs.expansion != rhs.expansion {
                        return lhs.expansion < rhs.expansion
                    }
                    return lhs.index < rhs.index
                }
            guard let match else {
                return nil
            }
            unusedIndices.remove(match.index)
            distance += match.expansion + match.index * 2
        }
        return distance + candidateTokens.count - queryTokens.count
    }
}

private enum SubstringMatcher {
    static func distance(query: SearchQuery, candidate: IndexedTerm) -> Int? {
        guard query.tokens.reduce(0, { $0 + $1.count }) >= 3,
              query.key != candidate.key,
              let range = candidate.key.range(of: query.key) else {
            return nil
        }
        let leadingDistance = candidate.key.distance(
            from: candidate.key.startIndex,
            to: range.lowerBound
        )
        return leadingDistance + candidate.key.count - query.key.count
    }
}

private enum TypoMatcher {
    static func distance(query: SearchQuery, candidate: IndexedTerm) -> Int? {
        guard !query.tokens.isEmpty,
              query.tokens.count <= candidate.tokens.count else {
            return nil
        }

        let finalStart = candidate.tokens.count - query.tokens.count
        return (0 ... finalStart).compactMap { start -> Int? in
            var totalEdits = 0
            for queryIndex in query.tokens.indices {
                let queryToken = query.tokens[queryIndex]
                let candidateToken = candidate.tokens[start + queryIndex]
                let maximumDistance = maximumDistance(for: queryToken)

                if maximumDistance == 0 {
                    guard queryToken == candidateToken else {
                        return nil
                    }
                    continue
                }
                guard let edits = BoundedDamerauLevenshtein.distance(
                    from: queryToken,
                    to: candidateToken,
                    maximum: maximumDistance
                ) else {
                    return nil
                }
                totalEdits += edits
                guard totalEdits <= 2 else {
                    return nil
                }
            }

            guard totalEdits > 0 else {
                return nil
            }
            return totalEdits * 100 + start * 4
        }
        .min()
    }

    private static func maximumDistance(for token: String) -> Int {
        switch token.count {
        case 0 ... 2: 0
        case 3 ... 5: 1
        default: 2
        }
    }
}

private enum BoundedDamerauLevenshtein {
    static func distance(from source: String, to target: String, maximum: Int) -> Int? {
        let sourceCharacters = Array(source)
        let targetCharacters = Array(target)
        guard !sourceCharacters.isEmpty,
              !targetCharacters.isEmpty,
              abs(sourceCharacters.count - targetCharacters.count) <= maximum else {
            return nil
        }

        var previousPrevious = Array(0 ... targetCharacters.count)
        var previous = previousPrevious

        for sourceIndex in 1 ... sourceCharacters.count {
            var current = Array(repeating: 0, count: targetCharacters.count + 1)
            current[0] = sourceIndex

            for targetIndex in 1 ... targetCharacters.count {
                let substitutionCost = sourceCharacters[sourceIndex - 1]
                    == targetCharacters[targetIndex - 1] ? 0 : 1
                current[targetIndex] = min(
                    previous[targetIndex] + 1,
                    current[targetIndex - 1] + 1,
                    previous[targetIndex - 1] + substitutionCost
                )

                if sourceIndex > 1,
                   targetIndex > 1,
                   sourceCharacters[sourceIndex - 1] == targetCharacters[targetIndex - 2],
                   sourceCharacters[sourceIndex - 2] == targetCharacters[targetIndex - 1] {
                    current[targetIndex] = min(
                        current[targetIndex],
                        previousPrevious[targetIndex - 2] + 1
                    )
                }
            }

            previousPrevious = previous
            previous = current
        }

        let result = previous[targetCharacters.count]
        return result <= maximum ? result : nil
    }
}
