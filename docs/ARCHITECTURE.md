# MojiPond architecture

MojiPond is a single native macOS application. Separate boundaries handle the
global event callback, text validation, UI, persistence, imports, networking,
and updates. If MojiPond cannot validate the current state, it
does nothing.

The current direct-distribution target is not App Sandbox-enabled. Global
event monitoring, Accessibility control, and user-selected pack imports are
instead bounded by explicit TCC consent, strict target revalidation, and the
validation layers described below. Release builds enable Hardened Runtime.
Ad-hoc local signatures can retain the runtime flag, but only
Developer ID release builds can provide the identity, Team ID, trusted
timestamp, notarization, and Gatekeeper posture required for public
distribution.

## Runtime data flow

```text
macOS session event tap
        │ immutable event snapshot
        ▼
constant-time interception gate ────────────► pass ordinary keys through
        │
        ▼
serial autocomplete worker
  ├─ bounded shortcode parser
  ├─ deterministic search + usage ranking
  └─ transaction/revision ownership
        │
        ▼
target validation and Accessibility capture
  ├─ permission preflight
  ├─ secure-input / secure-field check
  ├─ app and optional browser-domain exclusion
  ├─ focused target + selection
  └─ exact token validation near the caret
        │
        ├─ uncertain or stale ───────────────► leave text and key untouched
        ▼
main actor
  ├─ non-activating suggestion panel
  └─ insertion engine
       ├─ direct AX Unicode replacement
       └─ validated temporary pasteboard + tagged Command-V for media/fallback
```

The event-tap callback does not search, access the filesystem, call
Accessibility APIs, or update UI. It copies a small immutable snapshot, asks
the lock-bounded interception gate whether a navigation key belongs to an
already-visible MojiPond session, and enqueues work on the runtime’s serial
queue.

The worker owns parser state, search state, active transaction identity, and UI
revision numbers. Before any replacement it asks the Accessibility boundary to
capture the focused target again and prove that the expected token still ends
at the current caret. Insertion revalidates the process, element, selection,
token range, and token content.

## Modules

| Directory | Responsibility |
| --- | --- |
| `Sources/App` | Application lifecycle, status item, windows, preferences, permission status, and managed paths |
| `Sources/Core` | Emoji models, bundled gemoji decoding, parser, search/ranking, usage, tones, and exclusions |
| `Sources/Runtime` | Event-to-parser bridge, safety policy, browser host lookup, Unicode popup state, managed-media revalidation, and autocomplete lifecycle |
| `Sources/SystemIntegration` | macOS permission preflights, event tap, Accessibility text adapter, caret geometry, pasteboard transactions, and insertion |
| `Sources/Library` | Versioned library model, asset validation, collision resolution, persistence, ZIP handling, and pack source metadata |
| `Sources/Importing` | ZIP orchestration plus local, Slack, and public-GitHub import engines with bounded network and temporary storage |
| `Sources/Updates` | Small adapter around Sparkle's standard updater controller and its configured appcast trust boundary |
| `Sources/UI` | SwiftUI onboarding, settings, Library, ZIP-only import workflow, editors, previews, shared controls, and styling |

## Brand assets

`Resources/Branding/MojiPond-AppIcon-Source.png` is the source artwork for the
application icon. It was generated specifically for MojiPond and does not use
a third-party logo or emoji. The production sizes in
`Resources/Assets.xcassets/AppIcon.appiconset/` are derivatives of that source;
regenerate and review the complete icon set whenever the source changes.

`packaging/dmg/MojiPond-DMG-Background.png` and its `@2x` counterpart were
generated specifically for MojiPond using the application icon as a style
reference. They contain no third-party logo or emoji. `dmgbuild` combines the
pair into the Retina Finder background used by the release disk image.

## Text access and fail-closed behavior

The Accessibility adapter normally requests only the 66 UTF-16 code units
immediately before the caret using `AXStringForRange`. For controls that do not
support ranged access, it may read `AXValue` only after proving the entire
control contains at most 4,096 UTF-16 code units. Large documents without
ranged access are unsupported.

The runtime does nothing when any of these cannot be established:

