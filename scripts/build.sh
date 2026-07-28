#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY=${0:A:h}
REPOSITORY_ROOT=${SCRIPT_DIRECTORY:h}
BUILD_CONFIGURATION=${1:-Debug}
BUILD_ACTION=${2:-build}
DERIVED_DATA_PATH=${MOJIPOND_DERIVED_DATA_PATH:-"${REPOSITORY_ROOT}/DerivedData"}
SIGNING_IDENTITY=${MOJIPOND_SIGNING_IDENTITY:-"-"}
DEVELOPMENT_TEAM=${MOJIPOND_DEVELOPMENT_TEAM:-}
BUILD_ARCHITECTURES=${MOJIPOND_ARCHS:-}

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

if [[ "${MOJIPOND_REQUIRE_DEVELOPER_ID:-0}" == "1" \
      && "${SIGNING_IDENTITY}" != "Developer ID Application:"* ]]; then
  echo "MOJIPOND_REQUIRE_DEVELOPER_ID=1 requires a Developer ID Application identity." >&2
  exit 78
fi

for required_command in xcodegen xcodebuild codesign; do
  if ! command -v "${required_command}" >/dev/null 2>&1; then
    echo "Required command not found: ${required_command}" >&2
    exit 69
  fi
done

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

if [[ "${BUILD_CONFIGURATION}" == "Release" \
      && "${BUILD_ARCHITECTURES}" == *arm64* \
      && "${BUILD_ARCHITECTURES}" == *x86_64* ]]; then
  EXECUTABLE_PATH="${APPLICATION_PATH}/Contents/MacOS/MojiPond"
  /usr/bin/lipo "${EXECUTABLE_PATH}" -verify_arch arm64 x86_64
fi

echo "${APPLICATION_PATH}"
