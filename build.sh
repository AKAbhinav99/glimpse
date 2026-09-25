#!/bin/bash
# Builds Glimpse.app and packages it as Glimpse.dmg (drag-to-Applications).
set -euo pipefail
cd "$(dirname "$0")"

BUILD=build
APP="$BUILD/Glimpse.app"
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ Compiling"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 Sources/*.swift -o "$BUILD/Glimpse-arm64"
swiftc -O -swift-version 5 -target x86_64-apple-macos14.0 Sources/*.swift -o "$BUILD/Glimpse-x86_64"
lipo -create "$BUILD/Glimpse-arm64" "$BUILD/Glimpse-x86_64" -output "$APP/Contents/MacOS/Glimpse"

cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "→ Icon"
swift scripts/make_icon.swift "$BUILD/AppIcon.iconset"
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

echo "→ Signing (stable local certificate)"
# Same certificate every build => macOS keeps Camera/Accessibility/Keychain permissions across updates.
IDENTITY=$(scripts/signing.sh)
KC="$HOME/Library/Application Support/Glimpse-Signing/signing.keychain-db"
ORIG=$(security list-keychains -d user | tr -d '"' | xargs)
security list-keychains -d user -s $ORIG "$KC"
trap 'security list-keychains -d user -s $ORIG' EXIT
codesign --force --sign "$IDENTITY" --identifier com.local.glimpse "$APP"
security list-keychains -d user -s $ORIG
codesign -dr - "$APP" 2>&1 | tail -1

echo "→ DMG"
STAGE="$BUILD/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Glimpse" -srcfolder "$STAGE" -ov -format UDZO "$BUILD/Glimpse.dmg" >/dev/null
cp "$BUILD/Glimpse.dmg" ./Glimpse.dmg
echo "✓ Built $(pwd)/Glimpse.dmg"
