#!/bin/sh
# T72: finishes an in-app update after Amaranth quits. Started by the app (UpdateInstaller) once the new build has been
# downloaded, checked against the manifest's sha256, unzipped and verified (signature, bundle ID, team ID, arm64,
# minimum macOS, build number). Waits for the app's process to exit, swaps the bundles on the same volume, restores the
# old bundle if the swap fails, deletes the old bundle after a successful swap (no rollbacks), and relaunches.
#   update-helper.sh <pid> <new.app> <dest.app> <new build> <old build> <staging dir> <log file>
# Test hooks: AMARANTH_HELPER_OPEN replaces /usr/bin/open; AMARANTH_HELPER_WAIT is the wait for the app in tenths of a
# second (default 600 = 60 s); AMARANTH_HELPER_FAIL_SWAP=1 makes the second move fail.
PID=$1 NEW=$2 DEST=$3 BUILD=$4 FROM=$5 STAGING=$6 LOG=$7
OPEN=${AMARANTH_HELPER_OPEN:-/usr/bin/open}
WAIT=${AMARANTH_HELPER_WAIT:-600}
FAIL_SWAP=${AMARANTH_HELPER_FAIL_SWAP:-0}
# `open` hands this environment to the relaunched app, which would pass it to its next helper: drop the test hooks.
unset AMARANTH_HELPER_OPEN AMARANTH_HELPER_WAIT AMARANTH_HELPER_FAIL_SWAP
mkdir -p "$(dirname "$LOG")" 2>/dev/null
exec >>"$LOG" 2>&1
say() { echo "$(date '+%Y-%m-%d %H:%M:%S') update $FROM → $BUILD: $*"; }

say "waiting for Amaranth (pid $PID) to quit"
i=0
while kill -0 "$PID" 2>/dev/null; do
  i=$((i + 1))
  if [ "$i" -gt "$WAIT" ]; then
    say "Amaranth didn't quit; nothing was changed"
    rm -rf "$STAGING"
    exit 1
  fi
  sleep 0.1
done

OLD="$STAGING/previous.app"
if [ ! -d "$NEW" ]; then
  say "the new build is missing from $NEW; nothing was changed"
  rm -rf "$STAGING"
  "$OPEN" "$DEST" --args --update-failed "$BUILD"
  exit 1
fi
if ! mv "$DEST" "$OLD"; then
  say "couldn't move the installed app aside; nothing was changed"
  rm -rf "$STAGING"
  "$OPEN" "$DEST" --args --update-failed "$BUILD"
  exit 1
fi
if [ "$FAIL_SWAP" = 1 ] || ! mv "$NEW" "$DEST"; then
  say "couldn't move the new build into place; restoring the previous app"
  if [ -e "$DEST" ]; then rm -rf "$DEST"; fi
  if mv "$OLD" "$DEST"; then say "previous app restored"; else say "RESTORE FAILED: the previous app is at $OLD"; exit 2; fi
  rm -rf "$STAGING"
  "$OPEN" "$DEST" --args --update-failed "$BUILD"
  exit 1
fi
rm -rf "$STAGING"
say "installed; relaunching"
"$OPEN" "$DEST" --args --updated-from "$FROM"
exit 0
