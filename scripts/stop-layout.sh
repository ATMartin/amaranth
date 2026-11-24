#!/usr/bin/env bash
# T67: the window after Stop, in the real Debug app (no permissions needed). Runs every variant of the check in
# App/Launch/StopLayoutProbe.swift: 1100 and 900 pt, sidebar open and closed, with and without the calendar prompt,
# each at the screen's full visible height. Window captures land next to the log. Exits non-zero if any variant fails.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=${APP:-build/DerivedData/Build/Products/Debug/Amaranth.app}
OUT=${1:-${TMPDIR:-/tmp}/amaranth-stop-layout}
mkdir -p "$OUT"
# The check moves and resizes the real "main" window, which macOS saves: put the app's preferences back afterwards.
DOMAIN=com.alexmartin.amaranth
if defaults export "$DOMAIN" "$OUT/defaults-before.plist" 2>/dev/null; then
  trap 'defaults import "$DOMAIN" "$OUT/defaults-before.plist"' EXIT
else
  trap 'defaults delete "$DOMAIN" 2>/dev/null || true' EXIT   # there were none
fi
fail=0
for width in "" --narrow; do
  for sidebar in "" --sidebar-closed; do
    for prompt in "" --prompt; do
      w=1100; [ -n "$width" ] && w=900; name="w$w${sidebar}${prompt}"; name=${name//--/-}
      mkdir -p "$OUT/$name"; /bin/rm -f "$OUT/$name"/*
      open -W -n "$APP" --args --debug-stop-layout "$OUT/$name/out.jsonl" $width $sidebar $prompt
      result=$(grep '"result"' "$OUT/$name/out.jsonl" || echo '{"result":"missing"}')
      echo "$name $result"
      grep -q '"result":"pass"' <<<"$result" || fail=1
    done
  done
done
exit $fail
