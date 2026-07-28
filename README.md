# MojiPond

MojiPond is a native macOS menu-bar app for Slack-style emoji autocomplete.
Type a shortcode such as `:wave:`, choose a result beside the caret, and keep
typing. The project also contains a local custom-pack library, safe import
pipelines, and Messages-only sticker and GIF command engines.

> **Pre-release status:** global Unicode autocomplete, the custom-pack Library,
> and Messages media commands are connected to the app and exercised by
> automated tests. They have not all been manually verified against real
> third-party editors or Messages. Treat this as a personal development build,
> not a notarized public release. The evidence ledger is in
> [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md).

## Highlights

- Native AppKit and SwiftUI menu-bar application; no browser extension or
  background server.
- Built-in Unicode emoji catalog with aliases, search ranking, recents, and
  skin-tone variants.
- Configurable trigger, Tab and Return acceptance, exact closing-token
  replacement, and a double-trigger browser.
- Fail-closed handling for secure fields, unknown targets, excluded apps, and
  excluded browser domains.
- Local Unicode, PNG, JPEG, GIF, and WebP pack model with aliases and
  metadata.
- Bounded import engines for files, folders, ZIP archives, portable
  `mojipond.json` packs, Slack-style `emoji.json`, and public GitHub repositories.
- Offline Noto Animated Emoji subset plus opt-in online sticker and GIPHY
  providers for Messages command workflows.
- Enabled custom Unicode and image entries participate in `:query`, exact
  `:name:`, and `::` browsing beside the built-in catalog.
- Clipboard-safe media insertion that snapshots all pasteboard items and
  representations before a temporary paste.
- Signed update checks plus an explicit, bounded download-and-verify flow for a
  single Developer ID-signed, hardened, Gatekeeper-accepted app. MojiPond
  installs only after **Install & Relaunch**, with a locked atomic swap,
  post-launch readiness acknowledgement, and rollback.
- No accounts, message-database access, telemetry, or cloud storage.

## Requirements

