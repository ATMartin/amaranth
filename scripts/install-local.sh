#!/usr/bin/env bash
# Build Amaranth and replace /Applications/Amaranth.app with it, then relaunch. Stopgap until Milestone Q's in-app
# "Check for Updates…". Refuses while a recording is in progress (the running app holds its meeting's journal.jsonl
# open from Record to Stop, paused included) and refuses a build signed by a different team than the installed one,
# since that would lose the microphone/system-audio grants.
#   scripts/install-local.sh [--debug] [--no-build] [--no-launch] [--force-identity]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=Release; BUILD=1; LAUNCH=1; FORCE_IDENTITY=0
for arg in "$@"; do
  case $arg in
    --debug) CONFIG=Debug ;;
    --no-build) BUILD=0 ;;
    --no-launch) LAUNCH=0 ;;
    --force-identity) FORCE_IDENTITY=1 ;;
    -h|--help) sed -n 2,6p "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done
DEST=/Applications/Amaranth.app
BUNDLE_ID=com.alexmartin.amaranth

# T70: build + verification (bundle, signature, build stamp) shared with build-release.sh and publish.sh.
ARGS=(); [ "$CONFIG" = Debug ] && ARGS+=(--debug); [ $BUILD = 0 ] && ARGS+=(--no-build)
APP=$(scripts/build-app.sh ${ARGS[@]+"${ARGS[@]}"} | tee /dev/stderr | sed -n 's/^APP=//p')
test -n "$APP"
COMMIT="build $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist") ($(/usr/libexec/PlistBuddy -c "Print :AmaranthCommit" "$APP/Contents/Info.plist"))"
team() { codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p'; }
NEW_TEAM=$(team "$APP")
echo "build: $CONFIG $COMMIT, team ${NEW_TEAM:-none}"
if [ -d "$DEST" ]; then
  OLD_TEAM=$(team "$DEST")
  if [ "$OLD_TEAM" != "$NEW_TEAM" ] && [ $FORCE_IDENTITY = 0 ]; then
    echo "installed app is signed by team '${OLD_TEAM:-none}', this build by '${NEW_TEAM:-none}'." >&2
    echo "Installing it would make macOS ask for microphone/system audio again. Re-run with --force-identity to do it anyway." >&2
    exit 1
  fi
fi

PID=$(pgrep -x Amaranth -u "$(id -u)" | head -1 || true)
WAS_RUNNING=0
if [ -n "$PID" ]; then
  WAS_RUNNING=1
  if lsof -p "$PID" -Fn 2>/dev/null | grep -q '/journal\.jsonl$'; then
    echo "Amaranth is recording. Stop the recording, then run this again. Nothing was changed." >&2; exit 1
  fi
  echo "== quit Amaranth"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 60); do kill -0 "$PID" 2>/dev/null || break; sleep 0.5; done
  if kill -0 "$PID" 2>/dev/null; then
    echo "Amaranth didn't quit within 30 s (a recording may have started; check its window). Nothing was changed." >&2
    exit 1
  fi
fi

echo "== install to $DEST"
STAGED=/Applications/.Amaranth.app.installing
OLD=/Applications/.Amaranth.app.previous
/bin/rm -rf "$STAGED" "$OLD"
ditto "$APP" "$STAGED"
codesign --verify --deep --strict "$STAGED" || { /bin/rm -rf "$STAGED"; echo "copy failed verification" >&2; exit 1; }
[ -d "$DEST" ] && mv "$DEST" "$OLD"
if ! mv "$STAGED" "$DEST"; then
  [ -d "$OLD" ] && mv "$OLD" "$DEST"
  echo "install failed; previous app restored" >&2; exit 1
fi
/bin/rm -rf "$OLD"
echo "installed: $CONFIG $COMMIT"

if [ $LAUNCH = 1 ]; then
  echo "== launch"; open "$DEST"
fi
