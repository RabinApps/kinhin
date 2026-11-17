#!/bin/bash
# Decides what CI has to check for a diff, so a PR pays only for what it touched.
#
#   scripts/ci-changes.sh <base-ref>     diff <base-ref>...HEAD
#   scripts/ci-changes.sh --all          everything (push to main, nightly, manual, or a diff git cannot compute)
#
# Prints key=value lines (append to $GITHUB_OUTPUT, or read them by eye):
#   swift=true|false        a Swift/package change: lint, build, tests and the release build apply
#   tests=all|<regex>       `swift test --filter` regex; `all` means no filter
#   swift_files=<paths>     changed .swift files under Sources/ and Tests/ (space separated), for per-file lint
#   docs=true|false         docs-lint / docs-sync / skills-lint inputs changed
#   video=true|false        video suite inputs changed
#
# Tests run only for the updated files (see select_tests): a changed test file runs its own classes, a changed source
# file runs the classes in its mirrored test folder (Sources/<S>/<Dir> -> Tests/<T>/<Dir>) plus any <Name>*Tests.swift.
# No mirrored folder, or Core/, selects the target / everything. Shared inputs (KinhinTestSupport, Package.*, scripts/,
# templates/, docs/ and unknown paths) select every test, since tests read those from the repo.
set -euo pipefail

cd "$(dirname "$0")/.."

all=false
changed=""
case "${1:-}" in
    --all) all=true ;;
    "") echo "usage: $0 <base-ref> | --all" >&2; exit 2 ;;
    *) changed="$(git diff --name-only --diff-filter=ACMRD "$1...HEAD")" || all=true ;;
esac

swift=false
docs=false
video=false
touched=false everything=false
files=()
classes=()   # XCTestCase classes to run
targets=()   # whole test targets to run (no finer mapping available)

# Classes declared in the given test files.
classes_in() { [[ $# -gt 0 ]] && { grep -hoE 'class [A-Za-z0-9_]+Tests' "$@" 2>/dev/null | awk '{print $2}' || true; }; }

# select <file> <test-target>: tests for one changed file under Sources/<S>/ or Tests/<T>/.
#   a changed test file          -> the classes it declares (non-Swift test resources: the whole target)
#   Sources/<S>/<Dir>/...        -> every class under the mirrored Tests/<T>/<Dir>/, plus any <Name>*Tests.swift
#   Core/ or a file at the root, or no mirrored folder -> the whole target (Core is shared by every feature: all tests)
select_tests() {
    local f="$1" t="$2" rel dir base
    touched=true
    if [[ "$f" == Tests/* ]]; then
        if [[ "$f" == *Tests.swift && -f "$f" ]]; then
            while IFS= read -r c; do classes+=("$c"); done < <(classes_in "$f")
        else
            targets+=("$t")
        fi
        return
    fi
    rel="${f#Sources/*/}"
    dir="${rel%%/*}"
    if [[ "$dir" == Core ]]; then everything=true; return; fi
    if [[ "$rel" == "$dir" || ! -d "Tests/$t/$dir" ]]; then targets+=("$t"); return; fi
    base="$(basename "$f" .swift)"
    while IFS= read -r c; do classes+=("$c"); done < <(
        classes_in $(find "Tests/$t/$dir" -name '*.swift') $(find "Tests/$t" -name "${base}*Tests.swift")
    )
}

while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    case "$f" in
        Sources/KinhinKit/* | Tests/KinhinKitTests/*) swift=true; select_tests "$f" KinhinKitTests ;;
        Sources/kinhin/* | Tests/KinhinCLITests/*) swift=true; select_tests "$f" KinhinCLITests ;;
        Sources/kinhin-app/* | Tests/KinhinAppTests/*) swift=true; select_tests "$f" KinhinAppTests ;;
        Tests/KinhinTestSupport/* | Package.swift | Package.resolved | .swift-format | Plugins/* | scripts/* | templates/* | .github/*)
            swift=true; everything=true ;;
        docs/*) docs=true; swift=true; everything=true ;;
        skills/*) docs=true ;;
        video/*) video=true ;;
        website/* | assets/* | shots/* | examples/*) ;;
        *.md) docs=true ;;
        *) swift=true; everything=true ;; # unknown path: do not guess
    esac
    case "$f" in
        scripts/video-* | .github/*) video=true; docs=true ;;
        scripts/docs-* | scripts/skills-* | scripts/rules-* | scripts/changelog.sh) docs=true ;;
    esac
    if [[ "$f" == *.swift && ("$f" == Sources/* || "$f" == Tests/*) && -f "$f" ]]; then
        files+=("$f")
    fi
done <<<"$changed"

# Docs-sync derives doc blocks from Swift source, so any Sources change re-checks docs.
if [[ $touched == true ]]; then docs=true; fi

if [[ $all == true ]]; then
    swift=true docs=true video=true everything=true
fi

# Only the updated files' tests run: no cascade into the CLI/app targets for a KinhinKit change. main, develop and the
# nightly run stay full, which is the backstop for a cross-folder regression this mapping cannot see.
tests=all
if [[ $everything != true && $touched == true ]]; then
    parts=()
    for t in ${targets[@]+"${targets[@]}"}; do parts+=("$t"); done
    if [[ ${#classes[@]} -gt 0 ]]; then
        cls="$(printf '%s\n' "${classes[@]}" | sort -u | paste -sd'|' -)"
        parts+=("\\.($cls)/")
    fi
    if [[ ${#parts[@]} -gt 0 ]]; then tests="$(IFS='|'; echo "${parts[*]}")"; fi
fi

echo "swift=$swift"
echo "tests=$tests"
if [[ $all == true || $everything == true ]]; then
    echo "swift_files="
else
    echo "swift_files=${files[*]-}"
fi
echo "docs=$docs"
echo "video=$video"
