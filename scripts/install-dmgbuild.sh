#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY=${0:A:h}
REPOSITORY_ROOT=${SCRIPT_DIRECTORY:h}
DMGBUILD_VERSION="1.6.7"
VIRTUAL_ENVIRONMENT="${REPOSITORY_ROOT}/.derived/tools/dmgbuild-${DMGBUILD_VERSION}"
DMGBUILD_EXECUTABLE="${VIRTUAL_ENVIRONMENT}/bin/dmgbuild"
REQUIREMENTS_PATH="${REPOSITORY_ROOT}/packaging/dmg/requirements.txt"
PYTHON_EXECUTABLE=${MOJIPOND_PYTHON:-$(command -v python3)}

installed_version() {
  "${VIRTUAL_ENVIRONMENT}/bin/python" -c \
    'import importlib.metadata; print(importlib.metadata.version("dmgbuild"))' \
    2>/dev/null || true
}

if [[ -x "${DMGBUILD_EXECUTABLE}" ]] \
    && [[ "$(installed_version)" == "${DMGBUILD_VERSION}" ]]; then
  echo "${DMGBUILD_EXECUTABLE}"
  exit 0
fi

if [[ ! -s "${REQUIREMENTS_PATH}" ]]; then
  echo "Missing pinned dmgbuild requirements: ${REQUIREMENTS_PATH}" >&2
  exit 66
fi
if [[ ! -x "${PYTHON_EXECUTABLE}" ]] \
    || ! "${PYTHON_EXECUTABLE}" -c \
      'import sys; raise SystemExit(sys.version_info < (3, 10))'; then
  echo "Installing dmgbuild requires Python 3.10 or newer." >&2
  exit 69
fi

"${PYTHON_EXECUTABLE}" -m venv --clear "${VIRTUAL_ENVIRONMENT}"
"${VIRTUAL_ENVIRONMENT}/bin/python" -m pip install \
  --disable-pip-version-check \
  --index-url https://pypi.org/simple \
  --only-binary=:all: \
  --require-hashes \
  --requirement "${REQUIREMENTS_PATH}" >&2

if [[ ! -x "${DMGBUILD_EXECUTABLE}" ]] \
    || [[ "$(installed_version)" != "${DMGBUILD_VERSION}" ]]; then
  echo "The pinned dmgbuild installation could not be verified." >&2
  exit 69
fi

echo "${DMGBUILD_EXECUTABLE}"
