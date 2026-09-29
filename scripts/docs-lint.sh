#!/bin/bash
# Docs lint: two checks, both failing with file/line annotations.
#
# 1. Stale strings: the markdown docs must not mention strings that no
#    longer exist in the app. Every drift bug we fixed by hand (the
#    "Runtimes…" pane that never shipped, the lowercase support-directory
#    casing, a moved Forge.swift path) is a pattern below, with a note on
#    what replaced it — so the next rename only needs one new table row.
#    Scans every git-tracked .md file (README, docs/, website/), which by
#    construction excludes generated output like website/.vitepress/dist.
# 2. Orchard allowlist: Sources/ and docs/ must not grow new mentions of
#    the pre-rename name, in any file type. See the allowlist section
#    below for the files that carry the legacy strings on purpose.
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
    "orchard-container|the Linux-pool opt-in marker is "kinhin-container" (RuntimeRouting.swift)"
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

# ---------------------------------------------------------------------------
# Orchard allowlist. Sources/ and docs/ must not grow new mentions of the
# pre-rename name, in any file type. The files below carry the legacy
# strings on purpose — the migration has to know where the old data lives
# (support directory, Keychain service, LaunchAgent label, VM-name prefix,
# update-repo env var) and the config template greets upgraders. Anything
# else is drift: add a path here only for a deliberate compat surface.
# ---------------------------------------------------------------------------
orchardAllowlist=(
    "Sources/KinhinKit/Config/ConfigTemplate.swift"
    "Sources/KinhinKit/Core/Paths.swift"
    "Sources/KinhinKit/Core/TokenStore.swift"
    "Sources/KinhinKit/Fleet/Daemon.swift"
    "Sources/KinhinKit/Fleet/FleetReconcile.swift"
    "Sources/kinhin-app/UpdatePreferences.swift"
    "docs/compat-sunset.md"
)

orchardFiles=()
while IFS= read -r f; do
    orchardFiles+=("$f")
done < <(git ls-files Sources docs)
if [[ ${#orchardFiles[@]} -eq 0 ]]; then
    echo "docs lint: no Sources/ or docs/ files found for the orchard sweep" >&2
    exit 1
fi

for f in "${orchardFiles[@]}"; do
    allowed=false
    for exempt in "${orchardAllowlist[@]}"; do
        if [[ $f == "$exempt" ]]; then allowed=true; break; fi
    done
    if [[ $allowed == false ]]; then
        if hits=$(grep -inHI -- "orchard" "$f"); then
            status=1
            while IFS= read -r hit; do
                hitFile="${hit%%:*}"
                rest="${hit#*:}"
                hitLine="${rest%%:*}"
                echo "::error file=${hitFile},line=${hitLine}::pre-rename \"orchard\" outside the migration allowlist — add the path to orchardAllowlist in scripts/docs-lint.sh only for a deliberate compat surface"
                echo "  ${hit}"
            done <<< "$hits"
        fi
    fi
done

if [[ $status -eq 0 ]]; then
    echo "docs lint: clean (${#files[@]} md files, ${#patterns[@]} patterns; orchard sweep over ${#orchardFiles[@]} files with ${#orchardAllowlist[@]} allowlisted)"
fi
exit "$status"
