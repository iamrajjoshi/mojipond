# Compatibility and verification ledger

This is an evidence ledger, not a marketing compatibility list. Update a row
only after preserving the evidence named in its notes.

## State definitions

- **Pending** — not yet proven at the required boundary, even if related code
  exists.
- **Automated** — covered by deterministic tests that passed in the most recent
  recorded local suite; this does not prove behavior in a real third-party app.
- **Manually verified** — exercised through the named real build, application,
  OS, or packaging boundary. Automated coverage may also exist.

Local verification environment for this snapshot:

```text
Date: 2026-07-28
Hardware: Apple silicon (arm64)
macOS: 26.3.1 (25D2128)
Xcode: 26.5 (17F42)
XcodeGen: 2.46.0
Signing identities installed: none
```

## Build and distribution

| Capability | State | Evidence or remaining proof |
| --- | --- | --- |
| macOS 14 deployment target | Automated | `project.yml` sets `MACOSX_DEPLOYMENT_TARGET=14.0`; runtime launch on macOS 14 remains pending |
| Debug build on the environment above | Automated | Final warnings-as-errors test build completed successfully on 2026-07-28 |
| Unit test suite on the environment above | Automated | 384 executed: 383 passed, 0 failed, and 1 intentionally gated live-network test skipped; the same Bufo test passed separately against the real repository |
| Universal Release binary (`arm64` + `x86_64`) | Manually verified | The 2026-07-28 local Release archive passed strict code-signature verification; `lipo -archs` reported `x86_64 arm64`, both slices declare macOS 14.0 minimum, and the ad-hoc signature carries Hardened Runtime |
| Xcode archive, ZIP, DMG, and SHA-256 output | Manually verified | `MojiPond-20260728T090608Z-local` was independently checked: SHA-256 verification passed (`6f241377…` ZIP, `6e517d63…` DMG), the metadata-free ZIP tested clean and expanded to exactly one byte-identical `MojiPond.app`, and the read-only DMG verified, mounted, and contained the same valid app plus an `/Applications` link |
| Launch from `/Applications` with ad-hoc signing | Manually verified | The current Universal Release build was installed at `/Applications/MojiPond.app`, its strict signature verified, and the process launched successfully on the environment above. The bundle contains one executable, reports `x86_64 arm64`, and carries an ad-hoc Hardened Runtime signature |
| Developer ID signing | Pending | No Developer ID Application identity is installed |
| Apple notarization and stapling | Pending | Requires Developer ID signing and Apple notary credentials |
| Clean-clone build | Manually verified | A new private-repository clone at `cfcbaa7` passed XcodeGen, all 374 deterministic test executions (373 passed and one intentional live-network skip), `./scripts/build.sh Debug`, strict signature verification, and all three signed-feed generator groups; the temporary checkout was clean and removed afterward |
| GitHub Actions | Manually verified | CI run `30345666439` on exact commit `9e33097` passed the secret scan, project generation, build, deterministic tests, and signed-feed generator on `macos-26` |

## Global autocomplete and safety

| Capability | State | Evidence or remaining proof |
| --- | --- | --- |
| Bounded shortcode parser and exact closing token | Automated | Parser tests cover timeout, reset, maximum length, modifiers, double trigger, and exact replacement actions |
| Deterministic search, aliases, ranking, usage, and tones | Automated | Core catalog/search/usage tests |
| Constant-time event callback boundary | Automated | Event-tap and interception-gate tests |
| Caret popup positioning and display clamping | Automated | Positioner and runtime presentation tests; physical multi-display proof remains pending |
| Secure Event Input and secure-field denial | Automated | Safety and secure-context tests |
| Unknown app or security state fails closed | Automated | Runtime safety tests |
| Default and custom application exclusions | Automated | Preferences and runtime safety tests |
| Safari and Chromium domain exclusions | Automated | Browser address-bar normalization and bounded AX traversal tests |
| Exact target, selection, and token revalidation | Automated | Accessibility adapter and runtime worker tests |
| Clipboard snapshot, restoration race, and GIF-byte preservation | Automated | Pasteboard and insertion-engine tests |
| Unicode replacement in an unsent Messages draft | Pending | Requires user-granted TCC permissions and a manual Messages check |
| Unicode replacement in TextEdit and Notes | Pending | Real-app checks not yet recorded |
| Rich-editor Unicode fallback | Pending | Requires a real supported editor check |
| Password or secure field in a real app | Pending | Automated only; no real-app check recorded |
| Browser exclusion in live Safari and Chrome | Pending | Automated only; no real-browser check recorded |

