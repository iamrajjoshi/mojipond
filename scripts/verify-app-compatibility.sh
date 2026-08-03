#!/bin/zsh

set -euo pipefail

EXPECTED_MINIMUM_SYSTEM_VERSION="13.0"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /absolute/path/to/MojiPond.app" >&2
  exit 64
fi

APPLICATION_PATH=$1
if [[ "${APPLICATION_PATH}" != /* || ! -d "${APPLICATION_PATH}" ]]; then
  echo "Application path must be an existing absolute path." >&2
  exit 66
fi

INFO_PLIST_PATH="${APPLICATION_PATH}/Contents/Info.plist"
if [[ ! -f "${INFO_PLIST_PATH}" ]]; then
  echo "Application is missing Info.plist: ${INFO_PLIST_PATH}" >&2
  exit 65
fi

EXECUTABLE_NAME=$(
  /usr/bin/plutil \
    -extract CFBundleExecutable \
    raw \
    -expect string \
    -o - \
    "${INFO_PLIST_PATH}"
)
EXECUTABLE_PATH="${APPLICATION_PATH}/Contents/MacOS/${EXECUTABLE_NAME}"
if [[ ! -f "${EXECUTABLE_PATH}" ]]; then
  echo "Application executable is missing: ${EXECUTABLE_PATH}" >&2
  exit 65
fi

MINIMUM_SYSTEM_VERSION=$(
  /usr/bin/plutil \
    -extract LSMinimumSystemVersion \
    raw \
    -expect string \
    -o - \
    "${INFO_PLIST_PATH}"
)
if [[ "${MINIMUM_SYSTEM_VERSION}" != "${EXPECTED_MINIMUM_SYSTEM_VERSION}" ]]; then
  echo \
    "Expected LSMinimumSystemVersion ${EXPECTED_MINIMUM_SYSTEM_VERSION}, found ${MINIMUM_SYSTEM_VERSION}." \
    >&2
  exit 65
fi

/usr/bin/lipo "${EXECUTABLE_PATH}" -verify_arch arm64 x86_64

minimum_system_version() {
  local binary_path=$1
  local architecture=$2

  /usr/bin/vtool \
    -arch "${architecture}" \
    -show-build \
    "${binary_path}" \
    | /usr/bin/awk '
        $1 == "minos" || $1 == "version" {
          print $2
          exit
        }
      '
}

version_is_at_most() {
  local actual=$1
  local maximum=$2

  /usr/bin/awk -v actual="${actual}" -v maximum="${maximum}" '
    BEGIN {
      split(actual, actualParts, ".")
      split(maximum, maximumParts, ".")
      for (component = 1; component <= 3; component += 1) {
        actualPart = actualParts[component] + 0
        maximumPart = maximumParts[component] + 0
        if (actualPart < maximumPart) {
          exit 0
        }
        if (actualPart > maximumPart) {
          exit 1
        }
      }
      exit 0
    }
  '
}

while IFS= read -r -d '' candidate_path; do
  if [[ "$(/usr/bin/file -b "${candidate_path}")" != *Mach-O* ]]; then
    continue
  fi

  /usr/bin/lipo "${candidate_path}" -verify_arch arm64 x86_64
  for architecture in arm64 x86_64; do
    SLICE_MINIMUM_SYSTEM_VERSION=$(
      minimum_system_version "${candidate_path}" "${architecture}"
    )
    if [[ -z "${SLICE_MINIMUM_SYSTEM_VERSION}" ]] \
        || ! version_is_at_most \
          "${SLICE_MINIMUM_SYSTEM_VERSION}" \
          "${EXPECTED_MINIMUM_SYSTEM_VERSION}"; then
      echo \
        "Expected ${candidate_path} (${architecture}) to support macOS ${EXPECTED_MINIMUM_SYSTEM_VERSION}, found ${SLICE_MINIMUM_SYSTEM_VERSION:-nothing}." \
        >&2
      exit 65
    fi
  done
done < <(
  /usr/bin/find \
    "${APPLICATION_PATH}/Contents/MacOS" \
    "${APPLICATION_PATH}/Contents/Frameworks" \
    -type f \
    -perm -111 \
    -print0
)

echo \
  "Verified Universal application compatibility (macOS ${EXPECTED_MINIMUM_SYSTEM_VERSION}+): ${APPLICATION_PATH}"
