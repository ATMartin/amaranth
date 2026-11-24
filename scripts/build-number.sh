#!/bin/sh
# Prints the build number of HEAD: the number in Config/build-number-base plus the git commit count. The base keeps
# numbers rising across a history that was restarted, so installed copies still see later builds as newer. Raise the
# base only together with such a restart, never lower it. Fails outside a git checkout.
set -eu
cd "$(dirname "$0")/.."
COUNT=$(git rev-list --count HEAD 2>/dev/null) || exit 1
BASE=$(tr -cd '0-9' < Config/build-number-base 2>/dev/null || true)
echo $(( ${BASE:-0} + COUNT ))
