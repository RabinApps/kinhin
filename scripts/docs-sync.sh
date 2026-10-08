#!/bin/bash
# Docs sync: regenerate the doc blocks that are derived from code.
#
# Some documented facts live in Swift and drift when hand-copied: the forge
# IDs, the daemon RPC methods, the CLI exit codes, and the `kinhin help`
# screen. Each one is a generator below, writing between a pair of markers in
# a markdown file:
#
#     <!-- docs-sync:begin forges -->
#     ...generated, do not edit by hand...
#     <!-- docs-sync:end forges -->
#
# Everything outside the markers stays hand-written. The generators read the
# Swift sources with grep/sed/awk (no toolchain), so this runs on the Linux
# docs-lint CI job and stays bash 3.2 compatible for macOS.
#
#   scripts/docs-sync.sh            rewrite every stale block in place
#   scripts/docs-sync.sh --check    change nothing; diff + exit 1 if stale
#   scripts/docs-sync.sh --list     print each block and its owning file
#
# To add a block: write a `gen_<name>` function that prints markdown, add a
# `<name>|<file>` row to `blocks`, and put the marker pair in that file. See
# "Generated doc blocks" in CONTRIBUTING.md.
set -euo pipefail

cd "$(dirname "$0")/.."

mode=write
case "${1:-}" in
    "") ;;
    --check) mode=check ;;
    --list) mode=list ;;
    *)
        echo "usage: $0 [--check|--list]" >&2
        exit 2
        ;;
esac

# Each row is "<block name>|<markdown file that holds it>".
blocks=(
    "forges|docs/forges/README.md"
    "rpc-methods|docs/architecture.md"
    "exit-codes|website/cli/commands.md"
    "cli-help|website/cli/commands.md"
    "maturity|docs/app.md"
)

# MARK: - Generators

# `ForgeID` raw values: the IDs valid for `forge:` in the config and in the
# `auth add --<forge>` flags.
gen_forges() {
    local ids
    ids=$(sed -n '/enum ForgeID/,/^}/p' Sources/KinhinKit/Forges/Forge/Forge.swift |
        sed -nE 's/^[[:space:]]*case ([a-z]+)[[:space:]]*$/`\1`/p' | paste -sd, - | sed 's/,/, /g')
    echo "Forge IDs recognized by the config and the CLI (\`ForgeID\`): $ids."
}

# `RPCMethod` raw values, with the case's doc comment when it has one.
gen_rpc-methods() {
    echo "| Method | Notes |"
    echo "|---|---|"
    sed -n '/enum RPCMethod/,/^    var mutatesFleet/p' Sources/KinhinKit/Fleet/RPC/RPC.swift | awk '
        /^[[:space:]]*\/\/\// { sub(/^[[:space:]]*\/\/\/ ?/, ""); note = note (note == "" ? "" : " ") $0; next }
        /^[[:space:]]*case / {
            name = $2
            if ($0 ~ /= "/) { raw = $0; sub(/^[^"]*"/, "", raw); sub(/".*$/, "", raw); name = raw }
            printf "| `%s` | %s |\n", name, (note == "" ? "—" : note)
            note = ""; next
        }
        { note = "" }'
}

# `CLIExit` codes. The meanings are the one hand-kept piece; a new case still
# appears (by name) until someone adds its meaning here.
gen_exit-codes() {
    echo "| Code | Meaning |"
    echo "|---|---|"
    sed -n '/enum CLIExit/,/^    init/p' Sources/kinhin/Commands/CLIExit.swift |
        sed -nE 's/^[[:space:]]*case ([a-z]+) = ([0-9]+)$/\2 \1/p' | while read -r code name; do
        case "$name" in
            general) meaning="Needs attention (not healthy), or anything unclassified" ;;
            usage) meaning="Bad command line" ;;
            config) meaning="Invalid or unreadable config" ;;
            runtime) meaning="Runtime or engine failure" ;;
            auth) meaning="Missing or rejected token" ;;
            cancelled) meaning="Cancelled (Ctrl-C); in-progress work was cleaned up" ;;
            *) meaning="$name" ;;
        esac
        echo "| $code | $meaning |"
    done
}

# The `kinhin help` screen as a fenced block. The screen is generated from
# the Swift command catalog, which this script cannot run (no toolchain on the
# docs job), so it copies the checked-in golden file; `HelpRendererTests`
# fails when that file differs from the real output, naming the command that
# regenerates it.
gen_cli-help() {
    echo '```text'
    cat scripts/golden/cli-help.txt
    echo '```'
}

# `MaturityTable`: the forges and runtimes that are live-tested. The app shows
# an "untested" badge on everything else.
gen_maturity() {
    local forges runtimes
    forges=$(sed -nE 's/^.*liveTestedForges: \[ForgeID\] = \[(.*)\]$/\1/p' Sources/KinhinKit/Core/MaturityTable.swift |
        sed -E 's/\.([a-zA-Z]+)/`\1`/g')
    runtimes=$(sed -nE 's/^.*liveTestedRuntimes: \[RuntimeID\] = \[(.*)\]$/\1/p' Sources/KinhinKit/Core/MaturityTable.swift |
        sed -E 's/\.([a-zA-Z]+)/`\1`/g')
    echo "Live-tested forges (\`MaturityTable\`): $forges. Live-tested runtimes: $runtimes (\`tart\` means macOS VMs)."
    echo "Every other forge and runtime, and Tart serving Linux VMs, is shown with an **untested** badge."
}

# MARK: - Block replacement

# Prints <file> with the body of block <name> replaced by the contents of
# <body-file>. Fails when the marker pair is missing or unbalanced.
render() {
    local file=$1 name=$2 body=$3
    awk -v name="$name" -v body="$body" '
        $0 == "<!-- docs-sync:begin " name " -->" {
            if (state != 0) bad = 1
            print; while ((getline line < body) > 0) print line
            close(body); state = 1; seen++; next
        }
        $0 == "<!-- docs-sync:end " name " -->" {
            if (state != 1) bad = 1
            state = 0; print; next
        }
        state == 1 { next }
        { print }
        END { if (bad || state != 0 || seen != 1) exit 3 }' "$file"
}

status=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for row in "${blocks[@]}"; do
    name=${row%%|*}
    file=${row#*|}

    if [ "$mode" = list ]; then
        echo "$name -> $file"
        continue
    fi

    "gen_$name" >"$tmp/body"
    if [ ! -s "$tmp/body" ]; then
        echo "::error file=scripts/docs-sync.sh::generator '$name' produced no output; did its Swift source change shape?"
        status=1
        continue
    fi
    if ! render "$file" "$name" "$tmp/body" >"$tmp/out"; then
        echo "::error file=$file::needs exactly one '<!-- docs-sync:begin $name -->' / '<!-- docs-sync:end $name -->' pair"
        status=1
        continue
    fi

    if cmp -s "$file" "$tmp/out"; then
        continue
    fi
    if [ "$mode" = check ]; then
        echo "::error file=$file::block '$name' is out of sync with the code; run scripts/docs-sync.sh"
        diff -u "$file" "$tmp/out" || true
        status=1
    else
        cat "$tmp/out" >"$file"
        echo "updated $name in $file"
    fi
done

if [ "$mode" = write ] && [ "$status" -eq 0 ]; then
    echo "docs sync: done (${#blocks[@]} blocks)"
elif [ "$mode" = check ] && [ "$status" -eq 0 ]; then
    echo "docs sync: clean (${#blocks[@]} blocks)"
fi
exit "$status"
