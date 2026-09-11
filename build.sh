#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="${BUILD_DIR:-$ROOT/build}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
MIN_MACOS="${MIN_MACOS:-14.0}"
CONFIG="${CONFIG:-debug}"
# Idlesse is currently developed/tested on Apple Silicon. Override ARCHS later
# (for example: ARCHS="arm64 x86_64") when we actually need a universal build.
ARCHS="${ARCHS:-arm64}"

SAVER="$BUILD/Idlesse.saver"
APP="$BUILD/Idlesse.app"
TAHOE_DIAG="$HOME/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/tmp/idlesse-diag.log"

SHARED_SOURCES=(
  "$ROOT/Sources/Runtime/Scene.swift"
  "$ROOT/Sources/Runtime/ImagePreparation.swift"
  "$ROOT/Sources/Shared/Preferences.swift"
  "$ROOT/Sources/Shared/ImageLibrary.swift"
  "$ROOT/Sources/Shared/DisplayImageDecoder.swift"
  "$ROOT/Sources/Shared/ImageCanvasView.swift"
  "$ROOT/Sources/Shared/PhotosProbe.swift"
)

SAVER_SOURCES=(
  "$ROOT/Sources/Saver/ConfigureSheetController.swift"
  "$ROOT/Sources/Saver/IdlesseView.swift"
)

if [[ "$CONFIG" == "release" ]]; then
  SWIFT_OPT=( -O -wmo )
else
  SWIFT_OPT=( -Onone -g )
fi

log() { printf '\033[1;32m▸ %s\033[0m\n' "$*"; }

compile_saver_arch() {
  local arch="$1"
  local output="$2"

  xcrun swiftc \
    -sdk "$SDK" \
    -target "$arch-apple-macosx$MIN_MACOS" \
    -swift-version 5 \
    "${SWIFT_OPT[@]}" \
    -module-name Idlesse \
    -emit-executable \
    -Xlinker -bundle \
    "${SHARED_SOURCES[@]}" \
    "${SAVER_SOURCES[@]}" \
    -framework AppKit \
    -framework Photos \
    -framework ScreenSaver \
    -framework UniformTypeIdentifiers \
    -o "$output"
}

build_saver() {
  log "Building Idlesse.saver ($CONFIG)"
  rm -rf "$SAVER"
  mkdir -p "$SAVER/Contents/MacOS" "$SAVER/Contents/Resources" "$BUILD/thin"

  read -r -a arch_list <<< "$ARCHS"
  local thin_bins=()
  local arch

  for arch in "${arch_list[@]}"; do
    local thin="$BUILD/thin/Idlesse-$arch"
    log "Compiling saver for $arch"
    compile_saver_arch "$arch" "$thin"
    thin_bins+=( "$thin" )
  done

  if [[ "${#thin_bins[@]}" -eq 1 ]]; then
    cp "${thin_bins[0]}" "$SAVER/Contents/MacOS/Idlesse"
  else
    xcrun lipo -create "${thin_bins[@]}" -output "$SAVER/Contents/MacOS/Idlesse"
  fi

  cp "$ROOT/Sources/Saver/Info.plist" "$SAVER/Contents/Info.plist"
  mkdir -p "$SAVER/Contents/Resources"
  cp "$ROOT/Assets/Idlesse.icns" "$SAVER/Contents/Resources/Idlesse.icns"
  chmod +x "$SAVER/Contents/MacOS/Idlesse"
  codesign --force --sign - "$SAVER" >/dev/null

  log "Saver ready: $SAVER"
  file "$SAVER/Contents/MacOS/Idlesse"
}

