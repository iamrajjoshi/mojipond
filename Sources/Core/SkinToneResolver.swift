import Foundation

enum SkinToneSelectionSource: Equatable, Sendable {
    case explicit
    case itemPreference
    case globalDefault
    case itemUsage
    case baseEmoji
}

struct ResolvedUnicodeEmoji: Equatable, Sendable {
    let value: String
    let skinTone: EmojiSkinTone?
    let source: SkinToneSelectionSource
}

enum SkinToneResolver {
    static func resolve(
        item: EmojiItem,
        explicitTone: EmojiSkinTone? = nil,
        defaultTone: EmojiSkinTone? = nil,
        usage: EmojiUsageSnapshot = EmojiUsageSnapshot()
    ) -> ResolvedUnicodeEmoji? {
        guard case let .unicode(content) = item.content else {
            return nil
        }

        let candidates: [(EmojiSkinTone?, SkinToneSelectionSource)] = [
            (explicitTone, .explicit),
            (usage.preferredSkinToneByItemID[item.id], .itemPreference),
            (defaultTone, .globalDefault),
            (mostUsedTone(for: item.id, content: content, usage: usage), .itemUsage)
        ]

        for (tone, source) in candidates {
            guard let tone,
                  let variant = content.skinToneVariants.first(where: { $0.skinTone == tone }) else {
                continue
            }
            return ResolvedUnicodeEmoji(value: variant.value, skinTone: tone, source: source)
        }

        return ResolvedUnicodeEmoji(
            value: content.value,
            skinTone: nil,
            source: .baseEmoji
        )
    }

    static func resolve(
        item: EmojiItem,
        explicitTone: EmojiSkinTone? = nil,
        preferences: MojiPondPreferences,
        usage: EmojiUsageSnapshot = EmojiUsageSnapshot()
    ) -> ResolvedUnicodeEmoji? {
        resolve(
            item: item,
            explicitTone: explicitTone,
            defaultTone: preferences.defaultSkinTone,
            usage: usage
        )
    }

    private static func mostUsedTone(
        for itemID: EmojiItem.ID,
        content: UnicodeEmojiContent,
        usage: EmojiUsageSnapshot
    ) -> EmojiSkinTone? {
        let available = Set(content.skinToneVariants.map(\.skinTone))
        let statistics = usage.statistics(for: itemID)
        return statistics.skinToneUseCounts
            .filter { available.contains($0.key) && $0.value > 0 }
            .sorted { lhs, rhs in
                if lhs.value != rhs.value {
                    return lhs.value > rhs.value
                }
                if lhs.key == statistics.lastUsedSkinTone {
                    return true
                }
                if rhs.key == statistics.lastUsedSkinTone {
                    return false
                }
                return EmojiSkinTone.allCases.firstIndex(of: lhs.key)!
                    < EmojiSkinTone.allCases.firstIndex(of: rhs.key)!
            }
            .first?
            .key
    }
}
