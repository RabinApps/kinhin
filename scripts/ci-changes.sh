#!/bin/bash
# Decide which of CI's Swift work a pull request needs, from the files it changes.
#
#   scripts/ci-changes.sh <base-ref>       changed files = `git diff --name-only --no-renames <base-ref>...HEAD`
#   scripts/ci-changes.sh --stdin          changed files = one path per line on stdin (used by the test)
#
# Prints key=value lines (append them to $GITHUB_OUTPUT):
#   swift=true|false     false when every changed file is outside Swift's reach (docs, website, skills, video, design)
#   filter=<regex>       empty = run the whole suite; otherwise a `swift test --filter` regex naming test targets
#
# The test targets are independent (Package.swift): KinhinCLITests depends on `kinhin`, KinhinAppTests on `kinhin-app`,
# KinhinKitTests on KinhinKit, and all three on KinhinTestSupport. So the suite narrows only when every Swift change is
# confined to the CLI or the app. Anything shared, unrecognized or build-affecting (Package.swift, scripts, workflows,
# KinhinKit, KinhinTestSupport, templates, fixtures) runs everything: an unknown path must never skip tests.
#
# Some tests read files outside Sources/ and Tests/ through #filePath (video/themes, video/music, the demo example,
# docs/telemetry; scripts/ and templates/ already run everything). Those paths are listed explicitly below and run the
# whole suite. When a test starts reading another directory, add it here and to scripts/ci-changes-test.sh.
#
# This is the PR-only fast path. Pushes to main/develop, the nightly run and manual dispatches always run everything
# (see ci.yml). Bash 3.2 compatible.
set -euo pipefail

cd "$(dirname "$0")/.."

case "${1:-}" in
    --stdin) files=$(cat) ;;
    "")
        echo "usage: $0 <base-ref> | --stdin" >&2
        exit 2
        ;;
    *) files=$(git diff --name-only --no-renames "$1"...HEAD) ;;
esac

swift=false
cli=false
app=false
full=false

while IFS= read -r path; do
    [[ -z $path ]] && continue
    # Markdown at the repository root (README, CHANGELOG, ...) is docs; Markdown deeper down (a bundled resource
    # under Sources/, a fixture under Tests/) is not.
    if [[ $path != */* && $path == *.md ]]; then
        continue
    fi
    case "$path" in
        # Files tests read straight from the repository (see the header): the whole suite.
        video/themes/* | video/music/* | video/adapters/kinhin/demos/* | docs/telemetry/*)
            swift=true
            full=true
            ;;
        # Outside Swift's reach. Tests/E2E is a separate package that only the e2e workflow builds.
        docs/* | website/* | skills/* | video/* | design/* | Tests/E2E/* | LICENSE* | .github/CODEOWNERS | .github/ISSUE_TEMPLATE/* | .github/PULL_REQUEST_TEMPLATE*) ;;
        Sources/kinhin/* | Tests/KinhinCLITests/*)
            swift=true
            cli=true
            ;;
        Sources/kinhin-app/* | Tests/KinhinAppTests/*)
            swift=true
            app=true
            ;;
        *)
            swift=true
            full=true
            ;;
    esac
done <<<"$files"

filter=""
if [[ $swift == true && $full == false ]]; then
    if [[ $cli == true && $app == true ]]; then
        filter="KinhinCLITests|KinhinAppTests"
    elif [[ $cli == true ]]; then
        filter="KinhinCLITests"
    else
        filter="KinhinAppTests"
    fi
fi

echo "swift=$swift"
echo "filter=$filter"
