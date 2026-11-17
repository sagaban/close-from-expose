#!/bin/zsh
# Builds build/CloseFromExpose.app (universal: arm64 + x86_64).
#   ./build.sh            build only
#   ./build.sh install    build, copy to /Applications and relaunch
#   VERSION=1.2.0 ./build.sh   set the bundle version (CI sets it from the git tag)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-0.0.0-dev}"
APP=build/CloseFromExpose.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$ARCH-apple-macos13.0" \
    Sources/main.swift -o "build/obj/CloseFromExpose-$ARCH"
done
lipo -create build/obj/CloseFromExpose-arm64 build/obj/CloseFromExpose-x86_64 \
  -output "$APP/Contents/MacOS/CloseFromExpose"

cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.santiago.CloseFromExpose</string>
  <key>CFBundleName</key><string>Close from Exposé</string>
  <key>CFBundleDisplayName</key><string>Close from Exposé</string>
  <key>CFBundleExecutable</key><string>CloseFromExpose</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

# A stable identity keeps the Accessibility permission across rebuilds
# (create it once with scripts/create-signing-cert.sh); fall back to ad-hoc.
IDENTITY="CloseFromExpose Local Signing"
if security find-identity -p codesigning | grep -q "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "warning: '$IDENTITY' not found, signing ad-hoc (Accessibility permission resets on every build)"
  codesign --force --sign - "$APP"
fi
echo "Built $APP ($VERSION)"

# The login item points at the installed copy, not at build/.
if [[ "${1:-}" == "install" ]]; then
  DEST=/Applications/CloseFromExpose.app
  pkill -x CloseFromExpose || true
  sleep 0.5
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  open "$DEST"
  echo "Installed $DEST"
fi
