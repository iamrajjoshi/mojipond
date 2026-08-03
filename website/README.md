# MojiPond website

This directory contains the static site for `mojipond.com`. Astro builds it
for GitHub Pages; pnpm owns the workspace and lockfile.

From the repository root:

```sh
corepack enable
pnpm install --frozen-lockfile
pnpm site:dev
```

Run the same checks as CI before pushing:

```sh
pnpm site:format:check
pnpm site:check
pnpm audit --prod --audit-level high
pnpm site:build
pnpm site:test
```

The browser tests start an Astro preview server and cover desktop and mobile
viewports, the interactive shortcode demo, links, metadata, and automated
accessibility checks.

## Sparkle appcast

`public/releases/appcast.xml` keeps the update endpoint live before the first
public release. When a stable GitHub Release is published, the Pages workflow
replaces that placeholder with the signed `appcast.xml` attached to the latest
stable release. The appcast points to the tag-specific release ZIP; Pages
does not copy or rename the update archive.

The landing page does not advertise a development build. Add a public download
only after the Developer ID release is notarized and the appcast is signed.

Do not add generated `dist/`, `.astro/`, Playwright output, signing material,
or private release assets to Git.
