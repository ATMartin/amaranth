#!/usr/bin/env bash
# T13: Release build → verification → DMG. Without signing credentials this produces an ad-hoc-signed DEVELOPER build
# (not notarized; Gatekeeper will ask the tester to allow it). Outputs dist/Amaranth-<version>-<build>.dmg + .sha256.
set -euo pipefail
cd "$(dirname "$0")/.."
# T70: build + verification shared with install-local.sh and publish.sh.
APP=$(scripts/build-app.sh | tee /dev/stderr | sed -n 's/^APP=//p')
test -n "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -A1 audio-input || true
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
STAGE=dist/stage
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
cp docs/release/TESTER-GUIDE.md "$STAGE/Read Me First.md"
cp App/Resources/THIRD_PARTY_NOTICES.md "$STAGE/Third-Party Notices.md"
ln -s /Applications "$STAGE/Applications"
DMG=dist/Amaranth-$VERSION-$BUILD-developer.dmg
rm -f "$DMG"
hdiutil create -volname "Amaranth $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
shasum -a 256 "$DMG" | tee "$DMG.sha256"
du -h "$DMG"
echo "DEVELOPER BUILD: ad-hoc signed, not notarized. Distribution qualification incomplete (no signing credentials)."
