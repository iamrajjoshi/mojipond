# Releasing MojiPond

MojiPond currently supports two different artifact classes:

1. **Local development artifacts** — Apple Development signed when one valid
   identity is available, otherwise ad-hoc signed; suitable for this Mac and
   not public distribution.
2. **Direct-distribution artifacts** — signed with a Developer ID Application
   certificate, hardened, timestamped, notarized by Apple, stapled, and tested
   after download.

Do not present a local artifact as notarized or Gatekeeper-ready.

Apple’s current requirements are described in
[Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution),
[Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow),
and
[Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates).

## 1. Prepare the source

Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`.
Confirm third-party provenance and licenses. Confirm that
`Resources/Branding/MojiPond-AppIcon-Source.png` is the reviewed first-party
source and that every file in `Resources/Assets.xcassets/AppIcon.appiconset/`
was regenerated from it. Do not bundle `knobiknows/all-the-bufo`; its repository
is a retained importer-engine compatibility target, not a source exposed by the
current public UI. The public repository audit on 2026-07-28 recorded 1,715
tree entries (1,403 PNG, 295 GIF, and 10 JPG), found only `README` among
license-like paths, and detected no `LICENSE`, repository license metadata, or
other redistribution grant. Do not redistribute that artwork without suitable
permission from the rights holder. Then start from a clean checkout:

```sh
git status --short
./scripts/test.sh
```

Generate and inspect the project if build settings changed:

```sh
xcodegen generate
xcodebuild \
  -project MojiPond.xcodeproj \
  -scheme MojiPond \
  -configuration Release \
  -showBuildSettings
```

Never place signing certificates, private update keys, notarization
credentials, or API keys in the repository.

## 2. Make a local ad-hoc package

No Apple Developer identity is required:

```sh
./scripts/package-local.sh
```

The command creates a new timestamped folder under `Artifacts/releases/`
containing:

```text
MojiPond-<UTC timestamp>-local.xcarchive/
MojiPond-<UTC timestamp>-local.zip
MojiPond-<UTC timestamp>-local.dmg
BUILD-METADATA.json
SHA256SUMS.txt
```

Packaging refuses to start when any tracked file differs from `HEAD`, any
non-ignored untracked file is present, or an ignored file exists below
`Sources/` or `Resources/` where XcodeGen could include it in the app. It
also rejects Git `assume-unchanged` and `skip-worktree` index flags, which can
hide modified tracked bytes from an ordinary status check. It checks the
source identity before and after checksumming the finished artifacts. Ignored
local build output outside those input directories does not affect that
check. The archive itself is built from a temporary `git archive` snapshot of
the recorded revision with fresh Derived Data, rather than from the mutable
working directory.
`BUILD-METADATA.json` is a deterministic, fixed-schema record containing:

- schema version `1`;
- the full Git revision and branch (`(detached)` when no branch is checked
  out);
- `clean: true`;
- one UTC build timestamp shared with the artifact directory name;
- the app's bundle identifier, marketing version, and build number; and
- signing class: `ad-hoc`, `developer-id`, or `other`.

It intentionally excludes the remote URL, signing-identity name, credentials,
user or machine names, and absolute local paths. `SHA256SUMS.txt` covers the
ZIP, DMG, and `BUILD-METADATA.json`.

The Release app is built as a Universal binary by default. Verify it:

```sh
export RELEASE_DIR="/absolute/path/to/Artifacts/releases/MojiPond-<timestamp>-local"
export APP_PATH="$RELEASE_DIR/MojiPond-<timestamp>-local.xcarchive/Products/Applications/MojiPond.app"
export METADATA_PATH="$RELEASE_DIR/BUILD-METADATA.json"
export EXPECTED_REVISION="<reviewed 40-character Git revision>"

