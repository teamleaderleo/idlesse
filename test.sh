#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p build/tests

CLEAN=0
OPT_FLAG="-Onone"
for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN=1 ;;
    --release) OPT_FLAG="-O" ;;
  esac
done
if [[ "${CONFIG:-}" == "release" ]]; then
  OPT_FLAG="-O"
fi

needs_build() {
  local target="$1"; shift
  if [[ "$CLEAN" -eq 1 || ! -f "$target" ]]; then
    return 0
  fi
  for src in "$@"; do
    if [[ "$src" -nt "$target" ]]; then
      return 0
    fi
  done
  return 1
}

pids=()

# 1. Decoder
DECODER_SRCS=(
  Sources/Shared/Preferences.swift
  Sources/Shared/DisplayImageDecoder.swift
  Sources/Shared/ImageCanvasView.swift
  Tests/main.swift
)
if needs_build "build/tests/decoder" "${DECODER_SRCS[@]}"; then
  xcrun swiftc "$OPT_FLAG" "${DECODER_SRCS[@]}" -framework AppKit -framework ScreenSaver -framework ImageIO -o build/tests/decoder &
  pids+=($!)
fi

# 2. Scenes
SCENES_SRCS=(
  Sources/Runtime/Scene.swift
  Sources/Runtime/SceneClock.swift
  Tests/SceneTests.swift
)
if needs_build "build/tests/scenes" "${SCENES_SRCS[@]}"; then
  xcrun swiftc "$OPT_FLAG" "${SCENES_SRCS[@]}" -o build/tests/scenes &
  pids+=($!)
fi

# 3. Recovery
RECOVERY_SRCS=(
  Sources/Runtime/Scene.swift
  Sources/Harness/SceneDocument.swift
  Tests/RecoveryTests.swift
)
if needs_build "build/tests/recovery" "${RECOVERY_SRCS[@]}"; then
  xcrun swiftc "$OPT_FLAG" "${RECOVERY_SRCS[@]}" -framework AppKit -framework AVFoundation -o build/tests/recovery &
  pids+=($!)
fi

# 4. Audio
AUDIO_SRCS=(
  Sources/Runtime/Scene.swift
  Sources/Runtime/SceneClock.swift
  Sources/Runtime/AudioBandAnalyzer.swift
  Tests/AudioTests.swift
)
if needs_build "build/tests/audio" "${AUDIO_SRCS[@]}"; then
  xcrun swiftc "$OPT_FLAG" "${AUDIO_SRCS[@]}" -o build/tests/audio &
  pids+=($!)
fi

# 5. Comfort
COMFORT_SRCS=(
  Sources/Wallpaper/DesktopComfortController.swift
  Tests/ComfortTests.swift
)
if needs_build "build/tests/comfort" "${COMFORT_SRCS[@]}"; then
  xcrun swiftc "$OPT_FLAG" "${COMFORT_SRCS[@]}" -framework AppKit -o build/tests/comfort &
  pids+=($!)
fi

# 6. Library storage
LIBRARY_SRCS=(
  Sources/Harness/SceneLibraryStore.swift
  Tests/LibraryTests.swift
)
if needs_build "build/tests/library" "${LIBRARY_SRCS[@]}"; then
  xcrun swiftc "$OPT_FLAG" "${LIBRARY_SRCS[@]}" -o build/tests/library &
  pids+=($!)
fi

# 7. Library gallery virtualization. Compile only the production layout planner
# from LibraryGridView so 1k/4k coverage stays synthetic and never decodes media.
LIBRARY_GRID_SRCS=(
  Sources/Harness/LibraryGridView.swift
  Tests/LibraryGridVirtualizationTests.swift
)
if needs_build "build/tests/library-grid" "${LIBRARY_GRID_SRCS[@]}"; then
  xcrun swiftc "$OPT_FLAG" -D LIBRARY_GRID_VIRTUALIZATION_TESTS "${LIBRARY_GRID_SRCS[@]}" -framework AppKit -o build/tests/library-grid &
  pids+=($!)
fi

# 8. Property-centric Studio motion / Auto-Key rules
STUDIO_MOTION_SRCS=(
  Sources/Runtime/Scene.swift
  Sources/Harness/StudioMotionAuthoring.swift
  Tests/StudioMotionTests.swift
)
if needs_build "build/tests/studio-motion" "${STUDIO_MOTION_SRCS[@]}"; then
  xcrun swiftc "$OPT_FLAG" "${STUDIO_MOTION_SRCS[@]}" -o build/tests/studio-motion &
  pids+=($!)
fi

# Await any parallel background compilations
for pid in ${pids[@]+"${pids[@]}"}; do
  wait "$pid"
done

# Run test suites
build/tests/decoder
build/tests/scenes
build/tests/recovery
build/tests/audio
build/tests/comfort
build/tests/library
build/tests/library-grid
build/tests/studio-motion
