#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY=${0:A:h}
REPOSITORY_ROOT=${SCRIPT_DIRECTORY:h}
SOURCE_APPLICATION="${REPOSITORY_ROOT}/DerivedData/Build/Products/Debug/MojiPond.app"
INSTALLED_APPLICATION="/Applications/MojiPond.app"
EXPECTED_IDENTIFIER="com.rajjoshi.MojiPond"

"${SCRIPT_DIRECTORY}/build.sh" Debug

if [[ -d "${INSTALLED_APPLICATION}" ]]; then
  INSTALLED_IDENTIFIER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${INSTALLED_APPLICATION}/Contents/Info.plist" 2>/dev/null || true)
  if [[ "${INSTALLED_IDENTIFIER}" != "${EXPECTED_IDENTIFIER}" ]]; then
    echo "Refusing to replace ${INSTALLED_APPLICATION}: bundle identifier is '${INSTALLED_IDENTIFIER}'." >&2
    exit 1
  fi
fi

pkill -x MojiPond 2>/dev/null || true
/usr/bin/ditto "${SOURCE_APPLICATION}" "${INSTALLED_APPLICATION}"
/usr/bin/codesign --verify --deep --strict "${INSTALLED_APPLICATION}"
/usr/bin/open "${INSTALLED_APPLICATION}"

echo "Installed ${INSTALLED_APPLICATION}"

