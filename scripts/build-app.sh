#!/usr/bin/env bash
# T70: the one build + verify step shared by build-release.sh, install-local.sh and publish.sh.
#   scripts/build-app.sh [--debug] [--no-build] [--quiet]
# Builds Amaranth (Release by default) with xcodebuild, then checks the bundle: XPC worker and llama.framework
# embedded, notices and model pack definition bundled, arm64 only, bundle ID, minimum macOS, a valid deep/strict
# signature, the build stamp (scripts/stamp-build.sh) matching HEAD, and, for Release, fault injection compiled out.
# Prints the checks, then a last line `APP=<path to the built Amaranth.app>`. Exits non-zero on any failure.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=Release; BUILD=1; QUIET=0
for arg in "$@"; do
  case $arg in
    --debug) CONFIG=Debug ;;
    --no-build) BUILD=0 ;;
    --quiet) QUIET=1 ;;
    -h|--help) sed -n 2,7p "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done
if [ "$CONFIG" = Release ]; then DERIVED=build/ReleaseDerivedData; else DERIVED=build/DerivedData; fi
APP=$DERIVED/Build/Products/$CONFIG/Amaranth.app
WORKER=$APP/Contents/XPCServices/com.alexmartin.amaranth.InferenceWorker.xpc
BUNDLE_ID=com.alexmartin.amaranth
say() { [ $QUIET = 1 ] || echo "$@"; }
fail() { echo "build-app: $*" >&2; exit 1; }

if [ $BUILD = 1 ]; then
  say "== build ($CONFIG)"
  [ "$CONFIG" = Release ] && scripts/generate-notices.sh >/dev/null
  xcodegen generate --quiet
  LOG=$(mktemp -t amaranth-build)
  if ! xcodebuild -project Amaranth.xcodeproj -scheme Amaranth -configuration "$CONFIG" -derivedDataPath "$DERIVED" build \
      >"$LOG" 2>&1; then
    grep -E "error:" "$LOG" | sort -u | head -20 >&2
    fail "BUILD FAILED (full log: $LOG)"
  fi
  /bin/rm -f "$LOG"
fi
test -d "$APP" || fail "no build at $APP (run without --no-build)"

say "== verify bundle"
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }
test -d "$WORKER" || fail "XPC worker missing"
test -d "$WORKER/Contents/Frameworks/llama.framework" || fail "llama.framework missing from the worker"
test -f "$APP/Contents/Resources/default-model-pack.json" || fail "model pack definition missing"
if [ "$CONFIG" = Release ]; then test -f "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md" || fail "notices missing"; fi
for bin in "$APP/Contents/MacOS/Amaranth" "$WORKER/Contents/MacOS/com.alexmartin.amaranth.InferenceWorker"; do
  [ "$(lipo -archs "$bin")" = arm64 ] || fail "$(basename "$bin") is not arm64 only: $(lipo -archs "$bin")"
done
[ "$(plist "$APP" CFBundleIdentifier)" = "$BUNDLE_ID" ] || fail "unexpected bundle ID: $(plist "$APP" CFBundleIdentifier)"
codesign --verify --deep --strict "$APP" || fail "signature invalid or build incomplete: $APP"
TEAM=$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
# The stamp: build number = commit count, the same commit and dirty state as the working tree, in the app and the worker.
EXPECT_BUILD=$(git rev-list --count HEAD); EXPECT_COMMIT=$(git rev-parse --short=7 HEAD)
if git diff --quiet HEAD --; then EXPECT_DIRTY=false; else EXPECT_DIRTY=true; fi
BUILD_NO=$(plist "$APP" CFBundleVersion); COMMIT=$(plist "$APP" AmaranthCommit); DIRTY=$(plist "$APP" AmaranthDirty)
CHANNEL=$(plist "$APP" AmaranthChannel)
[ "$BUILD_NO" = "$EXPECT_BUILD" ] && [ "$COMMIT" = "$EXPECT_COMMIT" ] && [ "$DIRTY" = "$EXPECT_DIRTY" ] \
  || fail "stale build stamp: app says build $BUILD_NO $COMMIT dirty=$DIRTY, HEAD is $EXPECT_BUILD $EXPECT_COMMIT dirty=$EXPECT_DIRTY"
[ "$(plist "$WORKER" CFBundleVersion)" = "$BUILD_NO" ] || fail "worker build $(plist "$WORKER" CFBundleVersion) differs from the app's $BUILD_NO"
if [ "$CONFIG" = Release ]; then
  [ "$CHANNEL" = release ] || fail "Release build stamped channel $CHANNEL"
  # grep the binary directly: `strings | grep -q` dies of SIGPIPE under pipefail.
  LC_ALL=C grep -qa "faultInjection.disabled" "$WORKER/Contents/MacOS/com.alexmartin.amaranth.InferenceWorker" \
    || fail "fault injection not compiled out of Release"
fi
say "verified: $CONFIG build $BUILD_NO ($COMMIT$( [ "$DIRTY" = true ] && echo -dirty ), channel $CHANNEL), team ${TEAM:-none}," \
  "macOS $(plist "$APP" LSMinimumSystemVersion)+, arm64, signature valid (deep, strict)"
echo "APP=$APP"
