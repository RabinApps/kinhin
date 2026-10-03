#!/bin/bash
# docs-refs — keep the `File.swift:<line>` citations in docs/forges/*.md true.
#
# The forge reference pages cite exact source lines, which rot whenever the
# cited code moves. Each citation is content-anchored in scripts/docs-refs.lock
# (one entry per cited line number: <markdown file> <Base.swift> <line> <the
# line's trimmed content>). sync re-finds every anchored line in the source and
# rewrites the numbers; check verifies them and fails docs-lint on drift.
#
#   scripts/docs-refs.sh sync     # re-locate cited lines, rewrite docs + lock
#   scripts/docs-refs.sh check    # verify only (docs-lint runs this)
#
# Bootstrap: delete scripts/docs-refs.lock and run sync. Scope is docs/forges/
# on purpose: docs/plans/ are point-in-time proposals whose references are
# allowed to age.
set -euo pipefail
cd "$(dirname "$0")/.."

LOCK="scripts/docs-refs.lock"
mode="${1:-check}"
[[ $mode == check || $mode == sync ]] || { echo "usage: scripts/docs-refs.sh check|sync" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Resolve every cited basename to its unique source file.
basenames=$(grep -hoE '[A-Za-z0-9+]+\.swift:[0-9][0-9,-]*' docs/forges/*.md 2>/dev/null |
    sed -E 's/:.*//' | sort -u || true)
: > "$TMP/paths"
for base in $basenames; do
    hits=$(find Sources Tests -name "$base" | sort)
    count=$(printf '%s\n' "$hits" | grep -c . || true)
    if [[ $count -ne 1 ]]; then
        echo "docs-refs: $base resolves to $count source files (need exactly one)" >&2
        exit 1
    fi
    printf '%s\034%s\n' "$base" "$hits" >> "$TMP/paths"
done

havelock=0
[[ -f $LOCK ]] && havelock=1

status=0
if ! awk -v mode="$mode" -v lock="$LOCK" -v havelock="$havelock" -v paths="$TMP/paths" -v tmp="$TMP" \
    -f scripts/docs-refs.awk docs/forges/*.md; then
    status=1
fi

if [[ $mode == sync ]]; then
    if [[ -f $TMP/lock.new ]]; then
        mv "$TMP/lock.new" "$LOCK"
    else
        : > "$LOCK" # no citations found
    fi
    if [[ -f $TMP/rewritten.map ]]; then
        while IFS=$'\t' read -r md rewritten; do
            [[ -n $md ]] || continue
            mv "$rewritten" "$md"
            echo "docs-refs: updated $md"
        done < "$TMP/rewritten.map"
    fi
fi

exit "$status"
