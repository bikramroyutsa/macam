#!/bin/zsh
# Builds Macam and wraps it into build/Macam.app (ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/Macam.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Macam "$APP/Contents/MacOS/Macam"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"
echo "Built $APP"
