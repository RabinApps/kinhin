#!/bin/bash
# CHANGELOG.md workflow. Entries for user-visible changes accumulate under "## Unreleased" between releases.
# At release time `promote` turns that section into "## v<version>" and starts a fresh, empty Unreleased.
#
#   scripts/changelog.sh check               validate the heading structure (check.sh and CI run this)
#   scripts/changelog.sh promote <version>   rename Unreleased to v<version>; prints the next steps
#
# promote never commits. It refuses an empty Unreleased section and a version heading that already exists.
# CHANGELOG=<path> points both commands at another file (used by the tests).
set -euo pipefail
cd "$(dirname "$0")/.."

FILE="${CHANGELOG:-CHANGELOG.md}"
MARKER='<!-- changelog: entries for the next release go here -->'

usage() {
    echo "usage: scripts/changelog.sh check | promote <version>" >&2
    exit 2
}

check() {
    local problems
    problems="$(awk '
        /^## / {
            if (++n == 1 && $0 != "## Unreleased") print NR": the first section must be \"## Unreleased\""
            if ($0 != "## Unreleased" && $0 !~ /^## v[0-9]+\.[0-9]+\.[0-9]+(-beta-[0-9]+)?$/) \
                print NR": heading must be \"## Unreleased\" or \"## v<version>\": "$0
            if (seen[$0]++) print NR": duplicate heading: "$0
        }
        END { if (!seen["## Unreleased"]) print "missing \"## Unreleased\" section" }
    ' "$FILE")"
    if [[ -n "$problems" ]]; then
        while IFS= read -r problem; do
            echo "::error file=$FILE::changelog: $problem" >&2
        done <<<"$problems"
        echo "changelog: $FILE is malformed" >&2
        return 1
    fi
    echo "changelog: $FILE structure ok"
}

promote() {
    local version="$1"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-beta-[0-9]+)?$ ]] || {
        echo "FATAL: version '$version' is not MAJOR.MINOR.PATCH[-beta-N]" >&2
        exit 1
    }
    check
    if grep -qxF "## v$version" "$FILE"; then
        echo "FATAL: $FILE already has '## v$version'; nothing to promote." >&2
        exit 1
    fi

    # Count the real entries in Unreleased: non-blank lines other than the marker.
    local entries
    entries="$(awk -v marker="$MARKER" '
        /^## / { if (in_section) exit; in_section = ($0 == "## Unreleased"); next }
        in_section && NF && $0 != marker { count++ }
        END { print count + 0 }
    ' "$FILE")"
    if [[ "$entries" -eq 0 ]]; then
        echo "FATAL: the Unreleased section in $FILE has no entries; there is nothing to release." >&2
        exit 1
    fi

    local tmp
    tmp="$(mktemp)"
    awk -v heading="## v$version" -v marker="$MARKER" '
        !promoted && $0 == "## Unreleased" {
            print "## Unreleased"; print ""; print marker; print ""; print heading; print ""
            promoted = 1; next
        }
        promoted && $0 == marker { next }
        promoted && !body && NF == 0 { next }
        promoted && NF { body = 1 }
        { print }
    ' "$FILE" >"$tmp"
    mv "$tmp" "$FILE"
    check

    echo ""
    echo "Promoted Unreleased to '## v$version' ($entries entry lines). Next:"
    echo "  1. Set Sources/KinhinKit/Core/Version.swift to \"$version\""
    echo "  2. Commit both changes together, then scripts/release.sh $version"
}

case "${1:-}" in
    check) check ;;
    promote)
        [[ $# -eq 2 ]] || usage
        promote "$2"
        ;;
    *) usage ;;
esac
