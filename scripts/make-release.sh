#!/bin/bash
# Build Dropyk for release: Release config, build number = commit count, signed with the
# "Dropyk Local Signing" certificate (scripts/make-signing-cert.sh) rather than ad hoc, so
# macOS keeps Dropyk's permissions across updates and the in-app updater can check that a
# download is signed like the running app.
# Out: build/release/Dropyk.dmg (the app and a link to Applications) and Dropyk.dmg.sha256.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="Dropyk Local Signing"
security find-identity -v -p codesigning | grep -q "$IDENTITY" || { echo "no \"$IDENTITY\" certificate" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "commit your changes first: a release is built from a commit" >&2; exit 1; }

BUILD=$(git rev-list --count HEAD)
OUT=build/release
rm -rf "$OUT"
xcodebuild -project NearDrop.xcodeproj -scheme NearDrop -configuration Release -derivedDataPath build -quiet \
  CURRENT_PROJECT_VERSION="$BUILD" CODE_SIGNING_ALLOWED=NO build
mkdir -p "$OUT/dmg"
APP="$OUT/dmg/Dropyk.app"
cp -R build/Build/Products/Release/Dropyk.app "$APP"

# Inside out: the bundled library, the share extension (sandboxed, as extensions must be), the app.
sign() { codesign --force --options runtime --timestamp=none -s "$IDENTITY" "$@"; }
sign "$APP/Contents/Frameworks/libNearbyShare.dylib"
sign --entitlements ShareExtension/ShareExtension.entitlements "$APP/Contents/PlugIns/ShareExtension.appex"
sign --entitlements NearDrop/NearDrop.entitlements "$APP"
codesign --verify --deep --strict "$APP"

ln -s /Applications "$OUT/dmg/Applications"
# Unsigned on purpose: macOS blocks a quarantined image signed by a certificate it doesn't
# know before it even opens; an unsigned one opens, and only the app asks.
hdiutil create -quiet -volname Dropyk -srcfolder "$OUT/dmg" -format UDZO -ov "$OUT/Dropyk.dmg"
rm -rf "$OUT/dmg"
(cd "$OUT" && shasum -a 256 Dropyk.dmg > Dropyk.dmg.sha256)
VERSION=$(defaults read "$PWD/build/Build/Products/Release/Dropyk.app/Contents/Info.plist" CFBundleShortVersionString)
echo "Dropyk $VERSION ($BUILD): $OUT/Dropyk.dmg"
cat "$OUT/Dropyk.dmg.sha256"