## Packs and imports

| Capability | State | Evidence or remaining proof |
| --- | --- | --- |
| PNG, JPEG, GIF, and WebP validation | Automated | ImageIO validation tests cover formats, dimensions, frames, mismatch, and corrupt data |
| Individual-file and recursive-folder scan | Automated | Scanner tests cover normalization, ignored files, symlinks, depth, and limits |
| Portable `mojipond.json` schema v1 and v2 | Automated | Portable-manifest tests cover legacy v1 file packs, v2 `file`/`unicode` exclusivity, mixed folder import, Unicode sequences, path validation, and export round trips |
| Hardened ZIP extraction | Automated | ZIP tests cover traversal, symlinks, duplicates, sizes, and compression limits |
| Slack maps, arrays, aliases, and cycles | Automated | Slack manifest and orchestration tests |
| ZIP source-snapshot boundary | Automated | Focused ZIP suite passed 10/10 with warnings-as-errors: bounded `O_NOFOLLOW` snapshot copy, read-only permissions, closed extractor stdin, Unicode filenames, noisy stderr, exact-tree verification, and cleanup |
| Remote Slack local-network denial | Automated | Public-address checks cover the initial HTTPS request and every redirect; the final deterministic suite passed |
| Public GitHub ref resolution and archive policy | Automated | Mocked HTTP, redirect, size, ref, and subdirectory tests |
| Collision decisions and duplicate-content preview | Automated | Import and library tests |
| Atomic library install, edit, replacement, removal, and migration | Automated | Actor store tests |
| Custom Unicode creation, search, copy, and portable export | Automated | Store tests cover collision-safe creation, validation, digesting, Unicode-only export, and mixed round trips; Library ViewModel tests cover creation, alias search, rejection, and clipboard bytes |
| Library import workflow in the running app | Pending | Full browse, edit, import-preview, conflict-resolution, install, export, and GitHub-refresh UI is connected; a manual running-app check is not yet recorded |
| Real `knobiknows/all-the-bufo` import | Manually verified | Gated live XCTest on 2026-07-28 fetched the public repository, resolved its revision, validated 1,000+ assets including `bufo-fußball.png`, exposed normalized-name conflicts, installed with explicit keep-first/drop-alias decisions, and removed its workspace in 17.5 seconds. The repository audit found no detected license or redistribution grant, so its artwork is neither bundled nor redistributed |

## Messages media commands

| Capability | State | Evidence or remaining proof |
| --- | --- | --- |
| Messages-only `/sticker` and `/gif` parsing | Automated | Parser tests cover app gating, query limits, timeout, cancellation, and modifiers |
| Offline Noto manifest and bundled GIF integrity | Automated | Manifest, hash, attribution, and lookup tests |
| Opt-in online Noto state machine | Automated | Coordinator tests use controlled provider doubles |
| Opt-in GIPHY search | Automated | HTTP client and coordinator tests use mocked responses; no live key test |
| GIPHY attribution, privacy, and no-cache constraint | Automated | Runtime intentionally omits optional analytics and request/query logging, displays attribution, uses ephemeral non-caching sessions, downloads a selected original directly, and rejects GIPHY at the disk-cache boundary |
| Live GIPHY key and production provider review | Pending | No live-key test or production approval is recorded |
| Media download validation and Noto-only cache | Automated | Downloader/cache tests cover HTTPS, content type, limits, cancellation, atomic cache behavior, and GIPHY rejection |
| Managed custom-media insertion validation | Automated | Resolver tests cover root containment, symlink escape, regular files, size, digest, magic bytes, and original animated bytes |
| `/sticker` grid and GIF insertion in an unsent Messages draft | Pending | Command parser, grid, resolver, and insertion engine are connected to the global runtime and covered by the 384-test suite; a manual Messages check still needs to be recorded |
| Custom PNG insertion in an unsent Messages draft | Pending | Managed-media resolution is connected to shortcode selection and covered by the 384-test suite; a manual Messages check with TCC permission still needs to be recorded |
| Custom animated GIF remains animated in Messages | Pending | Clipboard bytes are tested; end-to-end Messages behavior is not |
| Clipboard unchanged after Messages media insertion | Pending | Restoration engine is automated; real-app paste race is not |
| User-visible **Copy Media Instead** recovery | Pending | Status-menu action and notice are connected and covered by the 384-test suite; a manual clipboard check still needs to be recorded |

## UI and accessibility quality

