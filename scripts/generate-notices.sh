#!/usr/bin/env bash
# Builds App/Resources/THIRD_PARTY_NOTICES.md from the pinned dependencies that ship inside the app or worker
# (FluidAudio + its bundled third-party code, llama.cpp) and the model pack's per-model licenses.
set -euo pipefail
cd "$(dirname "$0")/.."
SCRATCH=${SCRATCH:-.build-check}
FA="$SCRATCH/checkouts/FluidAudio"
OUT=App/Resources/THIRD_PARTY_NOTICES.md
test -f "$FA/LICENSE" || { echo "resolve packages first (swift package resolve --scratch-path $SCRATCH)"; exit 1; }
{
  echo "# Third-party notices"
  echo
  echo "Amaranth includes the following software. Models are downloaded separately at your request; their licenses are listed at the end and installed next to each model."
  echo
  echo "## FluidAudio 0.17.7 (Apache License 2.0)"
  echo "https://github.com/FluidInference/FluidAudio"
  echo
  echo '```'; cat "$FA/LICENSE"; echo '```'
  for f in vbx-LICENSE.md fastcluster-LICENSE.md NemoTextProcessing-LICENSE.md; do
    if [ -f "$FA/ThirdPartyLicenses/$f" ]; then
      echo; echo "### Included in FluidAudio: ${f%-LICENSE.md}"; echo; echo '```'; cat "$FA/ThirdPartyLicenses/$f"; echo '```'
    fi
  done
  echo
  echo "## llama.cpp b11669 (MIT License)"
  echo "https://github.com/ggml-org/llama.cpp"
  echo
  cat <<'MIT'
```
MIT License

Copyright (c) 2023-2024 The ggml authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
MIT
  echo
  echo "## Models (downloaded on request; not bundled)"
  echo
  python3 -I - App/Resources/default-model-pack.json <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["payload"]
for m in d["manifests"]:
    lic = m.get("license", {})
    print(f"- **{m['id']}** — {lic.get('identifier', '?')}: {lic.get('attribution', '')}")
PY
} > "$OUT"
echo "wrote $OUT ($(wc -l < "$OUT") lines)"
