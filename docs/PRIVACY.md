# Privacy

MojiPond is designed as a local utility with narrowly separated, opt-in network
features. This document describes the current source implementation; it is not
a substitute for macOS’s own permission dialogs.

## What MojiPond observes

When enabled and granted Input Monitoring, macOS delivers keyboard and mouse
events to MojiPond’s session event tap while other applications are active.
MojiPond copies the key code, event type, modifier flags, timestamp, and the
single-character interpretation needed by its bounded parser. The event tap
also sees mouse-down events so it can cancel an active suggestion session.

Parsing and search happen on the Mac. MojiPond does not persist raw keystrokes,
message text, or clipboard history, and it does not read the Messages database.
It retains only a bounded shortcode candidate in memory while a session is
active. The default maximum shortcode length is 64 bytes and the default
inactivity timeout is three seconds.

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
| Event Posting | A tagged Command-V for media or rich-editor paste fallback |

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
Input Monitoring, Accessibility, and Event Posting still require explicit
macOS approval. It does mean the validation and fail-closed boundaries in this
document are part of the app’s security model rather than sandbox-enforced file
or network restrictions.

## Stored data

MojiPond stores:

| Data | Location | Purpose |
| --- | --- | --- |
| Custom pack metadata and copied assets | `~/Library/Application Support/MojiPond/Library/` | Keep imported packs available independently of their source |
| Import staging | `~/Library/Application Support/MojiPond/Import Staging/` | App-owned preparation area |
| Recency and use counts | `~/Library/Application Support/MojiPond/usage.json` | Local ranking and recents |
| Online Noto media cache | `~/Library/Caches/MojiPond/Media/` | Bounded on-demand storage for selected Noto originals; the GIPHY runtime path cannot use it |
| Verified update staging | Private `0700` directory below the macOS temporary directory | Verified ZIP stored with `0400` permissions and an extracted candidate app awaiting explicit installation or discard |
| Preferences and permission-request history | macOS `UserDefaults` for `com.rajjoshi.MojiPond` | Settings and permission UI state |
| GIPHY API key, when configured | Login Keychain, service `com.rajjoshi.MojiPond`, account `giphy-api-key` | Authenticate GIPHY requests |

Usage records contain emoji identity, use count, and recency—not the surrounding
message. There is no account or background cloud synchronization.

The Settings Keychain editor can add, replace, or remove the GIPHY key. It
reports only whether a key exists and never reads the saved value back into the
visible field.

Deleting the application does not automatically delete its Application Support
data, cache, preferences, or Keychain entry. Remove those separately if you
want to erase all local state.

## Clipboard behavior

Unicode normally uses direct Accessibility replacement and does not touch the
clipboard.

For image, GIF, or rich-editor paste insertion, MojiPond first captures every
pasteboard item and each advertised representation, up to a 32 MiB memory cap.
It temporarily writes the payload, revalidates the exact token, posts
Command-V to the validated target process, and restores the complete snapshot
after a short delay. If another
process changes the clipboard during the transaction, MojiPond does not
overwrite that newer content. If the initial snapshot cannot be captured
completely, the temporary paste is not attempted.

The insertion engine exposes a non-mutating copy-fallback result. When it
includes an already-validated media payload, MojiPond shows **Copy Media
Instead** in its status menu. That explicit action replaces the clipboard
permanently because the user then owns the manual paste.

## Network features

Every online feature has an independent preference and defaults to off.

| Feature | Data sent | Destination |
| --- | --- | --- |
| Public GitHub import | Repository owner/name, ref, and requested subdirectory | `api.github.com` and `codeload.github.com` |
| Online sticker search | No query; MojiPond downloads a fixed Noto Animated Emoji manifest, filters it locally, and requests only the selected asset | Google’s Noto Animated Emoji manifest and asset hosts |
| GIPHY search | Exact GIF query, API key, preview-rendition requests for displayed results, and the selected-original request | `api.giphy.com` and GIPHY media hosts |
| Signed update check | Standard HTTPS request metadata | The separately configured update-feed host |
| Verified update download | Standard HTTPS request metadata, only after the user selects **Download & Verify** | The download host authenticated by the signed feed metadata, including HTTPS redirect destinations |

