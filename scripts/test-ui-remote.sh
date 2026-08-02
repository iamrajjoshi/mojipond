#!/bin/zsh

set -euo pipefail

if [[ "${CI:-}" != "true" && "${MOJIPOND_ALLOW_LOCAL_UI_TESTS:-}" != "1" ]]; then
  print -u2 "MojiPond UI tests control the active macOS desktop."
  print -u2 "Run the macOS UI workflow in GitHub Actions instead."
  print -u2 "To opt in locally, set MOJIPOND_ALLOW_LOCAL_UI_TESTS=1."
  exit 2
fi

SCRIPT_DIRECTORY=${0:A:h}
REPOSITORY_ROOT=${SCRIPT_DIRECTORY:h}
RUN_IDENTIFIER=${GITHUB_RUN_ID:-local-$(date -u +%Y%m%dT%H%M%SZ)}
DERIVED_DATA_PATH="${REPOSITORY_ROOT}/.derived/ui-remote"
RESULTS_DIRECTORY="${REPOSITORY_ROOT}/.derived/ui-results"
RESULT_BUNDLE_PATH="${RESULTS_DIRECTORY}/MojiPond-${RUN_IDENTIFIER}.xcresult"

cd "${REPOSITORY_ROOT}"
mkdir -p "${RESULTS_DIRECTORY}"
xcodegen generate
xcodebuild \
  -project MojiPond.xcodeproj \
  -scheme MojiPondUITests \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  -resultBundlePath "${RESULT_BUNDLE_PATH}" \
  test \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=YES
