#!/bin/bash
# Tests for scripts/mobile-init.sh. Builds a throwaway fixture for each project shape and checks
# what gets written, what gets kept, and the error paths. No network, no Ruby, no Xcode.
#
#   scripts/mobile-init-test.sh
set -euo pipefail

cd "$(dirname "$0")/.."
script="$PWD/scripts/mobile-init.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; failures=$((failures + 1)); }

check() { # check DESCRIPTION COMMAND...
    local desc="$1"; shift
    if "$@"; then pass "$desc"; else fail "$desc"; fi
}

has_line() { grep -Fq -- "$2" "$1"; }
absent() { [[ ! -e "$1" ]]; }

# run_init DIR [ARGS...] — capture output and exit code without tripping set -e.
run_init() {
    local dir="$1"; shift
    set +e
    out="$("$script" "$@" "$dir" 2>&1)"
    code=$?
    set -e
}

# MARK: - Fixtures

mk_flutter() { mkdir -p "$1/ios" "$1/android"; touch "$1/pubspec.yaml"; }
mk_rn() {
    mkdir -p "$1/ios" "$1/android"
    printf '{"dependencies":{"react-native":"0.80.0"}}\n' > "$1/package.json"
    printf 'source "https://rubygems.org"\ngem "cocoapods", ">= 1.13"\n' > "$1/Gemfile"
}
mk_expo() { mkdir -p "$1"; printf '{"dependencies":{"expo":"~54.0.0"}}\n' > "$1/package.json"; }
mk_ios_root() { mkdir -p "$1/App.xcodeproj"; touch "$1/App.xcodeproj/project.pbxproj"; }
mk_android_root() { mkdir -p "$1/app"; touch "$1/settings.gradle.kts"; }

echo "mobile-init: help and argument errors"
run_init "$work" --help; check "--help exits 0" [ "$code" -eq 0 ]
run_init "$work" --bogus; check "unknown option exits 2" [ "$code" -eq 2 ]
run_init "$work" --framework nope; check "unknown framework exits 2" [ "$code" -eq 2 ]
run_init "$work" --framework; check "--framework without a value exits 2" [ "$code" -eq 2 ]
run_init "$work/missing"; check "missing directory exits 2" [ "$code" -eq 2 ]

echo "mobile-init: detection and scaffolding"
mkdir -p "$work/empty"
run_init "$work/empty"; check "empty directory exits 2" [ "$code" -eq 2 ]
check "empty directory explains what to do" has_line <(echo "$out") "pass --framework"

mk_flutter "$work/flutter"
run_init "$work/flutter"; check "flutter exits 0" [ "$code" -eq 0 ]
check "flutter writes Gemfile" [ -f "$work/flutter/Gemfile" ]
check "flutter writes ios fastlane" [ -f "$work/flutter/ios/fastlane/Fastfile" ]
check "flutter writes android fastlane" [ -f "$work/flutter/android/fastlane/Fastfile" ]
check "flutter workflow has ios and android jobs" bash -c "grep -q '^  ios:' '$work/flutter/.github/workflows/mobile-release.yml' && grep -q '^  android:' '$work/flutter/.github/workflows/mobile-release.yml'"
check "flutter workflow runs in ios/" has_line "$work/flutter/.github/workflows/mobile-release.yml" "working-directory: ios"
check "flutter workflow sets up Ruby 3.1+ for fastlane" has_line "$work/flutter/.github/workflows/mobile-release.yml" "ruby/setup-ruby@v1"

mk_rn "$work/rn"
run_init "$work/rn"; check "react-native exits 0" [ "$code" -eq 0 ]
check "react-native keeps its CocoaPods gem" has_line "$work/rn/Gemfile" 'gem "cocoapods"'
check "react-native appends fastlane to its Gemfile" has_line "$work/rn/Gemfile" 'gem "fastlane"'
check "react-native writes ios fastlane" [ -f "$work/rn/ios/fastlane/Matchfile" ]
run_init "$work/rn"; check "re-run keeps the Gemfile unchanged" [ "$(grep -c 'gem "fastlane"' "$work/rn/Gemfile")" -eq 1 ]

