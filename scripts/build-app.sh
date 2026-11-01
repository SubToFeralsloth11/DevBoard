#!/bin/bash
# Builds DevBoard.app (release), signs it and installs it to /Applications.
#   scripts/build-app.sh            build + install
#   scripts/build-app.sh --no-install
set -euo pipefail
cd "$(dirname "$0")/.."

HEAVY="$HOME/.agents/bin/heavy"
run_heavy() { if [ -x "$HEAVY" ]; then "$HEAVY" 900 "$@"; else "$@"; fi; }

run_heavy swift build -c release
BIN="$(swift build -c release --show-bin-path)/DevBoard"

APP="build/DevBoard.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DevBoard"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Icon: rendered by the app itself, cached until the renderer changes.
ICONSET="build/AppIcon.iconset"
if [ ! -f build/AppIcon.icns ] || [ Sources/DevBoard/Support/IconRenderer.swift -nt build/AppIcon.icns ]; then
  rm -rf "$ICONSET"
  "$BIN" --render-icon "$ICONSET"
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# A stable self-signed identity keeps the Screen Recording permission across rebuilds.
# It lives in its own keychain (password "devboard") so codesign never shows a keychain prompt.
IDENTITY="DevBoard Local Signing"
KEYCHAIN="$HOME/Library/Keychains/devboard-signing.keychain-db"
if [ -f "$KEYCHAIN" ] && security unlock-keychain -p devboard "$KEYCHAIN" 2>/dev/null; then
  codesign --force --keychain "$KEYCHAIN" --sign "$IDENTITY" --timestamp=none "$APP"
else
  echo "No DevBoard signing keychain; ad-hoc signing (Screen Recording permission resets each build)."
  codesign --force --sign - "$APP"
fi

if [ "${1:-}" != "--no-install" ]; then
  pkill -x DevBoard 2>/dev/null || true
  rm -rf /Applications/DevBoard.app
  cp -R "$APP" /Applications/DevBoard.app
  echo "Installed /Applications/DevBoard.app"
fi
