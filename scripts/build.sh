#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY=${0:A:h}
REPOSITORY_ROOT=${SCRIPT_DIRECTORY:h}
BUILD_CONFIGURATION=${1:-Debug}
DERIVED_DATA_PATH="${REPOSITORY_ROOT}/DerivedData"

cd "${REPOSITORY_ROOT}"
xcodegen generate

xcodebuild \
  -project MojiPond.xcodeproj \
  -scheme MojiPond \
  -configuration "${BUILD_CONFIGURATION}" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  build \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=YES

echo "${DERIVED_DATA_PATH}/Build/Products/${BUILD_CONFIGURATION}/MojiPond.app"

