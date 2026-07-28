#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY=${0:A:h}
REPOSITORY_ROOT=${SCRIPT_DIRECTORY:h}
BUILD_CONFIGURATION=${1:-Debug}
DERIVED_DATA_PATH=${MOJIPOND_DERIVED_DATA_PATH:-"${REPOSITORY_ROOT}/DerivedData"}
SOURCE_APPLICATION="${DERIVED_DATA_PATH}/Build/Products/${BUILD_CONFIGURATION}/MojiPond.app"
INSTALLED_APPLICATION="/Applications/MojiPond.app"
EXPECTED_IDENTIFIER="com.rajjoshi.MojiPond"

"${SCRIPT_DIRECTORY}/build.sh" "${BUILD_CONFIGURATION}" build

SOURCE_IDENTIFIER=$(
  /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
    "${SOURCE_APPLICATION}/Contents/Info.plist" 2>/dev/null || true
)
if [[ "${SOURCE_IDENTIFIER}" != "${EXPECTED_IDENTIFIER}" ]]; then
  echo "Refusing to install an unexpected bundle identifier: '${SOURCE_IDENTIFIER}'." >&2
  exit 65
fi

if [[ -e "${INSTALLED_APPLICATION}" || -L "${INSTALLED_APPLICATION}" ]]; then
  if [[ -L "${INSTALLED_APPLICATION}" ]]; then
    echo "Refusing to replace a symlinked app path: ${INSTALLED_APPLICATION}" >&2
    exit 1
  fi
  if [[ ! -d "${INSTALLED_APPLICATION}" ]]; then
    echo "Refusing to replace non-application path: ${INSTALLED_APPLICATION}" >&2
    exit 1
  fi
  INSTALLED_IDENTIFIER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${INSTALLED_APPLICATION}/Contents/Info.plist" 2>/dev/null || true)
  if [[ "${INSTALLED_IDENTIFIER}" != "${EXPECTED_IDENTIFIER}" ]]; then
    echo "Refusing to replace ${INSTALLED_APPLICATION}: bundle identifier is '${INSTALLED_IDENTIFIER}'." >&2
    exit 1
  fi
fi

if ! INSTALL_STAGING_DIRECTORY=$(
  /usr/bin/mktemp -d "/Applications/.mojipond-install.XXXXXX"
); then
  echo "Could not create a staging directory in /Applications. Check write access." >&2
  exit 73
fi
STAGED_APPLICATION="${INSTALL_STAGING_DIRECTORY}/MojiPond.app"
PREVIOUS_APPLICATION="${INSTALL_STAGING_DIRECTORY}/Previous.app"
FAILED_APPLICATION="${INSTALL_STAGING_DIRECTORY}/Failed.app"
INSTALLED_EXECUTABLE="${INSTALLED_APPLICATION}/Contents/MacOS/MojiPond"
INSTALLED_EXECUTABLE_PATTERN="^/Applications/MojiPond[.]app/Contents/MacOS/MojiPond([[:space:]]|$)"
NEW_APPLICATION_INSTALLING=0
INSTALLATION_SUCCEEDED=0

