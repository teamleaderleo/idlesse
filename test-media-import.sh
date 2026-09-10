#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/build"
TEST_DIR="$(mktemp -d "$ROOT/build/media-import.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
ffmpeg -v error -f lavfi -i testsrc2=size=32x32:rate=10 -t 1 "$TEST_DIR/sample.gif"
ffmpeg -v error -f lavfi -i testsrc2=size=32x32:rate=10 -t 1 -c:v libvpx-vp9 "$TEST_DIR/sample.webm"
swiftc -swift-version 5 "$ROOT/Sources/Harness/MediaImport.swift" "$ROOT/Tests/MediaImportTests.swift" -o "$TEST_DIR/check"
"$TEST_DIR/check" "$TEST_DIR/sample.gif" "$TEST_DIR/sample.webm"
