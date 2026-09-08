#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/tests
xcrun swiftc -O Sources/Shared/Preferences.swift Sources/Shared/DisplayImageDecoder.swift Sources/Shared/ImageCanvasView.swift Tests/main.swift -framework AppKit -framework ScreenSaver -framework ImageIO -o build/tests/decoder
build/tests/decoder
xcrun swiftc -O Sources/Runtime/Scene.swift Tests/SceneTests.swift -o build/tests/scenes
build/tests/scenes
