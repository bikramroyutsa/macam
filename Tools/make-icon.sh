#!/bin/zsh
# Regenerates Resources/AppIcon.icns from Tools/make-icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
swiftc -O Tools/make-icon.swift -o "$work/make-icon"
"$work/make-icon" Resources/AppIcon-1024.png
set_dir="$work/AppIcon.iconset"
mkdir -p "$set_dir"
for size in 16 32 64 128 256 512 1024; do
  sips -z $size $size Resources/AppIcon-1024.png --out "$work/i$size.png" >/dev/null
done
cp "$work/i16.png"   "$set_dir/icon_16x16.png"
cp "$work/i32.png"   "$set_dir/icon_16x16@2x.png"
cp "$work/i32.png"   "$set_dir/icon_32x32.png"
cp "$work/i64.png"   "$set_dir/icon_32x32@2x.png"
cp "$work/i128.png"  "$set_dir/icon_128x128.png"
cp "$work/i256.png"  "$set_dir/icon_128x128@2x.png"
cp "$work/i256.png"  "$set_dir/icon_256x256.png"
cp "$work/i512.png"  "$set_dir/icon_256x256@2x.png"
cp "$work/i512.png"  "$set_dir/icon_512x512.png"
cp "$work/i1024.png" "$set_dir/icon_512x512@2x.png"
iconutil -c icns "$set_dir" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"
