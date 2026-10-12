// Generated from templates/mobile/ by scripts/mobile-templates-embed.py. Do not edit by hand:
// MobileScaffoldTests fails when this file and the template files differ.

enum MobileTemplates {
    /// Template text by its path under templates/mobile/.
    static let files: [String: String] = [
        "Gemfile": Gemfile,
        "android/fastlane/Appfile": androidFastlaneAppfile,
        "android/fastlane/Fastfile": androidFastlaneFastfile,
        "expo/eas.json": expoEasJson,
        "github/android.job.yml": githubAndroidJobYml,
        "github/header.yml": githubHeaderYml,
        "github/ios.job.yml": githubIosJobYml,
        "github/prebuild/flutter-android.yml": githubPrebuildFlutterAndroidYml,
        "github/prebuild/flutter-ios.yml": githubPrebuildFlutterIosYml,
        "github/prebuild/react-native-android.yml": githubPrebuildReactNativeAndroidYml,
        "github/prebuild/react-native-ios.yml": githubPrebuildReactNativeIosYml,
        "ios/fastlane/Appfile": iosFastlaneAppfile,
        "ios/fastlane/Fastfile": iosFastlaneFastfile,
        "ios/fastlane/Matchfile": iosFastlaneMatchfile,
    ]

    private static let Gemfile = #"""
        # Pinned fastlane. Run lanes with `bundle exec fastlane <lane>` from ios/ or android/.
        # Bump the pin deliberately: `bundle update fastlane` and commit Gemfile.lock.
        source "https://rubygems.org"

        gem "fastlane", "~> 2.240"
        """#

    private static let androidFastlaneAppfile = #"""
        # Google Play package name. Set from the environment so nothing personal is committed.
        package_name(ENV["ANDROID_PACKAGE_NAME"]) # e.g. com.example.app
        """#

    private static let androidFastlaneFastfile = #"""
        # Android lanes. Uploads go through the Google Play Developer API with a service account.
        # AAB_PATH skips the Gradle build when another step already built the bundle.
        # `build` makes a signed bundle without uploading it; CI and the e2e use it to check signing.
        default_platform(:android)

        # Stop before any store call when a required variable is missing, with the name of the variable.
        def require_env!(*names)
          missing = names.select { |name| ENV[name].to_s.strip.empty? }
          UI.user_error!("Missing environment variables: #{missing.join(', ')}. See docs/mobile-fastlane.md#secrets") unless missing.empty?
        end

        # The folder that holds the Android project: android/ in Flutter and React Native, the app root otherwise.
        # Built from this Fastfile's location, because fastlane's working directory is not reliable for relative paths.
        def android_root
          File.expand_path("..", __dir__)
        end

        # Gradle writes the bundle under the project's build folder. Flutter sets that folder to <flutter root>/build, one
        # level above android/, so a pubspec.yaml there means a Flutter project.
        def default_aab_path
          flutter_root = File.expand_path("..", android_root)
          if File.exist?(File.join(flutter_root, "pubspec.yaml"))
            File.join(flutter_root, "build/app/outputs/bundle/release/app-release.aab")
          else
            File.join(android_root, "app/build/outputs/bundle/release/app-release.aab")
          end
        end

        # Returns the path of a signed release bundle, building it with Gradle unless AAB_PATH is set.
        def build_signed_aab
          aab = ENV["AAB_PATH"] || default_aab_path
          unless ENV["AAB_PATH"]
            require_env!("ANDROID_KEYSTORE_PATH", "ANDROID_KEYSTORE_PASSWORD", "ANDROID_KEY_ALIAS", "ANDROID_KEY_PASSWORD")
            UI.user_error!("Keystore not found at #{ENV['ANDROID_KEYSTORE_PATH']}") unless File.exist?(ENV["ANDROID_KEYSTORE_PATH"])

            gradle(
              task: "bundle",
              build_type: "Release",
              print_command: false,
              properties: {
                "android.injected.signing.store.file" => ENV["ANDROID_KEYSTORE_PATH"],
                "android.injected.signing.store.password" => ENV["ANDROID_KEYSTORE_PASSWORD"],
                "android.injected.signing.key.alias" => ENV["ANDROID_KEY_ALIAS"],
                "android.injected.signing.key.password" => ENV["ANDROID_KEY_PASSWORD"]
              }
            )
          end
          UI.user_error!("No release AAB at #{aab}. Check AAB_PATH or the Gradle output.") unless File.exist?(aab)
          aab
        end

        platform :android do
          desc "Build a signed release AAB without uploading it"
          lane :build do
            aab = build_signed_aab
            UI.success("Built #{aab}")
          end

          desc "Build a release AAB and upload it to the Play internal track"
          lane :beta do
            require_env!("PLAY_SERVICE_ACCOUNT_JSON")
            aab = build_signed_aab

