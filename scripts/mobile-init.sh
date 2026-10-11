#!/bin/bash
# Scaffold fastlane (and an EAS config for Expo) into a mobile project, for a kinhin runner.
#
#   scripts/mobile-init.sh [--framework NAME] [--force] [--dry-run] [DIR]
#
# Detects the project shape, then copies templates/mobile/ into DIR. Existing files are kept
# unless --force is given, so re-running is safe. Nothing is installed or run: afterwards,
# `bundle install` and `bundle exec fastlane lanes` work from each platform folder.
#
# Detection: pubspec.yaml → Flutter; "expo" in package.json → Expo; "react-native" in
# package.json → React Native; otherwise the iOS and Android folders decide. The platform list
# is computed once from the framework and used for both the fastlane folders and the CI jobs.
#
# Bash 3.2 compatible (macOS default). Templates are read from the kinhin checkout this script is in.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
templates="$here/templates/mobile"

framework="auto"
force=0
dry_run=0
dir="."
tmpfile=""
trap 'rm -f "${tmpfile:-}"' EXIT

die() { echo "mobile-init: $*" >&2; exit 2; }

usage() {
    cat <<'EOF'
Usage: scripts/mobile-init.sh [options] [DIR]

Scaffold fastlane into a mobile project (DIR, default: the current directory).

Options:
  --framework NAME  auto (default), ios, android, native, flutter, react-native, expo
  --force           overwrite files that already exist
  --dry-run         print what would change, and write nothing
  -h, --help        show this help

Existing files are kept unless --force is given, so re-running is safe.
EOF
}

# MARK: - Arguments

while [[ $# -gt 0 ]]; do
    case "$1" in
        --framework)
            [[ $# -ge 2 ]] || die "--framework needs a value (see --help)"
            framework="$2"; shift 2 ;;
        --force) force=1; shift ;;
        --dry-run) dry_run=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) die "unknown option $1 (see --help)" ;;
        *) dir="$1"; shift ;;
    esac
done

case "$framework" in
    auto|ios|android|native|flutter|react-native|expo) ;;
    *) die "unknown framework '$framework' (auto, ios, android, native, flutter, react-native, expo)" ;;
esac

[[ -d "$dir" ]] || die "no such directory: $dir"

# Fail before writing anything if this script was copied away from its templates.
required_templates="Gemfile expo/eas.json github/header.yml github/ios.job.yml github/android.job.yml
ios/fastlane/Fastfile ios/fastlane/Appfile ios/fastlane/Matchfile
android/fastlane/Fastfile android/fastlane/Appfile"
for t in $required_templates; do
    [[ -f "$templates/$t" ]] || die "template missing: $templates/$t (run this script from a kinhin checkout)"
done

cd "$dir"

# MARK: - Detection

has_ios()     { [[ -d ios ]] || compgen -G "*.xcodeproj" >/dev/null || compgen -G "*.xcworkspace" >/dev/null; }
has_android() { [[ -d android ]] || [[ -f settings.gradle ]] || [[ -f settings.gradle.kts ]]; }
pkg_has()     { [[ -f package.json ]] && grep -Fq "\"$1\"" package.json; }

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
    [[ "$framework" != "none" ]] || die "no iOS or Android project in $(pwd); pass --framework"
fi

# The platforms to scaffold, as a space-separated list (bash 3.2 has no safe empty-array expansion).
platforms=""
case "$framework" in
    ios)     platforms="ios" ;;
    android) platforms="android" ;;
    native|flutter|react-native)
        if has_ios; then platforms="ios"; fi
        if has_android; then platforms="$platforms android"; fi
        platforms="${platforms# }"
        [[ -n "$platforms" ]] || die "no ios/ or android/ folder in $(pwd) for a $framework project"
        ;;
    expo) platforms="" ;;
esac

echo "mobile-init: framework=$framework platforms=${platforms:-none} dir=$(pwd)"
[[ $dry_run -eq 0 ]] || echo "mobile-init: dry run, nothing will be written"

# MARK: - Writing

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
    mkdir -p "$(dirname "$dst")" || die "cannot create $(dirname "$dst")"
    cp "$src" "$dst" || die "cannot write $dst"
    echo "  wrote   $dst"
}

# An existing Gemfile (React Native ships one for CocoaPods) keeps its own gems; fastlane is appended.
ensure_gemfile() {
    if [[ ! -e Gemfile ]]; then
        copy_file "$templates/Gemfile" "Gemfile"
        return 0
    fi
    [[ -r Gemfile ]] || die "Gemfile exists but is not readable"
    if grep -Eq "^[[:space:]]*gem[[:space:]]*\(?[\"']fastlane[\"']" Gemfile; then
        echo "  keep    Gemfile (already has fastlane)"
        return 0
    fi
    if [[ $dry_run -eq 1 ]]; then
        echo "  would append fastlane to Gemfile"
        return 0
    fi
    printf '\n# Added by kinhin mobile-init: fastlane lanes live in ios/ and android/.\ngem "fastlane", "~> 2.240"\n' >> Gemfile \
        || die "cannot append to Gemfile"
    echo "  append  fastlane to Gemfile"
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

# The workflow is the header plus one job per scaffolded platform, so an iOS-only app gets no Android job.
write_workflow() {
    tmpfile="$(mktemp)" || die "cannot create a temp file"
    cat "$templates/github/header.yml" > "$tmpfile"
    for p in $platforms; do
        sed "s|__DIR__|$(platform_dir "$p")|" "$templates/github/$p.job.yml" >> "$tmpfile"
    done
    copy_file "$tmpfile" ".github/workflows/mobile-release.yml"
}

if [[ "$framework" == "expo" ]]; then
    copy_file "$templates/expo/eas.json" "eas.json"
    echo "  note    Expo uses EAS Build/Submit by default; no fastlane workflow is written."
    echo "          For fastlane, run 'npx expo prebuild' and re-run with --framework react-native."
    exit 0
fi

ensure_gemfile
for p in $platforms; do
    scaffold_fastlane "$p"
done
write_workflow

if [[ $dry_run -eq 1 ]]; then
    echo "mobile-init: dry run complete. Nothing was written."
else
    echo "mobile-init: done. Add the secrets listed in .github/workflows/mobile-release.yml, then run"
    echo "             'bundle install' and 'bundle exec fastlane lanes' from each platform folder."
fi
