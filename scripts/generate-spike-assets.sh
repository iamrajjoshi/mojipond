#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY=${0:A:h}
REPOSITORY_ROOT=${SCRIPT_DIRECTORY:h}
OUTPUT_DIRECTORY="${1:-${REPOSITORY_ROOT}/Artifacts/Spike}"
FFMPEG=${FFMPEG:-/opt/homebrew/bin/ffmpeg}

if [[ ! -x "${FFMPEG}" ]]; then
  echo "ffmpeg was not found at ${FFMPEG}. Set FFMPEG to its absolute path." >&2
  exit 1
fi

mkdir -p "${OUTPUT_DIRECTORY}"

"${FFMPEG}" \
  -hide_banner \
  -loglevel error \
  -y \
  -f lavfi \
  -i "color=c=0x00000000:s=128x128:d=0.1,format=rgba,drawbox=x=18:y=18:w=92:h=92:color=0x4FAF93CC:t=fill,drawbox=x=46:y=42:w=12:h=12:color=white@0.95:t=fill,drawbox=x=70:y=42:w=12:h=12:color=white@0.95:t=fill" \
  -frames:v 1 \
  "${OUTPUT_DIRECTORY}/transparent-pond.png"

"${FFMPEG}" \
  -hide_banner \
  -loglevel error \
  -y \
  -f lavfi \
  -i "testsrc2=s=128x128:r=12:d=1" \
  -filter_complex "[0:v]split[frames][palette_input];[palette_input]palettegen=stats_mode=diff[palette];[frames][palette]paletteuse=dither=sierra2_4a" \
  -loop 0 \
  "${OUTPUT_DIRECTORY}/animated-pond.gif"

/usr/bin/shasum -a 256 \
  "${OUTPUT_DIRECTORY}/transparent-pond.png" \
  "${OUTPUT_DIRECTORY}/animated-pond.gif"
