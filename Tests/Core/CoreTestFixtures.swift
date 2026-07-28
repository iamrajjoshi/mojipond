import Foundation
@testable import MojiPond

enum CoreTestFixtures {
    static func item(
        id: String,
        shortcode: String,
        name: String? = nil,
        aliases: [String] = [],
        keywords: [String] = [],
        packID: String = "test.pack",
        packPriority: Int = 0,
        order: Int? = nil,
        value: String = "🧪",
        variants: [UnicodeEmojiVariant] = []
    ) -> EmojiItem {
        EmojiItem(
            id: id,
            shortcode: try! Shortcode(validating: shortcode),
            name: name ?? shortcode,
            aliases: aliases,
            keywords: keywords,
            category: "Tests",
            content: .unicode(
                UnicodeEmojiContent(value: value, skinToneVariants: variants)
            ),
            packID: packID,
            packPriority: packPriority,
            order: order
        )
    }
}
