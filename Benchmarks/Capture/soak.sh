#!/usr/bin/env bash
# Loaded capture soak (T03: 30 min, T05/T12: 2 h / 4 h). Runs the app's capture-soak self-test via LaunchServices
# (so TCC attributes permissions to Amaranth) while N busy-loop processes simulate CPU load.
# Usage: Benchmarks/Capture/soak.sh <minutes> <load-procs> <output.jsonl> [app-path]
set -euo pipefail
MIN=${1:-30}; LOAD=${2:-6}; OUT=${3:?output path}; APP=${4:-build/DerivedData/Build/Products/Debug/Amaranth.app}
pids=()
cleanup() { for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT
for _ in $(seq 1 "$LOAD"); do yes > /dev/null & pids+=($!); done
echo "{\"step\":\"load\",\"busyProcesses\":$LOAD,\"host\":\"$(sysctl -n machdep.cpu.brand_string)\",\"os\":\"$(sw_vers -productVersion)\"}" > "$OUT.meta"
open -W -n "$APP" --args --self-test capture-soak --minutes "$MIN" --self-test-output "$OUT"
tail -1 "$OUT"
