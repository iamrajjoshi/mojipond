#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY=${0:A:h}
REPOSITORY_ROOT=${SCRIPT_DIRECTORY:h}
BUILD_CONFIGURATION=${1:-Debug}
BUILD_ACTION=${2:-build}
DERIVED_DATA_PATH=${MOJIPOND_DERIVED_DATA_PATH:-"${REPOSITORY_ROOT}/DerivedData"}
SIGNING_IDENTITY=${MOJIPOND_SIGNING_IDENTITY:-}
DEVELOPMENT_TEAM=${MOJIPOND_DEVELOPMENT_TEAM:-}
BUILD_ARCHITECTURES=${MOJIPOND_ARCHS:-}
UPDATE_FEED_URL=${MOJIPOND_UPDATE_FEED_URL:-}
UPDATE_SIGNATURE_ALGORITHM=${MOJIPOND_UPDATE_SIGNATURE_ALGORITHM:-}
UPDATE_PUBLIC_KEY_BASE64=${MOJIPOND_UPDATE_PUBLIC_KEY_BASE64:-}
UPDATE_TEAM_IDENTIFIER=${MOJIPOND_UPDATE_TEAM_IDENTIFIER:-}

UPDATE_CONFIGURATION_VALUES=(
  "${UPDATE_FEED_URL}"
  "${UPDATE_SIGNATURE_ALGORITHM}"
  "${UPDATE_PUBLIC_KEY_BASE64}"
  "${UPDATE_TEAM_IDENTIFIER}"
)
UPDATE_CONFIGURATION_VALUE_COUNT=0
for value in "${UPDATE_CONFIGURATION_VALUES[@]}"; do
  if [[ -n "${value}" ]]; then
    (( UPDATE_CONFIGURATION_VALUE_COUNT += 1 ))
  fi
done

if (( UPDATE_CONFIGURATION_VALUE_COUNT != 0 \
      && UPDATE_CONFIGURATION_VALUE_COUNT != 4 )); then
  echo "Update configuration must set all four MOJIPOND_UPDATE_* values or none." >&2
  exit 64
fi

