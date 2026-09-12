#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
output="${BUILD_DIR:-$PWD/build/native-wallpaper-probe}"
app="$output/Idlesse Native Probe.app"
ext="$app/Contents/Extensions/IdlesseNativeProbe.appex"
mkdir -p "$app/Contents/MacOS" "$ext/Contents/MacOS"
python3 - "$app" "$ext" <<'PY'
import plistlib, sys
from pathlib import Path
for path, identifier, executable, package in [
 (sys.argv[1], 'dev.idlesse.nativeprobe', 'NativeProbe', 'APPL'),
 (sys.argv[2], 'dev.idlesse.nativeprobe.catalog', 'NativeWallpaperProbe', 'XPC!')]:
 d = dict(CFBundleIdentifier=identifier, CFBundleExecutable=executable,
          CFBundleName='Idlesse Native Probe', CFBundlePackageType=package,
          CFBundleVersion='2', CFBundleShortVersionString='0.1', LSMinimumSystemVersion='26.0')
 if package == 'XPC!':
  d['EXAppExtensionAttributes'] = {'EXExtensionPointIdentifier': 'com.apple.wallpaper'}
 with (Path(path)/'Contents/Info.plist').open('wb') as f: plistlib.dump(d,f)
with (Path(sys.argv[2]).parent.parent.parent.parent/'probe-entitlements.plist').open('wb') as f:
 plistlib.dump({'com.apple.security.app-sandbox': True}, f)
PY
cache="${IDLESSE_MODULE_CACHE_PATH:-$output/module-cache}"
mkdir -p "$cache"
xcrun swiftc -parse-as-library -target arm64-apple-macos26.0 -module-cache-path "$cache" Experiments/NativeWallpaper/Probe.swift Experiments/NativeWallpaper/Catalog.swift Experiments/NativeWallpaper/Vendor/CodableShims.swift -framework AppKit -o "$app/Contents/MacOS/NativeProbe"
xcrun swiftc -parse-as-library -application-extension -target arm64-apple-macos26.0 -module-cache-path "$cache" -import-objc-header Experiments/NativeWallpaper/Bridge.h Experiments/NativeWallpaper/Extension.swift Experiments/NativeWallpaper/Catalog.swift Experiments/NativeWallpaper/Vendor/CodableShims.swift -framework AppKit -framework Security -framework ExtensionFoundation -o "$ext/Contents/MacOS/NativeWallpaperProbe"
mkdir -p "$ext/Contents/Resources"
"$app/Contents/MacOS/NativeProbe" --make-poster "$ext/Contents/Resources/SyntheticOrbit.png"
"$app/Contents/MacOS/NativeProbe" --catalog-check "$ext/Contents/Resources/SyntheticOrbit.png" > "$output/catalog-check.txt"
codesign --force --sign - --entitlements "$output/probe-entitlements.plist" "$ext"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
"$app/Contents/MacOS/NativeProbe" --inspect > "$output/runtime-inspection.json"
printf '%s\n' "$app"
