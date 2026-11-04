#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
if [[ $# -ne 0 ]]; then
  printf '%s\n' 'Usage: ./scripts/build-app.sh' >&2
  exit 2
fi
STAGE="$(mktemp -d "$ROOT/build/.app-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/DueBridge.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/en.lproj" "$APP/Contents/Resources/zh-Hans.lproj"
xcrun swiftc "${FLAGS[@]}" -O -parse-as-library "${APP_FRAMEWORKS[@]}" -o "$APP/Contents/MacOS/DueBridge" "${APP_SOURCES[@]}"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/DueBridge.icns "$APP/Contents/Resources/DueBridge.icns"
cp Resources/en.lproj/InfoPlist.strings "$APP/Contents/Resources/en.lproj/InfoPlist.strings"
cp Resources/zh-Hans.lproj/InfoPlist.strings "$APP/Contents/Resources/zh-Hans.lproj/InfoPlist.strings"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - --timestamp=none "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
if [[ -e "$ROOT/build/DueBridge.app" ]]; then mv "$ROOT/build/DueBridge.app" "$STAGE/previous.app"; fi
if ! mv "$APP" "$ROOT/build/DueBridge.app"; then
  if [[ -e "$STAGE/previous.app" ]]; then mv "$STAGE/previous.app" "$ROOT/build/DueBridge.app"; fi
  printf '%s\n' 'Unable to move the completed application into build/.' >&2
  exit 1
fi
printf '%s\n' 'Built build/DueBridge.app (local ad hoc signature).'
