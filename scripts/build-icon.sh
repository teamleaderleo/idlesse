#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
stage="$(mktemp -d "$PWD/build/icon.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/Idlesse.iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Assets/Idlesse.png --out "$stage/Idlesse.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" Assets/Idlesse.png --out "$stage/Idlesse.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$stage/Idlesse.iconset" -o Assets/Idlesse.icns
