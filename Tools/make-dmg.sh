#!/bin/zsh
# Builds the app and packs it into build/Macam-<version>.dmg (drag Macam onto Applications).
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
STAGE=$(mktemp -d)
cp -R build/Macam.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="build/Macam-$VERSION.dmg"
hdiutil create -volname "Macam" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG"
echo "Wrote $DMG"
