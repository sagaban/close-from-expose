#!/bin/zsh
# Packages build/CloseFromExpose.app into build/CloseFromExpose.dmg
# (app + /Applications shortcut, so users drag and drop to install).
set -euo pipefail
cd "$(dirname "$0")/.."

STAGE=build/dmg
DMG=build/CloseFromExpose.dmg
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R build/CloseFromExpose.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Close from Exposé" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Built $DMG"
