# MojiPond architecture

MojiPond is a single native macOS application. It deliberately separates the
global event callback, text validation, UI, persistence, import, network, and
update-verification boundaries so that uncertain state results in no action.

The current direct-distribution target is not App Sandbox-enabled. Global
event monitoring, Accessibility control, and user-selected pack imports are
instead bounded by explicit TCC consent, strict target revalidation, and the
validation layers described below. Hardened Runtime is enabled for a real
signed Release. Ad-hoc local signatures can retain the runtime flag, but only
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
safety and Accessibility capture
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
| `Sources/Runtime` | Event-to-parser bridge, safety policy, browser host lookup, Unicode and media popup state, managed-media revalidation, and autocomplete lifecycle |
| `Sources/SystemIntegration` | macOS permission preflights, event tap, Accessibility text adapter, caret geometry, pasteboard transactions, and insertion |
| `Sources/Library` | Versioned library model, asset validation, collision resolution, persistence, ZIP handling, and pack source metadata |
| `Sources/Importing` | Local, Slack, ZIP, and public-GitHub import orchestration with bounded network and temporary storage |
| `Sources/Media` | GIPHY and Noto clients, direct HTTPS downloads, Keychain key storage, and bounded disk-cache primitives |
| `Sources/MediaCommands` | Messages-only `/sticker` and `/gif` parser, state machine, result grid, offline catalog, and asset resolution |
| `Sources/Updates` | Signed-feed verification, explicit bounded asset download, hostile ZIP inspection, Developer ID and Gatekeeper validation, private staging, and a locked one-executable installer with atomic replacement, readiness acknowledgement, and rollback |
| `Sources/UI` | SwiftUI onboarding, settings, full Library and import workflows, editors, previews, and shared visual language |

## Brand assets

`Resources/Branding/MojiPond-AppIcon-Source.png` is the source artwork for the
application icon. It was generated specifically for MojiPond and does not use
a third-party logo or emoji. The production sizes in
`Resources/Assets.xcassets/AppIcon.appiconset/` are derivatives of that source;
regenerate and review the complete icon set whenever the source changes.

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
Accessibility shapes. Failure to identify a host does not invent one. App
exclusions still apply independently.

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
folder can disappear without breaking the pack. User-created Unicode entries
store one validated emoji grapheme directly in the library; their shortcode
and aliases use the same global collision rules as imported content. Unicode
also participates in pack content digests and portable export.

Default locations:

```text
~/Library/Application Support/MojiPond/
├── Library/                 versioned library and managed pack assets
├── Import Staging/          app-owned import staging
└── usage.json               local recency and use counts

~/Library/Caches/MojiPond/
└── Media/                   bounded, reproducible media cache
```

Preferences and permission-request history use `UserDefaults`. A GIPHY key,
when configured, uses the login Keychain service
`com.rajjoshi.MojiPond` and account `giphy-api-key`.

## Import trust boundary

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
and export model; Unicode-only exports do not invent an empty asset directory.

Selected ZIPs are copied into a fresh app-private `0700` staging directory
through a bounded `O_NOFOLLOW` file descriptor, then locked read-only.
MojiPond validates central and local ZIP headers before invoking the system
`ditto` extractor with closed stdin, and accepts the result only when a second
walk exactly matches the validated regular-file tree. The snapshot and
extraction are deleted after preparation. GitHub imports accept public
`https://github.com` URLs, resolve the requested ref to a commit through the
GitHub API, and download from GitHub’s codeload host. Remote Slack assets and
all redirects remain HTTPS-only. They also reject credentials, custom ports,
localhost and `.local` names, and non-public IPv4 or IPv6 literals and DNS
answers on the initial request and every redirect.

Import preparation produces a preview with rejections, shortcode collisions,
and duplicate content hashes. Installation occurs only after collision
decisions are complete. The Library UI exposes individual and apply-all
collision decisions, then installs or discards the prepared import. It also
supports attributed empty-pack creation, custom Unicode creation and copying,
item edits and asset replacement, pack enablement and ordering, portable
export, and transactional local re-import. Custom Unicode entries join the
same indexed Library and runtime search surfaces as the built-in catalog.
Remote preparation and GitHub refresh require an explicit network confirmation
and can be cancelled.

## Messages media runtime

The global worker contains two separate parsers: Slack-style shortcodes and
Messages-only `/sticker` and `/gif` commands. A media query is debounced, bound
to the same focused target and expected token, and displayed in a
non-activating keyboard-navigable grid beside the caret. Arrow keys and Tab
move selection, Return resolves and inserts the original, and Escape cancels.

