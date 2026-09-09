#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
"${BUILD_DIR:-$PWD/build}/Idlesse.app/Contents/MacOS/Idlesse" --conformance "$PWD/Tests/Scenes/corpus.json"
