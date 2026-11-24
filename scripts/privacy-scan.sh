#!/usr/bin/env bash
# Keeps private material out of the repository. Checks tracked files (or, with --staged, what is about to be committed)
# for:
#   - terms from a private list kept outside the repository: one per line, case-insensitive, # for comments, in
#     $AMARANTH_PRIVATE_TERMS or ~/.config/amaranth/private-terms.txt (real names, clients, meeting titles);
#   - paths that only ever hold real-library material (docs/, Benchmarks/Results/, Benchmarks/Ask/);
#   - secrets, with gitleaks when it is installed.
# Without a private list the term check is skipped with a note. Install as a commit hook with:
#   git config core.hooksPath .githooks
#   scripts/privacy-scan.sh [--staged]
#   scripts/privacy-scan.sh --message FILE    (commit-msg hook: checks the commit message for private terms)
set -euo pipefail
cd "$(dirname "$0")/.."
STAGED=0; [ "${1:-}" = --staged ] && STAGED=1
TERMS=${AMARANTH_PRIVATE_TERMS:-$HOME/.config/amaranth/private-terms.txt}
if [ "${1:-}" = --message ]; then
  [ -f "$TERMS" ] || exit 0
  if grep -v '^#' "$2" | grep -q -i -F -f <(tr -d '\r' < "$TERMS" | grep -v -E '^[[:space:]]*(#|$)'); then
    echo "privacy-scan: the commit message contains a private term" >&2; exit 1
  fi
  exit 0
fi
bad=0

if [ $STAGED = 1 ]; then FILES=$(git diff --cached --name-only --diff-filter=ACMR); else FILES=$(git ls-files); fi
[ -n "$FILES" ] || { echo "privacy-scan: nothing to check"; exit 0; }

blocked=$(grep -E '^(docs|Benchmarks/Results|Benchmarks/Ask)/' <<<"$FILES" || true)
if [ -n "$blocked" ]; then
  echo "privacy-scan: these paths must stay out of the repository:" >&2; sed 's/^/  /' <<<"$blocked" >&2; bad=1
fi

if [ -f "$TERMS" ]; then
  PATTERNS=$(tr -d '\r' < "$TERMS" | grep -v -E '^[[:space:]]*(#|$)' || true)
  if [ -n "$PATTERNS" ]; then
    # File names only: the terms themselves are never printed. git grep reads whole files (no early-exit pipes).
    if [ $STAGED = 1 ]; then
      hits=$(tr '\n' '\0' <<<"$FILES" | xargs -0 git grep --cached -l -i -I -F -f <(echo "$PATTERNS") -- 2>/dev/null || true)
    else
      hits=$(git grep -l -i -I -F -f <(echo "$PATTERNS") -- . 2>/dev/null || true)
    fi
    named=$(grep -i -F -f <(echo "$PATTERNS") <<<"$FILES" || true)
    if [ -n "$hits$named" ]; then
      echo "privacy-scan: private terms found in (contents or file name):" >&2
      printf '%s\n' "$hits" "$named" | grep -v '^$' | sort -u | sed 's/^/  /' >&2; bad=1
    fi
  fi
else
  echo "privacy-scan: no private term list at $TERMS (term check skipped)"
fi

if command -v gitleaks >/dev/null 2>&1 && gitleaks version >/dev/null 2>&1; then
  if [ $STAGED = 1 ]; then
    gitleaks protect --staged --no-banner --redact -c .gitleaks.toml >/dev/null 2>&1 || {
      echo "privacy-scan: gitleaks found a possible secret in the staged changes (gitleaks protect --staged --redact -c .gitleaks.toml -v)" >&2; bad=1; }
  else
    # A copy of the tracked files only, so ignored local folders aren't scanned.
    COPY=$(/usr/bin/mktemp -d); trap '/bin/rm -rf "$COPY"' EXIT
    git ls-files -z | /usr/bin/cpio -0 -pdm "$COPY" 2>/dev/null
    gitleaks detect --no-git --no-banner --redact -c .gitleaks.toml --source "$COPY" >/dev/null 2>&1 || {
      echo "privacy-scan: gitleaks found a possible secret in tracked files (rerun gitleaks with -v to see where)" >&2; bad=1; }
  fi
else
  echo "privacy-scan: gitleaks isn't available (secret check skipped)"
fi

[ $bad = 0 ] && echo "privacy-scan: clean"
exit $bad