(
  cd "$RELEASE_DIR"
  shasum -a 256 -c SHA256SUMS.txt
)
plutil -p "$METADATA_PATH"
test "$(plutil -extract schemaVersion raw -o - "$METADATA_PATH")" = "1"
test "$(plutil -extract clean raw -o - "$METADATA_PATH")" = "true"
test "$(plutil -extract revision raw -o - "$METADATA_PATH")" = "$EXPECTED_REVISION"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
lipo -archs "$APP_PATH/Contents/MacOS/MojiPond"
```

Expected architectures are `arm64` and `x86_64`, in either order. An ad-hoc
signature can retain the Hardened Runtime flag, but it has no Developer ID
identity or Team ID, is not notarized, and is not suitable for
public-distribution Gatekeeper assessment. The updater validates the running
app as well as the candidate, so this local artifact is also deliberately
unable to stage a production update.

## 3. Install a Developer ID Application identity

Public direct distribution requires membership in the Apple Developer Program
and a **Developer ID Application** certificate with its private key available
in the build user’s Keychain. A Developer ID Installer certificate is for flat
installer packages and is not a substitute for signing the app.

List available identities:

```sh
security find-identity -v -p codesigning
```

An Apple Development identity used for local Debug builds is not a substitute
for Developer ID Application signing. Developer ID release steps cannot be
verified until that separate identity is installed.

## 4. Build a Developer ID archive and packages

Use the identity name exactly as shown by `security find-identity`:

```sh
export MOJIPOND_SIGNING_IDENTITY="Developer ID Application: YOUR NAME (TEAMID)"
export MOJIPOND_DEVELOPMENT_TEAM="TEAMID"
export MOJIPOND_REQUIRE_DEVELOPER_ID=1
./scripts/test.sh
./scripts/package-local.sh
```

`MOJIPOND_REQUIRE_DEVELOPER_ID=1` prevents the packaging command from silently
falling back to ad-hoc signing. The build keeps Hardened Runtime enabled.
Xcode’s Developer ID signing path should add a secure timestamp; verify rather
than assuming:

```sh
export RELEASE_DIR="/absolute/path/to/Artifacts/releases/MojiPond-<timestamp>-local"
export ARCHIVE_PATH="$RELEASE_DIR/MojiPond-<timestamp>-local.xcarchive"
export APP_PATH="$ARCHIVE_PATH/Products/Applications/MojiPond.app"
export DMG_PATH="$RELEASE_DIR/MojiPond-<timestamp>-local.dmg"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign --display --verbose=4 "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"
lipo -archs "$APP_PATH/Contents/MacOS/MojiPond"
```

Before notarization, `spctl` may report that no notarization ticket is present.
Inspect the designated requirement, Team ID, Hardened Runtime flags,
entitlements, and timestamp in the `codesign` output.

## 5. Store notarization credentials

Use an App Store Connect API key or an Apple ID with an app-specific password.
This example asks `notarytool` interactively rather than putting a password on
the command line:

```sh
xcrun notarytool store-credentials "mojipond-notary" \
  --apple-id "YOUR_APPLE_ID" \
  --team-id "TEAMID"
```

Do not use the retired `altool` workflow. Apple’s notary service accepts
`notarytool` submissions from current Xcode versions.

## 6. Notarize and staple the DMG

Submit the Developer ID-signed DMG and wait for the result:

```sh
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "mojipond-notary" \
  --wait
```

The result must be `Accepted`. If it is not, retrieve the submission log using
the ID printed by the submit command:

```sh
xcrun notarytool log "SUBMISSION_ID" \
  --keychain-profile "mojipond-notary" \
  "notary-log.json"
```

After acceptance:

```sh
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess \
  --type open \
  --context context:primary-signature \
  --verbose=4 \
  "$DMG_PATH"
