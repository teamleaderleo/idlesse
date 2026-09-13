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
  # A prior removal is normal. Still unregister the containing app so running
  # a build-time CLI check cannot leave a second discovered provider behind.
  if ! /usr/bin/pluginkit -r "$ext"; then
    matches=$(/usr/bin/pluginkit -m -A -D -v -i dev.idlesse.nativeprobe.catalog)
    if [[ "$matches" == *"$ext"* ]]; then
      echo 'Probe extension remains registered; cleanup failed.' >&2
      exit 1
    fi
  fi
  if ! output=$("$registrar" -u "$app" 2>&1); then
    # Launch Services returns application-not-found when this exact build copy
    # was already removed. Other failures must still be reported.
    if [[ "$output" != *"-10814"* ]]; then
      printf '%s\n' "$output" >&2
      exit 1
    fi
  fi
fi
/usr/bin/pluginkit -m -A -D -v -i dev.idlesse.nativeprobe.catalog
