#!/usr/bin/env bash
# T70: publish the current commit as an update the app's Check for Updates… can install (Milestone Q).
#   scripts/publish.sh [--debug] [--local-only [--dest DIR]]
# Refuses a working tree with any change (tracked or untracked) and, for GitHub, a HEAD that isn't on origin; it never
# pushes. Builds and verifies (scripts/build-app.sh), zips the app (ditto --keepParent) and writes manifest.json
# (version, build, commit, channel, date, sha256 + size of the zip, team ID, minimum macOS, library schema version, commit
# subjects since the previous published build of the channel).
#   GitHub (default): release tag build-<N> (Release) or build-<N>-debug (prerelease) on ATMartin/amaranth; the zip is
#     uploaded first and manifest.json last, because the app ignores a release without a manifest. An existing tag is
#     refused. Only run this when the user asks to publish.
#   --local-only: the same zip + manifest into DIR/<channel>/<N>/ (default dist/updates) through a staging folder
#     renamed into place, for Settings → Updates → Local folder and tests. No origin check.
set -euo pipefail
cd "$(dirname "$0")/.."

CHANNEL=release; LOCAL=0; DEST=dist/updates
REPO=${AMARANTH_REPO:-ATMartin/amaranth}
while [ $# -gt 0 ]; do
  case $1 in
    --debug) CHANNEL=debug ;;
    --local-only) LOCAL=1 ;;
    --dest) DEST=$2; shift ;;
    -h|--help) sed -n 2,13p "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
fail() { echo "publish: $*" >&2; exit 1; }
# JSON without jq (the Homebrew jq on this Mac is an Intel binary): plutil reads, /usr/bin/python3 writes.
field() { plutil -extract "$1" raw -o - - <<<"$2"; }

# 1. Only committed, pushed code is ever published.
[ -z "$(git status --porcelain)" ] || fail "the working tree has changes; commit or stash them first. Nothing was published."
SHA=$(git rev-parse HEAD)
if [ $LOCAL = 0 ]; then
  git fetch -q origin
  git branch -r --contains "$SHA" | grep -q 'origin/' || fail "HEAD ($(git rev-parse --short HEAD)) isn't on origin; push it first (this script never pushes). Nothing was published."
fi
N=$(git rev-list --count HEAD)
if [ "$CHANNEL" = debug ]; then TAG=build-$N-debug; else TAG=build-$N; fi
if [ $LOCAL = 0 ]; then
  if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1 || [ -n "$(git ls-remote --tags origin "refs/tags/$TAG")" ]; then
    fail "$TAG already exists on $REPO; a published build is never replaced. Nothing was published."
  fi
else
  [ ! -e "$DEST/$CHANNEL/$N" ] || fail "$DEST/$CHANNEL/$N already exists; a published build is never replaced."
fi

# 2. Build and verify (the same step as install-local.sh and build-release.sh).
ARGS=(); [ "$CHANNEL" = debug ] && ARGS+=(--debug)
APP=$(scripts/build-app.sh ${ARGS[@]+"${ARGS[@]}"} | tee /dev/stderr | sed -n 's/^APP=//p')
test -n "$APP" || fail "build failed"
INFO=$("$APP/Contents/MacOS/Amaranth" --build-info)
[ "$(field build "$INFO")" = "$N" ] || fail "built app says build $(field build "$INFO"), expected $N"
[ "$(field channel "$INFO")" = "$CHANNEL" ] || fail "built app is channel $(field channel "$INFO"), expected $CHANNEL"
[ "$(field dirty "$INFO")" = false ] || fail "built app is marked modified"
TEAM=$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
[ -n "$TEAM" ] && [ "$TEAM" != "not set" ] || fail "the build has no team ID (ad-hoc); updates are checked against the team, so set Config/Signing.local.xcconfig"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")

# 3. Commit subjects since the previous published build of this channel (first publish: the last 20).
PREV=""
if [ $LOCAL = 0 ]; then
  if [ "$CHANNEL" = debug ]; then RX='^build-[0-9]+-debug$'; else RX='^build-[0-9]+$'; fi
  PREV_TAG=$(gh release list -R "$REPO" --limit 200 --json tagName --jq '.[].tagName' | { grep -E "$RX" || true; } \
    | sed -E 's/^build-([0-9]+).*/\1 &/' | sort -n | awk -v n="$N" '$1 < n { t = $2 } END { print t }' || true)
  if [ -n "$PREV_TAG" ]; then git fetch -q origin "refs/tags/$PREV_TAG:refs/tags/$PREV_TAG" 2>/dev/null || true; PREV=$(git rev-list -n1 "$PREV_TAG" 2>/dev/null || true); fi