| Capability | State | Evidence or remaining proof |
| --- | --- | --- |
| Onboarding permission states and library-only path | Automated | App-state and permission-center tests |
| Installed Release permission preflight | Manually verified | `/Applications/MojiPond.app --print-permissions-and-quit` reported Accessibility, Input Monitoring, and Event Posting granted after the final Release install; denial, revocation, and re-grant still require an interactive System Settings audit |
| Settings persistence and legacy migration | Automated | Preferences-store tests |
| GIPHY Keychain settings editor | Pending | Secure add, replace, status, and remove UI is connected; the current suite and a manual Keychain check still need to be recorded |
| Keyboard navigation of suggestion surface | Automated | Runtime keyboard, parser, and worker tests |
| VoiceOver labels and traversal | Pending | Deterministic tests cover runtime preview labels, selected-state announcements, loading, and failure semantics; an interactive VoiceOver traversal audit is not yet recorded |
| Light and dark appearance | Pending | No screenshot audit recorded |
| Reduced Motion | Automated | Runtime animated media falls back to a validated static first frame and interaction transitions disable animation; deterministic policy tests passed, while a manual setting audit remains pending |
| Reduced Transparency and increased contrast | Automated | Runtime surfaces provide solid-material and stronger-border fallbacks and adaptive colors; source and build verification passed, while a manual setting audit remains pending |
| Window resizing and smallest supported size | Automated | Onboarding, Library, and Settings use scrollable or adaptive layouts with explicit minimum sizes; both UI-test schemes compiled, while an unlocked screenshot and interaction audit remains pending |
| Multi-display and scaled-display behavior | Pending | Geometry is automated; physical displays are not |

## Performance

| Capability | State | Evidence or remaining proof |
| --- | --- | --- |
| Installed-app idle CPU and memory | Manually verified | Five one-second `top` samples of the installed Universal Release build on 2026-07-28 measured 0.0–0.3% CPU, 33 MiB resident memory, and seven threads; every sample reported the process sleeping |
| Event-tap callback time | Pending | The callback boundary is structurally bounded and covered by deterministic tests, but an actual callback-duration measurement has not yet been recorded |
| Warm suggestion latency | Pending | Search and presentation paths are covered by deterministic tests, but an unlocked real-caret measurement has not yet been recorded |

## Update safety

| Capability | State | Evidence or remaining proof |
| --- | --- | --- |
| HTTPS-only feed and redirect policy | Automated | Signed-update checker tests |
| Ed25519 and P-256 signature verification before decode | Automated | CryptoKit verification tests |
| Signed asset byte count, local size cap, and SHA-256 validation | Automated | Stager tests cover exact-size and digest mismatch, signed-count streaming cap, 512 MiB local cap, and no-download rejection |
| Hardened single-app update ZIP | Automated | Archive tests cover traversal, symlinks, extra root payload, multiple apps, release-style ZIPs, entry/size/ratio limits, and exact extracted-tree verification |
| Developer ID, Hardened Runtime, timestamp, Gatekeeper, and same-team policy | Automated | Stager policy tests use controlled signature identities; both the running and candidate apps must pass, so an ad-hoc current app is rejected by design |
| Explicit one-executable installation plan | Automated | Stager/controller tests require fresh confirmation and revalidation before launching the verified candidate in installer mode |
| Automatic checks off without feed, key, and opt-in | Automated | Disabled-path tests |
| Manual check, opt-in startup check, and newer-version UI state | Automated | App update-controller tests use controlled checker results |
| Minimum-system-version validation and gating | Automated | Checker rejects malformed versions; controller and stager tests reject a signed release requiring a newer macOS version |
| Production feed, embedded public key, and expected Team ID | Pending | No production update configuration exists |
| Staging a real notarized release from a Developer ID build | Pending | Requires a production-signed current app, a same-team notarized candidate, configured feed/key/Team ID, and a live Gatekeeper check |
| Locked atomic replacement and rollback | Automated | Installer tests cover strict paths/identity, archive linkage, old-PID timeout, copy/exchange/rename/final-verify/launch/readiness failures, rollback, lock contention, staging-lease takeover, and conservative stale cleanup |
| Real Developer ID install-and-relaunch | Pending | Requires a production-signed current app, same-team notarized candidate, configured signed feed, writable destination, final-app readiness acknowledgement, and a live Gatekeeper check |
| Manual Finder fallback for unwritable destination | Automated | Controller/installer policy tests limit the fallback to destination-parent permission failure; a live protected destination check is not yet recorded |
