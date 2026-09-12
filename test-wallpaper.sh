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
app="${BUILD_DIR:-$PWD/build}/Idlesse.app/Contents/MacOS/Idlesse"

# The broad wallpaper regression suite also exercises Studio authoring state.
# Keep it for manual/full wallpaper qualification, while media-focused CI can
# isolate decode/playback/import/export compatibility from unrelated Studio checks.
if [[ "${IDLESSE_MEDIA_COMPAT_ONLY:-0}" != "1" ]]; then
  "$app" -comfort.liveMenuStrip NO --smoke-wallpaper "$fixture_dir/loop.mp4"
fi
"$app" -comfort.liveMenuStrip NO --smoke-resume "$fixture_dir/loop.mp4"
"$app" -comfort.liveMenuStrip NO --smoke-library "$fixture_dir/library.png" "$fixture_dir/loop.mp4"
"$app" -comfort.liveMenuStrip NO --smoke-export "$fixture_dir/loop.mp4"

# Main10 fixture: production wallpaper lifecycle, Library poster/import path and
# Metal-backed offline scene export all consume the same 10-bit HEVC sample.
main10="$fixture_dir/main10.mp4"
python3 - "$PWD/Tests/Fixtures/tiny-main10.mp4.b64" "$main10" <<'PY'
import base64, pathlib, sys
pathlib.Path(sys.argv[2]).write_bytes(base64.b64decode(pathlib.Path(sys.argv[1]).read_text()))
PY
"$app" -comfort.liveMenuStrip NO --qualify-desktop "$main10" "$fixture_dir/main10-qualification.json" 1 1
"$app" -comfort.liveMenuStrip NO --smoke-library "$fixture_dir/library-main10.png" "$main10"
"$app" -comfort.liveMenuStrip NO --smoke-export "$main10"
