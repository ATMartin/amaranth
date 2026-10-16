#!/usr/bin/env bash
# Browser playback capture trials (T03). Each browser runs in a throwaway profile with autoplay permitted,
# plays Benchmarks/Capture/tone.html (1234 Hz), while Amaranth records and checks the system track.
# Usage: Benchmarks/Capture/browser-matrix.sh <out-dir> [app-path]
set -uo pipefail
OUT=${1:?out dir}; APP=${2:-build/DerivedData/Build/Products/Debug/Amaranth.app}
mkdir -p "$OUT"; PAGE="file://$(cd "$(dirname "$0")" && pwd)/tone.html"
trial() { # name launch-command...
  local name=$1; shift
  rm -f "$OUT/$name.jsonl"
  open -W -n "$APP" --args --self-test capture-tone --hz 1234 --seconds 10 --label "$name" --self-test-output "$OUT/$name.jsonl" &
  local ap=$!
  # Start the player once recording has begun (permission prompts can delay it).
  for _ in $(seq 1 600); do grep -q '"step":"recording"' "$OUT/$name.jsonl" 2>/dev/null && break; sleep 0.1; done
  sleep 1
  "$@" >/dev/null 2>&1 & local bp=$!
  wait $ap
  pkill -P $bp 2>/dev/null; kill $bp 2>/dev/null; wait $bp 2>/dev/null
  local v; v=$(defaults read "$BROWSER_APP/Contents/Info" CFBundleShortVersionString 2>/dev/null)
  echo "$name ($v): $(grep -o '"windowsWithTone":"[^"]*"' "$OUT/$name.jsonl") $(grep -o '"maxLevelDB":"[^"]*"' "$OUT/$name.jsonl") $(tail -1 "$OUT/$name.jsonl")"
}
TMP=$(mktemp -d)
BROWSER_APP="/Applications/Google Chrome.app" trial chrome \
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --user-data-dir="$TMP/chrome" --no-first-run \
  --no-default-browser-check --autoplay-policy=no-user-gesture-required "$PAGE"
mkdir -p "$TMP/ff"; echo 'user_pref("media.autoplay.default", 0); user_pref("browser.shell.checkDefaultBrowser", false);' > "$TMP/ff/user.js"
BROWSER_APP="/Applications/Firefox.app" trial firefox \
  /Applications/Firefox.app/Contents/MacOS/firefox -no-remote -profile "$TMP/ff" "$PAGE"
rm -rf "$TMP"
