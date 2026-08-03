# Releasing MojiPond

MojiPond ships outside the Mac App Store as a Developer ID application. GitHub
Actions builds the release on `main`, uploads dSYMs to Sentry, notarizes the
artifacts, signs a Sparkle appcast, and creates one draft GitHub Release. A
person reviews and publishes that draft.

The release workflow never publishes a draft on its own.

## Release trust

Three unrelated credentials protect a release:

- Apple Developer ID signs the app and DMG; App Store Connect notarizes them.
- Sparkle's Ed25519 key signs the appcast and update enclosure metadata. The
  private key is not an Apple credential.
- A Sentry organization token uploads release dSYMs without source files.

Keep the Apple and Sparkle private keys in the protected GitHub environment
named `production-release`. Do not put them in `.env`, repository variables,
workflow output, artifacts, or release notes.

## GitHub configuration

Set this repository variable:

| Variable        | Value                                                                |
| --------------- | -------------------------------------------------------------------- |
| `APPLE_TEAM_ID` | The 10-character Team ID on the Developer ID Application certificate |

Set these secrets on the `production-release` environment:

| Secret                       | Value                                                                    |
| ---------------------------- | ------------------------------------------------------------------------ |
| `DEVELOPER_ID_P12_BASE64`    | Base64 of the exported Developer ID Application `.p12`                   |
| `DEVELOPER_ID_P12_PASSWORD`  | Password used when exporting the `.p12`                                  |
| `APPLE_NOTARY_KEY_P8_BASE64` | Base64 of the App Store Connect Team API `.p8`                           |
| `APPLE_NOTARY_KEY_ID`        | The API key's 10-character Key ID                                        |
| `APPLE_NOTARY_ISSUER_ID`     | The App Store Connect Issuer ID UUID                                     |
| `SPARKLE_EDDSA_PRIVATE_KEY`  | Sparkle's exported Ed25519 private key                                   |
| `SENTRY_AUTH_TOKEN`          | Sentry organization token with `org:ci` access for `flash-corp/mojipond` |

Require approval for the environment and limit deployment to `main`. The
workflow imports the `.p12` into a temporary keychain, writes the notary key to
the runner's temporary directory, and removes both in its final cleanup step.

## Create the Apple credentials

Create a **Developer ID Application** certificate in the Apple Developer
portal. Export the certificate and private key together from Keychain Access as
a password-protected `.p12`; a `.cer` by itself cannot sign a build.

Create a Team API key under App Store Connect's **Users and Access →
Integrations** page. Give it the Developer role, download the `.p8` once, and
record its Key ID and Issuer ID. Use a Team Key rather than an Individual Key.

Encode the two files without line wrapping:

```sh
base64 < DeveloperIDApplication.p12 | tr -d '\n' | pbcopy
base64 < AuthKey_KEYID.p8 | tr -d '\n' | pbcopy
```

## Create the Sparkle key

MojiPond pins Sparkle 2.9.5. Use that version's `generate_keys` tool so the
private key is stored in your login Keychain under a named account:

```sh
generate_keys --account mojipond
generate_keys --account mojipond -p
```

The second command prints the public key. It must match
`SPARKLE_PUBLIC_ED_KEY` in `project.yml` and `SUPublicEDKey` in the built app's
Info property list.

Export the private key to a protected temporary file, set the environment
secret through standard input, then remove the file:

```sh
(
  set -e
  umask 077
  private_key_directory="$(mktemp -d)"
  private_key_file="$private_key_directory/sparkle-private-key"
  trap 'rm -f "$private_key_file"; rmdir "$private_key_directory"' EXIT
  generate_keys --account mojipond -x "$private_key_file"
  gh secret set SPARKLE_EDDSA_PRIVATE_KEY \
    --env production-release \
    < "$private_key_file"
)
```

