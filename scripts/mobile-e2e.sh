#!/bin/bash
# End-to-end check for the fastlane integration, run against a clean copy of the tracked examples.
#
#   scripts/mobile-e2e.sh [--with-builds] [--keep]
#
# Uses the kinhin binary (KINHIN_BIN, default .build/debug/kinhin, built if missing).
#
# What it does, per example app (flutter_app, RnApp, ios_native_app, android_native_app, expo_app):
#   1. Copies the tracked and untracked files that git does not ignore (git ls-files -co --exclude-standard), so build output
#      cannot hide a problem and uncommitted changes are tested before they are committed.
#   2. Re-runs `kinhin mobile init --force` on the copy and checks the generated fastlane files and
#      CI workflow still match the committed example. That catches drift between templates and examples.
#   3. Parses each CI workflow as YAML.
#   4. Installs the Gemfile with Ruby 3.2+ and lists the lanes for every platform folder.
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
# A git repository, so the copy is a monorepo layout like this one: the workflow paths start at examples/.
git init -q "$work"
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

# Ruby 3.2+ is required by fastlane 2.241 (the pin resolves to it). The macOS system Ruby (2.6) is not enough.
find_ruby() {
    local candidate
    for candidate in ${RUBY_BIN:-} /opt/homebrew/opt/ruby@3.3/bin/ruby /opt/homebrew/opt/ruby@3.2/bin/ruby \
        "$(command -v ruby 2>/dev/null || true)"; do
        [[ -n "$candidate" && -x "$candidate" ]] || continue
        if "$candidate" -e 'exit(Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.2") ? 0 : 1)' 2>/dev/null; then
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
echo "mobile-e2e: ruby ${ruby_bin:-not found (need 3.2+)}; python yaml $([[ $has_yaml -eq 1 ]] && echo yes || echo no)"

# MARK: - The kinhin binary

KINHIN_BIN="${KINHIN_BIN:-$root/.build/debug/kinhin}"
if [[ ! -x "$KINHIN_BIN" ]]; then
    echo "mobile-e2e: building kinhin (swift build --product kinhin)"
    (cd "$root" && swift build --product kinhin >"$work/swift-build.log" 2>&1) || {
        echo "mobile-e2e: swift build failed (see $work/swift-build.log)" >&2
        exit 1
    }
fi

# MARK: - Copy the committed example files

apps="flutter_app RnApp ios_native_app android_native_app expo_app"
section "copy committed examples"
while IFS= read -r -d '' file; do
    mkdir -p "$work/$(dirname "$file")"
    cp -p "$file" "$work/$file"
done < <(git ls-files -z -co --exclude-standard examples)
for app in $apps; do
    if [[ -d "$work/examples/$app" ]]; then ok "$app copied"; else bad "$app missing from examples"; fi
done

# MARK: - CLI usage errors

section "kinhin mobile init reports usage errors with exit 2"
usage_dir="$(mktemp -d)"
set +e
"$KINHIN_BIN" mobile init --framework nope "$usage_dir" >/dev/null 2>&1; code_bad_framework=$?
"$KINHIN_BIN" mobile init "$usage_dir/missing" >/dev/null 2>&1; code_missing=$?
"$KINHIN_BIN" mobile init "$usage_dir" >/dev/null 2>&1; code_empty=$?
"$KINHIN_BIN" mobile >/dev/null 2>&1; code_bare=$?
set -e
[[ $code_bad_framework -eq 2 ]] && ok "unknown --framework exits 2" || bad "unknown --framework exits $code_bad_framework"
[[ $code_missing -eq 2 ]] && ok "missing directory exits 2" || bad "missing directory exits $code_missing"
[[ $code_empty -eq 2 ]] && ok "folder with no project exits 2" || bad "folder with no project exits $code_empty"
[[ $code_bare -eq 2 ]] && ok "bare 'kinhin mobile' exits 2" || bad "bare 'kinhin mobile' exits $code_bare"
rm -rf "$usage_dir"

# MARK: - Scaffold drift

section "templates regenerate the committed examples"
# Each file a scaffold writes, relative to the app folder. Gemfile is excluded: react-native keeps its own.
generated="ios/fastlane/Fastfile ios/fastlane/Appfile ios/fastlane/Matchfile ios/fastlane/Snapfile ios/fastlane/Framefile.json ios/UITests/SnapshotHelper.swift ios/UITests/ScreenshotTests.swift android/fastlane/Fastfile android/fastlane/Appfile android/fastlane/Screengrabfile android/app/src/androidTest/java/screenshots/ScreenshotTest.java android/app/src/debug/AndroidManifest.xml fastlane/Fastfile fastlane/Appfile fastlane/Matchfile fastlane/Snapfile fastlane/Framefile.json UITests/SnapshotHelper.swift UITests/ScreenshotTests.swift fastlane/Screengrabfile app/src/androidTest/java/screenshots/ScreenshotTest.java app/src/debug/AndroidManifest.xml .github/workflows/mobile-release.yml eas.json"
for app in flutter_app RnApp ios_native_app android_native_app expo_app; do
    dir="$work/examples/$app"
    before="$(mktemp -d)"
    for f in $generated; do
        [[ -f "$dir/$f" ]] && mkdir -p "$before/$(dirname "$f")" && cp "$dir/$f" "$before/$f"
    done
    "$KINHIN_BIN" mobile init --force "$dir" > "$before/log" 2>&1 || true
    drift=0
    for f in $generated; do
        [[ -f "$before/$f" ]] || continue
        if ! cmp -s "$before/$f" "$dir/$f"; then
            echo "         drift: $app/$f differs from the template"
            drift=1
        fi
    done
    if [[ $drift -eq 0 ]]; then ok "$app matches its templates"; else bad "$app drifted from its templates (run kinhin mobile init --force on it)"; fi
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
    skip "bundle install and lanes (Ruby 3.2+ not found; set RUBY_BIN)"
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
          "upload_to_app_store" => %w[api_key skip_metadata skip_screenshots submit_for_review skip_binary_upload skip_app_version_update overwrite_screenshots screenshots_path],
          "upload_to_play_store" => %w[track aab json_key_data skip_upload_metadata skip_upload_images skip_upload_screenshots skip_upload_apk skip_upload_aab skip_upload_changelogs metadata_path package_name],
          "gradle" => %w[task build_type print_command properties],
          "snapshot" => %w[scheme devices languages output_directory clear_previous_screenshots stop_after_first_error],
          "screengrab" => %w[app_package_name locales device_type output_directory clear_previous_screenshots],
          "frameit" => %w[path],
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

# MARK: - Builds (opt-in), mirroring what the generated CI jobs run

# run_build LABEL LOGNAME DIR COMMAND...: runs a build in the copy, logs to $work/LOGNAME.log.
run_build() {
    local label="$1" logname="$2" dir="$3"; shift 3
    if (cd "$dir" && "$@" >"$work/$logname.log" 2>&1); then
        ok "$label"
    else
        bad "$label (see $work/$logname.log)"
    fi
}

# The React Native install step, extracted from the template, run for each lockfile kind. corepack must not need
# /usr/local/bin, which is read-only on many runners, so the step points its shims at RUNNER_TEMP.
if [[ $with_builds -eq 1 && $has_yaml -eq 1 ]] && command -v npm >/dev/null; then
    section "React Native install step (yarn, pnpm, npm, no lockfile)"
    install_script="$work/js-install.sh"
    python3 - "$root/templates/mobile/github/prebuild/react-native-ios.yml" "$install_script" <<'PY'
import sys, yaml
steps = yaml.safe_load("steps:\n" + open(sys.argv[1]).read())["steps"]
run = next(s["run"] for s in steps if "JavaScript" in s.get("name", ""))
open(sys.argv[2], "w").write(run)
PY
    for kind in yarn pnpm npm none; do
        js="$work/js-$kind"
        mkdir -p "$js"
        printf '{"name":"rn-check","version":"1.0.0","private":true,"dependencies":{"left-pad":"1.3.0"}}\n' > "$js/package.json"
        case $kind in
            yarn) (cd "$js" && npx --yes yarn@1.22.22 install >/dev/null 2>&1 || true) ;;
            pnpm) (cd "$js" && pnpm install --lockfile-only >/dev/null 2>&1 || true) ;;
            npm)  (cd "$js" && npm install --package-lock-only >/dev/null 2>&1 || true) ;;
            none) ;;
        esac
        rm -rf "$js/node_modules"
        if (cd "$js" && RUNNER_TEMP="$work/rt-$kind" GITHUB_PATH="$work/gp-$kind" bash "$install_script" >"$work/js-$kind.log" 2>&1) \
            && [[ -d "$js/node_modules/left-pad" ]]; then
            ok "install step with $kind"
        else
            bad "install step with $kind (see $work/js-$kind.log)"
        fi
    done
