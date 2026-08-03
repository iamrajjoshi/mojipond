# Privacy

MojiPond processes autocomplete locally. First-run setup shows the crash and
hang reporting choice before Sentry starts. It defaults to on and can be
disabled there or later in **Settings → Privacy**. Online sticker search and
automatic update checks default to off. This document describes the current
source implementation; it does not replace macOS’s permission dialogs.

## What MojiPond observes

When enabled and granted Input Monitoring, macOS delivers keyboard and mouse
events to MojiPond’s session event tap while other applications are active.
MojiPond copies the key code, event type, modifier flags, timestamp, and the
single-character interpretation needed by its bounded parser. The event tap
also sees mouse-down events so it can cancel an active suggestion session.

Parsing and search happen on the Mac. MojiPond does not persist raw keystrokes,
message text, or clipboard history, and it does not read the Messages database.
It retains only a bounded shortcode candidate in memory while a session is
active. The default maximum shortcode length is 64 bytes. The candidate stays
in memory until you finish or dismiss the picker, change focus, move the caret,
or quit MojiPond.

Accessibility is used to:

- identify the focused process and editable element;
- prove that the element is not a secure text field;
- read at most 66 UTF-16 code units immediately before the caret when the
  target supports ranged reads;
- obtain caret bounds for the non-activating suggestion panel;
- revalidate and replace the exact selected shortcode;
- identify a supported browser’s address-bar host only when website exclusions
  are configured.

For controls without ranged text access, MojiPond reads the complete value only
after proving it contains no more than 4,096 UTF-16 code units. Larger controls
without ranged access are left untouched.

## System permissions

| Permission | Scope in MojiPond |
| --- | --- |
| Input Monitoring | Global key events for shortcode parsing and suggestion navigation |
| Accessibility | Focused-control safety checks, bounded text context, caret placement, exact replacement, and configured browser exclusions |
| Event Posting (shown as Image emoji in Messages) | Tagged Command-V for custom-image insertion and Return after a confirmed shortcode replacement; optional for Unicode emoji |

Permission checks are preflight-only during normal startup. A system prompt is
requested only after an explicit Allow action in onboarding or settings.
MojiPond records whether it previously requested or received each permission
so it can distinguish not-requested, denied, granted, and later-revoked states.

These macOS permissions are inherently powerful. Grant them only to a build
you trust. Keep the app at a stable `/Applications/MojiPond.app` path and review
access at any time in **System Settings → Privacy & Security**.

MojiPond does not request Screen Recording, Full Disk Access, Contacts,
Microphone, Camera, or access to the Messages database.

The current app is not App Sandbox-enabled. That does not bypass TCC:
Input Monitoring and Accessibility require explicit macOS approval for typing
shortcuts. Event Posting requires separate approval for custom-image insertion
in Messages and for replaying Return after an accepted replacement. The
validation and fail-closed boundaries in this document are part of the app’s
security model rather than sandbox-enforced file or network restrictions.

## Stored data

MojiPond stores:

| Data | Location | Purpose |
| --- | --- | --- |
| Custom pack metadata and copied assets | `~/Library/Application Support/MojiPond/Library/` | Keep imported packs available independently of their source |
| Import staging | `~/Library/Application Support/MojiPond/Import Staging/` | App-owned preparation area |
| Recency and use counts | `~/Library/Application Support/MojiPond/usage.json` | Local ranking and recents |
| Online Noto media cache | `~/Library/Caches/MojiPond/Media/` | Bounded on-demand storage for selected Noto originals |
| Sentry diagnostic cache | `~/Library/Caches/MojiPond/Sentry/io.sentry/` | Pending crash and hang diagnostics stored by Sentry Cocoa |
| Update files | Sparkle-managed cache and temporary locations | Signed appcast data and an update being downloaded or installed |
| Preferences and permission-request history | macOS `UserDefaults` for `com.rajjoshi.MojiPond` | Settings and permission UI state |

Usage records contain emoji identity, use count, and recency—not the surrounding
message. There is no account or background cloud synchronization.

Current builds do not create or use media-provider API keys. On first launch
after an older GIPHY-capable development build, MojiPond removes the local GIPHY
customer identifier and enablement preference, then deletes the legacy
generic-password item for service `com.rajjoshi.MojiPond` and account
`giphy-api-key`. None of these values are read or transmitted. Local preferences
are removed even if Keychain is temporarily unavailable; the completion marker
stays unset so Keychain cleanup retries on the next launch.

Deleting the application does not automatically delete its Application Support
data, caches, or preferences. When upgrading from an older development build,
launch the current app once to run the legacy Keychain cleanup before deleting
it. Remove the remaining locations separately if you want to erase all local
state.

