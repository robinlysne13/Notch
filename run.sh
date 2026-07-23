#!/bin/bash
# Build the Swift package, wrap it in a .app bundle (so macOS Automation permissions
# and the accessory activation policy work), then relaunch it.
set -e
cd "$(dirname "$0")"

CONFIG="${1:-release}"
echo "==> Building ($CONFIG)…"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/NotchApp"
APP="Notch.app"

echo "==> Packaging $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/NotchApp"
cp Info.plist "$APP/Contents/Info.plist"

# Ad-hoc sign so the bundle has a stable-ish identity for TCC prompts.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "==> Relaunching…"
killall NotchApp >/dev/null 2>&1 || true
sleep 0.3
open "$APP"
echo "==> Launched. Hover the notch to expand it."
