#!/bin/bash
# Rules lint: the CONTRIBUTING.md code rules a compiler and swift-format do not enforce, over Sources/ (never Tests/).
#
# Rule names (as used by the escape hatch below) and what each one flags:
#
#   try-bang       `try!`
#   as-bang        `as!`
#   force-unwrap   a postfix `!`: an identifier, `)` or `]` immediately followed by `!` and then anything but `=`
#                  (so `a != b`, `!flag` and `x!==y`-free code pass). Implicitly unwrapped optional types (`T!`) count.
#   legacy-sync    `NSLock`, `DispatchQueue`, `DispatchSemaphore`: use `Mutex`, `Locked` or an actor
#   try-question   `try?` without a `//` comment on the same line or the line directly above saying why ignoring the
#                  failure is safe
#   file-length    a Swift file over 450 lines that is not in scripts/rules-lint.allow
#
# The code rules run on each line with string literals (single-line, multi-line and raw, with their `\( )`
# interpolations still checked as code) and comments removed, so a `!` in a message or a comment never counts.
# The scanner is a small lexer in awk, not a compiler: bare regex literals (`/.../`) are not recognized.
#
# Escape hatch, for a genuine exception: a `// rules-lint: allow <rule>` comment on the same line suppresses that
# rule's hit on that line (several rules: `// rules-lint: allow force-unwrap, try-bang`). Say why next to it.
#
# file-length: scripts/rules-lint.allow lists the files that were already over the limit when the rule landed. The
# list only ever shrinks: split a listed file and delete its line (the lint prints a hint once one fits). Never add
# a file to it; split the file instead.
#
# Generated files (Sources/KinhinKit/Mobile/MobileTemplates.swift) are skipped.
#
# awk/grep/sort only — no toolchain, bash 3.2 and POSIX awk (BSD awk, mawk, gawk) compatible. Runs in CI's docs job
# (ubuntu) and locally via scripts/check.sh.
set -euo pipefail

cd "$(dirname "$0")/.."

max_lines=450
allow_file="scripts/rules-lint.allow"
generated="Sources/KinhinKit/Mobile/MobileTemplates.swift"

files=$(find Sources -name '*.swift' -type f | grep -vxF "$generated" | LC_ALL=C sort)
if [[ -z $files ]]; then
    echo "rules lint: no Swift files under Sources/" >&2
    exit 1
fi

status=0
hits=""

err() { # err <file> <line> <rule> <message>
    echo "::error file=$1,line=$2::rules lint ($3) — $4"
    echo "  $1:$2: [$3] $4"
    status=1
}

# MARK: - Code rules (one awk pass over every file)