Local folder, file, ZIP, portable-manifest, bundled Unicode, and offline Noto
lookups do not require a network request. A Slack manifest may refer to remote
HTTPS assets; those are fetched only when remote assets are explicitly allowed
for that import. Each request and redirect rejects credentials, custom ports,
localhost and `.local` names, and non-public IPv4 or IPv6 literals and DNS
answers.

MojiPond displays GIPHY creator and source attribution when the API supplies
it, alongside the official **Powered by GIPHY** mark. In keeping with
MojiPond's no-telemetry rule, GIPHY action analytics URLs are not invoked.
GIPHY media and media URLs are not persisted or placed in MojiPond's disk
cache. Provider approval and current-term review remain release gates before
shipping a GIPHY-enabled build.

Manual update checks are user-initiated. Automatic checking runs only after
the user enables it. Both paths are hard-disabled without a bundled HTTPS feed
URL and trusted public key. A successful check surfaces verified version and
release-notes metadata and does not download the app automatically.

Downloading a newer build is a second explicit action. The response is capped
at its signed byte count and a 512 MiB local limit, then checked against the
signed size and SHA-256 digest. MojiPond stores the verified ZIP and one
extracted `MojiPond.app` in a private temporary directory. Before the candidate
can be installed, both the running and candidate apps must pass strict
Developer ID Application, Hardened Runtime, secure-timestamp, Gatekeeper,
bundle-ID, and same-Team-ID checks. This deliberately blocks update staging
from a local ad-hoc build.

**Install & Relaunch** requires another explicit confirmation and a fresh
digest, bundle, and signature revalidation. The candidate's own executable
runs a locked installer mode, replaces the exact destination with a sibling
backup, launches the final app, and removes the backup and staging data only
after a private readiness acknowledgement. Failed replacement rolls back to
the verified previous build. If the destination parent is not writable, the
candidate can instead be revealed for manual replacement. Discarding the
download, cancelling, starting another check, or quitting before installer
handoff removes active staging. A private advisory lease prevents live staging
from being scavenged; expired, unlocked, exactly named crash residue is removed
without following symlinks.

Imported image bytes and filenames can be stored locally as managed pack
assets. Selected online Noto originals may use the bounded on-demand cache.
GIPHY results are an explicit exception: search, preview, and media sessions
are ephemeral with URL caching disabled, and a selected original is downloaded
directly for the insertion transaction without being stored in
`MediaDiskCache`, proxied, or rewritten. HTTPS responses, redirects, sizes,
file types, paths, and archive expansion are validated before installation.
Selected ZIPs are prepared only from a private, read-only staging snapshot
that is removed afterward.

## Telemetry and logging

MojiPond has no first-party analytics or telemetry endpoint. Runtime
diagnostics are coarse states such as permission unavailable, unsupported
target, excluded context, or event-tap timeout. They do not include the typed
token or document text.

The GIPHY client does not expose or invoke action-register operations and does
not send a stable customer identifier. MojiPond sends no analytics events. It
also does not log media requests or query text. The UI retains conspicuous
`Powered by GIPHY` attribution. A distributed build must keep GIPHY media and
URLs uncached, unproxied, and unmodified unless written provider approval says
otherwise. Live-key use and a final review against then-current provider terms
remain release requirements.

## Safety defaults

MojiPond suspends itself when Secure Event Input is active, when a focused
field is secure, or when security status cannot be proven. It also ships with
default exclusions for MojiPond itself, common password managers, terminals,
virtual-machine or remote-desktop clients, Slack, and Discord. Users can add
application and browser-domain exclusions.

The parser, Accessibility capture, and insertion request carry transaction
identities. A focus, selection, target, or token change causes the operation to
fail closed.
