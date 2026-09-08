#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$ROOT/build"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
MIN_MACOS="${MIN_MACOS:-14.0}"
CONFIG="${CONFIG:-debug}"
ARCHS="${ARCHS:-arm64 x86_64}"

SAVER="$BUILD/Idlesse.saver"
PREVIEW_APP="$BUILD/Idlesse Preview.app"

SHARED_SOURCES=(
  "$ROOT/Sources/Shared/Preferences.swift"
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

build_preview() {
  local arch="$(uname -m)"
  log "Building preview harness for $arch"
  rm -rf "$PREVIEW_APP"
  mkdir -p "$PREVIEW_APP/Contents/MacOS" "$PREVIEW_APP/Contents/Resources"

  xcrun swiftc \
    -sdk "$SDK" \
    -target "$arch-apple-macosx$MIN_MACOS" \
    -swift-version 5 \
    "${SWIFT_OPT[@]}" \
    -module-name IdlessePreview \
    "${SHARED_SOURCES[@]}" \
    "${SAVER_SOURCES[@]}" \
    "$ROOT/Sources/Harness/main.swift" \
    -framework AppKit \
    -framework Photos \
    -framework ScreenSaver \
    -framework UniformTypeIdentifiers \
    -o "$PREVIEW_APP/Contents/MacOS/IdlessePreview"

  cp "$ROOT/Sources/Harness/Info.plist" "$PREVIEW_APP/Contents/Info.plist"
  chmod +x "$PREVIEW_APP/Contents/MacOS/IdlessePreview"
  codesign --force --sign - "$PREVIEW_APP" >/dev/null

  log "Preview ready: $PREVIEW_APP"
}

case "${1:-all}" in
  saver)
    build_saver
    ;;
  preview)
    build_preview
    ;;
  run)
    build_preview
    pkill -x IdlessePreview 2>/dev/null || true
    sleep 0.2
    open "$PREVIEW_APP"
    ;;
  install)
    CONFIG=release "$0" saver
    DEST="$HOME/Library/Screen Savers"
    mkdir -p "$DEST"
    rm -rf "$DEST/Idlesse.saver"
    cp -R "$SAVER" "$DEST/Idlesse.saver"
    killall legacyScreenSaver 2>/dev/null || true
    log "Installed to $DEST/Idlesse.saver"
    log "Open System Settings → Screen Saver and select Idlesse."
    ;;
  clean)
    rm -rf "$BUILD"
    log "Cleaned."
    ;;
  all|*)
    build_preview
    build_saver
    ;;
esac