- Input Monitoring and Accessibility are currently granted.
- The frontmost process and focused element are known.
- Secure Event Input is off and the target is proven non-secure.
- The application and, when configured, browser host are not excluded.
- The selection is an insertion caret.
- The token is syntactically valid, belongs to the active transaction, and
  still matches the text immediately before the caret.

Browser-domain exclusions are limited to known Safari and Chromium address-bar
Accessibility shapes. If MojiPond cannot identify a host, it leaves the host
unknown. App exclusions still apply independently.

## Insertion and clipboard ownership

Unicode first uses direct Accessibility replacement. Rich editors or media can
require a paste:

1. Capture every current pasteboard item and every advertised representation,
   up to a 32 MiB in-memory limit.
2. Revalidate and select the exact expected token.
3. Write the temporary payload.
4. Post a synthetic, tagged Command-V only if Event Posting is granted.
5. Restore the complete snapshot after a short delay, unless another process
   changed the pasteboard in the meantime.

If the snapshot is incomplete, the target changed, the system permission is
missing, or a write fails, the engine returns a non-mutating copy-fallback
result and does not silently replace the source token. The runtime publishes
that result through `onMediaCopyFallback`. When the already-validated payload
is available, AppDelegate surfaces a **Copy Media Instead** status-menu action;
the explicit action writes it permanently for a manual paste. Original GIF or
WebP bytes remain an advertised pasteboard representation; compatibility PNG
or TIFF data is additive.

## Catalogs, ranking, and persistence

The built-in catalog is generated from a pinned `gemoji` snapshot in
`Resources/Data/gemoji.json`. Enabled custom packs are converted to the same
search model and merged after startup. Search ranking is deterministic and
combines match quality, aliases/tags, pack priority, and a local usage snapshot.

The versioned custom library is owned by a Swift actor. Writes stage assets,
validate the resulting model, write JSON atomically, and then commit the
transaction. Imported assets are copied into managed storage so the source
folder can disappear without breaking the pack. Custom Unicode entries loaded
from portable packs store one validated emoji grapheme directly in the
library; their shortcode and aliases use the same global collision rules as
imported content. Unicode also participates in pack content digests and
portable export.

Default locations:

```text
~/Library/Application Support/MojiPond/
├── Library/                 versioned library and managed pack assets
├── Import Staging/          app-owned import staging
└── usage.json               local recency and use counts

```

Preferences and permission-request history use `UserDefaults`. One idempotent
upgrade migration deletes the unused media-provider Keychain credential left by
older development builds without reading its value.

## Import trust boundary

The shipping Library UI accepts exactly one local ZIP from the open panel or
drag and drop. Direct file, folder, Slack-manifest, and GitHub entry points are
not exposed. A ZIP may still contain a portable pack, a simple image folder, or
a Slack-style manifest with local assets, so those parsers remain inside the
archive-processing boundary.

All images pass through ImageIO validation before storage. Default limits
include 25 MiB per image, 4,096 × 4,096 dimensions, 256 frames, and bounded
decoded animation pixels. Folder enumeration, ZIP extraction, GitHub archives,
Slack manifests, redirects, response sizes, and aggregate import bytes have
separate caps.

Portable manifests cannot execute scripts. Paths must remain relative to the
pack root; absolute paths, traversal, backslashes, control characters, and
symlinked path components are rejected, and every canonical asset path must
remain below the canonical pack root.

Portable schema version 2 gives each entry a typed content choice: exactly one
of a relative `file` path or a validated `unicode` grapheme. The reader still
accepts schema-version-1 file-only packs. Mixed and Unicode-only packs pass
through the same collision, transactional install, append, replace, digest,
and export model; Unicode-only exports omit an empty asset directory.

Selected ZIPs are copied into a fresh app-private `0700` staging directory
through a bounded `O_NOFOLLOW` file descriptor, then locked read-only.
MojiPond validates central and local ZIP headers before invoking the system
`ditto` extractor with closed stdin, and accepts the result only when a second
walk exactly matches the validated regular-file tree. The snapshot and
extraction are deleted after preparation. The internal GitHub engine
accepts public `https://github.com` URLs, resolves the requested ref to a commit
through the GitHub API, and downloads from GitHub’s codeload host. The remote
Slack path and all redirects remain HTTPS-only. Both paths reject
credentials, custom ports, localhost and `.local` names, and non-public IPv4 or
IPv6 literals and DNS answers on the initial request and every redirect. The
current public UI invokes neither network import path.

