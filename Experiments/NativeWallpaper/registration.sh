#!/bin/bash
set -euo pipefail
# Explicit path keeps the experiment separate from the shipping Idlesse bundle.
mode="${1:-}"
app="${2:-}"
if [[ "$mode" != register && "$mode" != unregister ]] || [[ ! -d "$app" ]]; then
  echo 'Usage: registration.sh register|unregister "/absolute/path/Idlesse Native Probe.app"' >&2
  exit 2
fi
identifier=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")
[[ "$identifier" == dev.idlesse.nativeprobe ]] || { echo 'Refusing a non-probe app.' >&2; exit 2; }
ext="$app/Contents/Extensions/IdlesseNativeProbe.appex"
registrar=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [[ "$mode" == register ]]; then
  codesign --verify --deep --strict "$app"
  "$registrar" -f "$app"
  /usr/bin/pluginkit -a "$ext"
else
  /usr/bin/pluginkit -r "$ext"
  "$registrar" -u "$app"
fi
/usr/bin/pluginkit -m -A -D -v -i dev.idlesse.nativeprobe.wallpaper
