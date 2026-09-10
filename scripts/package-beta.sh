#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:?Set VERSION, for example 0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:?Set a monotonically increasing BUILD_NUMBER}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo 'Invalid version/build'; exit 1; }
MODE="${1:-local}"
[[ "$MODE" == local || "$MODE" == notarized ]] || { echo 'Use local or notarized'; exit 1; }
if [[ "$MODE" == notarized ]]; then
  : "${SIGN_IDENTITY:?Developer ID Application identity required}"
  : "${NOTARY_PROFILE:?Keychain notarytool profile required}"
  [[ "$SIGN_IDENTITY" == 'Developer ID Application:'* ]] || { echo 'Developer ID Application identity required'; exit 1; }
fi
CONFIG=release "$ROOT/build.sh" all
STAGE="$(mktemp -d "$ROOT/build/beta-stage.XXXXXX")"
SUBMISSION="$STAGE.zip"
trap 'rm -rf "$STAGE"; rm -f "$SUBMISSION"' EXIT
for bundle in Idlesse.app Idlesse.saver; do ditto "$ROOT/build/$bundle" "$STAGE/$bundle"; done
EXT="$STAGE/Idlesse.app/Contents/PlugIns/IdlesseDesktopMenu.appex"
for bundle in "$EXT" "$STAGE/Idlesse.saver" "$STAGE/Idlesse.app"; do
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$bundle/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$bundle/Contents/Info.plist"
done
SIGN_ARGS=(--force --sign -)
if [[ "$MODE" == notarized ]]; then SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --options runtime --timestamp); fi
codesign "${SIGN_ARGS[@]}" --entitlements "$ROOT/Sources/DesktopMenu/Entitlements.plist" "$EXT"
codesign "${SIGN_ARGS[@]}" "$STAGE/Idlesse.saver"
codesign "${SIGN_ARGS[@]}" "$STAGE/Idlesse.app"
for bundle in Idlesse.app Idlesse.saver; do codesign --verify --deep --strict "$STAGE/$bundle"; done
cp "$ROOT/docs/beta-install.txt" "$STAGE/Read Me.txt"
OUT="$ROOT/build/Idlesse-$VERSION-$BUILD_NUMBER-$MODE.zip"
[[ ! -e "$OUT" ]] || { echo "Artifact already exists: $OUT"; exit 1; }
if [[ "$MODE" == notarized ]]; then
  ditto -c -k --keepParent "$STAGE" "$SUBMISSION"
  xcrun notarytool submit "$SUBMISSION" --keychain-profile "$NOTARY_PROFILE" --wait
  rm "$SUBMISSION"
  xcrun stapler staple "$STAGE/Idlesse.app"
  xcrun stapler staple "$STAGE/Idlesse.saver"
  spctl --assess --type execute "$STAGE/Idlesse.app"
fi
ditto -c -k "$STAGE" "$OUT"
shasum -a 256 "$OUT"
echo "Created $MODE artifact: $OUT"
