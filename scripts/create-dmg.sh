#!/bin/zsh

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 /absolute/path/MojiPond.app /absolute/path/MojiPond.dmg" >&2
  exit 64
fi

SCRIPT_DIRECTORY=${0:A:h}
REPOSITORY_ROOT=${SCRIPT_DIRECTORY:h}
APPLICATION_PATH=${1:A}
DMG_PATH=${2:A}
SETTINGS_PATH="${REPOSITORY_ROOT}/packaging/dmg/settings.py"
BACKGROUND_PATH="${REPOSITORY_ROOT}/packaging/dmg/MojiPond-DMG-Background.png"

if [[ ! -d "${APPLICATION_PATH}" \
      || "${APPLICATION_PATH:t}" != "MojiPond.app" ]]; then
  echo "The DMG source must be a MojiPond.app bundle." >&2
  exit 66
fi
if [[ "${DMG_PATH:e}" != "dmg" || -e "${DMG_PATH}" ]]; then
  echo "The DMG destination must be a new .dmg path." >&2
  exit 73
fi
if [[ ! -s "${SETTINGS_PATH}" || ! -s "${BACKGROUND_PATH}" ]]; then
  echo "The DMG settings or background artwork is missing." >&2
  exit 66
fi

DMGBUILD_EXECUTABLE=${MOJIPOND_DMGBUILD:-}
if [[ -z "${DMGBUILD_EXECUTABLE}" ]]; then
  DMGBUILD_EXECUTABLE=$("${SCRIPT_DIRECTORY}/install-dmgbuild.sh")
fi
if [[ ! -x "${DMGBUILD_EXECUTABLE}" ]]; then
  echo "dmgbuild is not executable: ${DMGBUILD_EXECUTABLE}" >&2
  exit 69
fi

/bin/mkdir -p "${DMG_PATH:h}"
"${DMGBUILD_EXECUTABLE}" \
  --settings "${SETTINGS_PATH}" \
  -D "application=${APPLICATION_PATH}" \
  -D "background=${BACKGROUND_PATH}" \
  "MojiPond" \
  "${DMG_PATH}"

/usr/bin/hdiutil verify "${DMG_PATH}"
