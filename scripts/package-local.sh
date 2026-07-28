#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY=${0:A:h}
REPOSITORY_ROOT=${SCRIPT_DIRECTORY:h}
ARTIFACT_DIRECTORY="${REPOSITORY_ROOT}/Artifacts"
STAGING_DIRECTORY="${ARTIFACT_DIRECTORY}/dmg-root"
APPLICATION_PATH="${REPOSITORY_ROOT}/DerivedData/Build/Products/Release/MojiPond.app"
ZIP_PATH="${ARTIFACT_DIRECTORY}/MojiPond-local.zip"
DMG_PATH="${ARTIFACT_DIRECTORY}/MojiPond-local.dmg"

"${SCRIPT_DIRECTORY}/build.sh" Release

mkdir -p "${ARTIFACT_DIRECTORY}" "${STAGING_DIRECTORY}"
rm -f "${ZIP_PATH}" "${DMG_PATH}"
rm -rf "${STAGING_DIRECTORY}/MojiPond.app"

/usr/bin/ditto "${APPLICATION_PATH}" "${STAGING_DIRECTORY}/MojiPond.app"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "${APPLICATION_PATH}" "${ZIP_PATH}"
/usr/bin/hdiutil create \
  -volname "MojiPond" \
  -srcfolder "${STAGING_DIRECTORY}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

/usr/bin/codesign --verify --deep --strict "${APPLICATION_PATH}"
shasum -a 256 "${ZIP_PATH}" "${DMG_PATH}"

