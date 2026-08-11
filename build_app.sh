#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

echo "==> Building DesktopPet (release)"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/DesktopPet"
APP="$ROOT/DesktopPet.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>DesktopPet</string>
  <key>CFBundleIdentifier</key>
  <string>local.desktoppet</string>
  <key>CFBundleName</key>
  <string>DesktopPet</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

cp "$BIN" "$APP/Contents/MacOS/DesktopPet"
chmod +x "$APP/Contents/MacOS/DesktopPet"

echo "==> App ready: $APP"
echo "Run with: open \"$APP\""
echo "Or: \"$APP/Contents/MacOS/DesktopPet\""