fi

# Signing material for the lane build: a throwaway keystore, passed as the same variables CI sets.
keystore="$work/test.keystore"
make_keystore() {
    keytool -genkeypair -keystore "$keystore" -storepass e2e-pass -keypass e2e-pass -alias e2e \
        -keyalg RSA -keysize 2048 -validity 2 -dname "CN=kinhin e2e" >/dev/null 2>&1
}
# lane_build_signed LABEL APP_DIR: runs `fastlane android build` and checks the bundle with jarsigner.
lane_build_signed() {
    local label="$1" app="$2"
    # Flutter and React Native keep the Android project in android/; a native project may keep it at the root.
    local android_dir="$app/android"
    [[ -d "$android_dir" ]] || android_dir="$app"
    if (cd "$android_dir" && env -i PATH="$PATH" HOME="$HOME" LANG=en_US.UTF-8 JAVA_HOME="$JAVA_HOME" \
        ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}" FASTLANE_SKIP_UPDATE_CHECK=1 FASTLANE_OPT_OUT_USAGE=1 \
        ANDROID_KEYSTORE_PATH="$keystore" ANDROID_KEYSTORE_PASSWORD=e2e-pass ANDROID_KEY_ALIAS=e2e \
        ANDROID_KEY_PASSWORD=e2e-pass bundle exec fastlane android build >"$work/lane-$(basename "$app").log" 2>&1); then
        local aab
        aab="$(sed 's/\x1b\[[0-9;]*m//g' "$work/lane-$(basename "$app").log" | grep -o 'Built .*\.aab' | sed 's/^Built //' | tail -1)"
        if [[ -n "$aab" && -f "$aab" ]] && jarsigner -verify "$aab" 2>&1 | grep -q "jar verified"; then
            ok "$label: fastlane android build produced a signed AAB"
        else
            bad "$label: lane ran but the AAB is missing or not signed (aab: ${aab:-none})"
        fi
    else
        bad "$label: fastlane android build failed (see $work/lane-$(basename "$app").log)"
    fi
}