cleanup() {
  local exit_status=$?
  local rollback_succeeded=1
  trap - EXIT
  trap "" HUP INT TERM

  if [[ "${exit_status}" != "0" \
        && "${INSTALLATION_SUCCEEDED}" != "1" \
        && ( -d "${PREVIOUS_APPLICATION}" \
          || "${NEW_APPLICATION_INSTALLING}" == "1" ) ]]; then
    /usr/bin/pkill -TERM -f \
      "${INSTALLED_EXECUTABLE_PATTERN}" 2>/dev/null || true
    for _ in {1..50}; do
      if ! /usr/bin/pgrep -f \
          "${INSTALLED_EXECUTABLE_PATTERN}" >/dev/null 2>&1; then
        break
      fi
      /bin/sleep 0.1
    done
    if /usr/bin/pgrep -f \
        "${INSTALLED_EXECUTABLE_PATTERN}" >/dev/null 2>&1; then
      /usr/bin/pkill -KILL -f \
        "${INSTALLED_EXECUTABLE_PATTERN}" 2>/dev/null || true
      /bin/sleep 0.2
    fi

    if /usr/bin/pgrep -f \
        "${INSTALLED_EXECUTABLE_PATTERN}" >/dev/null 2>&1; then
      rollback_succeeded=0
    elif [[ -e "${INSTALLED_APPLICATION}" \
          || -L "${INSTALLED_APPLICATION}" ]]; then
      if ! /bin/mv "${INSTALLED_APPLICATION}" "${FAILED_APPLICATION}"; then
        rollback_succeeded=0
      fi
    fi
    if [[ -d "${PREVIOUS_APPLICATION}" ]]; then
      if [[ -e "${INSTALLED_APPLICATION}" \
            || -L "${INSTALLED_APPLICATION}" ]] \
          || ! /bin/mv "${PREVIOUS_APPLICATION}" "${INSTALLED_APPLICATION}"; then
        rollback_succeeded=0
      else
        echo "Installation failed; restored the previous MojiPond app." >&2
      fi
    fi
  fi

  if [[ -n "${INSTALL_STAGING_DIRECTORY:-}" \
        && -d "${INSTALL_STAGING_DIRECTORY}" \
        && "${INSTALL_STAGING_DIRECTORY}" == /Applications/.mojipond-install.* \
        && "${rollback_succeeded}" == "1" ]]; then
    /bin/rm -rf -- "${INSTALL_STAGING_DIRECTORY}"
  fi
  if [[ "${rollback_succeeded}" != "1" ]]; then
    echo "Automatic rollback was incomplete. Recovery files remain at ${INSTALL_STAGING_DIRECTORY}." >&2
  fi
  exit "${exit_status}"
}

handle_signal() {
  local exit_status=$1
  trap - HUP INT TERM
  exit "${exit_status}"
}

trap cleanup EXIT
trap "handle_signal 129" HUP
trap "handle_signal 130" INT
trap "handle_signal 143" TERM

/usr/bin/ditto "${SOURCE_APPLICATION}" "${STAGED_APPLICATION}"
/usr/bin/codesign --verify --deep --strict "${STAGED_APPLICATION}"

/usr/bin/pkill -TERM -x MojiPond 2>/dev/null || true
for _ in {1..50}; do
  if ! /usr/bin/pgrep -x MojiPond >/dev/null 2>&1; then
    break
  fi
  /bin/sleep 0.1
done
if /usr/bin/pgrep -x MojiPond >/dev/null 2>&1; then
  echo "MojiPond did not quit within five seconds; installation was not started." >&2
  exit 70
fi

if [[ -d "${INSTALLED_APPLICATION}" ]]; then
  /bin/mv "${INSTALLED_APPLICATION}" "${PREVIOUS_APPLICATION}"
fi

NEW_APPLICATION_INSTALLING=1
if ! /bin/mv "${STAGED_APPLICATION}" "${INSTALLED_APPLICATION}"; then
  echo "Could not move the staged app into /Applications." >&2
  exit 1
fi

/usr/bin/codesign --verify --deep --strict "${INSTALLED_APPLICATION}"
/usr/bin/open -n "${INSTALLED_APPLICATION}"

LAUNCHED_PID=""
for _ in {1..100}; do
  LAUNCHED_PID=$(
    /usr/bin/pgrep -n -f \
      "${INSTALLED_EXECUTABLE_PATTERN}" 2>/dev/null || true
  )
  if [[ -n "${LAUNCHED_PID}" ]]; then
    break
  fi
  /bin/sleep 0.1
done
if [[ -z "${LAUNCHED_PID}" ]]; then
  echo "The installed app did not launch within ten seconds." >&2
  exit 70
fi

/bin/sleep 1
if ! /bin/kill -0 "${LAUNCHED_PID}" 2>/dev/null; then
  echo "The installed app exited during launch verification." >&2
  exit 70
fi

INSTALLATION_SUCCEEDED=1

echo "Installed and launched ${INSTALLED_APPLICATION} (PID ${LAUNCHED_PID})"
