#!/bin/zsh
# Builds Rummage.app (universal: Apple Silicon + Intel).
# Usage: ./build.sh            build only
#        ./build.sh install    + copy to ~/Applications and launch
#        ./build.sh dist       + zip for sharing: dist/Rummage-<version>.zip
#        ./build.sh release    + Developer ID signature, Apple notarization, stapled zip (no Gatekeeper warning)
#
# release needs (once): a "Developer ID Application" certificate in the keychain and notarytool credentials:
#   xcrun notarytool store-credentials rummage --apple-id <apple id> --team-id <TEAM ID>
# Override with SIGN_ID="Developer ID Application: …" / NOTARY_PROFILE=<name>.
set -e
cd "$(dirname "$0")"
NOTARY_PROFILE=${NOTARY_PROFILE:-rummage}
if [[ "$1" == "release" ]]; then
  SIGN_ID=${SIGN_ID:-$(security find-identity -v -p codesigning | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)"/\1/')}
  if [[ -z "$SIGN_ID" ]]; then
    echo "No 'Developer ID Application' certificate in the keychain. See README → Notarized releases." >&2
    exit 1
  fi
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "No notarytool credentials named '$NOTARY_PROFILE'. Run once:" >&2
    echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple id> --team-id <TEAM ID>" >&2
    exit 1
  fi
fi
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
if [[ -n "$SIGN_ID" ]]; then
  codesign --force --options runtime --timestamp --entitlements Resources/Rummage.entitlements --sign "$SIGN_ID" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  codesign --force --sign - "$APP"   # ad-hoc: fine locally, Gatekeeper warns on other Macs
fi
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

if [[ "$1" == "dist" || "$1" == "release" ]]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
  mkdir -p dist
  ZIP="dist/Rummage-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  if [[ "$1" == "release" ]]; then
    echo "Notarizing (usually 1–5 min)…"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"          # ticket inside the app: opens offline too
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    spctl --assess --type execute --verbose "$APP"
  fi
  echo "Packed $ZIP ($(du -h "$ZIP" | cut -f1))"
fi
