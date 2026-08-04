#!/bin/zsh

set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 /absolute/path/to/MojiPond.app 'Developer ID Application: …' /absolute/path/to/MojiPond.entitlements" >&2
  exit 64
fi

APPLICATION_PATH=$1
SIGNING_IDENTITY=$2
APPLICATION_ENTITLEMENTS=$3

if [[ "${APPLICATION_PATH}" != /* || ! -d "${APPLICATION_PATH}" ]]; then
  echo "The application path must be an existing absolute path." >&2
  exit 66
fi
if [[ "${APPLICATION_PATH:t}" != "MojiPond.app" ]]; then
  echo "Refusing to sign an unexpected application bundle." >&2
  exit 65
fi
if [[ "${SIGNING_IDENTITY}" != "Developer ID Application:"* ]]; then
  echo "Distribution signing requires a Developer ID Application identity." >&2
  exit 78
fi
if [[ "${APPLICATION_ENTITLEMENTS}" != /* || ! -f "${APPLICATION_ENTITLEMENTS}" ]]; then
  echo "The application entitlements path must be an existing absolute path." >&2
  exit 66
fi

SPARKLE_FRAMEWORK="${APPLICATION_PATH}/Contents/Frameworks/Sparkle.framework"
SPARKLE_VERSION_DIRECTORY="${SPARKLE_FRAMEWORK}/Versions/B"
INSTALLER_SERVICE="${SPARKLE_VERSION_DIRECTORY}/XPCServices/Installer.xpc"
DOWNLOADER_SERVICE="${SPARKLE_VERSION_DIRECTORY}/XPCServices/Downloader.xpc"
AUTOUPDATE_TOOL="${SPARKLE_VERSION_DIRECTORY}/Autoupdate"
UPDATER_APPLICATION="${SPARKLE_VERSION_DIRECTORY}/Updater.app"

for required_path in \
  "${INSTALLER_SERVICE}" \
  "${DOWNLOADER_SERVICE}" \
  "${AUTOUPDATE_TOOL}" \
  "${UPDATER_APPLICATION}" \
  "${SPARKLE_FRAMEWORK}"; do
  if [[ ! -e "${required_path}" ]]; then
    echo "The application is missing required embedded code: ${required_path}" >&2
    exit 65
  fi
done

sign_runtime_code() {
  /usr/bin/codesign \
    --force \
    --sign "${SIGNING_IDENTITY}" \
    --timestamp \
    --options runtime \
    "$1"
}

# Sparkle's helpers must be signed individually from the deepest code outward.
# Downloader.xpc carries a service-specific entitlement in Sparkle 2.6 and later.
sign_runtime_code "${INSTALLER_SERVICE}"
/usr/bin/codesign \
  --force \
  --sign "${SIGNING_IDENTITY}" \
  --timestamp \
  --options runtime \
  --preserve-metadata=entitlements \
  "${DOWNLOADER_SERVICE}"
sign_runtime_code "${AUTOUPDATE_TOOL}"
sign_runtime_code "${UPDATER_APPLICATION}"
sign_runtime_code "${SPARKLE_FRAMEWORK}"

# The containing app is always signed last, with only MojiPond's entitlements.
/usr/bin/codesign \
  --force \
  --sign "${SIGNING_IDENTITY}" \
  --timestamp \
  --options runtime \
  --entitlements "${APPLICATION_ENTITLEMENTS}" \
  "${APPLICATION_PATH}"
