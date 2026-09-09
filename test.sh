#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/tests
xcrun swiftc -O Sources/Shared/Preferences.swift Sources/Shared/DisplayImageDecoder.swift Sources/Shared/ImageCanvasView.swift Tests/main.swift -framework AppKit -framework ScreenSaver -framework ImageIO -o build/tests/decoder
build/tests/decoder
xcrun swiftc -O Sources/Runtime/Scene.swift Sources/Runtime/SceneClock.swift Tests/SceneTests.swift -o build/tests/scenes
build/tests/scenes
xcrun swiftc -O Sources/Runtime/Scene.swift Sources/Harness/SceneDocument.swift Tests/RecoveryTests.swift -framework AppKit -framework AVFoundation -o build/tests/recovery
build/tests/recovery
xcrun swiftc -O Sources/Runtime/Scene.swift Sources/Runtime/SceneClock.swift Sources/Runtime/AudioBandAnalyzer.swift Tests/AudioTests.swift -o build/tests/audio
build/tests/audio
xcrun swiftc -O Sources/Wallpaper/DesktopComfortController.swift Tests/ComfortTests.swift -framework AppKit -o build/tests/comfort
build/tests/comfort
xcrun swiftc -O Sources/Harness/SceneLibraryStore.swift Tests/LibraryTests.swift -o build/tests/library
build/tests/library