if (( UPDATE_CONFIGURATION_VALUE_COUNT == 4 )); then
  if [[ "${UPDATE_FEED_URL}" != https://* \
        || "${UPDATE_FEED_URL}" == *[[:space:]]* ]]; then
    echo "MOJIPOND_UPDATE_FEED_URL must be an absolute HTTPS URL without whitespace." >&2
    exit 64
  fi
  UPDATE_FEED_AUTHORITY=${UPDATE_FEED_URL#https://}
  UPDATE_FEED_AUTHORITY=${UPDATE_FEED_AUTHORITY%%/*}
  UPDATE_FEED_AUTHORITY=${UPDATE_FEED_AUTHORITY%%\?*}
  UPDATE_FEED_AUTHORITY=${UPDATE_FEED_AUTHORITY%%\#*}
  if [[ -z "${UPDATE_FEED_AUTHORITY}" \
        || "${UPDATE_FEED_AUTHORITY}" == *"@"* ]]; then
    echo "MOJIPOND_UPDATE_FEED_URL must include a host and must not include credentials." >&2
    exit 64
  fi

  case "${UPDATE_SIGNATURE_ALGORITHM}" in
    ed25519)
      EXPECTED_UPDATE_PUBLIC_KEY_BYTE_COUNT=32
      ;;
    p256-sha256)
      EXPECTED_UPDATE_PUBLIC_KEY_BYTE_COUNT=64
      ;;
    *)
      echo "MOJIPOND_UPDATE_SIGNATURE_ALGORITHM must be ed25519 or p256-sha256." >&2
      exit 64
      ;;
  esac

  if [[ "${UPDATE_PUBLIC_KEY_BASE64}" == *[[:space:]]* ]]; then
    echo "MOJIPOND_UPDATE_PUBLIC_KEY_BASE64 must not contain whitespace." >&2
    exit 64
  fi
  if ! /usr/bin/printf '%s\n' "${UPDATE_PUBLIC_KEY_BASE64}" \
      | /usr/bin/grep -Eq '^[A-Za-z0-9+/]+={1,2}$'; then
    echo "MOJIPOND_UPDATE_PUBLIC_KEY_BASE64 must contain valid standard Base64." >&2
    exit 64
  fi
  if ! DECODED_UPDATE_PUBLIC_KEY_BYTE_COUNT=$(
    /usr/bin/printf '%s' "${UPDATE_PUBLIC_KEY_BASE64}" \
      | /usr/bin/base64 -D 2>/dev/null \
      | /usr/bin/wc -c \
      | /usr/bin/tr -d '[:space:]'
  ); then
    echo "MOJIPOND_UPDATE_PUBLIC_KEY_BASE64 must contain valid Base64." >&2
    exit 64
  fi
  if [[ "${DECODED_UPDATE_PUBLIC_KEY_BYTE_COUNT}" \
        != "${EXPECTED_UPDATE_PUBLIC_KEY_BYTE_COUNT}" ]]; then
    echo "MOJIPOND_UPDATE_PUBLIC_KEY_BASE64 has the wrong raw-key length for ${UPDATE_SIGNATURE_ALGORITHM}." >&2
    exit 64
  fi

  if ! /usr/bin/printf '%s\n' "${UPDATE_TEAM_IDENTIFIER}" \
      | /usr/bin/grep -Eq '^[A-Z0-9]{10}$'; then
    echo "MOJIPOND_UPDATE_TEAM_IDENTIFIER must be a 10-character uppercase Apple Team ID." >&2
    exit 64
  fi
  if [[ -n "${DEVELOPMENT_TEAM}" \
        && "${UPDATE_TEAM_IDENTIFIER}" != "${DEVELOPMENT_TEAM}" ]]; then
    echo "MOJIPOND_UPDATE_TEAM_IDENTIFIER must match MOJIPOND_DEVELOPMENT_TEAM." >&2
    exit 64
  fi
fi

case "${BUILD_CONFIGURATION}" in
  Debug|Release)
    ;;
  *)
    echo "Usage: $0 [Debug|Release] [build|archive]" >&2
    exit 64
    ;;
esac

case "${BUILD_ACTION}" in
  build|archive)
    ;;
  *)
    echo "Usage: $0 [Debug|Release] [build|archive]" >&2
    exit 64
    ;;
esac

if [[ "${BUILD_ACTION}" == "archive" && "${BUILD_CONFIGURATION}" != "Release" ]]; then
  echo "Archives must use the Release configuration." >&2
  exit 64
fi

if [[ -z "${BUILD_ARCHITECTURES}" && "${BUILD_CONFIGURATION}" == "Release" ]]; then
  BUILD_ARCHITECTURES="arm64 x86_64"
fi

for required_command in xcodegen xcodebuild codesign; do
  if ! command -v "${required_command}" >/dev/null 2>&1; then
    echo "Required command not found: ${required_command}" >&2
    exit 69
  fi
done

if [[ -z "${SIGNING_IDENTITY}" ]]; then
  if [[ "${BUILD_CONFIGURATION}" == "Debug" ]]; then
    APPLE_DEVELOPMENT_IDENTITIES=(${(f)"$(
      /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
        | /usr/bin/sed -nE \
          's/^[[:space:]]*[0-9]+\)[[:space:]]+([[:xdigit:]]{40})[[:space:]]+"Apple Development:.*$/\1/p'
    )"})

    case "${#APPLE_DEVELOPMENT_IDENTITIES[@]}" in
      0)
        SIGNING_IDENTITY="-"
        echo "No Apple Development identity found; using ad-hoc Debug signing." >&2
        ;;
      1)
        SIGNING_IDENTITY=${APPLE_DEVELOPMENT_IDENTITIES[1]}
        echo "Using the available Apple Development identity for Debug signing." >&2
        ;;
      *)
        echo "Multiple Apple Development identities found." >&2
        echo "Set MOJIPOND_SIGNING_IDENTITY to the intended identity or fingerprint." >&2
        exit 78
        ;;
    esac
  else
    SIGNING_IDENTITY="-"
  fi
fi

if [[ "${MOJIPOND_REQUIRE_DEVELOPER_ID:-0}" == "1" \
      && "${SIGNING_IDENTITY}" != "Developer ID Application:"* ]]; then
  echo "MOJIPOND_REQUIRE_DEVELOPER_ID=1 requires a Developer ID Application identity." >&2
  exit 78
fi

cd "${REPOSITORY_ROOT}"
xcodegen generate

BUILD_SETTINGS=(
  "CODE_SIGN_STYLE=Manual"
  "CODE_SIGN_IDENTITY=${SIGNING_IDENTITY}"
  "CODE_SIGNING_REQUIRED=YES"
)

if [[ -n "${DEVELOPMENT_TEAM}" ]]; then
  BUILD_SETTINGS+=("DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM}")
fi

if [[ -n "${BUILD_ARCHITECTURES}" ]]; then
  BUILD_SETTINGS+=(
    "ARCHS=${BUILD_ARCHITECTURES}"
    "ONLY_ACTIVE_ARCH=NO"
  )
fi

if (( UPDATE_CONFIGURATION_VALUE_COUNT == 4 )); then
  BUILD_SETTINGS+=(
    "MOJIPOND_UPDATE_FEED_URL=${UPDATE_FEED_URL}"
    "MOJIPOND_UPDATE_SIGNATURE_ALGORITHM=${UPDATE_SIGNATURE_ALGORITHM}"
    "MOJIPOND_UPDATE_PUBLIC_KEY_BASE64=${UPDATE_PUBLIC_KEY_BASE64}"
    "MOJIPOND_UPDATE_TEAM_IDENTIFIER=${UPDATE_TEAM_IDENTIFIER}"
  )
fi

XCODEBUILD_ARGUMENTS=(
  -project MojiPond.xcodeproj \
  -scheme MojiPond \
  -configuration "${BUILD_CONFIGURATION}" \
  -derivedDataPath "${DERIVED_DATA_PATH}"
)

if [[ "${BUILD_ACTION}" == "archive" ]]; then
  ARCHIVE_PATH=${MOJIPOND_ARCHIVE_PATH:-}
  if [[ -z "${ARCHIVE_PATH}" ]]; then
    echo "Set MOJIPOND_ARCHIVE_PATH to a new .xcarchive path." >&2
    exit 64
  fi
  if [[ -e "${ARCHIVE_PATH}" ]]; then
    echo "Refusing to overwrite existing archive: ${ARCHIVE_PATH}" >&2
    exit 73
  fi
  mkdir -p "${ARCHIVE_PATH:h}"
  XCODEBUILD_ARGUMENTS+=(
    -destination "generic/platform=macOS"
    -archivePath "${ARCHIVE_PATH}"
    archive
  )
  APPLICATION_PATH="${ARCHIVE_PATH}/Products/Applications/MojiPond.app"
else
  XCODEBUILD_ARGUMENTS+=(build)
  APPLICATION_PATH="${DERIVED_DATA_PATH}/Build/Products/${BUILD_CONFIGURATION}/MojiPond.app"
fi

xcodebuild "${XCODEBUILD_ARGUMENTS[@]}" "${BUILD_SETTINGS[@]}"

if [[ ! -d "${APPLICATION_PATH}" ]]; then
  echo "Build succeeded but the application was not found: ${APPLICATION_PATH}" >&2
  exit 66
fi

/usr/bin/codesign --verify --deep --strict "${APPLICATION_PATH}"

if (( UPDATE_CONFIGURATION_VALUE_COUNT == 4 )); then
  SIGNED_TEAM_IDENTIFIER=$(
    /usr/bin/codesign --display --verbose=4 \
      "${APPLICATION_PATH}" 2>&1 \
      | /usr/bin/sed -n 's/^TeamIdentifier=//p' \
      | /usr/bin/head -n 1
  )
  if [[ "${SIGNED_TEAM_IDENTIFIER}" != "${UPDATE_TEAM_IDENTIFIER}" ]]; then
    echo "The signed app TeamIdentifier does not match MOJIPOND_UPDATE_TEAM_IDENTIFIER." >&2
    exit 65
  fi
fi

if [[ "${BUILD_CONFIGURATION}" == "Release" \
      && "${BUILD_ARCHITECTURES}" == *arm64* \
      && "${BUILD_ARCHITECTURES}" == *x86_64* ]]; then
  EXECUTABLE_PATH="${APPLICATION_PATH}/Contents/MacOS/MojiPond"
  /usr/bin/lipo "${EXECUTABLE_PATH}" -verify_arch arm64 x86_64
fi

echo "${APPLICATION_PATH}"