Enabled custom-pack image results share `:query`, exact `:name:`, and `::`
browsing with Unicode results, but their insertion is allowed only when the
captured target is Messages. Immediately before paste, the managed resolver
repeats the root-containment, symlink, regular-file, non-empty, 25 MiB,
SHA-256, and magic-byte checks against the imported asset. Remote downloads
are likewise size-, content-type-, and signature-checked. Failure leaves the
source token intact and publishes a copy-fallback diagnostic.

## Network boundaries

Every online feature has its own preference and defaults to off:

- public GitHub pack imports;
- online Noto sticker search;
- GIPHY search;
- signed update checks.

The offline Noto subset and built-in Unicode catalog require no network.
Selected online Noto originals may use the bounded on-demand disk cache. The
GIPHY client attaches the provider-required customer identifier and retains
provider analytics URLs in result metadata, but the runtime intentionally does
not invoke optional analytics operations or log requests and queries. GIPHY
search, preview, and media sessions are ephemeral with URL caching disabled.
The runtime downloads the selected GIPHY original directly for insertion and
does not put it in the disk cache, proxy it, or rewrite the provider’s media
URL. `Powered by GIPHY` remains visible on GIPHY result surfaces.

Update checking requires both an HTTPS feed and a bundled trusted public key.
Manual checks are available from the status menu and About settings;
automatic checking runs at startup only after the user enables its preference.
The checker limits the feed to 1 MiB by default and verifies its Ed25519 or
P-256 signature before decoding the release metadata.

A newer verified build can be downloaded only after a separate user action.
The staging boundary:

1. requires the signed byte count to fit the 512 MiB local cap;
2. streams no more than that signed count over HTTPS, then checks the exact
   byte count and SHA-256 digest;
3. writes the ZIP into an app-private `0700` temporary directory;
4. treats the authenticated archive as hostile, applying ZIP limits and
   accepting exactly one `MojiPond.app` with no unrelated payload;
5. verifies bundle identifier, version, and build metadata; and
6. requires both the running and candidate apps to pass strict Developer ID
   Application signature validation, Hardened Runtime, secure timestamp,
   Gatekeeper assessment, and the same Team ID.

These requirements deliberately block a local ad-hoc build from staging an
update. Another explicit **Install & Relaunch** confirmation repeats the
archive digest, bundle, signature, version, build, and identity checks. The
verified candidate starts the installer mode of its own executable; MojiPond
does not ship a helper, daemon, or privileged component.

The installer accepts only the authenticated staging directory and exact
installed-app destination. A private, one-time authorization record binds the
handoff to the running app and exact staged candidate; the command-line payload
alone is insufficient. The installer rejects symlinks and path confusion,
acquires a non-following sibling lock, consumes that authorization, waits for
the old PID, takes over the private staging lease, and rechecks the signed
archive and both app identities. Expired staging directories are removed only
when their leases are unlocked. Aged sibling artifacts with exact updater
names are removed only after they pass the same bundle and code-identity
validation as the running app.

The installer copies the candidate to a unique sibling, verifies that copy,
renames the candidate and current app with one atomic exchange, moves the
displaced app to a unique backup name, and verifies the final bundle before
launch. The new app must finish normal service and status-item startup before
writing the expected token to a private readiness channel. Only then may the
installer remove the backup and staging directory. Any failure after the
exchange terminates the attempted launch, restores the backup, and re-verifies
the restored app.

Only an unwritable destination parent enables the honest Finder/manual
replacement fallback. Unsafe paths, signature or identity failures, lock
contention, timeouts, and failed rollback remain hard failures.

## Testing boundaries

Most core and safety behavior is dependency-injected and covered without
global permissions: fake Accessibility targets, permission providers, event
monitors, pasteboards, HTTP transports, caches, signed feeds, update assets,
archive extraction, and code-signature identities. Portable-format tests cover
v1 compatibility, v2 mixed content, validation, and round trips. Library UI
tests cover custom Unicode creation, search, rejection, and clipboard output.
Update tests cover bounded download, digest checks, archive layout, app
metadata, signature policy, same-team policy, installer handoff validation,
copy and rename failures, final verification, relaunch readiness, rollback,
lock contention, and conservative stale cleanup. Those tests prove
deterministic behavior at module boundaries, not compatibility with every
third-party editor, a live TCC session, or a real notarized release.
Manual evidence is tracked separately in
[COMPATIBILITY.md](COMPATIBILITY.md).