Back up the private key in an encrypted password manager. Changing the public
key in a later build does not repair clients that still trust the old one;
follow [Sparkle's key-rotation process](https://sparkle-project.org/documentation/)
instead of replacing it in place.

## Update delivery

The app reads a signed appcast from:

```text
https://mojipond.com/releases/appcast.xml
```

`SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` are enabled. Sparkle
system profiling is disabled, automatic checks default to off, and the app does
not enable automatic download or installation by default.

The repository contains a signed empty appcast so the endpoint returns valid
XML before the first release. For each release, Sparkle's `generate_appcast`
tool reads the final notarized `MojiPond.zip`, signs its enclosure metadata with
`SPARKLE_EDDSA_PRIVATE_KEY`, and writes `appcast.xml`. The enclosure URL names
the versioned tag:

```text
https://github.com/iamrajjoshi/mojipond/releases/download/vVERSION/MojiPond.zip
```

The release workflow attaches `appcast.xml` beside the ZIP and DMG. After a
stable release is published, the Pages workflow copies only that appcast to the
site. It ignores drafts and prereleases, so publishing a beta cannot replace
the stable feed.

## Prepare a release

1. Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`.
   Keep the marketing version in `major.minor.patch` form and increment the
   integer build number for every submitted build.
2. Regenerate the project, run native and website tests, and merge the version
   change to `main`.
3. Confirm `main` is clean and CI is green.
4. Dispatch the **Release** workflow with the exact version and build from
   `project.yml`. Mark it as a prerelease only when it must stay off the stable
   appcast.

```sh
xcodegen generate
./scripts/test.sh
pnpm install --frozen-lockfile
pnpm site:format:check
pnpm site:check
pnpm site:build
pnpm site:test
```

The workflow rejects a version/build mismatch and an invocation from any branch
other than `main`.

## What the workflow produces

The protected job creates these draft-release assets:

```text
MojiPond.dmg
MojiPond.zip
appcast.xml
BUILD-METADATA.json
SHA256SUMS.txt
```

Before creating the draft it:

- builds a Universal `arm64` and `x86_64` Release archive with Hardened Runtime;
- uploads dSYMs to Sentry using `--no-sources`;
- notarizes the ZIP, staples the app, rebuilds the public ZIP, then notarizes
  and staples the DMG;
- proves the Sparkle private secret derives the public key embedded in the
  packaged app;
- runs strict code-signature, Gatekeeper, stapler, architecture, DMG, checksum,
  and Sparkle appcast checks.

The appcast must be generated from the rebuilt ZIP after the notarization ticket
has been stapled. Repacking or modifying `MojiPond.zip` afterward invalidates
its Sparkle signature and byte length.

## Review and publish

Download the draft assets to a clean directory and verify the checksums:

```sh
shasum -a 256 -c SHA256SUMS.txt
xmllint --noout appcast.xml
```

Install from the DMG on a Mac that does not have the development build or its
TCC grants. Check Gatekeeper launch, first-run setup, the default-on Sentry
choice, permission requests, Unicode insertion, ZIP import, and one update from
the prior public version. Do not use a conversation you cannot safely alter for
the Messages check.

Publish the draft only after that pass. GitHub's release event redeploys Pages;
once it completes, verify:

```sh
curl --fail --silent --show-error \
  https://mojipond.com/releases/appcast.xml \
  | xmllint --noout -
```

Also open **Check for Updates…** from the prior installed version. A stable
release must appear there. A prerelease must not alter the stable result.

## Local packages

`./scripts/package-local.sh` creates ZIP and DMG artifacts for inspection, but
an ad-hoc or Apple Development build is not a public release. It lacks the
Developer ID, notarization, stapled ticket, and Sparkle release signature used
by the protected workflow.

The appcast URL and Sparkle public key live in `project.yml`; local builds need
no update-related environment variables. `.env.example` covers only local code
signing and build-cache overrides.

## Recovery rules

- Revoke and replace a leaked Sentry token. It does not sign the app.
- Revoke a leaked App Store Connect key in App Store Connect, then replace the
  three notary secrets.
- Revoke a leaked Developer ID certificate through Apple and replace the `.p12`
  secrets. Existing notarized releases remain separate artifacts.
- Do not rotate a leaked Sparkle key by swapping `SUPublicEDKey`. Stop release
  publication and follow Sparkle's documented rotation or recovery procedure
  so installed clients can move to the new key.

Never edit a published ZIP or appcast in place. Publish a new version and build
number, then let the stable Pages deployment select it.
