#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${BUILD_DIR:?Run through the native-probe-xcode managed profile}"
: "${IDLESSE_SWIFT_SCRATCH_PATH:?Missing managed scratch directory}"
Experiments/NativeWallpaper/build.sh
xcodebuild -project Experiments/NativeWallpaper/NativeProbe.xcodeproj -target IdlesseNativeProbe -configuration Debug \
  SYMROOT="$BUILD_DIR/xcode" OBJROOT="$IDLESSE_SWIFT_SCRATCH_PATH" \
  MODULE_CACHE_DIR="$IDLESSE_MODULE_CACHE_PATH" build
app="$BUILD_DIR/Idlesse Native Probe.app"
ext="$app/Contents/Extensions/IdlesseNativeProbe.appex"
# Replace only this probe's extension; retain the generated synthetic poster.
ditto "$BUILD_DIR/xcode/Debug/IdlesseNativeProbe.appex" "$ext"
# The script build used a different executable name; do not ship that unused copy.
rm -f "$ext/Contents/MacOS/NativeWallpaperProbe"
codesign --force --sign - --options runtime --entitlements "$BUILD_DIR/probe-entitlements.plist" "$ext"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$app"
