#!/usr/bin/env bash
# T72: proves the in-app installer rejects bad builds before replacing anything. From one good build published with
# `scripts/publish.sh --local-only` (its <channel>/<N> folder), crafts bad ones in a temporary updates folder and runs
# the app's `--self-test update-verify` against each (download + checks into a temp folder; never swaps):
#   checksum mismatch, a truncated zip, a build whose number differs from its manifest, a copy re-signed ad hoc (no team).
#   scripts/test-update-verify.sh <app binary> <good build folder>
set -euo pipefail
APPBIN=$1; GOOD=$2
T=$(mktemp -d -t amaranth-verify); trap '/bin/rm -rf "$T"' EXIT
M="$GOOD/manifest.json"; ZIP="$GOOD/$(plutil -extract asset raw -o - "$M")"
CHANNEL=$(plutil -extract channel raw -o - "$M"); N=$(plutil -extract build raw -o - "$M")
DBG=(); [ "$CHANNEL" = debug ] && DBG=(--include-debug)
edit() {   # <manifest in> <manifest out> <python statements on m>
  /usr/bin/python3 -I -c "import json,sys; m=json.load(open(sys.argv[1])); $3; json.dump(m, open(sys.argv[2],'w'))" "$1" "$2"
}
case_dir() { local d="$T/$1/$CHANNEL/$N"; mkdir -p "$d"; echo "$d"; }
pass=0
expect() {   # <case folder name> <reason substring>
  local out; out=$("$APPBIN" --self-test update-verify --running-build $((N - 1)) ${DBG[@]+"${DBG[@]}"} --any-candidate --expect-reject --update-folder "$T/$1" 2>/dev/null || true)
  if grep -q '"result":"pass"' <<<"$out" && grep -q "$2" <<<"$out"; then echo "ok: $1 rejected ($(sed -n 's/.*"reason":"\([^"]*\)".*/\1/p' <<<"$out" | head -1))"
  else echo "FAIL: $1"; echo "$out"; pass=1; fi
}

d=$(case_dir checksum); cp "$ZIP" "$d/"; edit "$M" "$d/manifest.json" "m['sha256']='0'*64"
expect checksum checksum

d=$(case_dir truncated); head -c $(( $(stat -f %z "$ZIP") / 2 )) "$ZIP" > "$d/$(basename "$ZIP")"; cp "$M" "$d/manifest.json"
expect truncated incomplete

d="$T/build-number/$CHANNEL/$((N + 1000))"; mkdir -p "$d"; cp "$ZIP" "$d/"
edit "$M" "$d/manifest.json" "m['build']=$((N + 1000))"
expect build-number "release is build"

d=$(case_dir other-team); mkdir -p "$T/resign"; ditto -x -k "$ZIP" "$T/resign"
codesign --force --deep --sign - "$T/resign/Amaranth.app" 2>/dev/null
NAME=$(basename "$ZIP"); ditto -c -k --keepParent "$T/resign/Amaranth.app" "$d/$NAME"
SUM=$(shasum -a 256 "$d/$NAME" | awk '{print $1}'); SIZE=$(stat -f %z "$d/$NAME")
edit "$M" "$d/manifest.json" "m['sha256']='$SUM'; m['size']=$SIZE"
expect other-team "not this app's team"

d=$(case_dir good); cp "$ZIP" "$d/"; cp "$M" "$d/manifest.json"
out=$("$APPBIN" --self-test update-verify --running-build $((N - 1)) ${DBG[@]+"${DBG[@]}"} --update-folder "$T/good" 2>/dev/null || true)
if grep -q '"step":"verified"' <<<"$out"; then
  echo "ok: the untouched build verifies"; else echo "FAIL: the untouched build didn't verify"; pass=1; fi
[ $pass = 0 ] && echo "update-verify: all checks passed"
exit $pass
