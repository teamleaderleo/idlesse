#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
fixture_dir="$(mktemp -d "$PWD/build/wallpaper-smoke.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT
if [[ -f "$PWD/Tests/Fixtures/tiny-loop.mp4" ]]; then
  cp "$PWD/Tests/Fixtures/tiny-loop.mp4" "$fixture_dir/loop.mp4"
elif command -v ffmpeg >/dev/null; then
  ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=320x180:rate=24' -t 1 -c:v libx264 -preset veryfast -pix_fmt yuv420p -an "$fixture_dir/loop.mp4"
else
  echo "Install ffmpeg or provide Tests/Fixtures/tiny-loop.mp4 to run wallpaper smoke tests." >&2
  exit 1
fi
"${BUILD_DIR:-$PWD/build}/Idlesse.app/Contents/MacOS/Idlesse" -comfort.liveMenuStrip NO --smoke-wallpaper "$fixture_dir/loop.mp4"
"${BUILD_DIR:-$PWD/build}/Idlesse.app/Contents/MacOS/Idlesse" -comfort.liveMenuStrip NO --smoke-library "$fixture_dir/library.png" "$fixture_dir/loop.mp4"

"${BUILD_DIR:-$PWD/build}/Idlesse.app/Contents/MacOS/Idlesse" -comfort.liveMenuStrip NO --smoke-export "$fixture_dir/loop.mp4"

"${BUILD_DIR:-$PWD/build}/Idlesse.app/Contents/MacOS/Idlesse" -comfort.liveMenuStrip NO --smoke-resume "$fixture_dir/loop.mp4"
