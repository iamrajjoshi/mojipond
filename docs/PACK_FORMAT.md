# MojiPond portable pack format

A portable pack is a folder containing a UTF-8 JSON manifest named
`mojipond.json` and any image files it references. Schema version 2 supports
image-backed entries, Unicode-backed entries, or both in one pack. The format
is data-only: there are no scripts, hooks, commands, or executable extensions.

The current MojiPond UI imports one local ZIP archive at a time. Put the pack
folder described below inside a ZIP before choosing it or dropping it into the
Library. Direct file, folder, Slack-manifest, and GitHub import entry points are
not exposed.

## Complete example

```text
pond-friends/
├── mojipond.json
└── emoji/
    └── party-frog.gif
```

```json
{
  "schemaVersion": 2,
  "id": "com.example.pond-friends",
  "name": "Pond Friends",
  "version": "1.0.0",
  "author": "Example Artist",
  "description": "An original image emote and a Unicode shortcut.",
  "source": "https://example.com/pond-friends",
  "license": "CC-BY-4.0",
  "emoji": [
    {
      "shortcode": "party_frog",
      "aliases": ["frog_party", "celebrate"],
      "displayName": "Party Frog",
      "tags": ["frog", "party"],
      "category": "Pond Friends",
      "order": 0,
      "file": "emoji/party-frog.gif"
    },
    {
      "shortcode": "pond_coder",
      "aliases": ["frog_dev"],
      "displayName": "Pond Coder",
      "tags": ["pond", "coding"],
      "category": "Pond Friends",
      "order": 1,
      "unicode": "👨🏽‍💻"
    }
  ]
}
```

That mixed example is valid only when the referenced GIF exists, its bytes
decode as GIF, and the Unicode value passes the single-emoji validation below.

## Top-level fields

| Field | Required | Rules |
| --- | --- | --- |
| `schemaVersion` | Yes | Integer `1` or `2`; `2` is current, while `1` remains accepted for file-only packs |
| `id` | Yes | Stable lowercase pack ID, 1–128 bytes; starts with `a-z` or `0-9`; remaining characters may also include `.`, `_`, or `-`; no `..` or trailing `.` |
| `name` | Yes | Non-empty safe text, at most 200 UTF-8 bytes |
| `version` | Yes | Non-empty safe text, at most 64 UTF-8 bytes |
| `author` | No | Safe text, at most 256 UTF-8 bytes |
| `description` | No | Safe text, at most 4,096 UTF-8 bytes |
| `source` | No | HTTPS URL with a host and no embedded username or password |
| `license` | No | Safe text, at most 256 UTF-8 bytes |
| `emoji` | Yes | Array of emoji entries; at most 2,000 by default |

Pack IDs are persistent identities. Keep the same ID when publishing a new
version of the same pack.

## Emoji fields

| Field | Required | Rules |
| --- | --- | --- |
| `shortcode` | Yes | Canonical name without surrounding colons |
| `aliases` | No | Array of additional shortcodes; defaults to `[]` |
| `displayName` | No | Human-readable label |
| `tags` | No | At most 64 unique, non-empty tags; each at most 64 UTF-8 bytes |
| `category` | No | Non-empty trimmed text, at most 128 UTF-8 bytes |
| `order` | No | Non-negative integer; manifest order is used when omitted |
| `file` | Exactly one of `file` or `unicode` | Safe path relative to the manifest directory |
| `unicode` | Exactly one of `file` or `unicode` | One valid Unicode emoji grapheme, at most 256 UTF-8 bytes |

A shortcode must match:

```regex
[a-z0-9][a-z0-9_+-]{0,63}
```

Every emoji entry must contain exactly one of `file` or `unicode`. Supplying
both, or neither, is invalid. Schema version 1 remains backward-compatible with
existing file-only manifests; a Unicode entry requires schema version 2.

Unicode values may be a single emoji presentation character or one extended
grapheme such as a flag, keycap, skin-tone variant, variation-selector form, or
zero-width-joiner sequence. Empty values, multiple graphemes, plain text,
shortcode text such as `:frog:`, standalone modifiers, and control, whitespace,
or illegal scalars are rejected.

Shortcodes and aliases must be unique within the pack. Paths used by `file`
entries must also be unique after case-insensitive canonical normalization.
Two Unicode entries may deliberately use the same glyph when their shortcode
claims remain unique.

Paths may contain `/` to address subfolders. They cannot be absolute, contain
empty, `.` or `..` components, backslashes, colons, control characters, or a
component longer than 255 UTF-8 bytes. Symlinked manifests, roots, and assets
are rejected. Every path component is checked for symlinks, and the resolved
asset must remain below the canonical pack root.

## Supported image formats and default limits

MojiPond identifies content from decoded bytes rather than trusting the
filename alone. When an extension is present, it must agree with the detected
format.

