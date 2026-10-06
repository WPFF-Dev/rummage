#!/bin/zsh
# Builds Rummage.app (universal: Apple Silicon + Intel).
# Usage: ./build.sh            build only
#        ./build.sh install    + copy to ~/Applications and launch
#        ./build.sh dist       + zip for sharing: dist/Rummage-<version>.zip
set -e
cd "$(dirname "$0")"
swift build -c release --triple arm64-apple-macosx14.0
swift build -c release --triple x86_64-apple-macosx14.0
APP=build/Rummage.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/Rummage" \
  .build/arm64-apple-macosx/release/Rummage .build/x86_64-apple-macosx/release/Rummage
cp Resources/Info.plist "$APP/Contents/"
cp -R Resources/en.lproj Resources/ru.lproj "$APP/Contents/Resources/"
if [[ ! -f build/AppIcon.icns ]]; then
  swift scripts/make_icon.swift build
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
  rm -rf build/AppIcon.iconset
fi
cp build/AppIcon.icns "$APP/Contents/Resources/"
xattr -cr "$APP"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "$1" == "install" ]]; then
  pkill -x Rummage 2>/dev/null || true
  while pgrep -x Rummage >/dev/null; do sleep 0.2; done
  sleep 0.5
  mkdir -p ~/Applications
  rm -rf ~/Applications/Rummage.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/Rummage.app
  echo "Installed to ~/Applications/Rummage.app and launched"
fi

if [[ "$1" == "dist" ]]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
  mkdir -p dist
  ZIP="dist/Rummage-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Packed $ZIP ($(du -h "$ZIP" | cut -f1))"
fi
