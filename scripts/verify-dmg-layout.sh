#!/bin/zsh

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /absolute/path/MojiPond.dmg" >&2
  exit 64
fi

SCRIPT_DIRECTORY=${0:A:h}
DMG_PATH=${1:A}

if [[ ! -s "${DMG_PATH}" || "${DMG_PATH:e}" != "dmg" ]]; then
  echo "The DMG path must point to an existing disk image." >&2
  exit 66
fi

MOUNT_DIRECTORY=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/mojipond-dmg-check.XXXXXX")
mounted=0
cleanup() {
  if (( mounted == 1 )); then
    /usr/bin/hdiutil detach "${MOUNT_DIRECTORY}" >/dev/null
  fi
  if [[ -d "${MOUNT_DIRECTORY}" ]]; then
    /bin/rmdir "${MOUNT_DIRECTORY}"
  fi
}
trap cleanup EXIT

/usr/bin/hdiutil verify "${DMG_PATH}"
/usr/bin/hdiutil attach \
  -nobrowse \
  -readonly \
  -mountpoint "${MOUNT_DIRECTORY}" \
  "${DMG_PATH}" >/dev/null
mounted=1

if [[ ! -d "${MOUNT_DIRECTORY}/MojiPond.app" ]]; then
  echo "The DMG does not contain MojiPond.app." >&2
  exit 65
fi
if [[ ! -L "${MOUNT_DIRECTORY}/Applications" ]] \
    || [[ "$(/usr/bin/readlink "${MOUNT_DIRECTORY}/Applications")" != "/Applications" ]]; then
  echo "The DMG does not contain the Applications drag target." >&2
  exit 65
fi
for metadata_path in \
  "${MOUNT_DIRECTORY}/.DS_Store" \
  "${MOUNT_DIRECTORY}/.background.tiff"; do
  if [[ ! -s "${metadata_path}" ]]; then
    echo "The DMG is missing Finder presentation metadata: ${metadata_path:t}" >&2
    exit 65
  fi
done

DMGBUILD_EXECUTABLE=$("${SCRIPT_DIRECTORY}/install-dmgbuild.sh")
DMGBUILD_PYTHON="${DMGBUILD_EXECUTABLE:h}/python"
"${DMGBUILD_PYTHON}" - "${MOUNT_DIRECTORY}/.DS_Store" <<'PY'
import sys

from ds_store import DSStore


with DSStore.open(sys.argv[1], "r") as store:
    app_location = store["MojiPond.app"]["Iloc"]
    applications_location = store["Applications"]["Iloc"]
    icon_view = store["."]["icvp"]
    browser_window = store["."]["bwsp"]

expected_window = "{{120, 120}, {660, 400}}"
if app_location != (170, 225):
    raise SystemExit(f"Unexpected MojiPond icon location: {app_location}")
if applications_location != (490, 225):
    raise SystemExit(
        f"Unexpected Applications icon location: {applications_location}"
    )
if icon_view.get("backgroundType") != 2:
    raise SystemExit("The Finder window is not configured to use its background.")
if icon_view.get("iconSize") != 128.0:
    raise SystemExit(f"Unexpected Finder icon size: {icon_view.get('iconSize')}")
if browser_window.get("WindowBounds") != expected_window:
    raise SystemExit(
        f"Unexpected Finder window bounds: {browser_window.get('WindowBounds')}"
    )
PY

echo "Verified drag-to-Applications DMG layout: ${DMG_PATH}"
