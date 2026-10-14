#!/usr/bin/env bash
# Mobile release steps for a kinhin runner, written by `kinhin mobile init` for CI systems other than GitHub Actions
# (GitLab CI, Gitea and Forgejo Actions, Bitbucket Pipelines, Azure Pipelines, Buildkite). Their pipeline files call it as
#
#   bash .kinhin/mobile-release.sh <ios|android> <beta|release|screenshots>
#
# It does what the GitHub workflow's steps do: the framework's setup, the signing files from secrets, bundle install, then the
# fastlane lane. Secrets arrive as environment variables, under the names docs/mobile-credentials.md lists:
#   iOS:     ASC_KEY_ID, ASC_KEY_P8 (contents of the .p8 file), ASC_ISSUER_ID, MATCH_GIT_URL,
#            MATCH_PASSWORD, APPLE_TEAM_ID, APP_IDENTIFIER, IOS_SCHEME
#   Android: ANDROID_PACKAGE_NAME, PLAY_SERVICE_ACCOUNT_JSON, ANDROID_KEYSTORE_BASE64 (base64 of the
#            upload keystore), ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD
# There are no setup actions outside GitHub, so the tools (Ruby 3.2+, and Node, Flutter, Java or .NET as the app needs) come
# from the runner image: declare them in .kinhin/config.yml (`kinhin toolchains detect --write` proposes the list).
set -euo pipefail

platform="${1:-}"
lane="${2:-beta}"
case "$lane" in
  beta | release | screenshots) ;;
  *) echo "mobile-release: unknown lane '$lane' (beta, release or screenshots)" >&2; exit 2 ;;
esac
case "$platform" in
  ios) dir="__IOS_DIR__" ;;
  android)
    dir="__ANDROID_DIR__"
    if [ "$lane" = release ]; then
      echo "mobile-release: Android has no release lane yet, so there is nothing to do for 'release'."
      exit 0
    fi
    ;;
  *) echo "usage: mobile-release.sh <ios|android> <beta|release|screenshots>" >&2; exit 2 ;;
esac

framework="__FRAMEWORK__"
# The app folder: this script lives in its .kinhin/ folder.
app="$(cd "$(dirname "$0")/.." && pwd)"
export CI=true
# Signing files live here for the job only.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

need() {
  command -v "$1" >/dev/null 2>&1 && return
  echo "mobile-release: '$1' is not on this runner's PATH. Add it to the image's toolchains in .kinhin/config.yml." >&2
  exit 1
}

# fastlane needs Ruby 3.2+; the macOS system Ruby is 2.6. mise, when the image has it, supplies one.
ruby_ok() {
  command -v ruby >/dev/null 2>&1 \
    && ruby -e 'exit(Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.2") ? 0 : 1)'
}
if ! ruby_ok && command -v mise >/dev/null 2>&1; then
  mise install ruby@3.3 >/dev/null
  PATH="$(mise where ruby@3.3)/bin:$PATH"
  export PATH
fi
ruby_ok || { echo "mobile-release: fastlane needs Ruby 3.2 or newer on the runner (ruby@3.3 in .kinhin/config.yml)." >&2; exit 1; }

# JavaScript dependencies with the project's own package manager.
js_install() {
  need node
  if [ -f yarn.lock ] || [ -f pnpm-lock.yaml ]; then
    # corepack's default shim directory is often read-only on a runner, so give it a directory the job owns.
    mkdir -p "$work/corepack-bin"
    corepack enable --install-directory "$work/corepack-bin"
    export PATH="$work/corepack-bin:$PATH"
  fi
  if [ -f yarn.lock ]; then yarn install --frozen-lockfile
  elif [ -f pnpm-lock.yaml ]; then pnpm install --frozen-lockfile
  elif [ -f package-lock.json ]; then npm ci
  else npm install
  fi
}

# The framework's setup, run in the app folder.
cd "$app"
case "$framework/$platform" in
  flutter/ios)
    need flutter
    flutter pub get
    flutter build ios --config-only --release
    ;;
  flutter/android)
    need flutter
    flutter pub get  # writes android/local.properties
    ;;
  react-native/*) js_install ;;
  capacitor/*)
    js_install
    npm run build
    npx cap sync "$platform"
    # Capacitor keeps its Xcode project in ios/App, one level below the fastlane folder (ios/).
    if [ "$platform" = ios ]; then export IOS_PROJECT=App/App.xcodeproj; fi
    ;;
  kmp/ios) need java ;;  # the Xcode build phase runs Gradle to build the shared framework
  kmp/android)
    # The Gradle root is one folder above androidApp/, and the module is androidApp.
    export ANDROID_GRADLE_DIR=.. ANDROID_GRADLE_MODULE=androidApp
    ;;
  maui/*)
    need dotnet
    dotnet workload install maui
    MAUI_PROJECT="$(find . -maxdepth 2 -name '*.csproj' | head -1)"
    export MAUI_PROJECT
    ;;
esac
if [ "$platform" = android ]; then need java; fi

# Signing files from the secrets, removed again when the script exits.
if [ "$platform" = ios ] && [ -n "${ASC_KEY_P8:-}" ]; then
  printf '%s' "$ASC_KEY_P8" > "$work/AuthKey.p8"
  export ASC_KEY_FILEPATH="$work/AuthKey.p8"
fi
if [ "$platform" = android ] && [ -n "${ANDROID_KEYSTORE_BASE64:-}" ]; then
  printf '%s' "$ANDROID_KEYSTORE_BASE64" | base64 --decode > "$work/release.keystore"
  export ANDROID_KEYSTORE_PATH="$work/release.keystore"
fi

cd "$app/$dir"
bundle install
if [ "$platform" = ios ] && [ -f Podfile ]; then bundle exec pod install; fi
bundle exec fastlane "$platform" "$lane"
