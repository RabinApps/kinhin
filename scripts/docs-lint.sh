#!/bin/bash
# Docs lint: stale strings, failing with file/line annotations.
#
# The markdown docs must not mention strings that no longer exist in the
# app. Every drift bug we fixed by hand (the "Runtimes…" pane that never
# shipped, the lowercase support-directory casing, a moved Forge.swift path,
# the removed top-level gitea:/forgejo:/repo: keys) is a pattern below, with
# a note on what replaced it — so the next rename only needs one new table
# row. Scans every git-tracked .md file (README, docs/, website/), which by
# construction excludes generated output like website/.vitepress/dist.
set -euo pipefail

cd "$(dirname "$0")/.."

# Each entry is "<pattern>|<why it is stale>", matched as an extended
# regex. The pattern ends at the first "|", so it cannot use regex alternation:
# write one entry per alternative. Keep the why human-readable: it is what the CI annotation says.
patterns=(
    "Application Support/kinhin|the support directory is \"Kinhin\" (capital K) — see Paths.swift"
    "Runtimes…|the \"Runtimes…\" pane never shipped; routing lives in Advanced → Routing"
    "Runtimes\.\.\.|same stale pane name with a plain-ASCII ellipsis"
    "Runtimes pane|the routing UI is the Advanced → Routing tab, not a \"Runtimes pane\""
    "KinhinKit/Forge\.swift|the forge contract moved to Sources/KinhinKit/Forges/Forge.swift"
    "orchard-container|the Linux-pool opt-in marker is "kinhin-container" (RuntimeRouting.swift)"
    "guide/migrating|the migrating-from-Orchard page was removed — upgrading is automatic, so the site has no migration guide"
    "Migrating from Orchard|the migrating-from-Orchard page was removed — upgrading is automatic, so the site has no migration guide"
    "compat-sunset|the Orchard compat-sunset plan is retired — the compat layer is gone"
    "Orchard compat|the Orchard compat-sunset plan is retired — the compat layer is gone"
    "\nrepo:|the top-level repo: key is gone — declare the forge as an accounts: entry"
    "\ngitea:|the top-level gitea: key is gone — declare the forge as an accounts: entry"
    "\nforgejo:|the top-level forgejo: key is gone — declare the forge as an accounts: entry"
    "[Oo]nly GitHub Actions with Tart|the beta supports GitHub, Gitea, Forgejo and GitLab CE; see docs/forges.md (What has been tested)"
    "[Oo]nly GitHub Actions has been tested|the beta supports GitHub, Gitea, Forgejo and GitLab CE; see docs/forges.md (What has been tested)"
    "[Oo]nly GitHub Actions has run|the beta supports GitHub, Gitea, Forgejo and GitLab CE; see docs/forges.md (What has been tested)"
    "all seven forges|three forges are planned, not supported; the beta supports four"
)

# macOS ships bash 3.2: no mapfile. A plain loop also survives spaces
# in filenames, unlike word-splitting.
files=()
while IFS= read -r file; do
    # Skip paths deleted in the worktree (git still tracks them).
    [[ -f $file ]] || continue
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
    set +e
    hits=$(grep -nE -- "$pattern" "${files[@]}")
    found=$?
    set -e
    if [[ $found -gt 1 ]]; then
        echo "::error file=scripts/docs-lint.sh::docs lint — invalid pattern: ${pattern}"
        status=1
        continue
    fi
    if [[ $found -eq 0 ]]; then
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
    echo "docs lint: clean (${#files[@]} md files, ${#patterns[@]} patterns)"
fi
exit "$status"