Import preparation produces a preview with rejections, shortcode collisions,
and duplicate content hashes. Installation occurs only after collision
decisions are complete. The Library UI exposes individual and apply-all
collision decisions, then installs or discards the prepared import. It also
supports copying custom Unicode, item edits and asset replacement, pack
enablement and ordering, portable export, and transactional replacement from
another ZIP. Creating empty packs and individual Unicode items remains an
internal model capability rather than a Library UI workflow. Custom Unicode
entries join the same indexed Library and runtime search surfaces as the
built-in catalog.

## Messages custom-image runtime

Enabled custom-pack image results share `:query`, exact `:name:`, and `::`
browsing with Unicode results, but their insertion is allowed only when the
captured target is Messages. Immediately before paste, the managed resolver
repeats the root-containment, symlink, regular-file, non-empty, 25 MiB,
SHA-256, and magic-byte checks against the imported asset. Failure leaves the
source token intact and publishes a copy-fallback diagnostic.

On macOS 15 or later, a custom image then passes through the adaptive-glyph
bridge. Single-frame assets use their decoded image; multi-frame assets decode
frame 0 as a static glyph so Messages can resize it with surrounding text.
The selected frame is orientation-normalized, bounded while preserving its
aspect ratio, encoded as a metadata-bearing HEIC, validated by
`NSAdaptiveImageGlyph`, and exposed to Messages as RTFD plus a plain-text
shortcode fallback. The managed source asset is never rewritten, so the
original animation remains stored unchanged. The successful pasteboard item
deliberately omits raw PNG/TIFF representations so Messages does not prefer
photo semantics.

macOS 13 and 14, along with rejected conversions on newer systems, retain the
validated-media fallback policy. If animated WebP conversion fails, the
runtime preserves the token and offers **Copy Media Instead** with the original
animation. This path adds no permission beyond the existing Accessibility,
Input Monitoring, and Event Posting requirements.

## Network boundaries

Automatic update checks run at most once a day by default and can be disabled
under **Settings → General**. Manual checks run only after an explicit action
on that page.

Crash and hang reporting is controlled separately, defaults to on, and can be
disabled in **Settings → Privacy**. On a fresh install, AppDelegate waits for
first-run setup to finish before starting Sentry, so the disclosed toggle takes
effect before the SDK observes the process. Completed installations apply the
saved preference at launch.

The built-in Unicode catalog requires no network. ZIP import preparation is
local and never invokes the internal network import engines.

Updates use Sparkle 2.9.5 through `SPUStandardUpdaterController`. The release
build pins an HTTPS appcast URL and a Base64 Ed25519 public key in its Info
property list. `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` are
enabled; Sparkle system profiling is disabled. An invalid or incomplete
configuration disables update commands.

Settings → General can start a manual check. Automatic checks use Sparkle's
daily schedule by default and remain user-configurable. Sparkle verifies the
signed appcast and enclosure signature before it installs a release. The app
delegates download, extraction, installation, and rollback to Sparkle instead
of maintaining a second updater security boundary.

The appcast lives at `https://mojipond.com/releases/appcast.xml`. Its enclosure
points to a tag-specific GitHub Release ZIP. The release workflow signs
the final notarized ZIP metadata with a private Ed25519 key held only in the
protected GitHub environment; the matching public key ships in the app.

## Testing boundaries

Most core and safety behavior is dependency-injected and covered without
global permissions: fake Accessibility targets, permission providers, event
monitors, pasteboards, HTTP transports, and caches. Portable-format tests cover
v1 compatibility, v2 mixed content, validation, and round trips. Library store
tests cover custom Unicode creation and rejection; Library UI tests cover
search and clipboard output for imported Unicode entries.
Updater tests cover configuration validation, lifecycle start, manual checks,
and the automatic-check preference through a controlled Sparkle driver. The
release workflow verifies the notarized app, signs the appcast with Sparkle's
tooling, and publishes both as release assets. Those checks do not replace a
real update from one published Developer ID build to the next.
Manual evidence is tracked separately in
[COMPATIBILITY.md](COMPATIBILITY.md).
