import gemojiCatalog from "../../../Resources/Data/gemoji.json";

export interface EmojiOption {
  shortcode: string;
  emoji: string;
  name: string;
  aliases: string[];
  keywords: string[];
}

interface GemojiEntry {
  emoji: string;
  description: string;
  aliases: string[];
  tags: string[];
}

const demoOrder = new Map(
  ["wave", "warning", "watch", "watermelon", "waning_crescent_moon"].map(
    (shortcode, index) => [shortcode, index],
  ),
);

const displayName = (description: string) =>
  description.charAt(0).toLocaleUpperCase() + description.slice(1);

export const emojiOptions: EmojiOption[] = (gemojiCatalog as GemojiEntry[])
  .flatMap((entry): EmojiOption[] => {
    const shortcode = entry.aliases[0];
    if (!shortcode) return [];

    return [
      {
        shortcode,
        emoji: entry.emoji,
        name: displayName(entry.description),
        aliases: entry.aliases,
        keywords: entry.tags,
      },
    ];
  })
  .sort((left, right) => {
    const leftOrder = demoOrder.get(left.shortcode) ?? Number.MAX_SAFE_INTEGER;
    const rightOrder =
      demoOrder.get(right.shortcode) ?? Number.MAX_SAFE_INTEGER;
    return leftOrder - rightOrder;
  });

const waveQuery = "wa";

export const waveSuggestions = emojiOptions
  .filter(
    (option) =>
      option.shortcode.startsWith(waveQuery) ||
      option.aliases.some((alias) => alias.startsWith(waveQuery)) ||
      option.name.toLocaleLowerCase().includes(waveQuery) ||
      option.keywords.some((keyword) => keyword.includes(waveQuery)),
  )
  .slice(0, 5);