else
  PREV_DIR=$( { ls -d "$DEST/$CHANNEL"/[0-9]* 2>/dev/null || true; } | awk -F/ '{ print $NF " " $0 }' | sort -n | awk -v n="$N" '$1 < n { d = $2 } END { print d }')
  [ -n "$PREV_DIR" ] && PREV=$(plutil -extract commitSha raw -o - "$PREV_DIR/manifest.json" 2>/dev/null || true)
fi
if [ -n "$PREV" ] && git merge-base --is-ancestor "$PREV" HEAD 2>/dev/null; then
  CHANGES=$(git log --no-merges --format=%s -50 "$PREV..HEAD")
else
  CHANGES=$(git log --no-merges --format=%s -20)
fi

# 4. Zip + manifest, in a work folder.
VERSION=$(field version "$INFO")
SUFFIX=""; [ "$CHANNEL" = debug ] && SUFFIX=-debug
ZIP_NAME=Amaranth-$VERSION-$N$SUFFIX.zip
WORK=dist/publish/$TAG
/bin/rm -rf "$WORK"; mkdir -p "$WORK"
ditto -c -k --keepParent "$APP" "$WORK/$ZIP_NAME"
SUM=$(shasum -a 256 "$WORK/$ZIP_NAME" | awk '{ print $1 }')
SIZE=$(stat -f %z "$WORK/$ZIP_NAME")
INFO="$INFO" SHA="$SHA" ASSET="$ZIP_NAME" SUM="$SUM" SIZE="$SIZE" TEAM="$TEAM" BUNDLE="$BUNDLE_ID" CHANGES="$CHANGES" \
  /usr/bin/python3 -I -c '
import json, os, sys
e = os.environ; info = json.loads(e["INFO"])
json.dump({
    "format": 1, "app": "Amaranth", "bundleID": e["BUNDLE"], "version": info["version"], "build": info["build"],
    "commit": info["commit"], "commitSha": e["SHA"], "channel": info["channel"], "date": info["date"],
    "asset": e["ASSET"], "size": int(e["SIZE"]), "sha256": e["SUM"], "teamID": e["TEAM"],
    "minimumSystemVersion": info["minimumSystemVersion"], "schemaVersion": info["schemaVersion"],
    "changes": [l for l in e["CHANGES"].split("\n") if l],
}, sys.stdout, indent=2, ensure_ascii=False)
print()' > "$WORK/manifest.json"
echo "== manifest"; cat "$WORK/manifest.json"

# 5. Publish: the manifest always last, so a half-published build is never offered.
if [ $LOCAL = 1 ]; then
  mkdir -p "$DEST/$CHANNEL"
  STAGE="$DEST/$CHANNEL/.staging-$N"
  /bin/rm -rf "$STAGE"; mkdir -p "$STAGE"
  cp "$WORK/$ZIP_NAME" "$STAGE/"; cp "$WORK/manifest.json" "$STAGE/"
  mv "$STAGE" "$DEST/$CHANNEL/$N"
  echo "published locally: $DEST/$CHANNEL/$N ($ZIP_NAME, build $N, $CHANNEL)"
else
  TITLE="Amaranth $VERSION ($N)"; [ "$CHANNEL" = debug ] && TITLE="$TITLE Debug"
  NOTES=$(printf 'Build %s (%s, %s channel).\n\n%s\n' "$N" "$(git rev-parse --short=7 HEAD)" "$CHANNEL" "$(sed 's/^/- /' <<<"$CHANGES")")
  PRE=(--latest); [ "$CHANNEL" = debug ] && PRE=(--prerelease --latest=false)
  gh release create "$TAG" "$WORK/$ZIP_NAME" -R "$REPO" --target "$SHA" --title "$TITLE" --notes "$NOTES" "${PRE[@]}"
  if ! gh release upload "$TAG" "$WORK/manifest.json" -R "$REPO"; then
    fail "the zip is up but manifest.json failed to upload, so the app won't offer $TAG. Retry: gh release upload $TAG $WORK/manifest.json -R $REPO"
  fi
  echo "published: https://github.com/$REPO/releases/tag/$TAG"
fi
