#!/bin/bash
# Scaffold fastlane (and an EAS config for Expo) into a mobile project, for a kinhin runner.
#
#   scripts/mobile-init.sh [--framework auto|ios|android|flutter|react-native|expo] [--force] [--dry-run] [DIR]
#
# Detects the project shape, then copies templates/mobile/ into DIR. Existing files are kept
# unless --force is given, so re-running is safe. Nothing is installed or run: afterwards,
# `bundle install` and `bundle exec fastlane ios lanes` (or `android lanes`) work from the project.
#
# Detection order: pubspec.yaml → Flutter; "expo" in package.json → Expo; "react-native" in
# package.json → React Native; otherwise the iOS and Android folders decide. Flutter and React
# Native get fastlane in ios/ and android/. Expo gets EAS config only (see docs/mobile-fastlane.md).
#
# Bash 3.2 compatible (macOS default). Templates are read from the kinhin checkout this script is in.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
templates="$here/templates/mobile"

framework="auto"
force=0
dry_run=0
dir="."

while [[ $# -gt 0 ]]; do
    case "$1" in
        --framework) framework="${2:?--framework needs a value}"; shift 2 ;;
        --force) force=1; shift ;;
        --dry-run) dry_run=1; shift ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        -*) echo "mobile-init: unknown option $1" >&2; exit 2 ;;
        *) dir="$1"; shift ;;
    esac
done

if [[ ! -d "$dir" ]]; then
    echo "mobile-init: no such directory: $dir" >&2
    exit 2
fi
cd "$dir"

# MARK: - Detection

has_ios()     { [[ -d ios ]] || compgen -G "*.xcodeproj" >/dev/null || compgen -G "*.xcworkspace" >/dev/null; }
has_android() { [[ -d android ]] || [[ -f settings.gradle ]] || [[ -f settings.gradle.kts ]]; }
pkg_has()     { [[ -f package.json ]] && grep -q "\"$1\"" package.json; }

detect() {
    if [[ -f pubspec.yaml ]]; then echo flutter
    elif pkg_has expo; then echo expo
    elif pkg_has react-native; then echo react-native
    elif has_ios && has_android; then echo native
    elif has_ios; then echo ios
    elif has_android; then echo android
    else echo none
    fi
}

if [[ "$framework" == "auto" ]]; then
    framework="$(detect)"
fi

case "$framework" in
    ios|android|flutter|react-native|expo|native) ;;
    none) echo "mobile-init: no iOS or Android project found in $(pwd); pass --framework" >&2; exit 2 ;;
    *) echo "mobile-init: unknown framework '$framework'" >&2; exit 2 ;;
esac

echo "mobile-init: framework=$framework dir=$(pwd)"

# MARK: - Copying

copy_file() { # copy_file SRC DST
    local src="$1" dst="$2"
    if [[ -e "$dst" && $force -eq 0 ]]; then
        echo "  keep    $dst (exists; use --force to overwrite)"
        return 0
    fi
    if [[ $dry_run -eq 1 ]]; then
        echo "  would write $dst"
        return 0
    fi
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    echo "  wrote   $dst"
}

# A platform's fastlane folder lives in ios/ or android/ when that folder exists, else at the root
# (a native project with its project file at the root).
platform_dir() { # platform_dir ios|android
    if [[ -d "$1" ]]; then echo "$1"; else echo "."; fi
}

scaffold_fastlane() { # scaffold_fastlane ios|android
    local platform="$1" target
    target="$(platform_dir "$platform")/fastlane"
    copy_file "$templates/$platform/fastlane/Fastfile" "$target/Fastfile"
    copy_file "$templates/$platform/fastlane/Appfile" "$target/Appfile"
    if [[ "$platform" == "ios" ]]; then
        copy_file "$templates/ios/fastlane/Matchfile" "$target/Matchfile"
    fi
}

case "$framework" in
    ios)
        copy_file "$templates/Gemfile" "Gemfile"
        scaffold_fastlane ios
        ;;
    android)
        copy_file "$templates/Gemfile" "Gemfile"
        scaffold_fastlane android
        ;;
    native|flutter|react-native)
        copy_file "$templates/Gemfile" "Gemfile"
        if has_ios; then scaffold_fastlane ios; fi
        if has_android; then scaffold_fastlane android; fi
        ;;
    expo)
        copy_file "$templates/expo/eas.json" "eas.json"
        echo "  note    Expo uses EAS Build/Submit by default; no fastlane workflow is written."
        echo "          For fastlane, run 'npx expo prebuild' and re-run with --framework react-native."
        exit 0
        ;;
esac

copy_file "$templates/github/mobile-release.yml" ".github/workflows/mobile-release.yml"

echo "mobile-init: done. Next: add the secrets listed in .github/workflows/mobile-release.yml,"
echo "             then 'bundle install' and 'bundle exec fastlane ios lanes' locally."
