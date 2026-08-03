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
Date: 2026-08-02
Hardware: Apple silicon (arm64)
macOS: 26.3.1 (25D2128)
Xcode: 26.5 (17F42)
XcodeGen: 2.46.0
Signing identities installed: none
```

## Build and distribution

| Capability | State | Evidence or remaining proof |
| --- | --- | --- |
| macOS 13 deployment target | Automated | `project.yml` sets `MACOSX_DEPLOYMENT_TARGET=13.0`; CI and release verification reject an app whose Info.plist or either executable slice declares a different minimum. A runtime launch on macOS 13 still needs to be recorded |
| Debug build on the environment above | Automated | Final warnings-as-errors test build completed successfully on 2026-08-02 |
| Unit test suite on the environment above | Automated | 443 executed on 2026-08-02: 442 passed, 0 failed, and 1 intentionally gated live-network test skipped; the same Bufo test passed separately against the real repository. The adaptive-glyph group remains covered, including first-frame conversion, cache, priority, coalescing, supersession, and deferred preparation |
| Universal Release binary (`arm64` + `x86_64`) | Automated | A fresh 2026-08-02 Release build passed strict code-signature verification and `verify-app-compatibility.sh`: the main executable and every bundled framework/helper contain both architectures, Info.plist declares macOS 13.0, and no slice requires a newer system. Runtime testing on a physical Intel Mac remains pending |
| Xcode archive, ZIP, DMG, metadata, and SHA-256 output | Manually verified | `MojiPond-20260728T095411Z-local`, built from immutable snapshot `8c5eb77`, was independently checked: SHA-256 verification passed (`325e4a79…` ZIP, `103ed3f9…` DMG, `deb898ef…` metadata), metadata records the exact clean revision and branch, the metadata-free ZIP tested clean and expanded to exactly one byte-identical `MojiPond.app`, and the read-only DMG verified, mounted, and contained the same valid app plus an `/Applications` link |
| Launch from `/Applications` with ad-hoc signing | Manually verified | The `8c5eb77` Universal Release was installed at `/Applications/MojiPond.app`, compared byte-for-byte with the verified archive, and launched successfully on the environment above. The current static-glyph Release was subsequently installed and launched at the same path; its strict signature verifies, it reports `x86_64 arm64`, and all three permission preflights remain granted |
| Developer ID signing | Pending | No Developer ID Application identity is installed |
| Apple notarization, stapling, and Gatekeeper distribution | Pending | No Developer ID identity or Apple notary credentials are installed. Gatekeeper is enabled and correctly rejected the personal ad-hoc build (`spctl` exit 3), so this artifact must not be described as public-distribution ready |
| Clean-clone build | Manually verified | A new private-repository clone at exact commit `8c5eb77` passed XcodeGen, all 384 deterministic test executions (383 passed and one intentional live-network skip), and `./scripts/build.sh Debug`; the temporary checkout remained clean and was removed afterward |
| GitHub Actions | Manually verified | CI run `30348478490` on exact commit `8c5eb77` passed the secret scan, checksum-pinned XcodeGen bootstrap, project generation, build, and deterministic tests on `macos-26` |

## Global autocomplete and safety

| Capability | State | Evidence or remaining proof |
| --- | --- | --- |
| Bounded shortcode parser and exact closing token | Automated | Parser tests cover persistent and optional-timeout sessions, reset, boundaries, maximum length, modifiers, double trigger, and exact replacement actions |
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
| Unicode replacement in Mail | Pending | Real-app check not yet recorded |
| Native fields and browser content-editable fields | Pending | The native Accessibility integration fixture passed 2/2 on 2026-07-30; real Safari and Chrome content-editable checks are not yet recorded |
| Rich-editor Unicode fallback | Pending | Requires a real supported editor check |
| Password or secure field in a real app | Pending | Automated only; no real-app check recorded |
| Browser exclusion in live Safari and Chrome | Pending | Automated only; no real-browser check recorded |
| Chat, password-manager, remote-client, and terminal exclusions | Pending | Default-exclusion policy is automated; representative checks against installed apps are not yet recorded |
| User-added excluded app and domain | Pending | Preference and matching logic are automated; real excluded-app and excluded-domain checks are not yet recorded |
| US and non-US keyboard layouts | Pending | Parser behavior is automated independently of layout; manual US and at least one non-US layout check are not yet recorded |
| App, focus, target, and caret changes while open | Pending | Cancellation and stale-target paths are automated; manual cross-app and caret-movement checks with a visible panel are not yet recorded |
| Spaces and fullscreen | Pending | Geometry is automated; manual Space and fullscreen checks are not yet recorded |

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
| Custom Unicode creation, search, copy, and portable export | Automated | Store tests cover collision-safe creation, validation, digesting, Unicode-only export, and mixed round trips; Library ViewModel tests cover alias search and clipboard bytes for imported Unicode entries |
| Library ZIP import workflow in the running app | Pending | The public UI accepts one local ZIP through the picker or drag and drop, then presents preview, conflict resolution, install, export, and ZIP replacement; a manual running-app check is not yet recorded |
| Manual ZIP import and replacement | Pending | ZIP extraction, portable/simple-folder/Slack-local parsing, conflicts, and replacement are covered by deterministic scanner/orchestrator tests; interactive running-app checks are not yet recorded |
| Manual failed and cancelled ZIP imports | Pending | Failure, cancellation, and cleanup behavior are automated; interactive running-app checks are not yet recorded |
| Real `knobiknows/all-the-bufo` engine import | Manually verified | This verifies the retained importer engine, not a public import entry point. A gated live XCTest on 2026-07-28 fetched the repository, resolved its revision, validated 1,000+ assets including `bufo-fußball.png`, exposed normalized-name conflicts, installed with explicit keep-first/drop-alias decisions, and removed its workspace in 17.5 seconds. The repository audit found no detected license or redistribution grant, so its artwork is neither bundled nor redistributed |

## Messages custom-image insertion

| Capability | State | Evidence or remaining proof |
| --- | --- | --- |
| Managed custom-media insertion validation | Automated | Resolver tests cover root containment, symlink escape, regular files, size, digest, magic bytes, and original animated bytes |
| Static and animated custom-image adaptive glyph conversion | Automated | macOS-15 tests round-trip static images and frame 0 of animated assets through metadata-bearing HEIC and RTFD as one `NSAdaptiveImageGlyph`. The source animation remains stored unchanged; macOS 13 and 14, plus rejected conversions on newer systems, retain the media fallback, including **Copy Media Instead** for failed animated WebP conversion. The successful glyph item omits raw photo representations |
| Custom PNG insertion in an unsent Messages draft | Pending | Static glyph conversion and managed-media fallback have automated coverage; a manual inline-glyph check with TCC permission still needs to be recorded |
| Custom animated image inserts frame 0 as an inline glyph in Messages | Pending | First-frame conversion is automated; an unsent-draft check must confirm that the static glyph resizes with surrounding text while the stored source remains animated |
| Clipboard unchanged after Messages media insertion | Pending | Restoration engine is automated; real-app paste race is not |
| Messages cancellation and target switch during commit | Pending | Cancellation, transaction IDs, and stale-target revalidation are automated; an unsent-draft check that cancels and switches the focused app/target during commit is not yet recorded |
| User-visible **Copy Media Instead** recovery | Pending | Status-menu action and notice have automated coverage; a manual clipboard check still needs to be recorded |

## UI and accessibility quality

| Capability | State | Evidence or remaining proof |
| --- | --- | --- |
| Onboarding permission states and library-only path | Manually verified | The unlocked app UI suite passed 8/8 on 2026-07-30, rendering onboarding, not-requested, denied, granted, revoked, and library-only states without opening System Settings or requesting TCC access; it also exercised both onboarding-to-Library routes and the Settings-to-Library route |
| First-run Sentry choice | Automated | The onboarding UI test requires the crash-reporting disclosure and default-on toggle, exercises opt-out, and the launch-policy tests keep Sentry stopped until setup finishes |
| Installed Release permission preflight | Manually verified | `/Applications/MojiPond.app --print-permissions-and-quit` reported Accessibility, Input Monitoring, and Event Posting granted after the final Release install; denial, revocation, and re-grant still require an interactive System Settings audit |
| First install, denial, grant, revocation, re-grant, and relaunch | Pending | The UI suite now proves every rendered state and the installed app currently preflights all three permissions as granted; changing real TCC state still requires explicit user action in System Settings and has not been recorded |
| Settings persistence and legacy migration | Automated | Preferences-store tests cover schema migration plus one-time, retriable deletion of the unused legacy provider credential without reading its value |
| Keyboard navigation of suggestion surface | Automated | Runtime keyboard, parser, and worker tests |
| VoiceOver labels and traversal | Pending | Deterministic tests cover runtime preview labels, selected-state announcements, loading, and failure semantics. The unlocked UI suite additionally requires exactly one accessible `Import ZIP` action and permission-specific action labels; an interactive spoken VoiceOver traversal is still pending |
| Light and dark appearance | Manually verified | The current ZIP-only import surface passed its focused unlocked UI test in both forced appearances on 2026-07-29; both captures were visually reviewed and replaced the former multi-source screenshots |
| Required documentation screenshot set | Pending | Library, ZIP import, Settings, preview, caret-suggestion, browser, permission, and native-fixture captures are current. The simplified setup and practice screens are covered by the deterministic UI suite; a real unsent-Messages first-frame glyph capture is still required |
| Reduced Motion | Automated | Runtime animated media falls back to a validated static first frame and interaction transitions disable animation; deterministic policy tests passed, while a manual setting audit remains pending |
| Reduced Transparency and increased contrast | Automated | Runtime surfaces provide solid-material and stronger-border fallbacks and adaptive colors. Deterministic tests verify warning/error text at 4.5:1 or greater against native light, dark, and high-contrast backgrounds; a manual setting audit remains pending |
| Window resizing and smallest supported size | Pending | Onboarding, Library, and Settings use scrollable or adaptive layouts with explicit minimum sizes. The ZIP-only Library/import surface passed a fresh unlocked UI run; interactive resizing across the full range remains pending |
| Multi-display and scaled-display behavior | Pending | Geometry is automated; physical displays are not |

## Performance

| Capability | State | Evidence or remaining proof |
| --- | --- | --- |
| Installed-app idle CPU and memory | Manually verified | Five one-second `top` samples of the installed `8c5eb77` Universal Release on 2026-07-28 measured 0.0–0.6% CPU, 30 MiB resident memory, and seven threads; every sample reported the process sleeping |
| Event-tap callback time | Pending | The callback boundary is structurally bounded and covered by deterministic tests, but an actual callback-duration measurement has not yet been recorded |
| Warm suggestion latency | Pending | Search and presentation paths are covered by deterministic tests, but an unlocked real-caret measurement has not yet been recorded |

## Update safety

| Capability | State | Evidence or remaining proof |
| --- | --- | --- |
| Sparkle 2.9.5 dependency pin | Automated | `project.yml` pins the package exactly and package resolution is part of the build |
| HTTPS appcast and Ed25519 public-key configuration | Automated | Configuration tests reject a non-HTTPS feed, missing host, and public keys that are not 32 bytes |
| Signed feed and pre-extraction verification settings | Automated | The built Info property list enables `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction`; Sparkle system profiling is disabled |
| Manual and daily automatic checks | Automated | Controller tests cover one-time Sparkle startup, live check availability, manual checks, the daily default, and preference propagation after opt-out or opt-in |
| Signed stable appcast at `mojipond.com` | Pending | The Pages workflow and signed placeholder must deploy, then the live endpoint needs an HTTP and XML check |
| Release appcast generated from final notarized ZIP | Pending | Requires the first protected release run with `SPARKLE_EDDSA_PRIVATE_KEY` and inspection of the draft assets |
| Real Developer ID update and relaunch | Pending | Requires two published same-channel builds, a clean Mac, and a live update through Sparkle's standard prompt |