- macOS 14 or newer (deployment target; older releases are unsupported).
- Xcode with the macOS SDK. The currently exercised toolchain is recorded in
  [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46.0, the version
  pinned and checksum-verified by CI.

Install XcodeGen with Homebrew if needed:

```sh
brew install xcodegen
```

## Build and install

From the repository root:

```sh
./scripts/test.sh
./scripts/build.sh Debug
./scripts/install-local.sh
```

`install-local.sh` builds an ad-hoc-signed development copy, verifies its
signature, installs it at `/Applications/MojiPond.app`, and launches it. A
stable path matters because macOS privacy approvals are associated with the
installed application.

To produce a local Universal Release archive, ZIP, DMG, and SHA-256 checksum
file:

```sh
./scripts/package-local.sh
```

Artifacts are written to a new timestamped directory below
`Artifacts/releases/`. Local packages are ad-hoc signed and are not suitable
for public distribution. Developer ID and notarization instructions are in
[docs/RELEASING.md](docs/RELEASING.md).

### UI test harness

`./scripts/test.sh` remains the headless unit-test suite used by CI. Run the
macOS UI tests separately from an unlocked interactive desktop:

```sh
xcodegen generate
xcodebuild \
  -project MojiPond.xcodeproj \
  -scheme MojiPondUITests \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .derived/ui-app \
  test \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=YES
xcodebuild \
  -project MojiPond.xcodeproj \
  -scheme MojiPondIntegrationFixture \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .derived/ui-fixture \
  test \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=YES
```

The MojiPond UI scheme launches with isolated temporary Library data, fixed
permission-denied state, and runtime/network startup disabled. It does not
request TCC access or interact with Messages. The integration fixture safely
exercises an ordinary field, multiline editor, secure field, and
attachment-capable rich text view.

## Grant permissions

Open **MojiPond → Setup & Permissions** from the menu-bar item. MojiPond asks
only after you press an Allow button.

| Permission | Why it is used | Required for |
| --- | --- | --- |
| Input Monitoring | Receives keyboard events while another app is active | Global autocomplete |
| Accessibility | Identifies the focused editable control, reads a bounded token near the caret, positions suggestions, and replaces the validated token | Global autocomplete |
| Event Posting | Sends a tagged Command-V after a safe temporary pasteboard write | Image and GIF insertion |

Unicode insertion does not require Event Posting when the target supports
direct Accessibility replacement. MojiPond does not request Screen Recording,
Full Disk Access, Contacts, or access to the Messages database.

Apple explains these controls in
[Control access to input monitoring on Mac](https://support.apple.com/guide/mac-help/control-access-to-input-monitoring-on-mac-mchl4cedafb6/mac)
and
[Allow accessibility apps to access your Mac](https://support.apple.com/guide/mac-help/allow-accessibility-apps-to-access-your-mac-mh43185/mac).

You can print the app’s preflight view without displaying a consent prompt:

```sh
/Applications/MojiPond.app/Contents/MacOS/MojiPond \
  --print-permissions-and-quit
```

## Use Unicode autocomplete

1. Focus an ordinary editable text field in a non-excluded app.
2. Type `:wa` (or your configured trigger and query).
3. Use Up and Down Arrow to select a suggestion.
4. Press Tab or Return to replace the token.

With the default settings:

- `:wave:` performs an exact replacement when the closing colon is typed.
- `::` opens the emoji browser.
- Escape, a mouse click, cursor movement, an unsupported modifier, or parser
  timeout dismisses the session without changing the text.
- The popup is not shown for a bare `:` until that setting is enabled.

Settings let you pause MojiPond, launch it at login, change the trigger and
acceptance keys, opt into individual network features, and manage app or
website exclusions. Password managers, terminals, virtual-machine clients,
Slack, and Discord are excluded by default.

After onboarding, normal and login-item launches stay in the menu bar without
opening the Library. Open it from the status menu, or launch with
`--mojipond-open-library` when an explicit Library window is required.

## Custom packs and media commands

Open **MojiPond → Emoji Library** to browse, search, and filter built-in and
custom emoji in a grid or list. From the Library you can:

- Import image files, folders, ZIP archives, portable `mojipond.json` packs,
  Slack-style `emoji.json`, or a public GitHub repository. Drag and drop is
  supported.
- Review thumbnails, normalized shortcodes, ignored or rejected entries,
  duplicate hashes, and collisions before anything is installed.
- Resolve each collision by keeping the existing item, replacing it, renaming
  the import, or dropping an alias; the same choice can be applied to all
  matching conflicts.
- Enable, disable, reorder, inspect, create, edit, and remove packs; add a
  custom Unicode emoji with its own shortcode, aliases, tags, and category; add
  or replace image assets; export a portable pack; and reveal managed files.
- Search custom Unicode by shortcode, alias, name, tag, or category, then copy
  the Unicode value directly from its Library detail view.

Network-backed imports require explicit opt-in and can be cancelled while they
are prepared. Local re-import replaces the prior pack contents transactionally.
A GitHub-backed pack can be refreshed from its stored ref after another
explicit network confirmation.

- Portable pack authors: see [docs/PACK_FORMAT.md](docs/PACK_FORMAT.md).
- In Messages, type `/sticker <query>` to search the bundled offline Noto
  subset. Online Noto search is a separate opt-in.
- In Messages, type `/gif <query>` for opt-in GIPHY search. A key must already
  exist in the login Keychain under service `com.rajjoshi.MojiPond` and account
  `giphy-api-key`. Add, replace, or remove it under
  **Settings → General → GIPHY API key**; the saved value is never redisplayed.
- Use the arrow keys or Tab to move through a media grid, Return to insert the
  selected original, and Escape to close it. Media commands and custom-image
  shortcode insertion are restricted to Messages.
- GIPHY results retain conspicuous attribution. Selected originals are
  downloaded directly and are not cached, proxied, or rewritten.

## Signed updates

Update checks remain disabled until the app bundles an HTTPS feed and trusted
public key. A manual check, or an explicitly enabled startup check, verifies
the signed metadata before showing a release. Downloading is a separate user
action.

The downloader caps the ZIP at both its signed byte count and a local safety
limit, verifies its SHA-256 digest, extracts exactly one `MojiPond.app` in a
private directory, and validates the current and candidate apps. Both must
have the expected bundle ID, a Developer ID Application signature, Hardened
Runtime, secure timestamp, Gatekeeper acceptance, and the same Team ID. A
local ad-hoc build therefore cannot stage an update.

After a second explicit **Install & Relaunch** confirmation, MojiPond repeats
the archive, bundle, signature, identity, version, and build checks. The
verified candidate then runs the installer mode of the same MojiPond
executable—there is no helper, daemon, or privileged component. It acquires a
sibling lock and consumes a private, one-time handoff bound to the running app
and exact staged candidate. It then waits for the old process to exit, copies
and re-verifies the candidate beside the installed app, atomically exchanges
the two bundles,
moves the displaced app to a backup name, and verifies the final destination
before launch. The backup is removed only
after the final app writes a private readiness acknowledgement; failures
restore and re-verify the previous app.

If the installed app's parent directory is not writable, MojiPond does not
pretend installation succeeded: it offers the verified candidate in Finder for
manual replacement. Unsafe paths or identity failures never receive that
fallback. See
[docs/RELEASING.md](docs/RELEASING.md) for the release-side requirements.

The example environment file contains local build and packaging settings:

```sh
cp .env.example .env
set -a
source .env
set +a
```

The scripts do not load `.env` automatically. Never commit `.env`, signing
credentials, or a real API key.

## Troubleshooting

### The menu says “Permissions needed”

- Confirm the running copy is `/Applications/MojiPond.app`.
- In **System Settings → Privacy & Security**, enable MojiPond under both
  **Input Monitoring** and **Accessibility**.
- Quit and reopen MojiPond after changing access.
- Ad-hoc rebuilds can change the app’s code identity. If macOS retains a stale
  entry, remove MojiPond from the relevant list, add the installed copy again,
  and relaunch it.

### No suggestions appear

- Confirm MojiPond is enabled in the menu.
- Try a standard TextEdit or Notes text field; some custom editors do not
  expose the Accessibility attributes required for safe replacement.
- Check whether the current application or browser domain is excluded.
- Secure fields and fields whose security status cannot be proven are rejected
  deliberately.
- Type one query character after the trigger unless bare-trigger suggestions
  are enabled.

### Tab or Return behaves normally

MojiPond intercepts navigation keys only while its own suggestion surface is
active. If the popup is absent or the target cannot be revalidated, the key is
passed through.

### An image cannot be pasted

Image and GIF insertion needs Event Posting access. When MojiPond cannot
snapshot the clipboard safely, validate the target, or post the paste command,
the insertion engine leaves the token and clipboard unchanged and records a
copy-fallback notice. If the selected original passed validation, open the
MojiPond menu and choose **Copy Media Instead** to place it on the clipboard
for a manual paste.

### An import is rejected

Imports enforce file-count, byte, dimension, frame-count, archive, path, and
HTTPS limits. Symlinks, path traversal, credentials, custom ports, and
local/private network destinations are rejected. See
[docs/PACK_FORMAT.md](docs/PACK_FORMAT.md) for the exact limits and naming
rules.

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Portable pack format](docs/PACK_FORMAT.md)
- [Privacy model](docs/PRIVACY.md)
- [Compatibility and verification ledger](docs/COMPATIBILITY.md)
- [Release and notarization process](docs/RELEASING.md)

Third-party source notices are kept beside their inputs in `ThirdParty/`; a
complete distributable notice is also bundled at
`Contents/Resources/THIRD-PARTY-NOTICES.txt`, and packaging fails if it is
missing. The bundled Unicode metadata comes from `gemoji`; the offline animated
subset is attributed under `ThirdParty/NotoAnimatedEmoji/`. The MojiPond icon
is original, project-specific artwork—not a third-party logo or emoji. Its
source image is `Resources/Branding/MojiPond-AppIcon-Source.png`; the sized
files in `Resources/Assets.xcassets/AppIcon.appiconset/` derive from that
source.

The public `knobiknows/all-the-bufo` repository is an import-compatibility
target, not bundled content. Its 2026-07-28 audit found no detected license or
redistribution grant, so MojiPond does not bundle or redistribute its artwork.
