#!/usr/bin/env bash
# Wraps the SwiftPM-built GlassCaptureSpike in a minimal .app and signs it, so macOS can list it
# under Screen & System Audio Recording (since 26.1, bare executables don't appear there).
#
# Signing: ad-hoc by default. TCC pins an ad-hoc app to its exact code hash, so every rebuild is
# a "new" app and the permission must be granted again. Set GLASS_SIGN_IDENTITY to an Apple
# Development / Developer ID identity to keep the grant across rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/GlassCaptureSpike.app"
IDENTITY="${GLASS_SIGN_IDENTITY:--}"

swift build -c "$CONFIG" --product GlassCaptureSpike
BIN="$(swift build -c "$CONFIG" --show-bin-path)/GlassCaptureSpike"

mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/GlassCaptureSpike"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.g-l-a-s-s.capture-spike</string>
  <key>CFBundleName</key><string>GlassCaptureSpike</string>
  <key>CFBundleExecutable</key><string>GlassCaptureSpike</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign "$IDENTITY" --options runtime "$APP"
codesign --verify --strict --verbose=1 "$APP"
echo "built $APP (signed: ${IDENTITY/#-/ad-hoc})"