mk_expo "$work/expo"
run_init "$work/expo"; check "expo exits 0" [ "$code" -eq 0 ]
check "expo writes eas.json" [ -f "$work/expo/eas.json" ]
check "expo writes no fastlane workflow" absent "$work/expo/.github/workflows/mobile-release.yml"

mk_ios_root "$work/ios"
run_init "$work/ios"; check "root iOS project exits 0" [ "$code" -eq 0 ]
check "root iOS project puts fastlane at the root" [ -f "$work/ios/fastlane/Fastfile" ]
check "root iOS workflow has only an ios job" bash -c "! grep -q '^  android:' '$work/ios/.github/workflows/mobile-release.yml'"
check "root iOS workflow runs at the root" has_line "$work/ios/.github/workflows/mobile-release.yml" "working-directory: ."

mk_android_root "$work/android"
run_init "$work/android"; check "root Android project exits 0" [ "$code" -eq 0 ]
check "root Android workflow has only an android job" bash -c "! grep -q '^  ios:' '$work/android/.github/workflows/mobile-release.yml'"

echo "mobile-init: explicit framework follows the framework, not the folders"
mk_flutter "$work/explicit"
run_init "$work/explicit" --framework ios; check "--framework ios exits 0" [ "$code" -eq 0 ]
check "--framework ios writes no android folder" absent "$work/explicit/android/fastlane"
check "--framework ios workflow has only an ios job" bash -c "! grep -q '^  android:' '$work/explicit/.github/workflows/mobile-release.yml'"

mkdir -p "$work/bare-flutter"; touch "$work/bare-flutter/pubspec.yaml"
run_init "$work/bare-flutter"; check "flutter without ios/ or android/ exits 2" [ "$code" -eq 2 ]

echo "mobile-init: safety"
mk_flutter "$work/keep"
run_init "$work/keep"
printf 'custom\n' > "$work/keep/ios/fastlane/Fastfile"
run_init "$work/keep"; check "re-run keeps an edited Fastfile" has_line "$work/keep/ios/fastlane/Fastfile" custom
run_init "$work/keep" --force; check "--force overwrites an edited Fastfile" bash -c "! grep -q '^custom$' '$work/keep/ios/fastlane/Fastfile'"

mk_flutter "$work/dry"
run_init "$work/dry" --dry-run; check "--dry-run exits 0" [ "$code" -eq 0 ]
check "--dry-run writes no files" absent "$work/dry/ios/fastlane/Fastfile"
check "--dry-run says it wrote nothing" has_line <(echo "$out") "Nothing was written"

echo "mobile-init: generated files parse"
if command -v ruby >/dev/null; then
    for f in templates/mobile/Gemfile templates/mobile/ios/fastlane/Fastfile templates/mobile/ios/fastlane/Matchfile \
        templates/mobile/ios/fastlane/Appfile templates/mobile/android/fastlane/Fastfile templates/mobile/android/fastlane/Appfile; do
        check "ruby -c $f" ruby -c "$f"
    done
else
    echo "  skip  ruby not found"
fi
if command -v python3 >/dev/null && python3 -c "import yaml" 2>/dev/null; then
    check "flutter workflow is valid YAML" python3 -c "import yaml,sys; yaml.safe_load(open('$work/flutter/.github/workflows/mobile-release.yml'))"
    check "root iOS workflow is valid YAML" python3 -c "import yaml,sys; yaml.safe_load(open('$work/ios/.github/workflows/mobile-release.yml'))"
else
    echo "  skip  python3 with PyYAML not found"
fi
check "expo eas.json is valid JSON" python3 -m json.tool "$work/expo/eas.json"

echo ""
if [[ $failures -gt 0 ]]; then
    echo "mobile-init tests: $failures failed"
    exit 1
fi
echo "mobile-init tests: all passed"
