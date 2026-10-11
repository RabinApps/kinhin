#!/bin/bash
# End-to-end check for the fastlane integration, run against a clean copy of the tracked examples.
#
#   scripts/mobile-e2e.sh [--with-builds] [--keep]
#
# What it does, per example app (flutter_app, RnApp, ios_native_app, android_native_app, expo_app):
#   1. Copies the committed files only (git ls-files), so leftover build output cannot hide a problem.
#   2. Re-runs scripts/mobile-init.sh --force on the copy and checks the generated fastlane files and
#      CI workflow still match the committed example. That catches drift between templates and examples.
#   3. Parses each CI workflow as YAML.
#   4. Installs the Gemfile with Ruby 3.1+ and lists the lanes for every platform folder.
#   5. Runs each lane's secret checks in an empty environment and expects the named error.
#   6. Checks every action option the templates use exists in the installed fastlane.
#   7. With --with-builds: native builds (Android debug, iOS simulator) when the tools exist.
#
# Nothing is uploaded and no credentials are read. Steps that need a missing tool are reported as
# SKIP with the reason. The script exits 1 if any check fails.
#
# Not covered here (needs real credentials or a kinhin runner): match, build_app signing, any upload,
# and the workflow on a kinhin-xcode runner. See docs/plans/mobile-fastlane-test-checklist.md.
set -euo pipefail

cd "$(dirname "$0")/.."
root="$PWD"

with_builds=0
keep=0
for arg in "$@"; do
    case "$arg" in
        --with-builds) with_builds=1 ;;
        --keep) keep=1 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "mobile-e2e: unknown option $arg" >&2; exit 2 ;;
    esac
done

work="$(mktemp -d)"
cleanup() {
    if [[ $keep -eq 1 ]]; then echo "mobile-e2e: kept $work"; else rm -rf "$work"; fi
}
trap cleanup EXIT

passed=0
failed=0
skipped=0
ok()   { echo "  ok    $1"; passed=$((passed + 1)); }
bad()  { echo "  FAIL  $1"; failed=$((failed + 1)); }
skip() { echo "  SKIP  $1"; skipped=$((skipped + 1)); }
section() { echo ""; echo "== $1"; }

# MARK: - Tools

