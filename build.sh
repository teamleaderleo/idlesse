#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$ROOT/build"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
MIN_MACOS="${MIN_MACOS:-14.0}"
CONFIG="${CONFIG:-debug}"
ARCHS="${ARCHS:-arm64 x86_64}"

SAVER="$BUILD/Idlesse.saver"
APP="$BUILD/Idlesse.app"

SHARED_SOURCES=(
  "$ROOT/Sources/Shared/Preferences.swift"
  "$ROOT/Sources/Shared/SettingsFile.swift"
  "$ROOT/Sources/Shared/ImageLibrary.swift"
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
  chmod +x "$SAVER/Contents/MacOS/Idlesse"
  codesign --force --sign - "$SAVER" >/dev/null

  log "Saver ready: $SAVER"
  file "$SAVER/Contents/MacOS/Idlesse"
}

build_app() {
  local arch="$(uname -m)"
  log "Building Idlesse.app for $arch"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

  xcrun swiftc \
    -sdk "$SDK" \
    -target "$arch-apple-macosx$MIN_MACOS" \
    -swift-version 5 \
    "${SWIFT_OPT[@]}" \
    -module-name IdlesseApp \
    "${SHARED_SOURCES[@]}" \
    "${SAVER_SOURCES[@]}" \
    "$ROOT/Sources/Harness/main.swift" \
    -framework AppKit \
    -framework Photos \
    -framework ScreenSaver \
    -framework UniformTypeIdentifiers \
    -o "$APP/Contents/MacOS/Idlesse"

  cp "$ROOT/Sources/Harness/Info.plist" "$APP/Contents/Info.plist"
  chmod +x "$APP/Contents/MacOS/Idlesse"
  codesign --force --sign - "$APP" >/dev/null

  log "App ready: $APP"
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
    CONFIG=release "$0" all

    SAVER_DEST="$HOME/Library/Screen Savers"
    APP_DEST="$HOME/Applications"
    mkdir -p "$SAVER_DEST" "$APP_DEST"

    rm -rf "$SAVER_DEST/Idlesse.saver" "$APP_DEST/Idlesse.app"
    cp -R "$SAVER" "$SAVER_DEST/Idlesse.saver"
    cp -R "$APP" "$APP_DEST/Idlesse.app"

    killall legacyScreenSaver 2>/dev/null || true

    log "Installed screen saver: $SAVER_DEST/Idlesse.saver"
    log "Installed settings app: $APP_DEST/Idlesse.app"
    log "Configure Idlesse in the app. On macOS 26, System Settings → Wallpaper → Screen Saver → Custom → Other → Idlesse selects the saver."
    open "$APP_DEST/Idlesse.app"
    ;;
  clean)
    rm -rf "$BUILD"
    log "Cleaned."
    ;;
  all|*)
    build_app
    build_saver
    ;;
esac