APP_SOURCES=(
  "$ROOT/Sources/Runtime/SceneRenderer.swift"
  "$ROOT/Sources/Runtime/SceneClock.swift"
  "$ROOT/Sources/Runtime/AudioBandAnalyzer.swift"
  "$ROOT/Sources/Runtime/SystemAudioInput.swift"
  "$ROOT/Sources/Runtime/SceneWatcher.swift"
  "$ROOT/Sources/Runtime/GradientRenderer.swift"
  "$ROOT/Sources/Runtime/MetalSceneRenderer.swift"
  "$ROOT/Sources/Wallpaper/WallpaperController.swift"
  "$ROOT/Sources/Wallpaper/AmbientModesController.swift"
  "$ROOT/Sources/Wallpaper/DesktopComfortController.swift"
  "$ROOT/Sources/Wallpaper/WallpaperSmoke.swift"
  "$ROOT/Sources/Harness/SceneTimelineView.swift"
  "$ROOT/Sources/Harness/ScenePreviewHost.swift"
  "$ROOT/Sources/Harness/SceneVideoExporter.swift"
  "$ROOT/Sources/Harness/SceneParameterControls.swift"
  "$ROOT/Sources/Harness/SceneLayerList.swift"
  "$ROOT/Sources/Harness/SceneCanvasInteraction.swift"
  "$ROOT/Sources/Harness/SceneEditorController.swift"
  "$ROOT/Sources/Harness/SceneDocument.swift"
  "$ROOT/Sources/Harness/MediaImport.swift"
  "$ROOT/Sources/Harness/SceneLibraryStore.swift"
  "$ROOT/Sources/Harness/LibraryGridView.swift"
  "$ROOT/Sources/Harness/SceneLibraryController.swift"
  "$ROOT/Sources/Harness/StudioInspector.swift"
  "$ROOT/Sources/Harness/StudioWindowController.swift"
  "$ROOT/Sources/Harness/Benchmark.swift"
  "$ROOT/Sources/Harness/AudioSmoke.swift"
  "$ROOT/Sources/Harness/SceneConformance.swift"
  "$ROOT/Sources/Harness/DesktopQualification.swift"
  "$ROOT/Sources/Harness/AppSettingsController.swift"
  "$ROOT/Sources/Harness/main.swift"
)

APP_FRAMEWORKS=( AVFoundation ApplicationServices MetalKit Metal IOKit CoreLocation AppKit Photos ScreenSaver UniformTypeIdentifiers )

app_framework_args() {
  local f
  for f in "${APP_FRAMEWORKS[@]}"; do printf ' -framework %s' "$f"; done
}

# Full whole-module build. Used for release (-O -wmo) and as the fallback.
compile_app_full() {
  local arch="$1"
  local args=( -sdk "$SDK" -target "$arch-apple-macosx$MIN_MACOS" -swift-version 5
    "${SWIFT_OPT[@]}" -module-name IdlesseApp )
  local f
  for f in "${APP_FRAMEWORKS[@]}"; do args+=( -framework "$f" ); done
  xcrun swiftc "${args[@]}" "${SHARED_SOURCES[@]}" "${SAVER_SOURCES[@]}" "${APP_SOURCES[@]}" \
    -o "$APP/Contents/MacOS/Idlesse"
}

# NOTE: per-file object caching was tried here (output-file-map + -incremental)
# and reverted: this toolchain's driver never persists the build record for an
# emit-executable link, so every build re-ran the full frontend anyway while the
# cache only added disk weight and failure modes. Full debug builds run ~20s on
# Apple Silicon. The structural fix is a SwiftPM/Xcode project with real
# incremental state (plus scene content already hot-reloads via SceneWatcher,
# so content iteration never needs a rebuild). Until then: NO_CACHE is gone,
# builds are always full and honest about it.
compile_app_incremental() { return 1; }

build_app() {
  local arch="$(uname -m)"
  log "Building development preview for $arch"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

  if [[ "$CONFIG" != "release" && "${NO_CACHE:-0}" != "1" ]] && compile_app_incremental "$arch"; then
    log "Incremental link reused cached objects"
  else
    compile_app_full "$arch"
  fi

  cp "$ROOT/Sources/Harness/Info.plist" "$APP/Contents/Info.plist"
  mkdir -p "$APP/Contents/Resources/Scenes"
  cp "$ROOT/Assets/Idlesse.icns" "$APP/Contents/Resources/Idlesse.icns"
  for scene in DeskClock AfterHours Undertow Fireflies Ripple AudioAurora Gradient BreathingAurora; do
    cp -R "$ROOT/Examples/$scene.idlesse" "$APP/Contents/Resources/Scenes/"
  done
  chmod +x "$APP/Contents/MacOS/Idlesse"
  local extension="$APP/Contents/PlugIns/IdlesseDesktopMenu.appex"
  mkdir -p "$extension/Contents/MacOS"
  xcrun swiftc -sdk "$SDK" -target "$arch-apple-macosx$MIN_MACOS" \
    -swift-version 5 "${SWIFT_OPT[@]}" -module-name IdlesseDesktopMenu \
    -application-extension -emit-executable -Xlinker -e -Xlinker _NSExtensionMain \
    "$ROOT/Sources/DesktopMenu/FinderSync.swift" -framework AppKit -framework FinderSync \
    -o "$extension/Contents/MacOS/IdlesseDesktopMenu"
  cp "$ROOT/Sources/DesktopMenu/Info.plist" "$extension/Contents/Info.plist"
  codesign --force --sign - --entitlements "$ROOT/Sources/DesktopMenu/Entitlements.plist" "$extension" >/dev/null
  codesign --force --sign - "$APP" >/dev/null
  local stamp_sha
  stamp_sha="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
  if ! git -C "$ROOT" diff --quiet 2>/dev/null; then stamp_sha="$stamp_sha-dirty"; fi
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$stamp_sha" \
    > "$APP/Contents/Resources/build-stamp.txt"

  log "Development preview ready: $APP"
}