| Limit | Default |
| --- | ---: |
| Formats | PNG, JPEG, GIF, WebP |
| Bytes per image | 25 MiB |
| Width or height | 4,096 pixels |
| Pixels per frame | 16,777,216 |
| Frames per animation | 256 |
| Decoded pixels across an animation | 200,000,000 |
| Files or archive entries per import | 2,000 |
| Folder depth | 12 levels |
| Total accepted source bytes | 250 MiB |
| `mojipond.json` size | 1 MiB |

Every frame is decoded as a small thumbnail during validation so a file with
plausible metadata but truncated frame data is rejected. Assets are hashed
with SHA-256 and copied into MojiPond’s managed Application Support directory.

## Filename-derived folders inside a ZIP

A folder inside the selected ZIP without `mojipond.json` is treated as a simple
pack. Supported image files are discovered recursively and ordered by path. The
filename without its extension is normalized into a shortcode:

```text
Party Frog.gif  →  party_frog
hello-world.png →  hello-world
```

Diacritics and width variants are folded; unsupported characters become an
underscore boundary. Hidden files and package descendants are skipped.
Unsupported regular files are counted as ignored. Invalid image candidates
appear as rejections in the import preview.

If a folder contains `mojipond.json`, the portable manifest takes precedence.
If it has no portable manifest but contains `emoji.json`, the orchestrator
treats it as a Slack-style pack.

## Slack-style `emoji.json` inside a ZIP

MojiPond accepts the common name-to-location map when it is packaged inside the
selected ZIP:

```json
{
  "party_frog": "images/party-frog.gif",
  "celebrate": "alias:party_frog"
}
```

It also accepts an `emoji` wrapper and object arrays:

```json
{
  "emoji": [
    {
      "name": "party_frog",
      "path": "images/party-frog.gif"
    },
    {
      "name": "celebrate",
      "alias_for": "party_frog"
    }
  ]
}
```

Asset keys in array entries may be `url`, `image_url`, `imageUrl`, `path`, or
`file`. Alias keys may be `alias_for`, `aliasFor`, or `alias`. Aliases can chain
but must resolve to an asset; missing targets and cycles are rejected.

Local asset paths use the same traversal protections as portable packs. The
current public UI does not grant network access during ZIP preparation, so
remote asset URLs in a Slack-style manifest are not downloaded. The retained
import engine can validate explicitly authorized HTTPS assets in tests and
internal integrations; that path rejects embedded credentials, custom ports,
localhost and `.local` names, and non-public IPv4 or IPv6 literals or DNS
answers on the initial request and every redirect. Remote responses are capped
at 25 MiB each and 250 MiB total by default.

## ZIP archives

A ZIP can contain a portable pack, a Slack-style pack with local assets, or a
simple folder. A single top-level directory is unwrapped automatically.

The extractor rejects absolute paths, `..`, backslashes, control characters,
symlinks, special files, duplicate output paths, excessive entry counts,
oversized entries, excessive aggregate expansion, and suspicious compression
ratios. A selected archive is copied into a fresh app-private `0700` staging
directory, validated and extracted only from that read-only snapshot, and
deleted after preparation.

## Retained GitHub engine

The source tree retains a public-GitHub import engine for compatibility tests,
but the current application UI does not expose it or grant it network access.
The engine accepts:

```text
https://github.com/OWNER/REPOSITORY
https://github.com/OWNER/REPOSITORY/tree/REF/OPTIONAL/SUBDIRECTORY
```

Only public HTTPS GitHub URLs are accepted by the default anonymous client.
MojiPond resolves the ref through `api.github.com`, records the exact commit
SHA, downloads a bounded ZIP from `codeload.github.com`, and applies the same
archive and folder validation when an internal caller explicitly authorizes the
network operation.

Repository contents remain subject to their own license. MojiPond importing a
pack does not grant permission to redistribute its artwork.

[`knobiknows/all-the-bufo`](https://github.com/knobiknows/all-the-bufo) is an
engine-level import-compatibility fixture, not a source exposed by the current
UI or bundled content. The audit performed on 2026-07-28 recorded 1,715
repository-tree entries: 1,403 PNG, 295 GIF, and 10 JPG files. `README` was the
only license-like path found. No `LICENSE` file, repository license metadata,
or other redistribution grant was detected. MojiPond therefore does not bundle
or redistribute this artwork. Importing it outside the public UI does not
create redistribution rights; obtain permission from the rights holder before
redistributing it.

## Collisions and duplicate content

Before installation, the importer produces:

- accepted items and metadata;
- rejected or ignored files with reasons;
- collisions against existing primary shortcodes or aliases;
- collisions within the incoming pack;
- duplicate SHA-256 content groups for image assets.

A shortcode collision must be resolved by skipping the incoming item,
replacing the existing item, renaming the incoming claim, or dropping a
colliding incoming alias. Primary shortcodes cannot be dropped. Installation
does not proceed while a collision remains unresolved. Unicode values do not
participate in asset SHA-256 duplicate grouping; their identity is deliberate
and their shortcode claims still use the same collision rules.

Mixed and Unicode-only packs use the same reviewed install, append, replace,
digest, and export paths as image packs. A Unicode-only export contains
`mojipond.json` without an empty `emoji/` directory.
