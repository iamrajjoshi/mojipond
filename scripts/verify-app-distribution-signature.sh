#!/bin/zsh

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 /absolute/path/to/MojiPond.app ['Developer ID Application: …']" >&2
  exit 64
fi

APPLICATION_PATH=$1
EXPECTED_IDENTITY=${2:-}

if [[ "${APPLICATION_PATH}" != /* || ! -d "${APPLICATION_PATH}" ]]; then
  echo "The application path must be an existing absolute path." >&2
  exit 66
fi

/usr/bin/codesign \
  --verify \
  --all-architectures \
  --deep \
  --strict \
  --verbose=2 \
  "${APPLICATION_PATH}"

if [[ -z "${EXPECTED_IDENTITY}" ]]; then
  APPLICATION_SIGNATURE=$(
    /usr/bin/codesign --display --verbose=4 "${APPLICATION_PATH}" 2>&1
  )
  EXPECTED_IDENTITY=$(
    /usr/bin/printf '%s\n' "${APPLICATION_SIGNATURE}" \
      | /usr/bin/sed -nE 's/^Authority=(Developer ID Application:.*)$/\1/p' \
      | /usr/bin/head -n 1
  )
fi

if [[ "${EXPECTED_IDENTITY}" != "Developer ID Application:"* ]]; then
  echo "The application is not signed with a Developer ID Application identity." >&2
  exit 65
fi

EXPECTED_TEAM=$(
  /usr/bin/printf '%s\n' "${EXPECTED_IDENTITY}" \
    | /usr/bin/sed -nE 's/^Developer ID Application:.*\(([A-Z0-9]{10})\)$/\1/p'
)
if [[ -z "${EXPECTED_TEAM}" ]]; then
  echo "The Developer ID identity does not contain a 10-character team ID." >&2
  exit 65
fi
DEVELOPER_ID_REQUIREMENT="anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"${EXPECTED_TEAM}\""

MACH_O_PATHS=()
while IFS= read -r candidate_path; do
  if [[ "$(/usr/bin/file -b "${candidate_path}")" == Mach-O* ]]; then
    MACH_O_PATHS+=("${candidate_path}")
  fi
done < <(
  /usr/bin/find \
    "${APPLICATION_PATH}/Contents" \
    -type f \
    -print
)

if (( ${#MACH_O_PATHS[@]} == 0 )); then
  echo "The application does not contain any executable Mach-O code." >&2
  exit 65
fi

for code_path in "${MACH_O_PATHS[@]}"; do
  /usr/bin/codesign \
    --verify \
    --all-architectures \
    --strict \
    "-R=${DEVELOPER_ID_REQUIREMENT}" \
    "${code_path}"

  architectures=()
  while IFS= read -r architecture; do
    if [[ -n "${architecture}" ]]; then
      architectures+=("${architecture}")
    fi
  done < <(
    /usr/bin/lipo -archs "${code_path}" \
      | /usr/bin/tr ' ' '\n'
  )
  if (( ${#architectures[@]} == 0 )); then
    echo "Could not read any architecture from embedded code: ${code_path}" >&2
    exit 65
  fi

  for architecture in "${architectures[@]}"; do
    signature_details=$(
      /usr/bin/codesign \
        --display \
        --arch "${architecture}" \
        --verbose=4 \
        "${code_path}" 2>&1
    )
    if [[ "${signature_details}" != *"Authority=${EXPECTED_IDENTITY}"* ]]; then
      echo "Embedded ${architecture} code is not signed by the expected Developer ID: ${code_path}" >&2
      exit 65
    fi
    if [[ "${signature_details}" != *"TeamIdentifier=${EXPECTED_TEAM}"* ]]; then
      echo "Embedded ${architecture} code has an unexpected team identifier: ${code_path}" >&2
      exit 65
    fi
    if [[ "${signature_details}" != *"Timestamp="* ]]; then
      echo "Embedded ${architecture} code is missing a secure timestamp: ${code_path}" >&2
      exit 65
    fi
    if [[ "${signature_details}" != *"(runtime)"* ]]; then
      echo "Embedded ${architecture} code is missing Hardened Runtime: ${code_path}" >&2
      exit 65
    fi

    entitlements=$(
      /usr/bin/codesign \
        --display \
        --arch "${architecture}" \
        --entitlements :- \
        "${code_path}" 2>/dev/null \
        || true
    )
    if [[ "${entitlements}" == *"com.apple.security.get-task-allow"* ]]; then
      echo "Embedded ${architecture} code contains the development-only get-task-allow entitlement: ${code_path}" >&2
      exit 65
    fi
  done
done

echo "Verified ${#MACH_O_PATHS[@]} Developer ID signed Mach-O files in ${APPLICATION_PATH}."