            upload_to_play_store(
              track: "internal",
              aab: aab,
              json_key_data: ENV["PLAY_SERVICE_ACCOUNT_JSON"],
              skip_upload_metadata: true,
              skip_upload_images: true,
              skip_upload_screenshots: true
            )
          end
        end
        """#

    private static let expoEasJson = #"""
        {
          "cli": {
            "version": ">= 16.0.0"
          },
          "build": {
            "production": {
              "distribution": "store"
            }
          },
          "submit": {
            "production": {}
          }
        }
        """#

    private static let githubAndroidJobYml = #"""
          android:
            runs-on: [self-hosted, kinhin-xcode]
            defaults:
              run:
                working-directory: __DIR__
            steps:
              - uses: actions/checkout@v4
              - uses: ruby/setup-ruby@v1
                with:
                  # fastlane needs Ruby 3.1+; the macOS system Ruby is 2.6. Bundler cache is off because Gemfile.lock lives in the project root.
                  ruby-version: "3.3"
              - uses: actions/setup-java@v4
                with:
                  distribution: temurin
                  java-version: "17"
        __PREBUILD__
              - name: Write upload keystore
                env:
                  KEYSTORE_B64: ${{ secrets.ANDROID_KEYSTORE_BASE64 }}
                run: |
                  printf '%s' "$KEYSTORE_B64" | base64 --decode > "$RUNNER_TEMP/release.keystore"
                  echo "ANDROID_KEYSTORE_PATH=$RUNNER_TEMP/release.keystore" >> "$GITHUB_ENV"
              - run: bundle install
              - run: bundle exec fastlane android ${{ inputs.lane }}
                env:
                  ANDROID_PACKAGE_NAME: ${{ secrets.ANDROID_PACKAGE_NAME }}
                  PLAY_SERVICE_ACCOUNT_JSON: ${{ secrets.PLAY_SERVICE_ACCOUNT_JSON }}
                  ANDROID_KEYSTORE_PASSWORD: ${{ secrets.ANDROID_KEYSTORE_PASSWORD }}
                  ANDROID_KEY_ALIAS: ${{ secrets.ANDROID_KEY_ALIAS }}
                  ANDROID_KEY_PASSWORD: ${{ secrets.ANDROID_KEY_PASSWORD }}
                  CI: "true"
              - name: Remove upload keystore
                if: always()
                run: rm -f "$RUNNER_TEMP/release.keystore"
        """#

    private static let githubHeaderYml = #"""
        # Mobile release workflow for a kinhin runner, written by `kinhin mobile init` to .github/workflows/mobile-release.yml.
        # Manual trigger only, so store uploads never run by accident.
        #
        # Repo secrets used here:
        #   iOS:     ASC_KEY_ID, ASC_KEY_P8 (contents of the .p8 file), ASC_ISSUER_ID, MATCH_GIT_URL,
        #            MATCH_PASSWORD, APPLE_TEAM_ID, APP_IDENTIFIER, IOS_SCHEME
        #   Android: ANDROID_PACKAGE_NAME, PLAY_SERVICE_ACCOUNT_JSON, ANDROID_KEYSTORE_BASE64 (base64 of the
        #            upload keystore), ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD
        name: mobile-release

        on:
          workflow_dispatch:
            inputs:
              lane:
                description: "Lane to run"
                type: choice
                options: [beta, release]
                default: beta

