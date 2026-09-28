#!/bin/bash
# Docs lint: fails when the markdown docs mention strings that no longer
# exist in the app. Every drift bug we fixed by hand (the "Runtimes…" pane
# that never shipped, the lowercase support-directory casing, a moved
# Forge.swift path) is a pattern here, with a note on what replaced it —
# so the next rename only needs one new table row.
#
#   bash scripts/docs-lint.sh        # exit 0 clean, exit 1 with annotations
#
# Scans every git-tracked .md file (README, docs/, website/), which by
# construction excludes generated output like website/.vitepress/dist.
set -euo pipefail

cd "$(dirname "$0")/.."

# Each entry is "<pattern>|<why it is stale>", matched as an extended
# regex. Keep the why human-readable: it is what the CI annotation says.
patterns=(
    "Application Support/kinhin|the support directory is \"Kinhin\" (capital K) — see Paths.swift"
    "Runtimes…|the \"Runtimes…\" pane never shipped; routing lives in Advanced → Routing"
    "Runtimes\.\.\.|same stale pane name with a plain-ASCII ellipsis"
    "Runtimes pane|the routing UI is the Advanced → Routing tab, not a \"Runtimes pane\""
    "KinhinKit/Forge\.swift|the forge contract moved to Sources/KinhinKit/Forges/Forge.swift"
)

# macOS ships bash 3.2: no mapfile. A plain loop also survives spaces
# in filenames, unlike word-splitting.
files=()
while IFS= read -r file; do
    files+=("$file")
done < <(git ls-files '*.md')
if [[ ${#files[@]} -eq 0 ]]; then
    echo "docs lint: no markdown files found" >&2
    exit 1
fi

status=0
for entry in "${patterns[@]}"; do
    pattern="${entry%%|*}"
    reason="${entry#*|}"
    if hits=$(grep -nE -- "$pattern" "${files[@]}"); then
        status=1
        while IFS= read -r hit; do
            file="${hit%%:*}"
            rest="${hit#*:}"
            line="${rest%%:*}"
            echo "::error file=${file},line=${line}::stale docs string — ${reason}"
            echo "  ${hit}"
        done <<< "$hits"
        echo "  why: ${reason}"
    fi
done

if [[ $status -eq 0 ]]; then
    echo "docs lint: clean (${#files[@]} files, ${#patterns[@]} patterns)"
fi
exit "$status"
