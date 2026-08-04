#!/bin/zsh

set -euo pipefail

if [[ $# -ne 5 ]]; then
  echo "Usage: $0 artifact result.json AuthKey.p8 key-id issuer-id" >&2
  exit 64
fi

ARTIFACT_PATH=${1:A}
RESULT_PATH=${2:A}
NOTARY_KEY_PATH=${3:A}
NOTARY_KEY_ID=$4
NOTARY_ISSUER_ID=$5
LOG_PATH="${RESULT_PATH:r}-log.json"

if [[ ! -s "${ARTIFACT_PATH}" ]]; then
  echo "The notarization artifact does not exist: ${ARTIFACT_PATH}" >&2
  exit 66
fi
if [[ ! -s "${NOTARY_KEY_PATH}" ]]; then
  echo "The notarization key does not exist." >&2
  exit 66
fi
if [[ -e "${RESULT_PATH}" || -e "${LOG_PATH}" ]]; then
  echo "Refusing to overwrite existing notarization diagnostics." >&2
  exit 73
fi

submit_exit=0
/usr/bin/xcrun notarytool submit "${ARTIFACT_PATH}" \
  --key "${NOTARY_KEY_PATH}" \
  --key-id "${NOTARY_KEY_ID}" \
  --issuer "${NOTARY_ISSUER_ID}" \
  --wait \
  --output-format json \
  > "${RESULT_PATH}" || submit_exit=$?

if [[ -s "${RESULT_PATH}" ]] \
    && /usr/bin/jq -e 'type == "object"' "${RESULT_PATH}" >/dev/null; then
  /usr/bin/jq '{id, status, message}' "${RESULT_PATH}"
else
  echo "Apple did not return a readable notarization result." >&2
fi

if (( submit_exit == 0 )) \
    && /usr/bin/jq -e '.status == "Accepted"' "${RESULT_PATH}" >/dev/null 2>&1; then
  exit 0
fi

submission_id=$(
  /usr/bin/jq -r '.id // empty' "${RESULT_PATH}" 2>/dev/null || true
)
if [[ "${submission_id}" \
      =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
  log_exit=0
  /usr/bin/xcrun notarytool log \
    --key "${NOTARY_KEY_PATH}" \
    --key-id "${NOTARY_KEY_ID}" \
    --issuer "${NOTARY_ISSUER_ID}" \
    "${submission_id}" \
    "${LOG_PATH}" || log_exit=$?

  if [[ -s "${LOG_PATH}" ]]; then
    echo "Apple notarization log:" >&2
    /usr/bin/jq \
      '{id, status, statusSummary, issues}' \
      "${LOG_PATH}" >&2
  elif (( log_exit != 0 )); then
    echo "Apple's notarization log could not be retrieved." >&2
  fi
fi

echo "Apple did not accept ${ARTIFACT_PATH:t} for notarization." >&2
exit 65