case "${1:-all}" in
  saver)
    build_saver
    ;;
  app|preview)
    build_app
    ;;
  run)
    build_app
    pkill -x Idlesse 2>/dev/null || true
    sleep 0.2
    open "$APP"
    ;;
  install)
    CONFIG=release "$0" saver

    SAVER_DEST="$HOME/Library/Screen Savers"
    mkdir -p "$SAVER_DEST"

    rm -rf "$SAVER_DEST/Idlesse.saver"
    cp -R "$SAVER" "$SAVER_DEST/Idlesse.saver"

    rm -f "$TAHOE_DIAG" 2>/dev/null || true
    killall legacyScreenSaver 2>/dev/null || true

    log "Installed screen saver: $SAVER_DEST/Idlesse.saver"
    log "macOS 26: System Settings → Wallpaper → Screen Saver → Custom → Other → Idlesse."
    log "Click Options… to open Idlesse Settings."
    log "If Tahoe still misbehaves after one click, run: ./build.sh diagnose"
    open "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension" 2>/dev/null || true
    ;;
  installed-status)
    installed="$HOME/Library/Screen Savers/Idlesse.saver"
    if [[ ! -f "$installed/Contents/MacOS/Idlesse" ]]; then
      log "Idlesse is not installed. Run ./build.sh install."
      exit 1
    fi
    codesign --verify --strict "$installed"
    if [[ ! -f "$SAVER/Contents/MacOS/Idlesse" ]]; then
      log "Installed bundle is signed; no local build exists to compare."
      exit 0
    fi
    if cmp -s "$SAVER/Contents/MacOS/Idlesse" "$installed/Contents/MacOS/Idlesse"; then
      log "Installed saver matches the local build. A running host may still need restarting."
    else
      log "Installed saver differs from the local build. Building or pushing does not install it."
      log "Run ./build.sh install with System Settings closed, then reopen Settings."
      exit 1
    fi
    ;;
  diagnose)
    if [[ -f "$TAHOE_DIAG" ]]; then
      tail -n 200 "$TAHOE_DIAG"
    else
      echo "No Tahoe Idlesse diagnostic log found at:"
      echo "$TAHOE_DIAG"
      echo "Install Idlesse, select it in Wallpaper → Screen Saver, click Options once, then run this command again."
    fi
    ;;
  capture-settings)
    touch "$(dirname "$TAHOE_DIAG")/idlesse-capture-request"
    log "Capture armed. Click Idlesse Options in Wallpaper settings."
    log "Latest local render: $(dirname "$TAHOE_DIAG")/idlesse-settings.png"
    ;;
  clear-capture)
    rm -f "$(dirname "$TAHOE_DIAG")/idlesse-capture-request" "$(dirname "$TAHOE_DIAG")/idlesse-settings.png" "$(dirname "$TAHOE_DIAG")/idlesse-settings.json"
    log "Cleared local settings capture."
    ;;
  clear-diagnose)
    rm -f "$TAHOE_DIAG" 2>/dev/null || true
    log "Cleared Tahoe diagnostic log."
    ;;
  clean)
    rm -rf "$BUILD"
    log "Cleaned."
    ;;
  all|*)
    build_app &
    pid_app=$!
    build_saver &
    pid_saver=$!
    wait "$pid_app"
    wait "$pid_saver"
    ;;
esac