if [[ $with_builds -eq 1 ]]; then
    # Gradle finds the SDK from ANDROID_HOME, so the copies need no local.properties of their own.
    export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
    if [[ -z "${JAVA_HOME:-}" ]]; then JAVA_HOME="$(/usr/libexec/java_home -v 17 2>/dev/null || true)"; fi
    export JAVA_HOME
    make_keystore
    ios_sdk_ok=0; command -v xcodebuild >/dev/null && ios_sdk_ok=1

    # Flutter: the CI job runs the Flutter SDK, pub get and (iOS) config-only, then pods, then the lane.
    if command -v flutter >/dev/null; then
        fl="$work/examples/flutter_app"
        run_build "flutter_app pub get" flutter-pub "$fl" flutter pub get
        if [[ $ios_sdk_ok -eq 1 ]]; then
            run_build "flutter_app ios config-only" flutter-config "$fl" flutter build ios --config-only --release
            # The CI job runs pod install only when a Podfile exists; this example has none.
            if [[ -f "$fl/ios/Podfile" ]]; then
                run_build "flutter_app pod install" flutter-pods "$fl/ios" pod install
            fi
            # The Release device build is what the lane's archive step runs. A Debug simulator build needs a
            # simulator engine that --config-only does not produce.
            run_build "flutter_app Release device build" flutter-ios "$fl/ios" xcodebuild -workspace Runner.xcworkspace \
                -scheme Runner -sdk iphoneos -configuration Release build CODE_SIGNING_ALLOWED=NO
        else
            skip "flutter_app iOS build (no xcodebuild)"
        fi
        if [[ -n "${JAVA_HOME:-}" && -d "${ANDROID_HOME:-$HOME/Library/Android/sdk}" ]]; then
            lane_build_signed "flutter_app android" "$fl"
        else
            skip "flutter_app android build (needs JAVA_HOME and an Android SDK)"
        fi
    else
        skip "flutter_app builds (no flutter on PATH)"
    fi

    # React Native: the CI job runs npm (or yarn/npm ci), then pods, then the lane.
    if command -v npm >/dev/null && command -v pod >/dev/null; then
        rn="$work/examples/RnApp"
        run_build "RnApp npm install" rn-npm "$rn" npm install --no-audit --no-fund
        run_build "RnApp pod install" rn-pods "$rn/ios" pod install
        if [[ $ios_sdk_ok -eq 1 ]]; then
            run_build "RnApp simulator build" rn-ios "$rn/ios" xcodebuild -workspace RnApp.xcworkspace -scheme RnApp \
                -sdk iphonesimulator -configuration Debug build CODE_SIGNING_ALLOWED=NO
        else
            skip "RnApp iOS build (no xcodebuild)"
        fi
        if [[ -n "${JAVA_HOME:-}" && -d "${ANDROID_HOME:-$HOME/Library/Android/sdk}" ]]; then
            lane_build_signed "RnApp android" "$rn"
        else
            skip "RnApp android build (needs JAVA_HOME and an Android SDK)"
        fi
    else
        skip "RnApp builds (needs npm and CocoaPods)"
    fi

    # A fresh `flutter create` project, the way a new user meets the tool: the scaffold must note the iOS deployment target
    # (13.0 from flutter create does not build with Xcode 26), the documented fix must make the Release build pass, and the
    # signed Android lane must work on an untouched project.
    if command -v flutter >/dev/null && command -v bundle >/dev/null; then
        fresh="$work/fresh_app"
        run_build "fresh flutter create" fresh-create "$work" flutter create --platforms=ios,android fresh_app
        if [[ -d "$fresh" ]]; then
            if "$KINHIN_BIN" mobile init "$fresh" >"$work/fresh-init.log" 2>&1 \
                && grep -q "iOS deployment target is 13.0" "$work/fresh-init.log"; then
                ok "fresh flutter project: init notes the iOS deployment target"
            else
                bad "fresh flutter project: init did not note the deployment target (see $work/fresh-init.log)"
            fi
            run_build "fresh flutter pub get" fresh-pub "$fresh" flutter pub get
            run_build "fresh flutter bundle config" fresh-bundle-config "$fresh" bundle config set --local path vendor/bundle
            run_build "fresh flutter bundle install" fresh-bundle "$fresh" bundle install
            sed -i.bak 's/IPHONEOS_DEPLOYMENT_TARGET = 13.0;/IPHONEOS_DEPLOYMENT_TARGET = 15.0;/' \
                "$fresh/ios/Runner.xcodeproj/project.pbxproj"
            if [[ $ios_sdk_ok -eq 1 ]]; then
                (cd "$fresh" && flutter build ios --config-only --release >"$work/fresh-config.log" 2>&1) \
                    && ok "fresh flutter ios config-only" || bad "fresh flutter ios config-only (see $work/fresh-config.log)"
                run_build "fresh flutter Release device build (after the documented fix)" fresh-ios "$fresh/ios" \
                    xcodebuild -workspace Runner.xcworkspace -scheme Runner -sdk iphoneos -configuration Release build CODE_SIGNING_ALLOWED=NO
            fi
            if [[ -n "${JAVA_HOME:-}" && -d "${ANDROID_HOME:-$HOME/Library/Android/sdk}" ]]; then
                lane_build_signed "fresh flutter android" "$fresh"
            fi
        fi
    fi

    # Expo with fastlane: `expo prebuild` creates the native folders, then the React Native template applies to them.
    # EAS is the default path for Expo; this is the documented alternative.
    if command -v npx >/dev/null && command -v npm >/dev/null; then
        ex="$work/examples/expo_app"
        run_build "expo_app npm install" expo-npm "$ex" npm install --no-audit --no-fund
        run_build "expo_app prebuild" expo-prebuild "$ex" npx --yes expo prebuild --no-install
        if [[ -d "$ex/ios" && -d "$ex/android" ]]; then
            if "$KINHIN_BIN" mobile init --framework react-native "$ex" >"$work/expo-init.log" 2>&1; then
                ok "expo_app kinhin mobile init --framework react-native after prebuild"
            else
                bad "expo_app kinhin mobile init after prebuild (see $work/expo-init.log)"
            fi
            if [[ -d "$ex/fastlane" || -d "$ex/ios/fastlane" ]]; then
                run_build "expo_app bundle config" expo-bundle-config "$ex" bundle config set --local path vendor/bundle
                run_build "expo_app bundle install" expo-bundle "$ex" bundle install
                if [[ -f "$ex/ios/Podfile" ]]; then
                    run_build "expo_app pod install" expo-pods "$ex/ios" pod install
                    workspace="$(cd "$ex/ios" && find . -maxdepth 1 -name '*.xcworkspace' -type d | head -1 | sed 's|^\./||' || true)"
                    if [[ -n "$workspace" ]]; then
                        run_build "expo_app Release device build" expo-ios "$ex/ios" xcodebuild \
                            -workspace "$workspace" -scheme "${workspace%.xcworkspace}" -sdk iphoneos \
                            -configuration Release build CODE_SIGNING_ALLOWED=NO
                    else
                        bad "expo_app: no .xcworkspace after pod install"
                    fi
                fi
                if [[ -n "${JAVA_HOME:-}" && -d "${ANDROID_HOME:-$HOME/Library/Android/sdk}" ]]; then
                    lane_build_signed "expo_app android (fastlane)" "$ex"
                else
                    skip "expo_app android lane (needs JAVA_HOME and an Android SDK)"
                fi
            else
                bad "expo_app: kinhin mobile init wrote no fastlane folder"
            fi
        else
            skip "expo_app fastlane path (prebuild did not create ios/ and android/)"
        fi
    else
        skip "expo_app fastlane path (needs npm and npx)"
    fi

    # Screenshots: the iOS lane runs the UI tests on a simulator and must write PNGs. The simulator name comes from
    # E2E_SIMULATOR (default: a simulator this Mac has); the Android instrumented tests must compile.
    e2e_simulator="${E2E_SIMULATOR:-iPhone 17e}"
    if [[ $ios_sdk_ok -eq 1 ]] && command -v bundle >/dev/null; then
        shot_dir="$work/examples/ios_native_app"
        # The .xcodeproj is generated from project.yml and not tracked, so generate it before the lane needs it.
        run_build "ios_native_app xcodegen (for the screenshot lane)" ios-shots-xcodegen "$shot_dir" xcodegen generate
        run_build "ios_native_app screenshots lane (snapshot on $e2e_simulator)" ios-screenshots "$shot_dir" \
            env IOS_SCHEME=IosNativeApp SNAPSHOT_DEVICES="$e2e_simulator" SNAPSHOT_LANGUAGES=en-US bundle exec fastlane screenshots
        if [[ -n "$(find "$shot_dir/fastlane/screenshots" -name '*.png' 2>/dev/null | head -1)" ]]; then
            ok "ios_native_app wrote PNG screenshots under fastlane/screenshots"
        else
            bad "ios_native_app wrote no PNG screenshots"
        fi
    fi
    if [[ -n "${JAVA_HOME:-}" && -d "${ANDROID_HOME:-$HOME/Library/Android/sdk}" ]]; then
        run_build "android_native_app assembleDebugAndroidTest (screengrab tests compile)" android-test-apk \
            "$work/examples/android_native_app" ./gradlew --no-daemon assembleDebugAndroidTest
    fi

    # Native apps: the Android debug build, the iOS simulator build, and the signed lane build.
    native_android="$work/examples/android_native_app"
    if [[ -n "${JAVA_HOME:-}" && -d "${ANDROID_HOME:-$HOME/Library/Android/sdk}" ]]; then
        run_build "android_native_app assembleDebug" android-debug "$native_android" ./gradlew --no-daemon assembleDebug
        lane_build_signed "android_native_app" "$native_android"
    else
        skip "android_native_app builds (needs JAVA_HOME and an Android SDK)"
    fi
    if [[ $ios_sdk_ok -eq 1 ]] && command -v xcodegen >/dev/null; then
        # The .xcodeproj is generated from project.yml and not tracked, so generate it in the copy first.
        ios_dir="$work/examples/ios_native_app"
        run_build "ios_native_app xcodegen" xcodegen "$ios_dir" xcodegen generate
        run_build "ios_native_app simulator build" ios-native "$ios_dir" xcodebuild -project IosNativeApp.xcodeproj \
            -scheme IosNativeApp -sdk iphonesimulator -configuration Debug build CODE_SIGNING_ALLOWED=NO
    else
        skip "ios_native_app simulator build (needs xcodebuild and xcodegen)"
    fi

    # The unsigned check: a bundle built without signing properties must be rejected, so the signing check cannot
    # pass by accident.
    if [[ -n "${JAVA_HOME:-}" && -d "${ANDROID_HOME:-$HOME/Library/Android/sdk}" ]]; then
        if (cd "$native_android" && ./gradlew --no-daemon clean bundleRelease >"$work/unsigned.log" 2>&1); then
            if jarsigner -verify "$native_android/app/build/outputs/bundle/release/app-release.aab" 2>&1 | grep -q "jar is unsigned"; then
                ok "unsigned AAB is rejected by jarsigner"
            else
                bad "unsigned AAB was not reported as unsigned"
            fi
        else
            bad "unsigned release bundle build (see $work/unsigned.log)"
        fi
    fi
fi

echo ""
echo "mobile-e2e: $passed passed, $failed failed, $skipped skipped"
if [[ $failed -gt 0 ]]; then
    exit 1
fi
