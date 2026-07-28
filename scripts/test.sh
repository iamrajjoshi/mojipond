#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY=${0:A:h}
REPOSITORY_ROOT=${SCRIPT_DIRECTORY:h}
DERIVED_DATA_PATH="${REPOSITORY_ROOT}/DerivedData"

cd "${REPOSITORY_ROOT}"
xcodegen generate

xcodebuild \
  -project MojiPond.xcodeproj \
  -scheme MojiPond \
  -configuration Debug \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  test \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=YES

