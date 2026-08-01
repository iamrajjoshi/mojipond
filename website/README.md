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

## Release assets

The site does not hard-code a download version. The Pages workflow stages the
latest published GitHub release under `public/releases/` before building:

```text
MojiPond.dmg
MojiPond.zip
SHA256SUMS.txt
update-feed.json
release.json
```

`update-feed.json` is optional until the offline signing step is complete. The
landing page does not advertise a development build. Add a public download only
after the signed release and its support policy are ready.

Do not add generated `dist/`, `.astro/`, Playwright output, signing material,
or private release assets to Git.
