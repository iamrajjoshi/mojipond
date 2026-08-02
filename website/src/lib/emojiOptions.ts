export interface EmojiOption {
  shortcode: string;
  emoji: string;
  name: string;
}

export const emojiOptions: EmojiOption[] = [
  { shortcode: "wave", emoji: "👋", name: "Waving hand" },
  { shortcode: "warning", emoji: "⚠️", name: "Warning" },
  { shortcode: "watch", emoji: "⌚", name: "Watch" },
  { shortcode: "watermelon", emoji: "🍉", name: "Watermelon" },
  {
    shortcode: "waning_crescent_moon",
    emoji: "🌘",
    name: "Waning crescent moon",
  },
  { shortcode: "frog", emoji: "🐸", name: "Frog" },
  { shortcode: "lizard", emoji: "🦎", name: "Lizard" },
  { shortcode: "lotus", emoji: "🪷", name: "Lotus" },
  { shortcode: "sparkles", emoji: "✨", name: "Sparkles" },
  { shortcode: "duck", emoji: "🦆", name: "Duck" },
  { shortcode: "joy", emoji: "😂", name: "Face with tears of joy" },
  { shortcode: "heart_eyes", emoji: "😍", name: "Heart eyes" },
];

const waveQuery = "wa";

export const waveSuggestions = emojiOptions
  .filter(
    (option) =>
      option.shortcode.startsWith(waveQuery) ||
      option.name.toLocaleLowerCase().includes(waveQuery),
  )
  .slice(0, 5);