```

Recompute the checksum after stapling because the DMG bytes changed:

```sh
(
  cd "$RELEASE_DIR"
  shasum -a 256 ./*.zip ./*.dmg BUILD-METADATA.json > SHA256SUMS.txt
)
```

Mount the DMG, drag the app to `/Applications`, launch that installed copy on a
clean test account or separate Mac, and repeat the TCC and Messages checks in
[COMPATIBILITY.md](COMPATIBILITY.md). Verify behavior with the network
disconnected as well as connected.

## 7. If distributing a ZIP

A ZIP cannot carry a stapled ticket itself. Submit the ZIP, staple the ticket
to the app, and then create the final ZIP from that stapled app:

```sh
export ZIP_PATH="$RELEASE_DIR/MojiPond-<timestamp>-local.zip"
export FINAL_ZIP_PATH="$RELEASE_DIR/MojiPond-notarized.zip"

xcrun notarytool submit "$ZIP_PATH" \
  --keychain-profile "mojipond-notary" \
  --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

/usr/bin/ditto \
  -c \
  -k \
  --norsrc \
  --noextattr \
  --noqtn \
  --keepParent \
  "$APP_PATH" \
  "$FINAL_ZIP_PATH"

(
  cd "$RELEASE_DIR"
  shasum -a 256 ./*.zip ./*.dmg BUILD-METADATA.json > SHA256SUMS.txt
  shasum -a 256 -c SHA256SUMS.txt
)
```

Assess an extracted, quarantined copy—not only the build-tree app—before
publishing it. The checksum regeneration must happen after the final ZIP is
created because stapling and recompression both change release bytes.

## 8. Signed update metadata

`AppUpdateController` wires manual checks from the status menu and About
settings, plus one startup check when the user enables automatic checks.
`SignedUpdateChecker` authenticates the result before metadata reaches the UI.
A verified newer build produces a quiet availability status and an optional
release-notes link.

Downloading remains a separate explicit action. `VerifiedUpdateStager` accepts
only signed metadata from the configured feed/key boundary, downloads no more
than the signed byte count, verifies the exact byte count and SHA-256 digest,
and stages the ZIP in a private `0700` temporary directory. The shipping app
still has no production feed or trusted public key configured, so checks and
staging report that they are disabled.

The verifier accepts an HTTPS JSON envelope:

```json
{
  "schemaVersion": 1,
  "algorithm": "ed25519",
  "payload": "<base64 of the exact payload bytes>",
  "signature": "<base64 signature over those exact payload bytes>"
}
```

The decoded payload is:

```json
{
  "schemaVersion": 1,
  "version": "0.1.0",
  "build": 1,
  "publishedAt": "2026-07-27T00:00:00Z",
  "minimumSystemVersion": "14.0",
  "downloadURL": "https://updates.example.com/MojiPond-notarized.zip",
  "releaseNotesURL": "https://updates.example.com/releases/0.1.0",
  "assetSHA256": "<64 lowercase hexadecimal characters>",
  "assetByteCount": 123456
}
```

Supported signature algorithms are Ed25519 (`ed25519`) and P-256 ECDSA with
SHA-256 (`p256-sha256`). Sign the exact payload bytes before Base64 encoding.
Keep the private signing key offline or in a dedicated secrets service; embed
only the public key in the app. The asset digest and size must describe the
final published ZIP bytes. When present, `minimumSystemVersion` must contain
one to three numeric components, such as `14`, `14.5`, or `14.5.1`; incompatible
releases are not offered for download and are rejected again by the stager.

### Generate a signed feed

Use `scripts/generate-update-feed.swift` rather than assembling or signing JSON
by hand. It uses CryptoKit, hashes the archive as a stream, serializes the
payload and envelope as compact sorted-key JSON, signs the exact payload bytes,
and verifies the new signature before writing anything. It refuses
symbolic-link file inputs, archives above the default 512 MiB updater limit,
private keys accessible by group or other users, changing inputs, insecure
URLs, invalid metadata, missing output parents, and existing output files.

The generator accepts a Base64-encoded CryptoKit raw private key in a file. It
never prints or copies the private key into the feed. Generate and retain that
file on an offline key-management machine or materialize it temporarily from a
dedicated secrets service. Never place it in this repository, pass it as a
command-line value or environment variable, include it in CI artifacts, or
attach it to a release.

Ed25519 is the recommended default. This native command creates a new key file
without overwriting an existing one:

```zsh
KEY_PATH="/Volumes/SECURE/mojipond-update-ed25519-private-key.txt"
(
  umask 077
  set -o noclobber
  /usr/bin/xcrun swift -e \
    'import CryptoKit; print(Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString())' \
    > "${KEY_PATH}"
)
/bin/chmod 600 "${KEY_PATH}"
```

For P-256, replace `Curve25519.Signing.PrivateKey()` with
`P256.Signing.PrivateKey()`. Back up the private key in encrypted offline
storage and record who can access it. The matching public key is not secret;
the generator prints its Base64 raw representation and the same
domain-separated SHA-256 fingerprint recorded by MojiPond after verification.

Run the generator only after notarization, stapling, and creation of the final
ZIP. Every input that affects signed metadata is explicit:

```zsh
RELEASE_DIRECTORY="${PWD}/Artifacts/releases/MojiPond-0.2.0"
ARCHIVE_PATH="${RELEASE_DIRECTORY}/MojiPond-notarized.zip"
FEED_PATH="${RELEASE_DIRECTORY}/update-feed.json"

/usr/bin/xcrun swift scripts/generate-update-feed.swift \
  --algorithm ed25519 \
  --private-key "${KEY_PATH}" \
  --archive "${ARCHIVE_PATH}" \
  --version 0.2.0 \
  --build 2 \
  --published-at 2026-07-28T00:00:00Z \
  --minimum-system-version 14.0 \
  --download-url https://updates.example.com/MojiPond-notarized.zip \
  --release-notes-url https://updates.example.com/releases/0.2.0 \
  --output "${FEED_PATH}"
```

`--published-at` must be an exact UTC timestamp with whole seconds. The minimum
system version and release-notes URL are optional; omit their complete flag and
value when they do not apply. Paths must be absolute, the output directory must
already exist, and the output is created with mode `0644`. The tool never
overwrites an existing feed.

Identical inputs produce identical signed payload bytes. CryptoKit may hedge a
signature with fresh randomness, so separately generated valid envelope files
are not required to be byte-for-byte identical. Compare the printed payload
SHA-256, archive SHA-256 and byte count, verification-key fingerprint, and
decoded metadata during review instead.

Before publishing the feed:

1. Run the focused native tooling checks:

   ```zsh
   /usr/bin/xcrun swift scripts/test-update-feed-generator.swift
   ```

2. Confirm the printed public key and fingerprint match the public key pinned
   in the release build.
3. Upload the final ZIP without transforming it, download it from the signed
   HTTPS URL, and confirm its SHA-256 and byte count still match the generator
   summary.
4. Publish the reviewed feed last and retain the non-secret command arguments,
   feed, hashes, fingerprint, and notarization evidence with the release
   record.

Treat key rotation as a release migration. First publish, on the old feed and
with the old key, a transition build that pins a new public key and feed URL.
Keep the old feed available during the migration window; do not silently swap
the key behind a URL already pinned by older builds. For a bad but uncompromised
release, publish a fixed, notarized archive with a higher build number. If the
private key is suspected compromised, stop publishing through that trust
boundary, preserve evidence, retire the endpoint, and distribute a newly
keyed build through a separately authenticated channel.

### Release ZIP contract

The signed payload must point to a ZIP containing exactly one
`MojiPond.app`. Ancestor directories are allowed, but sibling files, a second
application, symlinks, special files, traversal, and unexpected extracted
paths are rejected. The default updater limits are:

| Limit | Default |
| --- | ---: |
| Signed/downloaded ZIP bytes | 512 MiB |
| ZIP entries | 20,000 |
| Bytes in one expanded entry | 256 MiB |
| Total expanded bytes | 1 GiB |
| Compression ratio | 200:1 |

Build the candidate with Developer ID Application signing, Hardened Runtime,
and a secure timestamp; notarize it and make sure the extracted app passes
Gatekeeper. The candidate bundle identifier must be
`com.rajjoshi.MojiPond`, and its version and integer build must exactly match
the signed metadata. Both the running app and candidate are strictly
code-signature checked and must have the same Team ID. An optional configured
Team ID pins both identities further.

Installer mode also consumes a private, one-time authorization record created
by the currently running app for the exact destination and staged candidate.
The command-line request is not sufficient by itself and cannot be replayed
after the record is consumed.

Create the final ZIP only after all signing, notarization, stapling, and
packaging steps that change bytes. Compute `assetByteCount` and `assetSHA256`
from that exact ZIP, then sign the exact payload bytes. Do not reuse the
checksum of an earlier archive or the DMG.

Configure the public verification boundary with four string keys in the app
Info.plist:

```text
MojiPondUpdateFeedURL                 HTTPS feed URL
MojiPondUpdateSignatureAlgorithm      ed25519 or p256-sha256
MojiPondUpdatePublicKeyBase64         Base64 raw public-key representation
MojiPondUpdateTeamIdentifier          10-character Apple Team ID
```

Before enabling production checks:

1. Run and review the signed-feed generator and its focused tooling checks for
   the final ZIP.
2. Configure the HTTPS feed and pin the public verification key and Team ID in
   the app.
3. Keep automatic checks opt-in.
4. Publish only the final single-app notarized ZIP described above.
5. Review and follow the rollback and signing-key rotation procedure above.
6. Test invalid signatures, wrong sizes and digests, stale builds, hostile
   archives, identity or Team-ID changes, offline behavior, cancellation,
   redirects, and a real Gatekeeper-accepted release.

### Explicit installation boundary

After **Download & Verify** succeeds, the app offers **Install & Relaunch**.
That action requires another explicit confirmation and repeats the ZIP digest,
bundle metadata, both signatures, Gatekeeper state, version/build, and
same-team checks before the running app starts the staged candidate executable
in installer mode and quits.

MojiPond ships no privileged helper, daemon, second executable, or silent
installation path. Its one-executable installer:

1. validates the exact staging/current/destination layout and rejects
   symlinks;
2. acquires a non-following lock beside the destination and consumes the
   private, one-time authorization for the exact running app and staged
   candidate;
3. waits for the old PID, then takes over the private staging lease;
4. rechecks the signed archive and both Developer ID identities;
5. copies and verifies a unique sibling candidate;
6. atomically exchanges the sibling candidate with the exact destination, then
   moves the displaced app to a backup name;
7. verifies and launches the final app; and
8. removes the backup and staging directory only after normal services and the
   status item start and the app writes a private readiness acknowledgement.

Failures after replacement begins terminate the attempted launch, restore the
backup, and verify the previous build. If the destination parent is not
writable, the UI instead offers the verified candidate in Finder for honest
manual replacement. Every other safety failure remains a hard failure.

## Release checklist

- [ ] Version and build number updated.
- [ ] Clean-clone build and complete test suite pass.
- [ ] Universal `arm64` and `x86_64` slices confirmed.
- [ ] Developer ID signature, Team ID, Hardened Runtime, timestamp, and
      entitlements inspected.
- [ ] Notary submission accepted; ticket stapled and validated.
- [ ] SHA-256 checksums regenerated after all byte-changing steps.
- [ ] DMG or ZIP tested after download and extraction on a clean environment.
- [ ] Permissions, secure-field suspension, exclusions, Unicode, PNG, GIF, and
      clipboard behavior manually verified without sending a Message.
- [ ] ZIP picker, ZIP drag and drop, preview, install, and ZIP replacement
      manually verified; no direct file, folder, Slack-manifest, or GitHub
      import entry point is exposed.
- [ ] Light, dark, reduced-motion, keyboard, and VoiceOver UI audits complete.
- [ ] Compatibility ledger updated with exact evidence.
- [ ] Release notes and third-party attributions reviewed.
- [ ] AppIcon renditions reviewed against the first-party source artwork at
      `Resources/Branding/MojiPond-AppIcon-Source.png`.
- [ ] Signed update metadata published only if the feed-generation and trusted
      public-key and Team-ID configuration are fully verified.
- [ ] Update ZIP contains exactly one notarized `MojiPond.app`, and its final
      signed byte count and SHA-256 are recorded in the signed metadata.
- [ ] A real Developer ID build downloads, stages, revalidates, installs,
      relaunches, acknowledges readiness, and removes its backup; an ad-hoc
      build is confirmed unable to stage it.
- [ ] A forced post-swap failure restores and re-verifies the previous build,
      and an unwritable destination shows only the manual Finder fallback.
- [ ] The packaged app contains one application executable and no updater
      helper, daemon, or privileged component.
