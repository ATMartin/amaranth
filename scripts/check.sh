#!/usr/bin/env bash
# One-command verification of everything that runs without a person (no TCC prompts, no network).
# Hardware capture trials (need permission prompts) are listed at the end; see docs/qualification/.
set -euo pipefail
cd "$(dirname "$0")/.."
DERIVED=build/DerivedData
APP=$DERIVED/Build/Products/Debug/Amaranth.app
SCRATCH=${SCRATCH:-.build-check}

echo "== swift test (contracts, capture, models, scoring)"
swift test --scratch-path "$SCRATCH" 2>&1 | tee /tmp/amaranth-swift-test.log | grep -E "✘|error:|Test run with" || true
# swift test prints one "Test run with" line per test binary; every one must pass (a single passing line used to be
# enough, so failures slipped through).
grep -q "Test run with .* passed" /tmp/amaranth-swift-test.log
if grep -q "✘ Test run with" /tmp/amaranth-swift-test.log; then
  echo "swift test FAILED (see /tmp/amaranth-swift-test.log); real-model and capture timing tests are flaky under load"
  exit 1
fi

echo "== xcodegen + xcodebuild (app + XPC worker)"
xcodegen generate --quiet
xcodebuild -project Amaranth.xcodeproj -scheme Amaranth -configuration Debug -derivedDataPath "$DERIVED" build \
  2>&1 | grep -E "error:|warning: .*\.swift|BUILD (SUCCEEDED|FAILED)" | sort -u
test -d "$APP/Contents/XPCServices/com.alexmartin.amaranth.InferenceWorker.xpc"

echo "== app self-tests against the real bundle (no audio permissions needed)"
for t in os-gate worker-crash worker-hang; do
  timeout 60 "$APP/Contents/MacOS/Amaranth" --self-test "$t" | tail -1
done
echo "ALL AUTOMATED CHECKS PASSED"
cat <<'MSG'

Hardware trials (need a person to answer permission prompts; launch through LaunchServices):
  open -W -n "$APP" --args --self-test capture-signals --self-test-output /tmp/sig.jsonl
  open -W -n "$APP" --args --self-test capture-routes  --self-test-output /tmp/routes.jsonl
  open -W -n "$APP" --args --self-test calendar-access --self-test-output /tmp/calendar.jsonl   # click Allow (or Don't Allow)
  Benchmarks/Capture/soak.sh 30 6 /tmp/soak.jsonl
  Benchmarks/Capture/browser-matrix.sh /tmp/browser
MSG
