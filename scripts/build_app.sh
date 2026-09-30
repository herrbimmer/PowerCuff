#!/bin/zsh
# Builds build/PowerCuff.app (ad-hoc signed). Pass --install to copy to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
ICON_SRC="Powercuff icon.jpg"
OUT=build
APP="$OUT/PowerCuff.app"

mkdir -p "$OUT/icons"
swift scripts/make_icons.swift "$ICON_SRC" "$OUT/icons"
iconutil -c icns "$OUT/icons/AppIcon.iconset" -o "$OUT/icons/AppIcon.icns"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/PowerCuff"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PowerCuff"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp "$OUT/icons/AppIcon.icns" "$OUT/icons/MenuBarIcon.png" "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/PowerCuff.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/PowerCuff.app"
fi
