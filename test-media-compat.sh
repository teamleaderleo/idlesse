#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
fixture_dir="$(mktemp -d "$PWD/build/main10-media.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT
main10="$fixture_dir/main10.mp4"
python3 - "$PWD/Tests/Fixtures/tiny-main10.mp4.b64" "$main10" <<'PY'
import base64,pathlib,sys
pathlib.Path(sys.argv[2]).write_bytes(base64.b64decode(pathlib.Path(sys.argv[1]).read_text()))
PY
PYTHONPATH="$PWD/scripts/media-batch" python3 - "$main10" <<'PY'
import sys
from fidelity import require_stream_bit_depth
stream=require_stream_bit_depth(sys.argv[1],10)
print('Main10 fixture:',stream)
PY
app="${BUILD_DIR:-$PWD/build}/Idlesse.app/Contents/MacOS/Idlesse"
"$app" -comfort.liveMenuStrip NO --smoke-video-preparation "$main10"
"$app" -comfort.liveMenuStrip NO --smoke-library "$fixture_dir/library-main10.png" "$main10"
"$app" -comfort.liveMenuStrip NO --smoke-export "$main10"
python3 scripts/media-batch/gradient_precision.py --encoder hevc_videotoolbox --output-json "$fixture_dir/main10-gradient.json"