        jobs:
        """#

    private static let githubIosJobYml = #"""
          ios:
            # kinhin-xcode is the Xcode image label. Change it if your pool uses another name.
            runs-on: [self-hosted, kinhin-xcode]
            defaults:
              run:
                working-directory: __DIR__
            steps:
              - uses: actions/checkout@v4
              - uses: ruby/setup-ruby@v1
                with:
                  # fastlane needs Ruby 3.1+; the macOS system Ruby is 2.6. Bundler cache is off because Gemfile.lock lives in the project root.
                  ruby-version: "3.3"
        __PREBUILD__
              - name: Write App Store Connect API key
                env:
                  ASC_KEY_P8: ${{ secrets.ASC_KEY_P8 }}
                run: |
                  mkdir -p "$RUNNER_TEMP/keys"
                  printf '%s' "$ASC_KEY_P8" > "$RUNNER_TEMP/keys/AuthKey.p8"
                  echo "ASC_KEY_FILEPATH=$RUNNER_TEMP/keys/AuthKey.p8" >> "$GITHUB_ENV"
              - run: bundle install
              - name: Install CocoaPods (React Native and Flutter)
                run: if [ -f Podfile ]; then bundle exec pod install; fi
              - run: bundle exec fastlane ios ${{ inputs.lane }}
                env:
                  ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
                  ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
                  MATCH_GIT_URL: ${{ secrets.MATCH_GIT_URL }}
                  MATCH_PASSWORD: ${{ secrets.MATCH_PASSWORD }}
                  APPLE_TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}
                  APP_IDENTIFIER: ${{ secrets.APP_IDENTIFIER }}
                  IOS_SCHEME: ${{ secrets.IOS_SCHEME }}
                  CI: "true"
              - name: Remove API key
                if: always()
                run: rm -rf "$RUNNER_TEMP/keys"

        """#

    private static let githubPrebuildFlutterAndroidYml = #"""
              - name: Flutter SDK
                uses: subosito/flutter-action@v2
                with:
                  channel: stable
              - name: Flutter packages (writes android/local.properties)
                working-directory: __APP__
                run: flutter pub get
        """#

    private static let githubPrebuildFlutterIosYml = #"""
              - name: Flutter SDK
                uses: subosito/flutter-action@v2
                with:
                  channel: stable
              - name: Flutter packages and iOS config
                working-directory: __APP__
                run: |
                  flutter pub get
                  flutter build ios --config-only --release
        """#

    private static let githubPrebuildReactNativeAndroidYml = #"""
              - name: Node.js
                uses: actions/setup-node@v4
                with:
                  node-version: "22"
              - name: JavaScript dependencies
                working-directory: __APP__
                run: |
                  if [ -f yarn.lock ] || [ -f pnpm-lock.yaml ]; then
                    # corepack's default shim directory is often read-only on a runner, so give it a directory the job owns.
                    shims="${RUNNER_TEMP:-$(mktemp -d)}/corepack-bin"
                    mkdir -p "$shims"
                    corepack enable --install-directory "$shims"
                    echo "$shims" >> "${GITHUB_PATH:-/dev/null}"
                    export PATH="$shims:$PATH"
                  fi
                  if [ -f yarn.lock ]; then yarn install --frozen-lockfile
                  elif [ -f pnpm-lock.yaml ]; then pnpm install --frozen-lockfile
                  elif [ -f package-lock.json ]; then npm ci
                  else npm install
                  fi
        """#

    private static let githubPrebuildReactNativeIosYml = #"""
              - name: Node.js
                uses: actions/setup-node@v4
                with:
                  node-version: "22"
              - name: JavaScript dependencies
                working-directory: __APP__
                run: |
                  if [ -f yarn.lock ] || [ -f pnpm-lock.yaml ]; then
                    # corepack's default shim directory is often read-only on a runner, so give it a directory the job owns.
                    shims="${RUNNER_TEMP:-$(mktemp -d)}/corepack-bin"
                    mkdir -p "$shims"
                    corepack enable --install-directory "$shims"
                    echo "$shims" >> "${GITHUB_PATH:-/dev/null}"
                    export PATH="$shims:$PATH"
                  fi
                  if [ -f yarn.lock ]; then yarn install --frozen-lockfile
                  elif [ -f pnpm-lock.yaml ]; then pnpm install --frozen-lockfile
                  elif [ -f package-lock.json ]; then npm ci
                  else npm install
                  fi
        """#

    private static let iosFastlaneAppfile = #"""
        # Who and what to ship. Values come from the environment so nothing personal is committed.
        app_identifier(ENV["APP_IDENTIFIER"]) # e.g. com.example.app
        team_id(ENV["APPLE_TEAM_ID"])         # Developer Portal team ID
        """#

    private static let iosFastlaneFastfile = #"""
        # iOS lanes. Auth uses an App Store Connect API key (no Apple ID password).
        # Secrets and paths come from CI environment variables; see docs/mobile-fastlane.md.
        default_platform(:ios)

        # Stop before any store call when a required variable is missing, with the name of the variable.
        def require_env!(*names)
          missing = names.select { |name| ENV[name].to_s.strip.empty? }
          UI.user_error!("Missing environment variables: #{missing.join(', ')}. See docs/mobile-fastlane.md#secrets") unless missing.empty?
        end

        # An empty secret (for example an unset repository secret) means "use the default", not an empty scheme name.
        def presence(value)
          value.to_s.strip.empty? ? nil : value
        end

        platform :ios do
          before_all do
            require_env!("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_FILEPATH", "APP_IDENTIFIER", "APPLE_TEAM_ID")
            UI.user_error!("ASC_KEY_FILEPATH does not exist: #{ENV['ASC_KEY_FILEPATH']}") unless File.exist?(ENV["ASC_KEY_FILEPATH"])

            setup_ci if ENV["CI"] # temporary keychain on CI runners

            @api_key = app_store_connect_api_key(
              key_id: ENV["ASC_KEY_ID"],
              issuer_id: ENV["ASC_ISSUER_ID"],
              key_filepath: ENV["ASC_KEY_FILEPATH"]
            )
          end

          desc "Build a signed IPA and upload it to TestFlight"
          lane :beta do
            require_env!("MATCH_GIT_URL", "MATCH_PASSWORD")
            match(api_key: @api_key, readonly: true)

            build_app(
              scheme: presence(ENV["IOS_SCHEME"]),
              export_method: "app-store"
            )

            upload_to_testflight(
              api_key: @api_key,
              skip_waiting_for_build_processing: true
            )
          end

          desc "Upload the latest processed build to the App Store (metadata and screenshots skipped)"
          lane :release do
            upload_to_app_store(
              api_key: @api_key,
              skip_metadata: true,
              skip_screenshots: true,
              submit_for_review: false
            )
          end
        end
        """#

    private static let iosFastlaneMatchfile = #"""
        # Code signing via fastlane match. The certificates repo is private and encrypted with MATCH_PASSWORD.
        git_url(ENV["MATCH_GIT_URL"])         # e.g. git@github.com:your-org/certificates.git
        storage_mode("git")
        type("appstore")
        readonly(true)                        # CI never creates or rotates certificates; run `fastlane match appstore` locally
        """#

}
