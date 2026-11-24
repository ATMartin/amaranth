#!/usr/bin/env bash
# T36 density check on a real meeting without touching the library: copies the database with sqlite's backup command
# into a temporary data directory, renders the meeting at 1280×826 and prints the visible transcript rows.
# Screenshots hold real meeting text: they go to Tests/Data/Recordings/ui-density/ (gitignored, never committed).
# Usage: scripts/ui-density.sh "<meeting title>" <label> [smaller|default|larger] [app path]
set -euo pipefail
cd "$(dirname "$0")/.."
TITLE=$1; LABEL=$2; SIZE=${3:-default}
APP=${4:-build/DerivedData/Build/Products/Debug/Amaranth.app}
SRC="$HOME/Library/Application Support/Amaranth/amaranth.sqlite"
ID=$(sqlite3 -readonly "$SRC" "select id from meetings where title = '${TITLE//\'/\'\'}' and deleted_at is null limit 1")
[ -n "$ID" ] || { echo "no meeting titled '$TITLE'" >&2; exit 1; }
COPY=$(mktemp -d)
trap '/bin/rm -rf "$COPY"' EXIT
sqlite3 -readonly "$SRC" ".backup '$COPY/amaranth.sqlite'"
OUT=Tests/Data/Recordings/ui-density
mkdir -p "$OUT"
"$APP/Contents/MacOS/Amaranth" --self-test ui-density --store-root "$COPY" --meeting "$ID" --png-dir "$OUT" \
  --label "$LABEL" --text-size "$SIZE" 2>/dev/null | grep '^{'