# Ruby 3.1+ is required by fastlane 2.240. The macOS system Ruby (2.6) is not enough.
find_ruby() {
    local candidate
    for candidate in ${RUBY_BIN:-} /opt/homebrew/opt/ruby@3.3/bin/ruby /opt/homebrew/opt/ruby@3.2/bin/ruby \
        /opt/homebrew/opt/ruby@3.1/bin/ruby "$(command -v ruby 2>/dev/null || true)"; do
        [[ -n "$candidate" && -x "$candidate" ]] || continue
        if "$candidate" -e 'exit(RUBY_VERSION >= "3.1" ? 0 : 1)' 2>/dev/null; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

ruby_bin=""
if ruby_bin="$(find_ruby)"; then
    export PATH="$(dirname "$ruby_bin"):$PATH"
fi
has_ruby=0
[[ -n "$ruby_bin" ]] && has_ruby=1

has_yaml=0
python3 -c "import yaml" 2>/dev/null && has_yaml=1 || true

export FASTLANE_SKIP_UPDATE_CHECK=1 FASTLANE_OPT_OUT_USAGE=1 LANG=en_US.UTF-8

echo "mobile-e2e: work dir $work"
echo "mobile-e2e: ruby ${ruby_bin:-not found (need 3.1+)}; python yaml $([[ $has_yaml -eq 1 ]] && echo yes || echo no)"

# MARK: - Copy the committed example files

apps="flutter_app RnApp ios_native_app android_native_app expo_app"
section "copy committed examples"
while IFS= read -r -d '' file; do
    mkdir -p "$work/$(dirname "$file")"
    cp -p "$file" "$work/$file"
done < <(git ls-files -z examples)
for app in $apps; do
    if [[ -d "$work/examples/$app" ]]; then ok "$app copied"; else bad "$app missing from examples"; fi
done

# MARK: - Scaffold drift

section "templates regenerate the committed examples"
# Each file a scaffold writes, relative to the app folder. Gemfile is excluded: react-native keeps its own.
generated="ios/fastlane/Fastfile ios/fastlane/Appfile ios/fastlane/Matchfile android/fastlane/Fastfile android/fastlane/Appfile fastlane/Fastfile fastlane/Appfile fastlane/Matchfile .github/workflows/mobile-release.yml eas.json"
for app in flutter_app RnApp ios_native_app android_native_app expo_app; do
    dir="$work/examples/$app"
    before="$(mktemp -d)"
    for f in $generated; do
        [[ -f "$dir/$f" ]] && mkdir -p "$before/$(dirname "$f")" && cp "$dir/$f" "$before/$f"
    done
    "$root/scripts/mobile-init.sh" --force "$dir" > "$before/log" 2>&1 || true
    drift=0
    for f in $generated; do
        [[ -f "$before/$f" ]] || continue
        if ! cmp -s "$before/$f" "$dir/$f"; then
            echo "         drift: $app/$f differs from the template"
            drift=1
        fi
    done
    if [[ $drift -eq 0 ]]; then ok "$app matches its templates"; else bad "$app drifted from its templates (run mobile-init.sh --force on it)"; fi
    rm -rf "$before"
done

# MARK: - Workflow YAML

section "CI workflows parse"
for app in flutter_app RnApp ios_native_app android_native_app; do
    wf="$work/examples/$app/.github/workflows/mobile-release.yml"
    if [[ ! -f "$wf" ]]; then bad "$app has no workflow"; continue; fi
    if [[ $has_yaml -eq 0 ]]; then skip "$app workflow YAML (python3 with PyYAML not found)"; continue; fi
    if python3 -c "import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); assert d['jobs']" "$wf" 2>/dev/null; then
        ok "$app workflow is valid YAML"
    else
        bad "$app workflow is not valid YAML"
    fi
done

# MARK: - Workflow lint

section "workflow lint (actionlint)"
# kinhin-xcode is a self-hosted label that actionlint cannot know, so that one message is ignored.
lint_args=(-ignore 'label "kinhin-xcode" is unknown')
workflows="flutter_app/.github/workflows/mobile-release.yml RnApp/.github/workflows/mobile-release.yml
ios_native_app/.github/workflows/mobile-release.yml android_native_app/.github/workflows/mobile-release.yml"
if command -v actionlint >/dev/null; then
    lint_files=""
    for wf in $workflows; do lint_files="$lint_files $work/examples/$wf"; done
    # shellcheck disable=SC2086
    if actionlint "${lint_args[@]}" $lint_files >"$work/actionlint.log" 2>&1; then
        ok "generated workflows pass actionlint"
    else
        bad "generated workflows fail actionlint"; sed 's/^/         /' "$work/actionlint.log" | head -20
    fi
elif command -v docker >/dev/null && docker info >/dev/null 2>&1; then
    if docker run --rm -v "$work":/repo -w /repo rhysd/actionlint:latest "${lint_args[@]}" \
        $(for wf in $workflows; do printf 'examples/%s ' "$wf"; done) >"$work/actionlint.log" 2>&1; then
        ok "generated workflows pass actionlint (docker)"
    else
        bad "generated workflows fail actionlint (docker)"; sed 's/^/         /' "$work/actionlint.log" | head -20
    fi
else
    skip "actionlint (install actionlint, or start Docker)"
fi

# MARK: - Bundles and lanes

if [[ $has_ruby -eq 0 ]]; then
    section "fastlane bundles and lanes"
    skip "bundle install and lanes (Ruby 3.1+ not found; set RUBY_BIN)"
else
    section "fastlane bundles and lanes"
    for app in flutter_app RnApp ios_native_app android_native_app; do
        dir="$work/examples/$app"
        if (cd "$dir" && bundle config set --local path vendor/bundle >/dev/null && bundle install >"$dir/bundle.log" 2>&1); then
            ok "$app bundle install"
        else
            bad "$app bundle install (see $dir/bundle.log)"
            continue
        fi
        for platform_dir in $(cd "$dir" && { [[ -d ios/fastlane ]] && echo ios; [[ -d android/fastlane ]] && echo android; [[ -d fastlane ]] && echo .; }); do
            lanes="$(cd "$dir/$platform_dir" && bundle exec fastlane lanes 2>&1 | sed 's/\x1b\[[0-9;]*m//g' || true)"
            platform_label="$platform_dir"
            [[ "$platform_dir" == "." ]] && platform_label="root"
            if echo "$lanes" | grep -q "fastlane ios beta\|fastlane android beta"; then
                ok "$app/$platform_label lists beta"
            else
                bad "$app/$platform_label does not list beta"
            fi
        done
    done
fi

# MARK: - Secret checks in an empty environment

if [[ $has_ruby -eq 1 ]]; then
    section "lanes stop with a clear error when inputs are missing"
    # env -i clears every variable, so a secret on this machine cannot satisfy a check.
    # run_lane DIR [VAR=value ...] -- LANE [ARGS...]: runs `bundle exec fastlane LANE ARGS` with only the given variables.
    run_lane() {
        local dir="$1"; shift
        local -a envs=()
        while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
        shift
        lane_out="$(cd "$dir" && env -i PATH="$PATH" HOME="$HOME" LANG=en_US.UTF-8 FASTLANE_SKIP_UPDATE_CHECK=1 \
            FASTLANE_OPT_OUT_USAGE=1 ${envs[@]+"${envs[@]}"} bundle exec fastlane "$@" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' || true)"
    }
    # expect_error LABEL DIR EXPECTED_TEXT [VAR=value ...] -- LANE [ARGS...]
    expect_error() {
        local label="$1" dir="$2" expected="$3"; shift 3
        run_lane "$dir" "$@"
        if echo "$lane_out" | grep -qF "$expected"; then
            ok "$label: \"$expected\""
        else
            bad "$label: expected \"$expected\""
            echo "$lane_out" | tail -4 | sed 's/^/         /'
        fi
    }
    ios="$work/examples/ios_native_app"
    android="$work/examples/android_native_app"
    expect_error "ios beta with no secrets" "$ios" "Missing environment variables: ASC_KEY_ID" -- ios beta
    expect_error "android beta with no secrets" "$android" "Missing environment variables: PLAY_SERVICE_ACCOUNT_JSON" -- android beta
    expect_error "ios key file missing" "$ios" "ASC_KEY_FILEPATH does not exist: /nope.p8" \
        ASC_KEY_ID=x ASC_ISSUER_ID=x ASC_KEY_FILEPATH=/nope.p8 APP_IDENTIFIER=com.example.a APPLE_TEAM_ID=T -- ios beta
    expect_error "android AAB missing" "$android" "No release AAB at /nope.aab" \
        PLAY_SERVICE_ACCOUNT_JSON='{}' AAB_PATH=/nope.aab -- android beta
    expect_error "android keystore missing" "$android" "Keystore not found at /nope.keystore" \
        PLAY_SERVICE_ACCOUNT_JSON='{}' ANDROID_KEYSTORE_PATH=/nope.keystore ANDROID_KEYSTORE_PASSWORD=x \
        ANDROID_KEY_ALIAS=x ANDROID_KEY_PASSWORD=x -- android beta
fi

# MARK: - Option names

if [[ $has_ruby -eq 1 && -d "$work/examples/ios_native_app" ]]; then
    section "every action option used by the templates exists in fastlane"
    (cd "$work/examples/ios_native_app" && bundle exec ruby -e '
        require "fastlane"
        Fastlane::Actions.load_default_actions
        checks = {
          "app_store_connect_api_key" => %w[key_id issuer_id key_filepath],
          "match" => %w[api_key readonly git_url storage_mode type app_identifier team_id],
          "build_app" => %w[scheme export_method],
          "upload_to_testflight" => %w[api_key skip_waiting_for_build_processing],
          "upload_to_app_store" => %w[api_key skip_metadata skip_screenshots submit_for_review],
          "upload_to_play_store" => %w[track aab json_key_data skip_upload_metadata skip_upload_images skip_upload_screenshots package_name],
          "gradle" => %w[task build_type print_command properties],
        }
        failures = 0
        checks.each do |action, options|
          klass = Fastlane::Actions.action_class_ref(action)
          if klass.nil?
            puts "  FAIL  action #{action} not found"; failures += 1; next
          end
          keys = klass.available_options.map { |o| o.key.to_s }
          options.each do |opt|
            if keys.include?(opt)
              puts "  ok    #{action}.#{opt}"
            else
              puts "  FAIL  #{action}.#{opt} is not an option of #{action}"; failures += 1
            end
          end
        end
        exit(failures.zero? ? 0 : 1)
    ') && passed=$((passed + 1)) || failed=$((failed + 1))
fi

# MARK: - Native builds (opt-in)

section "native builds"
if [[ $with_builds -eq 0 ]]; then
    skip "native builds (pass --with-builds)"
else
    # local.properties is not tracked (it holds a machine-specific SDK path), so the copy gets one here.
    sdk="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
    if [[ -d "$sdk" ]]; then printf 'sdk.dir=%s\n' "$sdk" > "$work/examples/android_native_app/local.properties"; fi
    if [[ -d "$sdk" ]] && { [[ -n "${JAVA_HOME:-}" ]] || /usr/libexec/java_home -v 17 >/dev/null 2>&1; }; then
        export JAVA_HOME="${JAVA_HOME:-$(/usr/libexec/java_home -v 17)}"
        if (cd "$work/examples/android_native_app" && ./gradlew --no-daemon assembleDebug >"$work/android-build.log" 2>&1); then
            ok "android_native_app assembleDebug (Java 17)"
        else
            bad "android_native_app assembleDebug (see $work/android-build.log)"
        fi
    else
        skip "android_native_app assembleDebug (needs an Android SDK and Java 17)"
    fi
    if command -v xcodebuild >/dev/null; then
        # The .xcodeproj is generated from project.yml and not tracked, so generate it in the copy first.
        ios_dir="$work/examples/ios_native_app"
        if (cd "$ios_dir" && xcodegen generate >"$work/xcodegen.log" 2>&1 && \
            xcodebuild -project IosNativeApp.xcodeproj -scheme IosNativeApp \
            -sdk iphonesimulator -configuration Debug build CODE_SIGNING_ALLOWED=NO >"$work/ios-build.log" 2>&1); then
            ok "ios_native_app simulator build"
        else
            bad "ios_native_app simulator build (see $work/ios-build.log)"
        fi
    else
        skip "ios_native_app simulator build (no xcodebuild)"
    fi
fi

# run_build LABEL LOGNAME DIR COMMAND...: runs a build in the copy, logs to $work/LOGNAME.log.
run_build() {
    local label="$1" logname="$2" dir="$3"; shift 3
    if (cd "$dir" && "$@" >"$work/$logname.log" 2>&1); then
        ok "$label"
    else
        bad "$label (see $work/$logname.log)"
    fi
}

if [[ $with_builds -eq 1 ]]; then
    # Flutter: the Android bundle and an unsigned iOS build. A signed IPA needs a distribution certificate.
    if command -v flutter >/dev/null; then
        run_build "flutter_app appbundle (release)" flutter-aab "$work/examples/flutter_app" flutter build appbundle --release
        run_build "flutter_app ios --no-codesign" flutter-ios "$work/examples/flutter_app" flutter build ios --no-codesign
    else
        skip "flutter_app builds (no flutter on PATH)"
    fi

    # React Native: needs node_modules and CocoaPods; neither is in the tracked files.
    if command -v npm >/dev/null && command -v pod >/dev/null; then
        rn="$work/examples/RnApp"
        run_build "RnApp npm install" rn-npm "$rn" npm install --no-audit --no-fund
        run_build "RnApp pod install" rn-pods "$rn/ios" pod install
        run_build "RnApp simulator build" rn-ios "$rn/ios" xcodebuild -workspace RnApp.xcworkspace -scheme RnApp \
            -sdk iphonesimulator -configuration Debug build CODE_SIGNING_ALLOWED=NO
        if [[ -n "${JAVA_HOME:-}" ]] && [[ -d "${ANDROID_HOME:-$HOME/Library/Android/sdk}" ]]; then
            printf 'sdk.dir=%s\n' "${ANDROID_HOME:-$HOME/Library/Android/sdk}" > "$rn/android/local.properties"
            run_build "RnApp android bundleRelease" rn-aab "$rn/android" ./gradlew --no-daemon bundleRelease
        else
            skip "RnApp android bundleRelease (needs JAVA_HOME and an Android SDK)"
        fi
    else
        skip "RnApp builds (needs npm and CocoaPods)"
    fi

    # Native Android release bundle, unsigned (the example has no signing config).
    if [[ -n "${JAVA_HOME:-}" && -d "${ANDROID_HOME:-$HOME/Library/Android/sdk}" ]]; then
        run_build "android_native_app bundleRelease (unsigned)" android-aab "$work/examples/android_native_app" \
            ./gradlew --no-daemon bundleRelease
    fi
fi

# Signing: the lane passes the upload keystore to Gradle as android.injected.signing.* properties. Build a
# release bundle with a throwaway keystore that way, then check jarsigner accepts it. Also check an unsigned
# build is rejected, so the check cannot pass by accident.
if [[ $with_builds -eq 1 && -n "${JAVA_HOME:-}" && -d "${ANDROID_HOME:-$HOME/Library/Android/sdk}" ]] && command -v keytool >/dev/null; then
    section "signing"
    keystore="$work/test.keystore"
    keytool -genkeypair -keystore "$keystore" -storepass e2e-pass -keypass e2e-pass -alias e2e \
        -keyalg RSA -keysize 2048 -validity 2 -dname "CN=kinhin e2e" >/dev/null 2>&1
    android="$work/examples/android_native_app"
    if (cd "$android" && ./gradlew --no-daemon clean bundleRelease \
        -Pandroid.injected.signing.store.file="$keystore" -Pandroid.injected.signing.store.password=e2e-pass \
        -Pandroid.injected.signing.key.alias=e2e -Pandroid.injected.signing.key.password=e2e-pass >"$work/signed.log" 2>&1); then
        if jarsigner -verify "$android/app/build/outputs/bundle/release/app-release.aab" 2>&1 | grep -q "jar verified"; then
            ok "signed AAB verifies with jarsigner"
        else
            bad "signed AAB does not verify (see $work/signed.log)"
        fi
    else
        bad "signed release bundle build (see $work/signed.log)"
    fi
    if (cd "$android" && ./gradlew --no-daemon clean bundleRelease >"$work/unsigned.log" 2>&1); then
        if jarsigner -verify "$android/app/build/outputs/bundle/release/app-release.aab" 2>&1 | grep -q "jar is unsigned"; then
            ok "unsigned AAB is rejected by jarsigner"
        else
            bad "unsigned AAB was not reported as unsigned"
        fi
    fi
fi

echo ""
echo "mobile-e2e: $passed passed, $failed failed, $skipped skipped"
if [[ $failed -gt 0 ]]; then
    exit 1
fi