# Emits `rule<TAB>file<TAB>line<TAB>message` per hit.
code_hits=$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 awk '
    function push(type, hashes) {
        sp++
        st_type[sp] = type
        st_hash[sp] = hashes
        st_depth[sp] = 1
    }
    function hashes(n,    s) {
        s = ""
        while (n-- > 0) s = s "#"
        return s
    }
    function allowed(rule,    p) {
        p = index(comment, "rules-lint: allow")
        return p > 0 && index(substr(comment, p), rule) > 0
    }
    function hit(rule, message) {
        if (!allowed(rule)) printf "%s\t%s\t%d\t%s\n", rule, FILENAME, FNR, message
    }
    FNR == 1 {
        sp = 0
        block = 0
        prev_line_comment = 0
    }
    {
        line = $0
        n = length(line)
        code = ""
        comment = ""
        line_comment = 0
        i = 1
        while (i <= n) {
            if (block > 0) {
                rest = substr(line, i)
                if (match(rest, /\/\*|\*\//) == 0) {
                    comment = comment rest
                    break
                }
                comment = comment substr(rest, 1, RSTART - 1)
                if (substr(rest, RSTART, 2) == "*/") block--
                else block++
                i += RSTART + 1
                continue
            }
            top = sp > 0 ? st_type[sp] : "C"
            if (top == "C" || top == "I") {
                rest = substr(line, i)
                if (match(rest, /["\/#()]/) == 0) {
                    code = code rest
                    break
                }
                code = code substr(rest, 1, RSTART - 1)
                i += RSTART - 1
                c = substr(line, i, 1)
                if (c == "/") {
                    two = substr(line, i, 2)
                    if (two == "//") {
                        comment = comment substr(line, i)
                        line_comment = 1
                        break
                    }
                    if (two == "/*") {
                        block++
                        i += 2
                        continue
                    }
                    code = code c
                    i++
                    continue
                }
                if (c == "#" || c == "\"") {
                    j = i
                    h = 0
                    while (substr(line, j, 1) == "#") { j++; h++ }
                    if (substr(line, j, 1) == "\"") {
                        code = code "\"\""
                        if (substr(line, j, 3) == "\"\"\"") {
                            push("M", h)
                            i = j + 3
                        } else {
                            push("S", h)
                            i = j + 1
                        }
                        continue
                    }
                    code = code c
                    i++
                    continue
                }
                if (top == "I") {
                    if (c == "(") st_depth[sp]++
                    else if (st_depth[sp] == 1) {
                        sp--  # the interpolation closes: back inside its string
                        i++
                        continue
                    } else st_depth[sp]--
                }
                code = code c
                i++
                continue
            }
            # Inside a string literal (S: single-line, M: multi-line) opened with st_hash[sp] `#`s.
            hs = hashes(st_hash[sp])
            rest = substr(line, i)
            if (match(rest, /["\\]/) == 0) break
            i += RSTART - 1
            c = substr(line, i, 1)
            if (c == "\\") {
                if (substr(line, i + 1, length(hs)) == hs) {
                    if (substr(line, i + 1 + length(hs), 1) == "(") {
                        push("I", 0)
                        i += 2 + length(hs)
                        continue
                    }
                    i += 2 + length(hs)
                } else i++
                continue
            }
            if (top == "S" && substr(line, i + 1, length(hs)) == hs) {
                sp--
                i += 1 + length(hs)
                continue
            }
            if (top == "M" && substr(line, i, 3) == "\"\"\"" && substr(line, i + 3, length(hs)) == hs) {
                sp--
                i += 3 + length(hs)
                continue
            }
            i++
        }
        # A single-line string (and any interpolation in it) cannot run past the end of its line.
        while (sp > 0 && st_type[sp] != "M") sp--

        if (code ~ /(^|[^A-Za-z0-9_])try!/) hit("try-bang", "try! — handle the error, or one documented preconditionFailure for a true invariant")
        if (code ~ /(^|[^A-Za-z0-9_])as!/) hit("as-bang", "as! — use as? with guard let / if let")
        stripped = code
        gsub(/(^|[^A-Za-z0-9_])(try|as)!/, " ", stripped)
        if (stripped ~ /[])A-Za-z0-9_]!([^=]|$)/) hit("force-unwrap", "force unwrap — use guard let / if let, or one documented preconditionFailure")
        if (code ~ /(^|[^A-Za-z0-9_])(NSLock|DispatchQueue|DispatchSemaphore)([^A-Za-z0-9_]|$)/) hit("legacy-sync", "NSLock / DispatchQueue / DispatchSemaphore — use Mutex, Locked or an actor")
        if (code ~ /(^|[^A-Za-z0-9_])try\?/ && !line_comment && !prev_line_comment) hit("try-question", "try? needs a // comment (same line or the line above) saying why ignoring the failure is safe")
        prev_line_comment = line_comment
    }
')

while IFS=$'\t' read -r rule file ln message; do
    [[ -n $rule ]] || continue
    err "$file" "$ln" "$rule" "$message"
    hits="$hits$rule"$'\n'
done <<< "$code_hits"

# MARK: - File length

if [[ ! -f $allow_file ]]; then
    echo "rules lint: $allow_file is missing" >&2
    exit 1
fi
allowed=$(grep -v -e '^#' -e '^[[:space:]]*$' "$allow_file" || true)
long_files=0
while IFS= read -r file; do
    count=$(wc -l < "$file" | tr -d ' ')
    if [[ $count -gt $max_lines ]]; then
        long_files=$((long_files + 1))
        if ! grep -Fxq "$file" <<< "$allowed"; then
            err "$file" 1 "file-length" "$count lines (limit $max_lines) — split it by responsibility (CONTRIBUTING.md \"Layout\")"
            hits="${hits}file-length"$'\n'
        fi
    fi
done <<< "$files"
while IFS= read -r file; do
    [[ -n $file ]] || continue
    if [[ ! -f $file ]]; then
        echo "  hint: $file is gone; delete its line from $allow_file"
    elif [[ $(wc -l < "$file" | tr -d ' ') -le $max_lines ]]; then
        echo "  hint: $file is within $max_lines lines now; delete its line from $allow_file (the list only shrinks)"
    fi
done <<< "$allowed"

# MARK: - Summary

file_count=$(printf '%s\n' "$files" | wc -l | tr -d ' ')
if [[ $status -eq 0 ]]; then
    echo "rules lint: clean ($file_count files; $long_files over $max_lines lines, all allowlisted)"
else
    summary=$(printf '%s' "$hits" | LC_ALL=C sort | uniq -c | awk '{ printf "%s%s %s", sep, $1, $2; sep = ", " }')
    echo "rules lint: failed ($summary)"
fi
exit "$status"
