import { defineConfig } from "astro/config";
import sitemap from "@astrojs/sitemap";

export default defineConfig({
  site: "https://mojipond.com",
  output: "static",
  integrations: [
    sitemap({
      filter: (page) => !page.endsWith("/404/") && !page.endsWith("/terms/"),
    }),
  ],
  build: {
    assets: "assets",
  },
  compressHTML: true,
});
