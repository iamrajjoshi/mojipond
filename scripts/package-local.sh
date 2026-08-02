#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY=${0:A:h}
REPOSITORY_ROOT=${SCRIPT_DIRECTORY:h}
ARTIFACT_ROOT="${REPOSITORY_ROOT}/Artifacts/releases"
SIGNING_IDENTITY=${MOJIPOND_SIGNING_IDENTITY:-"-"}
EXPECTED_IDENTIFIER="com.rajjoshi.MojiPond"
BUILD_TIMESTAMP_UTC=$(/bin/date -u "+%Y-%m-%dT%H:%M:%SZ")
RELEASE_TIMESTAMP=${BUILD_TIMESTAMP_UTC//[-:]/}
RELEASE_STEM="MojiPond-${RELEASE_TIMESTAMP}-local"
ARTIFACT_DIRECTORY="${ARTIFACT_ROOT}/${RELEASE_STEM}"
ARCHIVE_PATH="${ARTIFACT_DIRECTORY}/${RELEASE_STEM}.xcarchive"
APPLICATION_PATH="${ARCHIVE_PATH}/Products/Applications/MojiPond.app"
ZIP_PATH="${ARTIFACT_DIRECTORY}/${RELEASE_STEM}.zip"
DMG_PATH="${ARTIFACT_DIRECTORY}/${RELEASE_STEM}.dmg"
BUILD_METADATA_PATH="${ARTIFACT_DIRECTORY}/BUILD-METADATA.json"
CHECKSUM_PATH="${ARTIFACT_DIRECTORY}/SHA256SUMS.txt"

source_worktree_status() {
  /usr/bin/git \
    -C "${REPOSITORY_ROOT}" \
    status \
    --porcelain=v1 \
    --untracked-files=all \
    --ignore-submodules=none
  /usr/bin/git \
    -C "${REPOSITORY_ROOT}" \
    ls-files \
    --others \
    --ignored \
    --exclude-standard \
    -- \
    Sources \
    Resources \
    | /usr/bin/sed 's|^|!! |'
  /usr/bin/git \
    -C "${REPOSITORY_ROOT}" \
    ls-files \
    -v \
    | /usr/bin/awk '
        substr($0, 1, 1) == "S" || substr($0, 1, 1) ~ /[a-z]/ {
            print "index-flag " $0
          }
      '
}

assert_source_clean() {
  local source_changes
  source_changes=$(source_worktree_status)
  if [[ -n "${source_changes}" ]]; then
    echo "Refusing to package because the Git working tree differs from HEAD:" >&2
    echo "${source_changes}" >&2
    exit 65
  fi
}

current_source_branch() {
  local branch_name
  branch_name=$(
    /usr/bin/git \
      -C "${REPOSITORY_ROOT}" \
      symbolic-ref \
      --quiet \
      --short \
      HEAD 2>/dev/null || true
  )
  if [[ -z "${branch_name}" ]]; then
    branch_name="(detached)"
  fi
  echo "${branch_name}"
}

assert_source_identity_unchanged() {
  local current_revision current_branch
  assert_source_clean
  current_revision=$(
    /usr/bin/git -C "${REPOSITORY_ROOT}" rev-parse --verify "HEAD^{commit}"
  )
  current_branch=$(current_source_branch)
  if [[ "${current_revision}" != "${SOURCE_REVISION}" \
        || "${current_branch}" != "${SOURCE_BRANCH}" ]]; then
    echo "Refusing to package because the source revision or branch changed during the build." >&2
    exit 65
  fi
}

json_escape() {
  local escaped_value=$1
  escaped_value=${escaped_value//\\/\\\\}
  escaped_value=${escaped_value//\"/\\\"}
  escaped_value=${escaped_value//$'\b'/\\b}
  escaped_value=${escaped_value//$'\f'/\\f}
  escaped_value=${escaped_value//$'\n'/\\n}
  escaped_value=${escaped_value//$'\r'/\\r}
  escaped_value=${escaped_value//$'\t'/\\t}
  print -rn -- "${escaped_value}"
}

write_build_metadata() {
  local output_path=$1
  {
    /usr/bin/printf '{\n'
    /usr/bin/printf '  "schemaVersion": 1,\n'
    /usr/bin/printf '  "revision": "%s",\n' \
      "$(json_escape "${SOURCE_REVISION}")"
    /usr/bin/printf '  "branch": "%s",\n' \
      "$(json_escape "${SOURCE_BRANCH}")"
    /usr/bin/printf '  "clean": true,\n'
    /usr/bin/printf '  "buildTimestampUTC": "%s",\n' \
      "$(json_escape "${BUILD_TIMESTAMP_UTC}")"
    /usr/bin/printf '  "bundleIdentifier": "%s",\n' \
      "$(json_escape "${APPLICATION_IDENTIFIER}")"
    /usr/bin/printf '  "version": "%s",\n' \
      "$(json_escape "${APPLICATION_VERSION}")"
    /usr/bin/printf '  "build": "%s",\n' \
      "$(json_escape "${APPLICATION_BUILD}")"
    /usr/bin/printf '  "signingClass": "%s"\n' \
      "$(json_escape "${SIGNING_CLASS}")"
    /usr/bin/printf '}\n'
  } > "${output_path}"

  /bin/chmod 0644 "${output_path}"
  /usr/bin/plutil -extract schemaVersion raw -o - "${output_path}" \
    >/dev/null
}

if ! /usr/bin/git \
    -C "${REPOSITORY_ROOT}" \
    rev-parse \
    --is-inside-work-tree >/dev/null 2>&1; then
  echo "Packaging requires a Git working tree." >&2
  exit 69
fi

assert_source_clean
SOURCE_REVISION=$(
  /usr/bin/git -C "${REPOSITORY_ROOT}" rev-parse --verify "HEAD^{commit}"
)
SOURCE_BRANCH=$(current_source_branch)

case "${SIGNING_IDENTITY}" in
  -)
    SIGNING_CLASS="ad-hoc"
    ;;
  "Developer ID Application:"*)
    SIGNING_CLASS="developer-id"
    ;;
  *)
    SIGNING_CLASS="other"
    ;;
esac

if [[ "${MOJIPOND_REQUIRE_DEVELOPER_ID:-0}" == "1" \
      && "${SIGNING_IDENTITY}" != "Developer ID Application:"* ]]; then
  echo "MOJIPOND_REQUIRE_DEVELOPER_ID=1 requires a Developer ID Application identity." >&2
  exit 78
fi

if [[ -e "${ARTIFACT_DIRECTORY}" ]]; then
  echo "Refusing to overwrite existing release directory: ${ARTIFACT_DIRECTORY}" >&2
  exit 73
fi

if ! TEMPORARY_DIRECTORY=$(
  /usr/bin/mktemp -d "${TMPDIR:-/tmp}/mojipond-package.XXXXXX"
); then
  echo "Could not create a temporary packaging directory." >&2
  exit 73
fi
cleanup() {
  if [[ -n "${TEMPORARY_DIRECTORY:-}" \
        && -d "${TEMPORARY_DIRECTORY}" \
        && "${TEMPORARY_DIRECTORY}" == *"/mojipond-package."* ]]; then
    /bin/rm -rf -- "${TEMPORARY_DIRECTORY}"
  fi
}
trap cleanup EXIT

SOURCE_SNAPSHOT_DIRECTORY="${TEMPORARY_DIRECTORY}/source"
DMG_STAGING_DIRECTORY="${TEMPORARY_DIRECTORY}/dmg"
/bin/mkdir -m 0700 \
  "${SOURCE_SNAPSHOT_DIRECTORY}" \
  "${DMG_STAGING_DIRECTORY}"
/usr/bin/git \
  -C "${REPOSITORY_ROOT}" \
  archive \
  --format=tar \
  "${SOURCE_REVISION}" \
  | /usr/bin/tar -x -C "${SOURCE_SNAPSHOT_DIRECTORY}"

mkdir -p "${ARTIFACT_DIRECTORY}"
MOJIPOND_ARCHIVE_PATH="${ARCHIVE_PATH}" \
  MOJIPOND_DERIVED_DATA_PATH="${TEMPORARY_DIRECTORY}/DerivedData" \
  "${SOURCE_SNAPSHOT_DIRECTORY}/scripts/build.sh" Release archive

APPLICATION_IDENTIFIER=$(
  /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
    "${APPLICATION_PATH}/Contents/Info.plist" 2>/dev/null || true
)
if [[ "${APPLICATION_IDENTIFIER}" != "${EXPECTED_IDENTIFIER}" ]]; then
  echo "Archive contains an unexpected bundle identifier: '${APPLICATION_IDENTIFIER}'." >&2
  exit 65
fi

APPLICATION_VERSION=$(
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "${APPLICATION_PATH}/Contents/Info.plist" 2>/dev/null || true
)
APPLICATION_BUILD=$(
  /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" \
    "${APPLICATION_PATH}/Contents/Info.plist" 2>/dev/null || true
)
if [[ -z "${APPLICATION_VERSION}" || -z "${APPLICATION_BUILD}" ]]; then
  echo "Archive is missing its bundle version or build number." >&2
  exit 65
fi

NOTICE_PATH="${APPLICATION_PATH}/Contents/Resources/THIRD-PARTY-NOTICES.txt"
SENTRY_NOTICE_PATH="${APPLICATION_PATH}/Contents/Resources/SENTRY-THIRD-PARTY-NOTICES.txt"
if [[ ! -s "${NOTICE_PATH}" ]]; then
  echo "Archive is missing the bundled third-party notices." >&2
  exit 65
fi
if ! /usr/bin/grep -q "Copyright (c) 2019 GitHub, Inc." "${NOTICE_PATH}" \
    || ! /usr/bin/grep -q "Copyright (c) 2015 Sentry" "${NOTICE_PATH}" \
    || ! /usr/bin/grep -q "Creative Commons Attribution 4.0" "${NOTICE_PATH}"; then
  echo "Archive contains incomplete third-party notices." >&2
  exit 65
fi
if [[ ! -s "${SENTRY_NOTICE_PATH}" ]]; then
  echo "Archive is missing the bundled Sentry transitive notices." >&2
  exit 65
fi
if ! /usr/bin/grep -q "Karl Stenerud" "${SENTRY_NOTICE_PATH}" \
    || ! /usr/bin/grep -q "YANDEX LLC" "${SENTRY_NOTICE_PATH}" \
    || ! /usr/bin/grep -q "Facebook, Inc." "${SENTRY_NOTICE_PATH}" \
    || ! /usr/bin/grep -q "Apple Public Source License" "${SENTRY_NOTICE_PATH}"; then
  echo "Archive contains incomplete Sentry transitive notices." >&2
  exit 65
fi

/usr/bin/ditto \
  "${APPLICATION_PATH}" \
  "${DMG_STAGING_DIRECTORY}/MojiPond.app"
/bin/ln -s /Applications "${DMG_STAGING_DIRECTORY}/Applications"
/usr/bin/ditto \
  -c \
  -k \
  --norsrc \
  --noextattr \
  --noqtn \
  --keepParent \
  "${APPLICATION_PATH}" \
  "${ZIP_PATH}"
/usr/bin/hdiutil create \
  -volname "MojiPond" \
  -srcfolder "${DMG_STAGING_DIRECTORY}" \
  -format UDZO \
  "${DMG_PATH}"

if [[ "${SIGNING_IDENTITY}" != "-" ]]; then
  /usr/bin/codesign \
    --force \
    --sign "${SIGNING_IDENTITY}" \
    --timestamp \
    "${DMG_PATH}"
  /usr/bin/codesign --verify --verbose=2 "${DMG_PATH}"
fi

/usr/bin/hdiutil verify "${DMG_PATH}"
/usr/bin/unzip -tq "${ZIP_PATH}"
/usr/bin/codesign --verify --deep --strict "${APPLICATION_PATH}"
/usr/bin/lipo \
  "${APPLICATION_PATH}/Contents/MacOS/MojiPond" \
  -verify_arch \
  arm64 \
  x86_64

assert_source_identity_unchanged
TEMPORARY_BUILD_METADATA_PATH="${TEMPORARY_DIRECTORY}/BUILD-METADATA.json"
write_build_metadata "${TEMPORARY_BUILD_METADATA_PATH}"
/bin/mv "${TEMPORARY_BUILD_METADATA_PATH}" "${BUILD_METADATA_PATH}"
assert_source_identity_unchanged

(
  cd "${ARTIFACT_DIRECTORY}"
  /usr/bin/shasum \
    -a 256 \
    "${ZIP_PATH:t}" \
    "${DMG_PATH:t}" \
    "${BUILD_METADATA_PATH:t}" \
    > "${CHECKSUM_PATH:t}"
)
assert_source_identity_unchanged

echo "Archive: ${ARCHIVE_PATH}"
echo "ZIP: ${ZIP_PATH}"
echo "DMG: ${DMG_PATH}"
echo "Build metadata: ${BUILD_METADATA_PATH}"
echo "Checksums: ${CHECKSUM_PATH}"
