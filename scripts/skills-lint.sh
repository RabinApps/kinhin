#!/bin/bash
# Skills lint: SKILL.md frontmatter, plus command drift against the CLI.
#
# `skills/` is shipped product surface — the agent skills for *using* kinhin —
# so a renamed or removed command must fail here instead of a skill lying to
# the agent that trusts it. Two check families over skills/*/SKILL.md:
#
#   1. Frontmatter: the file starts with a `---` block carrying `name:` equal
#      to the skill's directory and a non-empty `description:` (that line is
#      what an agent's skill matcher reads to decide when to load it).
#   2. Command drift: every backticked `kinhin <command>` must name a command
#      the CLI routes (CLICommand.parse) and, when it has a plain second word,
#      one the help screen documents (helpText()). A word after `help` is
#      exempt: `help <topic>` is accepted and prints the full screen.
#
# Grep/sed/awk only — no toolchain, bash 3.2 compatible. Runs in CI's docs job
# (ubuntu) and locally via scripts/check.sh.
set -euo pipefail

cd "$(dirname "$0")/.."

parse_src="Sources/kinhin/Commands/CLICommand.swift"
help_src="Sources/kinhin/Commands/HelpText.swift"

skills=(skills/*/SKILL.md)
if [[ ! -e ${skills[0]} ]]; then
    echo "skills lint: no skills found (skills/*/SKILL.md)" >&2
    exit 1
fi

# MARK: - Command vocabulary (from the routing table + the help screen)

parse_strings=$(sed -n '/static func parse(/,/^    }/p' "$parse_src" |
    grep -oE '"[a-z][a-z0-9 -]*"' | tr -d '"' || true)

help_words=$(sed -n '/^func helpText()/,/^}/p' "$help_src" |
    awk '/^        [a-z]/ { print $1 }' || true)

heads=$(
    {
        printf '%s\n' "$parse_strings"
        printf '%s\n' "$help_words"
    } | grep -E '^[a-z][a-z0-9-]*$' | sort -u
)

pairs=$(
    {
        printf '%s\n' "$parse_strings" | awk 'NF == 2 { print $1 " " $2 }'
        sed -n '/^func helpText()/,/^}/p' "$help_src" | awk '
            /^        [a-z]/ {
                w1 = $1
                w2 = $2
                sub(/^\[/, "", w2)   # `auth [set]` -> pair auth set
                sub(/\]$/, "", w2)
                if (w2 ~ /^[a-z][a-z0-9-]*$/) print w1 " " w2
            }'
    } | grep -E '^[a-z][a-z0-9-]* [a-z][a-z0-9-]*$' | sort -u
)

# MARK: - Checks

status=0
skills_checked=0
commands_checked=0

err() { # err <file> <line> <message>
    echo "::error file=$1,line=$2::skills lint — $3"
    echo "  $1:$2: $3"
    status=1
}

for file in "${skills[@]}"; do
    dir=$(basename "$(dirname "$file")")
    skills_checked=$((skills_checked + 1))

    # --- frontmatter ---
    if [[ $(sed -n '1p' "$file") != "---" ]]; then
        err "$file" 1 "must start with a --- frontmatter block"
        continue
    fi
    close_ln=$(awk 'NR > 1 && $0 == "---" { print NR; exit }' "$file")
    if [[ -z $close_ln ]]; then
        err "$file" 1 "frontmatter is never closed with ---"
        continue
    fi
    fm=$(sed -n "2,$((close_ln - 1))p" "$file")

    name_ln=$(printf '%s\n' "$fm" | grep -n '^name:' | head -1 | cut -d: -f1 || true)
    if [[ -z $name_ln ]]; then
        err "$file" 2 "frontmatter needs a name: line"
    elif [[ $(printf '%s\n' "$fm" | sed -n "${name_ln}p" | sed 's/^name:[[:space:]]*//') != "$dir" ]]; then
        err "$file" $((name_ln + 1)) "name: must equal its directory name ($dir)"
    fi

    desc_ln=$(printf '%s\n' "$fm" | grep -n '^description:' | head -1 | cut -d: -f1 || true)
    if [[ -z $desc_ln ]]; then
        err "$file" 3 "frontmatter needs a description: line"
    elif [[ -z $(printf '%s\n' "$fm" | sed -n "${desc_ln}p" | sed 's/^description:[[:space:]]*//') ]]; then
        err "$file" $((desc_ln + 1)) "description: must not be empty"
    fi

    # --- command drift: backticked `kinhin …` references, line by line ---
    line_numbers=$(grep -n '`kinhin ' "$file" | cut -d: -f1 || true)
    for ln in $line_numbers; do
        line=$(sed -n "${ln}p" "$file")
        refs=$(printf '%s\n' "$line" | grep -oE '`kinhin [^`]+`' || true)
        while IFS= read -r ref; do
            [[ -n $ref ]] || continue
            cmd=${ref#\`}
            cmd=${cmd%\`}
            w1=$(printf '%s' "$cmd" | awk '{ print $2 }')
            w2=$(printf '%s' "$cmd" | awk '{ print $3 }')
            commands_checked=$((commands_checked + 1))

            if ! printf '%s\n' "$cmd" | grep -qE '^kinhin [a-z]'; then
                continue # placeholders/flags (`kinhin <command> --help`)
            fi
            if ! printf '%s\n' "$heads" | grep -Fxq "$w1"; then
                err "$file" "$ln" "unknown command '$w1' (not in kinhin help or CLICommand.parse)"
                continue
            fi
            if [[ $w1 == help ]]; then
                continue # `help <topic>`: accepted, prints the full screen
            fi
            if printf '%s\n' "$w2" | grep -qE '^[a-z][a-z0-9-]*$' &&
                ! printf '%s\n' "$pairs" | grep -Fxq "$w1 $w2"; then
                err "$file" "$ln" "unknown command '$w1 $w2' (not in kinhin help)"
            fi
        done <<< "$refs"
    done
done

if [[ $status -eq 0 ]]; then
    echo "skills lint: clean ($skills_checked skills, $commands_checked kinhin references)"
fi
exit "$status"
