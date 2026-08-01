#!/bin/zsh

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 /absolute/path/to/release-directory [expected-signing-class]" >&2
  exit 64
fi

ARTIFACT_DIRECTORY=$1
EXPECTED_SIGNING_CLASS=${2:-}

case "${EXPECTED_SIGNING_CLASS}" in
  "" | ad-hoc | developer-id | other)
    ;;
  *)
    echo "Expected signing class must be ad-hoc, developer-id, or other." >&2
    exit 64
    ;;
esac

if [[ "${ARTIFACT_DIRECTORY}" != /* || ! -d "${ARTIFACT_DIRECTORY}" ]]; then
  echo "Release directory must be an existing absolute path." >&2
  exit 66
fi

ARCHIVES=("${ARTIFACT_DIRECTORY}"/*.xcarchive(N))
ZIPS=("${ARTIFACT_DIRECTORY}"/*.zip(N))
DMGS=("${ARTIFACT_DIRECTORY}"/*.dmg(N))

if (( ${#ARCHIVES[@]} != 1 || ${#ZIPS[@]} != 1 || ${#DMGS[@]} != 1 )); then
  echo "Expected exactly one XCArchive, ZIP, and DMG." >&2
  exit 65
fi

ARCHIVE_PATH=${ARCHIVES[1]}
ZIP_PATH=${ZIPS[1]}
DMG_PATH=${DMGS[1]}
APPLICATION_PATH="${ARCHIVE_PATH}/Products/Applications/MojiPond.app"
METADATA_PATH="${ARTIFACT_DIRECTORY}/BUILD-METADATA.json"
CHECKSUM_PATH="${ARTIFACT_DIRECTORY}/SHA256SUMS.txt"

metadata_value() {
  local key=$1
  local expected_type=$2
  /usr/bin/plutil \
    -extract "${key}" \
    raw \
    -expect "${expected_type}" \
    -o - \
    "${METADATA_PATH}" \
    || {
      echo "BUILD-METADATA.json field '${key}' must be ${expected_type}." >&2
      exit 65
    }
}

for required_path in \
  "${APPLICATION_PATH}" \
  "${METADATA_PATH}" \
  "${CHECKSUM_PATH}"; do
  if [[ ! -e "${required_path}" ]]; then
    echo "Release package is missing: ${required_path}" >&2
    exit 65
  fi
done

(
  cd "${ARTIFACT_DIRECTORY}"
  /usr/bin/shasum -a 256 -c "${CHECKSUM_PATH:t}"
)

METADATA_SCHEMA_VERSION=$(metadata_value schemaVersion integer)
METADATA_REVISION=$(metadata_value revision string)
METADATA_BRANCH=$(metadata_value branch string)
METADATA_BUILD_TIMESTAMP=$(metadata_value buildTimestampUTC string)
METADATA_CLEAN=$(metadata_value clean bool)
METADATA_BUNDLE_IDENTIFIER=$(metadata_value bundleIdentifier string)
METADATA_VERSION=$(metadata_value version string)
METADATA_BUILD=$(metadata_value build string)
SIGNING_CLASS=$(metadata_value signingClass string)

if [[ "${METADATA_SCHEMA_VERSION}" != "1" \
      || ! "${METADATA_REVISION}" =~ ^[0-9a-f]{40}$ \
      || -z "${METADATA_BRANCH}" \
      || ! "${METADATA_BUILD_TIMESTAMP}" \
        =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ \
      || "${METADATA_CLEAN}" != "true" \
      || "${METADATA_BUNDLE_IDENTIFIER}" != "com.rajjoshi.MojiPond" \
      || ! "${METADATA_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ \
      || ! "${METADATA_BUILD}" =~ ^[1-9][0-9]*$ ]]; then
  echo "BUILD-METADATA.json failed its fixed-schema checks." >&2
  exit 65
fi

case "${SIGNING_CLASS}" in
  ad-hoc | developer-id | other)
    ;;
  *)
    echo "BUILD-METADATA.json contains an unknown signing class." >&2
    exit 65
    ;;
esac

if [[ -n "${EXPECTED_SIGNING_CLASS}" \
      && "${SIGNING_CLASS}" != "${EXPECTED_SIGNING_CLASS}" ]]; then
  echo "Expected signing class '${EXPECTED_SIGNING_CLASS}', found '${SIGNING_CLASS}'." >&2
  exit 65
fi

APPLICATION_VERSION=$(
  /usr/libexec/PlistBuddy \
    -c "Print :CFBundleShortVersionString" \
    "${APPLICATION_PATH}/Contents/Info.plist"
)
APPLICATION_BUILD=$(
  /usr/libexec/PlistBuddy \
    -c "Print :CFBundleVersion" \
    "${APPLICATION_PATH}/Contents/Info.plist"
)
if [[ "${APPLICATION_VERSION}" != "${METADATA_VERSION}" \
      || "${APPLICATION_BUILD}" != "${METADATA_BUILD}" ]]; then
  echo "The archived app and build metadata versions do not match." >&2
  exit 65
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "${APPLICATION_PATH}"
/usr/bin/lipo \
  "${APPLICATION_PATH}/Contents/MacOS/MojiPond" \
  -verify_arch arm64 x86_64
/usr/bin/unzip -tq "${ZIP_PATH}"
/usr/bin/hdiutil verify "${DMG_PATH}"

if [[ "${SIGNING_CLASS}" == "developer-id" ]]; then
  SIGNATURE_DETAILS=$(
    /usr/bin/codesign --display --verbose=4 "${APPLICATION_PATH}" 2>&1
  )
  if [[ "${SIGNATURE_DETAILS}" != *"Authority=Developer ID Application:"* \
        || "${SIGNATURE_DETAILS}" != *"flags=0x10000(runtime)"* \
        || "${SIGNATURE_DETAILS}" != *"Timestamp="* ]]; then
    echo "The app is missing a Developer ID authority, Hardened Runtime, or timestamp." >&2
    exit 65
  fi
fi

echo "Verified release package: ${ARTIFACT_DIRECTORY}"
