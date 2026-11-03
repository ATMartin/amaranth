#!/bin/sh
# T70: Xcode build phase (app and XPC worker, after Info.plist is processed, before signing). Stamps the built
# Info.plist so every build path (Xcode, check.sh, install-local.sh, build-release.sh, publish.sh) numbers builds the
# same way:
#   CFBundleVersion     git commit count of HEAD (one number line shared by Release and Debug)
#   AmaranthCommit      short commit of HEAD
#   AmaranthDirty       true when tracked files differ from HEAD
#   AmaranthBuildDate   UTC, ISO 8601
#   AmaranthChannel     release (Release configuration) or debug (anything else)
# Outside a git checkout the build number is 0 and the commit "unknown", so such a build is never newer than anything.
set -eu
PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
[ -f "$PLIST" ] || { echo "stamp-build: no Info.plist at $PLIST" >&2; exit 1; }
cd "${SRCROOT}"
if COUNT=$(git rev-list --count HEAD 2>/dev/null); then
  COMMIT=$(git rev-parse --short=7 HEAD)
  if git diff --quiet HEAD -- 2>/dev/null; then DIRTY=false; else DIRTY=true; fi
else
  COUNT=0; COMMIT=unknown; DIRTY=false
fi
DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [ "${CONFIGURATION}" = Release ]; then CHANNEL=release; else CHANNEL=debug; fi
PB=/usr/libexec/PlistBuddy
set_key() {   # key type value
  $PB -c "Delete :$1" "$PLIST" >/dev/null 2>&1 || true
  $PB -c "Add :$1 $2 $3" "$PLIST"
}
set_key CFBundleVersion string "$COUNT"
set_key AmaranthCommit string "$COMMIT"
set_key AmaranthDirty bool "$DIRTY"
set_key AmaranthBuildDate string "$DATE"
set_key AmaranthChannel string "$CHANNEL"
echo "stamp-build: ${PRODUCT_NAME} build $COUNT ($COMMIT$( [ "$DIRTY" = true ] && echo -dirty ), $CHANNEL)"
