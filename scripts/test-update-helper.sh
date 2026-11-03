#!/usr/bin/env bash
# T72: exercises App/Resources/update-helper.sh against throwaway bundles (no app, no /Applications): a good swap, a
# failed swap (the old app must come back), a missing new build, and an app that never quits (nothing may change).
set -euo pipefail
cd "$(dirname "$0")/.."
HELPER=App/Resources/update-helper.sh
T=$(mktemp -d -t amaranth-helper)
trap '/bin/rm -rf "$T"' EXIT
export AMARANTH_HELPER_OPEN="$T/open"
printf '#!/bin/sh\necho "$@" >> "%s/opened"\nenv | grep "^AMARANTH_HELPER_" >> "%s/opened-env"\n' "$T" "$T" > "$T/open"; chmod +x "$T/open"
fail() { echo "FAIL: $*" >&2; exit 1; }
setup() {   # fresh dest (old) + staged new bundle
  /bin/rm -rf "$T/Applications" "$T/opened" "$T/opened-env"; mkdir -p "$T/Applications/.update/unzipped/Amaranth.app" "$T/Applications/Amaranth.app"
  echo old > "$T/Applications/Amaranth.app/marker"; echo new > "$T/Applications/.update/unzipped/Amaranth.app/marker"
}
dead_pid() { sh -c 'exit 0' & local p=$!; wait $p; echo $p; }
run() { sh "$HELPER" "$1" "$T/Applications/.update/unzipped/Amaranth.app" "$T/Applications/Amaranth.app" 125 122 "$T/Applications/.update" "$T/log" || echo "exit $?" > "$T/exit"; }

setup; /bin/rm -f "$T/exit"; run "$(dead_pid)"
[ "$(cat "$T/Applications/Amaranth.app/marker")" = new ] || fail "good swap: new build not installed"
[ ! -e "$T/Applications/.update" ] || fail "good swap: staging (and the previous app) not deleted"
grep -q -- "--updated-from 122" "$T/opened" || fail "good swap: not relaunched with --updated-from"
[ ! -e "$T/exit" ] || fail "good swap: non-zero exit"
echo "ok: good swap installs, deletes the previous app, relaunches with --updated-from"

setup; /bin/rm -f "$T/exit"; AMARANTH_HELPER_FAIL_SWAP=1 run "$(dead_pid)"
[ "$(cat "$T/Applications/Amaranth.app/marker")" = old ] || fail "failed swap: old app not restored"
grep -q -- "--update-failed 125" "$T/opened" || fail "failed swap: not relaunched with --update-failed"
[ ! -s "$T/opened-env" ] || fail "failed swap: the relaunched app inherits the helper's test hooks: $(cat "$T/opened-env")"
echo "ok: failed swap restores the old app and relaunches it with --update-failed"

setup; /bin/rm -rf "$T/Applications/.update/unzipped/Amaranth.app" "$T/exit"; run "$(dead_pid)"
[ "$(cat "$T/Applications/Amaranth.app/marker")" = old ] || fail "missing build: old app changed"
grep -q -- "--update-failed 125" "$T/opened" || fail "missing build: not relaunched with --update-failed"
echo "ok: a missing new build changes nothing"

setup; /bin/rm -f "$T/exit"; sleep 30 & ALIVE=$!
AMARANTH_HELPER_WAIT=5 run "$ALIVE"; kill $ALIVE 2>/dev/null || true
[ "$(cat "$T/Applications/Amaranth.app/marker")" = old ] || fail "app still running: old app changed"
[ ! -e "$T/opened" ] || fail "app still running: something was launched"
[ ! -e "$T/Applications/.update" ] || fail "app still running: staging left behind"
echo "ok: an app that doesn't quit changes nothing"
echo "update-helper: all checks passed"
