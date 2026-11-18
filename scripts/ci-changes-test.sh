#!/bin/bash
# Table test for scripts/ci-changes.sh: each case is a list of changed paths and the expected `swift`/`filter` output.
# Runs in CI's docs job and scripts/check.sh. No toolchain needed.
set -euo pipefail

cd "$(dirname "$0")/.."

failures=0

expect() { # expect <swift> <filter> <path>...
    local want_swift=$1 want_filter=$2
    shift 2
    local out
    out=$(printf '%s\n' "$@" | bash scripts/ci-changes.sh --stdin)
    local got_swift got_filter
    got_swift=$(sed -n 's/^swift=//p' <<<"$out")
    got_filter=$(sed -n 's/^filter=//p' <<<"$out")
    if [[ $got_swift != "$want_swift" || $got_filter != "$want_filter" ]]; then
        echo "FAIL: $* -> swift=$got_swift filter='$got_filter' (want swift=$want_swift filter='$want_filter')"
        failures=$((failures + 1))
    fi
}

expect false "" docs/guide.md
expect false "" website/package.json docs/a.md skills/kinhin-x/SKILL.md
expect false "" video/script/launch.json design/kinhin-app.fig README.md CHANGELOG.md CONTRIBUTING.md
expect false "" Tests/E2E/E2ETests/CLITests.swift
expect false "" # no files at all
expect true "KinhinCLITests" Sources/kinhin/Main.swift
expect true "KinhinCLITests" Sources/kinhin/Main.swift Tests/KinhinCLITests/FooTests.swift docs/a.md
expect true "KinhinAppTests" Sources/kinhin-app/AppView.swift
expect true "KinhinCLITests|KinhinAppTests" Sources/kinhin/Main.swift Sources/kinhin-app/AppView.swift
expect true "" Sources/KinhinKit/Core/Thing.swift
expect true "" Sources/KinhinKit/Core/Thing.swift Sources/kinhin/Main.swift
expect true "" Tests/KinhinKitTests/ThingTests.swift
expect true "" Tests/KinhinTestSupport/Fake.swift Sources/kinhin/Main.swift
expect true "" Package.swift
expect true "" Package.resolved
expect true "" scripts/check.sh
expect true "" .github/workflows/ci.yml
expect true "" templates/mobile/App.swift
expect true "" Tests/Fixtures/x.json
expect true "" some-new-top-level-file.txt
expect true "" docs/a.md Package.swift
# Markdown below the root is not docs: a bundled resource or a fixture.
expect true "KinhinAppTests" Sources/kinhin-app/Resources/ForgeIcons/README.md
expect true "" Tests/Fixtures/notes.md
# Files Swift tests read from the repository.
expect true "" video/themes/dark.json
expect true "" video/music/catalog.json
expect true "" video/adapters/kinhin/demos/example.json
expect true "" docs/telemetry/metrics.md
expect true "" docs/telemetry/metrics.md docs/guide.md
expect false "" video/adapters/kinhin/launch.json
expect false "" docs/forges/azuredevops.md

if [[ $failures -ne 0 ]]; then
    echo "ci-changes test: $failures case(s) failed" >&2
    exit 1
fi
echo "ci-changes test: all cases passed"
