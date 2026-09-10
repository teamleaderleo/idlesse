#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
command -v ffmpeg >/dev/null || { echo "Install ffmpeg to generate the tiny video fixture."; exit 1; }
mkdir -p build
fixture_dir="$(mktemp -d "$PWD/build/wallpaper-smoke.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT
ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=320x180:rate=24'   -t 1 -c:v libx264 -preset veryfast -pix_fmt yuv420p -an "$fixture_dir/loop.mp4"
"${BUILD_DIR:-$PWD/build}/Idlesse.app/Contents/MacOS/Idlesse" --smoke-wallpaper "$fixture_dir/loop.mp4"
"${BUILD_DIR:-$PWD/build}/Idlesse.app/Contents/MacOS/Idlesse" --smoke-library "$fixture_dir/library.png" "$fixture_dir/loop.mp4"

"${BUILD_DIR:-$PWD/build}/Idlesse.app/Contents/MacOS/Idlesse" --smoke-export "$fixture_dir/loop.mp4"

"${BUILD_DIR:-$PWD/build}/Idlesse.app/Contents/MacOS/Idlesse" --smoke-resume "$fixture_dir/loop.mp4"
