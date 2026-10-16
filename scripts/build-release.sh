#!/usr/bin/env bash
# T13: Release build → verification → DMG. Without signing credentials this produces an ad-hoc-signed DEVELOPER build
# (not notarized; Gatekeeper will ask the tester to allow it). Outputs dist/Amaranth-<version>-<build>.dmg + .sha256.
set -euo pipefail
cd "$(dirname "$0")/.."
DERIVED=build/ReleaseDerivedData
APP=$DERIVED/Build/Products/Release/Amaranth.app
WORKER=$APP/Contents/XPCServices/com.alexmartin.amaranth.InferenceWorker.xpc
scripts/generate-notices.sh
xcodegen generate --quiet
xcodebuild -project Amaranth.xcodeproj -scheme Amaranth -configuration Release -derivedDataPath "$DERIVED" build \
  2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u
echo "== verify bundle"
test -d "$WORKER" && echo "worker: embedded"
test -d "$WORKER/Contents/Frameworks/llama.framework" && echo "llama.framework: embedded in worker"
test -f "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md" && echo "notices: bundled"
test -f "$APP/Contents/Resources/default-model-pack.json" && echo "model pack definition: bundled"
lipo -archs "$APP/Contents/MacOS/Amaranth"; lipo -archs "$WORKER/Contents/MacOS/com.alexmartin.amaranth.InferenceWorker"
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist"
codesign --verify --deep --strict "$APP" && echo "codesign: valid (deep, strict)"
codesign -dv "$APP" 2>&1 | grep -E "Signature|TeamIdentifier|flags" || true
codesign -d --entitlements - "$APP" 2>/dev/null | grep -A1 audio-input || true
# Fault injection must be compiled out of Release.
if strings "$WORKER/Contents/MacOS/com.alexmartin.amaranth.InferenceWorker" | grep -q "faultInjection.disabled"; then echo "fault injection: disabled in Release"; fi
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
