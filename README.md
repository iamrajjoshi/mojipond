# MojiPond

**Type `:wave:`. Get 👋.**

MojiPond is a native macOS menu-bar app that adds Slack-style emoji
autocomplete beside the text cursor. It includes the standard Unicode catalog
and a local library for custom emoji packs.

[Website](https://mojipond.com) ·
[Compatibility](docs/COMPATIBILITY.md) ·
[Privacy](docs/PRIVACY.md)

> **Pre-release:** MojiPond does not have a notarized public download yet.
> Source builds are for development and local testing; the compatibility ledger
> records what has and has not been checked in real macOS apps.

| Suggestions beside the cursor                                         | Emoji library                                           |
| --------------------------------------------------------------------- | ------------------------------------------------------- |
| ![MojiPond emoji suggestions](docs/screenshots/caret-suggestions.png) | ![MojiPond emoji library](docs/screenshots/library.png) |

## What it does

- Opens a five-item picker beside the cursor when you type a colon and part of
  an emoji name. Arrow keys move through the results; Tab or Return inserts the
  selected emoji.
- Ships with Unicode emoji, aliases, skin-tone variants, recents, and local
  search ranking. Typing an exact token such as `:wave:` replaces it
  immediately, while `::` opens the full browser.
- Imports ZIP packs built from image folders, a `mojipond.json` manifest, or a
  Slack `emoji.json` file with local artwork. Every import gets a review step
  before it changes the library.
- Inserts custom image emoji in Messages. On macOS 15 or newer, MojiPond turns
  static artwork and the first frame of an animation into an inline glyph; the
  original file stays unchanged in the library.
- Includes an offline Noto Animated Emoji set for the Messages-only `/sticker`
  command. Downloading the larger online set is optional and off by default.
- Skips secure fields, password managers, terminals, remote-desktop and virtual
  machine clients, Slack, Discord, and anything added to the exclusion list.

## Build from source

You need macOS 14 or newer, Xcode with the macOS SDK, and
[XcodeGen 2.46.0](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
git clone https://github.com/iamrajjoshi/mojipond.git
cd mojipond
./scripts/test.sh
./scripts/install-local.sh
```

`install-local.sh` builds MojiPond, checks the bundle, installs it at
`/Applications/MojiPond.app`, and launches it. The script uses the sole valid
Apple Development identity in your Keychain when one is available; otherwise
it uses an ad-hoc signature. If Keychain contains more than one valid identity,
set `MOJIPOND_SIGNING_IDENTITY` to the one you want. A changed signing identity
can make macOS ask for permissions again.

To build without installing:

```sh
./scripts/build.sh Debug
```

Local builds are not suitable for distribution. Developer ID signing,
notarization, and release packaging are covered in
[docs/RELEASING.md](docs/RELEASING.md).

## First use

1. Open **MojiPond → Setup & Permissions** from the menu bar.
2. Grant Input Monitoring and Accessibility.
3. Type `:wa` in a supported text field, then use Up or Down Arrow.
4. Press Tab or Return to insert the selected result.

These are the default shortcuts:

| Input                       | Result                                             |
| --------------------------- | -------------------------------------------------- |
| `:wa`                       | Opens matching suggestions                         |
| `:wave:`                    | Inserts the exact Unicode match                    |
| `::`                        | Opens the searchable emoji browser                 |
| `/sticker frog` in Messages | Opens the sticker picker                           |
| Escape                      | Closes the active picker without changing the text |

Waiting while you type leaves the picker open. Settings can change the trigger,
acceptance keys, login behavior, exclusions, and whether a bare colon shows
suggestions.

## Permissions and privacy

| Permission                              | Why MojiPond needs it                                                                             |
| --------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Input Monitoring                        | Notices the trigger and picker navigation keys while another app is active                        |
| Accessibility                           | Finds the active editable field, places the picker by the cursor, and replaces the selected token |
| Image emoji in Messages (Event Posting) | Optionally posts paste and Return events for custom images in Messages                            |

Unicode replacement does not need Event Posting when the target supports direct
Accessibility replacement. MojiPond does not request Screen Recording, Full
Disk Access, Contacts, or access to the Messages database.

Autocomplete and pack processing stay on the Mac. There are no accounts or
usage analytics. Crash and hang reporting through Sentry is enabled by default
and can be turned off under **Settings → Privacy**; online Noto downloads and
automatic update checks are separate opt-ins. The
[privacy document](docs/PRIVACY.md) lists the data, storage locations, and
network behavior.

## Custom emoji packs

The Library imports one local ZIP at a time. A ZIP can contain:

- a folder of PNG, JPEG, GIF, or WebP files;
- a portable `mojipond.json` pack with image or Unicode entries;
- a Slack `emoji.json` file whose artwork is included in the archive.

MojiPond shows normalized names, ignored files, duplicate artwork, and naming
conflicts before installation. The public import UI does not fetch remote pack
assets. See [docs/PACK_FORMAT.md](docs/PACK_FORMAT.md) for the manifest schema,
image limits, path rules, and export format.

## Troubleshooting

### The picker does not appear

- Confirm that MojiPond says **Enabled** in the menu bar and has both required
  permissions.
- Try TextEdit or Notes. Some custom editors do not expose enough Accessibility
  information for safe replacement.
- Check the app and website exclusion lists. Secure fields are always skipped.

### Permissions disappear after a rebuild

Development and ad-hoc signatures can change the app identity macOS associates
with a permission. Install the copy at `/Applications/MojiPond.app`; if a stale
entry remains, remove it from the relevant Privacy & Security list, add the
installed app again, and relaunch.

### A custom image will not insert

Image emoji work only in Messages and need the optional Event Posting access.
When automatic insertion cannot run safely, use **Copy Media Instead** from the
MojiPond menu and paste it yourself.

## Project documentation

| Topic                                        | Document                                         |
| -------------------------------------------- | ------------------------------------------------ |
| App structure and safety boundaries          | [Architecture](docs/ARCHITECTURE.md)             |
| Verified behavior and pending manual checks  | [Compatibility ledger](docs/COMPATIBILITY.md)    |
| ZIP and manifest rules                       | [Portable pack format](docs/PACK_FORMAT.md)      |
| Local data and network features              | [Privacy model](docs/PRIVACY.md)                 |
| Signing, notarization, updates, and releases | [Release guide](docs/RELEASING.md)               |
| Website development                          | [Website README](website/README.md)              |
| Artwork and third-party sources              | [Third-party assets](docs/THIRD_PARTY_ASSETS.md) |

## License and security

MojiPond source is available under the [MIT License](LICENSE). Third-party code
and artwork keep the licenses listed in `ThirdParty/` and
`Resources/THIRD-PARTY-NOTICES.txt`.

Report security problems through
[GitHub private vulnerability reporting](https://github.com/iamrajjoshi/mojipond/security/advisories/new),
not a public issue. See [SECURITY.md](SECURITY.md) for the reporting policy.