## Clipboard behavior

Unicode normally uses direct Accessibility replacement and does not touch the
clipboard.

For image or rich-editor paste insertion, MojiPond first captures every
pasteboard item and each advertised representation, up to a 32 MiB memory cap.
It temporarily writes the payload, revalidates the exact token, posts
Command-V to the validated target process, and restores the complete snapshot
after a short delay. If another
process changes the clipboard during the transaction, MojiPond does not
overwrite that newer content. If the initial snapshot cannot be captured
completely, the temporary paste is not attempted.

When Return was intercepted while a shortcode replacement was still
completing, MojiPond revalidates the same target and posts one tagged Return
after insertion. Escape revokes that pending send.

The insertion engine exposes a non-mutating copy-fallback result. When it
includes an already-validated media payload, MojiPond shows **Copy Media
Instead** in its status menu. That explicit action replaces the clipboard
permanently so the user can paste the copied media manually.

## Network features

Online sticker search and automatic update checks have independent preferences
and default to off. Manual update checks run only when requested. Crash and hang
reporting defaults to on, but Sentry does not start on a fresh install until
the user finishes first-run setup with that choice enabled. Turning it off
stops future collection; a report captured before opt-out may still be queued
or finish sending, and a report already transmitted cannot be recalled.

| Feature | Data sent | Destination |
| --- | --- | --- |
| Crash and hang reporting | Crash or hang diagnostics, including stack traces and app/runtime context | Sentry |
| Online sticker search | No query; MojiPond downloads a fixed Noto Animated Emoji manifest, filters it locally, and requests only the selected asset | Google’s Noto Animated Emoji manifest and asset hosts |
| Sparkle update check | Standard HTTPS request metadata; system profiling is disabled | `mojipond.com` |
| Sparkle update download | Standard HTTPS request metadata | The tag-specific GitHub Release URL named by the signed appcast |

MojiPond does not attach typing, clipboard contents, screenshots, view
hierarchy, or emoji files to Sentry reports. The SDK is configured not to send
usage analytics, performance tracing, profiling, default PII, network
breadcrumbs, failed-request capture,
sessions, client outcome reports, metrics, or logs. Sentry’s network transport
necessarily receives standard request metadata, including the source IP
address. IP storage is a separate Sentry project setting and must be disabled
there; the app cannot enforce that server-side setting.

The current import UI accepts one local ZIP at a time and makes no network
request. The archive may contain a portable manifest, a simple image folder, or
a Slack-style manifest with local assets. Remote asset URLs are not fetched,
and the retained GitHub import client has no public UI entry point.

Manual update checks are user-initiated. Automatic checking runs only after
the user enables it. Both paths stop when the app lacks its bundled HTTPS
appcast URL or Ed25519 public key. Sparkle 2.9.5 reads
`https://mojipond.com/releases/appcast.xml`, requires a signed feed, and checks
the selected release's Ed25519 enclosure signature before extraction. Sparkle
system profiling is disabled. Automatic update download and installation
default to off; the standard Sparkle prompt asks before installation and can
offer its own saved preference.

MojiPond delegates download, extraction, installation, and rollback to Sparkle.
The appcast points to the final notarized ZIP attached to a tagged GitHub
Release rather than a mutable Pages asset.

Imported image bytes and filenames can be stored locally as managed pack
assets. Selected online Noto originals may use the bounded on-demand cache.
HTTPS responses, redirects, sizes, and file types are validated before an
online Noto asset or update is accepted. Import paths and archive expansion are
validated before installation. Selected ZIPs are prepared only from a private,
read-only staging snapshot that is removed afterward.

## Crash reporting and local diagnostics

MojiPond does not operate a first-party analytics endpoint or collect usage
analytics. It uses Sentry Cocoa 9.24.0 for opt-out crash and hang reporting.
First-run setup discloses the data categories and offers a default-on toggle
before the SDK starts. The same setting remains in **Settings → Privacy**.

Runtime diagnostics kept inside the app are coarse states such as permission
unavailable, unsupported target, excluded context, or event-tap timeout. They
do not include the typed token or document text.

## Safety defaults

MojiPond suspends itself when Secure Event Input is active, when a focused
field is secure, or when security status cannot be proven. It also ships with
default exclusions for MojiPond itself, common password managers, terminals,
virtual-machine or remote-desktop clients, and chat apps with native emoji
shortcuts. Users can add application and browser-domain exclusions.

The parser, Accessibility capture, and insertion request carry transaction
identities. A focus, selection, target, or token change causes the operation to
fail closed.
