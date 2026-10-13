// Generated from templates/mobile/ by scripts/mobile-templates-embed.py. Do not edit by hand:
// MobileScaffoldTests fails when this file and the template files differ.

enum MobileTemplates {
    /// Template text by its path under templates/mobile/.
    static let files: [String: String] = [
        "Gemfile": Gemfile,
        "android/app/src/androidTest/java/screenshots/ScreenshotTest.java":
            androidAppSrcAndroidTestJavaScreenshotsScreenshotTestJava,
        "android/app/src/debug/AndroidManifest.xml": androidAppSrcDebugAndroidManifestXml,
        "android/fastlane/Appfile": androidFastlaneAppfile,
        "android/fastlane/Fastfile": androidFastlaneFastfile,
        "android/fastlane/Screengrabfile": androidFastlaneScreengrabfile,
        "expo/eas.json": expoEasJson,
        "github/android.job.yml": githubAndroidJobYml,
        "github/header.yml": githubHeaderYml,
        "github/ios.job.yml": githubIosJobYml,
        "github/prebuild/capacitor-android.yml": githubPrebuildCapacitorAndroidYml,
        "github/prebuild/capacitor-ios.yml": githubPrebuildCapacitorIosYml,
        "github/prebuild/flutter-android.yml": githubPrebuildFlutterAndroidYml,
        "github/prebuild/flutter-ios.yml": githubPrebuildFlutterIosYml,
        "github/prebuild/kmp-android.yml": githubPrebuildKmpAndroidYml,
        "github/prebuild/kmp-ios.yml": githubPrebuildKmpIosYml,
        "github/prebuild/maui-android.yml": githubPrebuildMauiAndroidYml,
        "github/prebuild/maui-ios.yml": githubPrebuildMauiIosYml,
        "github/prebuild/react-native-android.yml": githubPrebuildReactNativeAndroidYml,
        "github/prebuild/react-native-ios.yml": githubPrebuildReactNativeIosYml,
        "ios/UITests/ScreenshotTests.swift": iosUITestsScreenshotTestsSwift,
        "ios/UITests/SnapshotHelper.swift": iosUITestsSnapshotHelperSwift,
        "ios/fastlane/Appfile": iosFastlaneAppfile,
        "ios/fastlane/Fastfile": iosFastlaneFastfile,
        "ios/fastlane/Framefile.json": iosFastlaneFramefileJson,
        "ios/fastlane/Matchfile": iosFastlaneMatchfile,
        "ios/fastlane/Snapfile": iosFastlaneSnapfile,
    ]

    private static let Gemfile = #"""
        # Pinned fastlane. Run lanes with `bundle exec fastlane <lane>` from ios/ or android/.
        # Bump the pin deliberately: `bundle update fastlane` and commit Gemfile.lock.
        source "https://rubygems.org"

        gem "fastlane", "~> 2.240"
        """#

    private static let androidAppSrcAndroidTestJavaScreenshotsScreenshotTestJava = #"""
        package screenshots;

        import android.app.Instrumentation;
        import android.content.Intent;
        import android.os.SystemClock;

        import androidx.test.ext.junit.runners.AndroidJUnit4;
        import androidx.test.platform.app.InstrumentationRegistry;

        import org.junit.ClassRule;
        import org.junit.Test;
        import org.junit.runner.RunWith;

        import tools.fastlane.screengrab.Screengrab;
        import tools.fastlane.screengrab.locale.LocaleTestRule;

        // One test per screen you want in the store. Call Screengrab.screenshot() with a name that sorts in the order you want.
        // LocaleTestRule switches the device locale for each locale in the Screengrabfile. See docs/mobile-screenshots.md.
        @RunWith(AndroidJUnit4.class)
        public class ScreenshotTest {
            @ClassRule
            public static final LocaleTestRule localeTestRule = new LocaleTestRule();

            @Test
            public void captureHome() {
                Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
                Intent launch = instrumentation.getTargetContext().getPackageManager()
                        .getLaunchIntentForPackage(instrumentation.getTargetContext().getPackageName());
                if (launch == null) {
                    throw new IllegalStateException("the app has no launcher activity to start for screenshots");
                }
                // Some apps ask for Bluetooth or location on first launch, and the system dialog covers the screen in the capture.
                // Granting a permission the app does not declare is ignored, so this is safe for every app.
                String packageName = instrumentation.getTargetContext().getPackageName();
                for (String permission : new String[] {
                        "android.permission.BLUETOOTH_SCAN",
                        "android.permission.BLUETOOTH_CONNECT",
                        "android.permission.ACCESS_FINE_LOCATION"}) {
                    instrumentation.getUiAutomation().grantRuntimePermission(packageName, permission);
                }
                launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                instrumentation.getTargetContext().startActivity(launch);
                instrumentation.waitForIdleSync();
                // Flutter lays out its view after the locale switch restarts the activity. A capture taken earlier is blank
                // (logcat: "FlutterRenderer: Width is zero"), so give the first frame time to draw.
                SystemClock.sleep(4000);
                Screengrab.screenshot("01-home");
            }
        }
        """#

    private static let androidAppSrcDebugAndroidManifestXml = #"""
        <?xml version="1.0" encoding="utf-8"?>
        <manifest xmlns:android="http://schemas.android.com/apk/res/android">
            <!-- Screengrab needs these in debug builds to keep the screen on and write screenshots. See docs/mobile-screenshots.md. -->
            <uses-permission android:name="android.permission.DISABLE_KEYGUARD" />
            <uses-permission android:name="android.permission.WAKE_LOCK" />
            <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" />
            <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" />
            <uses-permission android:name="android.permission.CHANGE_CONFIGURATION" />
        </manifest>
        """#

    private static let androidFastlaneAppfile = #"""
        # Google Play package name. Set from the environment so nothing personal is committed.
        package_name(ENV["ANDROID_PACKAGE_NAME"]) # e.g. com.example.app
        """#

    private static let androidFastlaneFastfile = #"""
        # Android lanes. Uploads go through the Google Play Developer API with a service account.
        # AAB_PATH skips the Gradle build when another step already built the bundle.
        # `build` makes a signed bundle without uploading it; CI and the e2e use it to check signing.
        require "shellwords"

        default_platform(:android)

        # Stop before any store call when a required variable is missing, with the name of the variable.
        def require_env!(*names)
          missing = names.select { |name| ENV[name].to_s.strip.empty? }
          UI.user_error!("Missing environment variables: #{missing.join(', ')}. See https://kinhin.dev/guide/mobile-fastlane#secrets") unless missing.empty?
        end

        # The project folder (the parent of fastlane/). fastlane runs lanes from fastlane/, so build paths from here.
        def project_root
          File.expand_path("..", __dir__)
        end

        # A value the environment set to something other than blank, or nil. Empty repository variables count as unset.
        def presence(value)
          value.to_s.strip.empty? ? nil : value
        end

        # The folder that holds the Android project: android/ in Flutter and React Native, the app root otherwise.
        # Built from this Fastfile's location, because fastlane's working directory is not reliable for relative paths.
        def android_root
          File.expand_path("..", __dir__)
        end

        # The Gradle folder and module to build. ANDROID_GRADLE_DIR is relative to android_root (Kotlin Multiplatform keeps
        # its Gradle build at the top level, for example). ANDROID_GRADLE_MODULE names the module that holds the app (default app).
        def gradle_dir
          presence(ENV["ANDROID_GRADLE_DIR"]) ? File.expand_path(ENV["ANDROID_GRADLE_DIR"], android_root) : android_root
        end

        def gradle_module
          presence(ENV["ANDROID_GRADLE_MODULE"]) || "app"
        end

        # A Gradle task for the app module, with the module prefix when one is set (":androidApp:assembleDebug").
        def gradle_task(name)
          presence(ENV["ANDROID_GRADLE_MODULE"]) ? ":#{gradle_module}:#{name}" : name
        end

        # The project folder option for gradle(), set only when the Gradle root is not the Android folder.
        def gradle_project_options
          presence(ENV["ANDROID_GRADLE_DIR"]) ? { project_dir: gradle_dir } : {}
        end

        # Gradle writes the bundle under the project's build folder. Flutter sets that folder to <flutter root>/build, one
        # level above android/, so a pubspec.yaml there means a Flutter project.
        def default_aab_path
          flutter_root = File.expand_path("..", android_root)
          if File.exist?(File.join(flutter_root, "pubspec.yaml"))
            File.join(flutter_root, "build/app/outputs/bundle/release/app-release.aab")
          else
            File.join(gradle_dir, gradle_module, "build/outputs/bundle/release/#{gradle_module}-release.aab")
          end
        end

        # The debug app APK and the instrumented test APK that the screenshots lane builds. Flutter's Gradle build writes them
        # under <flutter root>/build, like the bundle above.
        def screengrab_apk_paths
          flutter_root = File.expand_path("..", android_root)
          if File.exist?(File.join(flutter_root, "pubspec.yaml"))
            outputs = File.join(flutter_root, "build/app/outputs")
            app_module = "app"
          else
            outputs = File.join(gradle_dir, gradle_module, "build/outputs")
            app_module = gradle_module
          end
          [File.join(outputs, "apk/debug/#{app_module}-debug.apk"), File.join(outputs, "apk/androidTest/debug/#{app_module}-debug-androidTest.apk")]
        end

        # .NET MAUI: dotnet publish builds and signs the AAB with the upload keystore. MAUI_PROJECT is the .csproj, relative to the
        # app folder. Requires the same keystore variables as the Gradle build.
        def build_maui_aab
          project = File.expand_path(ENV["MAUI_PROJECT"], File.expand_path("..", android_root))
          require_env!("ANDROID_KEYSTORE_PATH", "ANDROID_KEYSTORE_PASSWORD", "ANDROID_KEY_ALIAS", "ANDROID_KEY_PASSWORD")
          framework = File.read(project)[/net[0-9.]+-android/] || UI.user_error!("No net*-android target in #{project}")
          # The passwords reach MSBuild through the environment (it reads environment variables as properties), so they are
          # not in the process argument list that other processes on the runner can read.
          ENV["AndroidSigningStorePass"] = ENV["ANDROID_KEYSTORE_PASSWORD"]
          ENV["AndroidSigningKeyPass"] = ENV["ANDROID_KEY_PASSWORD"]
          begin
            sh(Shellwords.join(["dotnet", "publish", project, "-f", framework, "-c", "Release", "-p:AndroidPackageFormat=aab",
                                "-p:AndroidKeyStore=true", "-p:AndroidSigningKeyStore=#{ENV['ANDROID_KEYSTORE_PATH']}",
                                "-p:AndroidSigningKeyAlias=#{ENV['ANDROID_KEY_ALIAS']}"]), log: false)
          ensure
            ENV.delete("AndroidSigningStorePass")
            ENV.delete("AndroidSigningKeyPass")
          end
          aab = Dir.glob(File.join(File.dirname(project), "bin/**/*.aab")).max_by { |f| File.mtime(f) }
          UI.user_error!("dotnet publish wrote no AAB under #{File.dirname(project)}/bin") unless aab
          UI.success("Built #{aab}")
          aab
        end

        # Returns the path of a signed release bundle, building it with Gradle unless AAB_PATH is set.
        def build_signed_aab
          return build_maui_aab if ENV["AAB_PATH"].to_s.strip.empty? && presence(ENV["MAUI_PROJECT"])
          aab = ENV["AAB_PATH"] || default_aab_path
          unless ENV["AAB_PATH"]
            require_env!("ANDROID_KEYSTORE_PATH", "ANDROID_KEYSTORE_PASSWORD", "ANDROID_KEY_ALIAS", "ANDROID_KEY_PASSWORD")
            UI.user_error!("Keystore not found at #{ENV['ANDROID_KEYSTORE_PATH']}") unless File.exist?(ENV["ANDROID_KEYSTORE_PATH"])

            # The default task builds every module's bundle, which is what a one-module project needs. A named module builds only its own.
            gradle_options = {
              task: presence(ENV["ANDROID_GRADLE_MODULE"]) ? gradle_task("bundle") : "bundle",
              build_type: "Release",
              print_command: false,
              properties: {
                "android.injected.signing.store.file" => ENV["ANDROID_KEYSTORE_PATH"],
                "android.injected.signing.store.password" => ENV["ANDROID_KEYSTORE_PASSWORD"],
                "android.injected.signing.key.alias" => ENV["ANDROID_KEY_ALIAS"],
                "android.injected.signing.key.password" => ENV["ANDROID_KEY_PASSWORD"]
              }
            }
            gradle_options[:project_dir] = gradle_dir if presence(ENV["ANDROID_GRADLE_DIR"])
            gradle(gradle_options)
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

          desc "Capture localized screenshots with screengrab. UPLOAD_SCREENSHOTS=1 uploads them to Google Play"
          lane :screenshots do
            # Screengrabfile is written with the screenshot setup. A project without it (for example .NET MAUI) has no instrumented tests to run.
            UI.user_error!("No fastlane/Screengrabfile here, so screenshots are not set up. Add the instrumented tests and Screengrabfile to use this lane.") unless File.exist?(File.expand_path("Screengrabfile", __dir__))
            # screengrab runs the instrumented tests but does not build the APKs, so build them first.
            gradle(task: gradle_task("assemble"), build_type: "Debug", print_command: false, **gradle_project_options)
            gradle(task: gradle_task("assembleDebugAndroidTest"), print_command: false, **gradle_project_options)
            app_apk, tests_apk = screengrab_apk_paths
            screengrab(app_apk_path: app_apk, tests_apk_path: tests_apk)

            metadata = File.join(project_root, "fastlane/metadata/android")
            UI.user_error!("screengrab wrote no screenshots. Check the instrumented tests and the Screengrabfile.") if Dir.glob(File.join(metadata, "**/*.png")).empty?

            if ENV["UPLOAD_SCREENSHOTS"] == "1"
              require_env!("PLAY_SERVICE_ACCOUNT_JSON")

              upload_to_play_store(
                json_key_data: ENV["PLAY_SERVICE_ACCOUNT_JSON"],
                metadata_path: metadata,
                skip_upload_apk: true,
                skip_upload_aab: true,
                skip_upload_metadata: true,
                skip_upload_changelogs: true,
                skip_upload_images: false,
                skip_upload_screenshots: false
              )
            end
          end
        end
        """#

    private static let androidFastlaneScreengrabfile = #"""
        # Screenshot settings for `fastlane screengrab` (Android). Reference: https://docs.fastlane.tools/actions/screengrab/
        # Values can be overridden from the environment, so CI can change them without editing this file.

        # The application ID of the app under test (the applicationId in app/build.gradle).
        app_package_name(ENV["ANDROID_PACKAGE_NAME"])

        # Locales to capture. Each one gets its own folder under output_directory.
        locales(ENV["SCREENGRAB_LOCALES"].to_s.split(",").map(&:strip).reject(&:empty?).then { |list| list.empty? ? ["en-US"] : list })

        # Phone, sevenInch, tenInch, tv or wear. Matches the Google Play screenshot type.
        device_type(ENV["SCREENGRAB_DEVICE_TYPE"].to_s.strip.empty? ? "phone" : ENV["SCREENGRAB_DEVICE_TYPE"])

        # Where screenshots are written. The screenshots lane uploads from the same place.
        output_directory("./fastlane/metadata/android")

        # Remove earlier screenshots first, so a screen you deleted does not stay in the upload.
        clear_previous_screenshots(true)
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
            # Android has no release lane yet, so the release choice runs only the iOS job.
            if: inputs.lane != 'release'
            runs-on: [self-hosted, kinhin-xcode]
            defaults:
              run:
                working-directory: __DIR__
            steps:
              - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0
              - uses: ruby/setup-ruby@651ff0d62c5c79bed6d53ec518387aae20e72c1a # v1.329.0
                with:
                  # fastlane needs Ruby 3.2+; the macOS system Ruby is 2.6. Bundler cache is off because Gemfile.lock lives in the project root.
                  ruby-version: "3.3"
              - uses: actions/setup-java@cf277c60eb25467037889841efdb72551f06f6c3 # v4.9.1
                with:
                  distribution: temurin
                  java-version: ${{ vars.JAVA_VERSION || '__JAVA_VERSION__' }}
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
                  # Screenshot settings, read from repository variables (not secrets). Empty means the default.
                  UPLOAD_SCREENSHOTS: ${{ vars.UPLOAD_SCREENSHOTS }}
                  SCREENGRAB_LOCALES: ${{ vars.SCREENGRAB_LOCALES }}
                  SCREENGRAB_DEVICE_TYPE: ${{ vars.SCREENGRAB_DEVICE_TYPE }}
              # Screenshots are written inside the VM, which is deleted when the job ends. Keep them as an artifact, even when the
              # lane fails, so the captures can be inspected. __DIR__ is relative to the workspace, which artifact paths need.
              - name: Upload screenshots
                if: ${{ always() && inputs.lane == 'screenshots' }}
                uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4.6.2
                with:
                  name: android-screenshots
                  path: __DIR__/fastlane/metadata/android
                  if-no-files-found: warn
                  retention-days: 14
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
                options: [beta, release, screenshots]
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
              - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0
              - uses: ruby/setup-ruby@651ff0d62c5c79bed6d53ec518387aae20e72c1a # v1.329.0
                with:
                  # fastlane needs Ruby 3.2+; the macOS system Ruby is 2.6. Bundler cache is off because Gemfile.lock lives in the project root.
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
                  # Screenshot settings, read from repository variables (not secrets). Empty means the default.
                  FRAME_SCREENSHOTS: ${{ vars.FRAME_SCREENSHOTS }}
                  UPLOAD_SCREENSHOTS: ${{ vars.UPLOAD_SCREENSHOTS }}
                  SNAPSHOT_DEVICES: ${{ vars.SNAPSHOT_DEVICES }}
                  SNAPSHOT_LANGUAGES: ${{ vars.SNAPSHOT_LANGUAGES }}
              # Screenshots are written inside the VM, which is deleted when the job ends. Keep them as an artifact, even when the
              # lane fails, so the captures can be inspected. __DIR__ is relative to the workspace, which artifact paths need.
              - name: Upload screenshots
                if: ${{ always() && inputs.lane == 'screenshots' }}
                uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4.6.2
                with:
                  name: ios-screenshots
                  path: __DIR__/fastlane/screenshots
                  if-no-files-found: warn
                  retention-days: 14
              - name: Remove API key
                if: always()
                run: rm -rf "$RUNNER_TEMP/keys"

        """#

    private static let githubPrebuildCapacitorAndroidYml = #"""
              - name: Node.js
                uses: actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020 # v4.4.0
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
              - name: Build the web app and copy it into the Android project
                working-directory: __APP__
                run: |
                  npm run build
                  npx cap sync android
        """#

    private static let githubPrebuildCapacitorIosYml = #"""
              - name: Node.js
                uses: actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020 # v4.4.0
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
              - name: Build the web app and copy it into the iOS project
                # Capacitor 8 resolves the iOS packages with Swift Package Manager, so there is no Podfile to install.
                working-directory: __APP__
                run: |
                  npm run build
                  npx cap sync ios
              - name: Point fastlane at the Capacitor Xcode project
                # Capacitor keeps its project in ios/App, one level below the fastlane folder (ios/).
                run: echo "IOS_PROJECT=App/App.xcodeproj" >> "$GITHUB_ENV"
        """#

    private static let githubPrebuildFlutterAndroidYml = #"""
              - name: Flutter SDK
                uses: subosito/flutter-action@1a449444c387b1966244ae4d4f8c696479add0b2 # v2.23.0
                with:
                  channel: stable
              - name: Flutter packages (writes android/local.properties)
                working-directory: __APP__
                run: flutter pub get
        """#

    private static let githubPrebuildFlutterIosYml = #"""
              - name: Flutter SDK
                uses: subosito/flutter-action@1a449444c387b1966244ae4d4f8c696479add0b2 # v2.23.0
                with:
                  channel: stable
              - name: Flutter packages and iOS config
                working-directory: __APP__
                run: |
                  flutter pub get
                  flutter build ios --config-only --release
        """#

    private static let githubPrebuildKmpAndroidYml = #"""
              - name: Gradle project for the Android module
                # The Gradle root is the repository root, one folder above androidApp/, and the module is androidApp.
                run: |
                  echo "ANDROID_GRADLE_DIR=.." >> "$GITHUB_ENV"
                  echo "ANDROID_GRADLE_MODULE=androidApp" >> "$GITHUB_ENV"
        """#

    private static let githubPrebuildKmpIosYml = #"""
              - name: Java for the shared Kotlin module
                # The Xcode build phase runs Gradle to build the shared framework, so Gradle needs a JDK on the runner.
                uses: actions/setup-java@cf277c60eb25467037889841efdb72551f06f6c3 # v4.9.1
                with:
                  distribution: temurin
                  java-version: "17"
        """#

    private static let githubPrebuildMauiAndroidYml = #"""
              - name: .NET SDK and the MAUI workload
                uses: actions/setup-dotnet@d4c94342e560b34958eacfc5d055d21461ed1c5d # v5.0.0
                with:
                  dotnet-version: ${{ vars.DOTNET_VERSION || '10.0.x' }}
              - name: Install the MAUI workload
                run: dotnet workload install maui
              - name: Point fastlane at the MAUI project
                # The lane runs dotnet publish with the upload keystore, which the job writes below.
                working-directory: __APP__
                run: |
                  project="$(find . -maxdepth 2 -name '*.csproj' | head -1)"
                  echo "MAUI_PROJECT=$project" >> "$GITHUB_ENV"
        """#

    private static let githubPrebuildMauiIosYml = #"""
              - name: .NET SDK and the MAUI workload
                uses: actions/setup-dotnet@d4c94342e560b34958eacfc5d055d21461ed1c5d # v5.0.0
                with:
                  dotnet-version: ${{ vars.DOTNET_VERSION || '10.0.x' }}
              - name: Install the MAUI workload
                run: dotnet workload install maui
              - name: Point fastlane at the MAUI project
                # The lane runs dotnet publish after match has installed the signing certificate.
                working-directory: __APP__
                run: |
                  project="$(find . -maxdepth 2 -name '*.csproj' | head -1)"
                  echo "MAUI_PROJECT=$project" >> "$GITHUB_ENV"
        """#

    private static let githubPrebuildReactNativeAndroidYml = #"""
              - name: Node.js
                uses: actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020 # v4.4.0
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
                uses: actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020 # v4.4.0
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

    private static let iosUITestsScreenshotTestsSwift = #"""
        import XCTest

        // One screenshot per screen you want in the store. Add a test method for each screen, and call snapshot() with a name
        // that sorts in the order you want (for example "01-home"). See docs/mobile-screenshots.md.
        // The snapshot helpers are main-actor isolated, so the test class must be too.
        @MainActor
        final class ScreenshotTests: XCTestCase {
            override func setUpWithError() throws {
                continueAfterFailure = false
                let app = XCUIApplication()
                setupSnapshot(app)  // from SnapshotHelper.swift: lets fastlane set the language and device
                // The app reads this with Settings.get('KinhinLanguage'), so it knows the language without relying on AppleLanguages.
                app.launchArguments += ["-KinhinLanguage", Snapshot.deviceLanguage]
                app.launch()
            }

            func testHome() {
                snapshot("01-home")
            }
        }
        """#

    private static let iosUITestsSnapshotHelperSwift = #"""
        //
        //  SnapshotHelper.swift
        //  Example
        //
        //  Created by Felix Krause on 10/8/15.
        //

        // -----------------------------------------------------
        // IMPORTANT: When modifying this file, make sure to
        //            increment the version number at the very
        //            bottom of the file to notify users about
        //            the new SnapshotHelper.swift
        // -----------------------------------------------------

        import Foundation
        import XCTest

        @MainActor
        func setupSnapshot(_ app: XCUIApplication, waitForAnimations: Bool = true) {
            Snapshot.setupSnapshot(app, waitForAnimations: waitForAnimations)
        }

        @MainActor
        func snapshot(_ name: String, waitForLoadingIndicator: Bool) {
            if waitForLoadingIndicator {
                Snapshot.snapshot(name)
            } else {
                Snapshot.snapshot(name, timeWaitingForIdle: 0)
            }
        }

        /// - Parameters:
        ///   - name: The name of the snapshot
        ///   - timeout: Amount of seconds to wait until the network loading indicator disappears. Pass `0` if you don't want to wait.
        @MainActor
        func snapshot(_ name: String, timeWaitingForIdle timeout: TimeInterval = 20) {
            Snapshot.snapshot(name, timeWaitingForIdle: timeout)
        }

        enum SnapshotError: Error, CustomDebugStringConvertible {
            case cannotFindSimulatorHomeDirectory
            case cannotRunOnPhysicalDevice

            var debugDescription: String {
                switch self {
                case .cannotFindSimulatorHomeDirectory:
                    return "Couldn't find simulator home location. Please, check SIMULATOR_HOST_HOME env variable."
                case .cannotRunOnPhysicalDevice:
                    return "Can't use Snapshot on a physical device."
                }
            }
        }

        @objcMembers
        @MainActor
        open class Snapshot: NSObject {
            static var app: XCUIApplication?
            static var waitForAnimations = true
            static var cacheDirectory: URL?
            static var screenshotsDirectory: URL? {
                return cacheDirectory?.appendingPathComponent("screenshots", isDirectory: true)
            }
            static var deviceLanguage = ""
            static var currentLocale = ""

            open class func setupSnapshot(_ app: XCUIApplication, waitForAnimations: Bool = true) {

                Snapshot.app = app
                Snapshot.waitForAnimations = waitForAnimations

                do {
                    let cacheDir = try getCacheDirectory()
                    Snapshot.cacheDirectory = cacheDir
                    setLanguage(app)
                    setLocale(app)
                    setLaunchArguments(app)
                } catch let error {
                    NSLog(error.localizedDescription)
                }
            }

            class func setLanguage(_ app: XCUIApplication) {
                guard let cacheDirectory = self.cacheDirectory else {
                    NSLog("CacheDirectory is not set - probably running on a physical device?")
                    return
                }

                let path = cacheDirectory.appendingPathComponent("language.txt")

                do {
                    let trimCharacterSet = CharacterSet.whitespacesAndNewlines
                    deviceLanguage = try String(contentsOf: path, encoding: .utf8).trimmingCharacters(in: trimCharacterSet)
                    app.launchArguments += ["-AppleLanguages", "(\(deviceLanguage))"]
                } catch {
                    NSLog("Couldn't detect/set language...")
                }
            }

            class func setLocale(_ app: XCUIApplication) {
                guard let cacheDirectory = self.cacheDirectory else {
                    NSLog("CacheDirectory is not set - probably running on a physical device?")
                    return
                }

                let path = cacheDirectory.appendingPathComponent("locale.txt")

                do {
                    let trimCharacterSet = CharacterSet.whitespacesAndNewlines
                    currentLocale = try String(contentsOf: path, encoding: .utf8).trimmingCharacters(in: trimCharacterSet)
                } catch {
                    NSLog("Couldn't detect/set locale...")
                }

                if currentLocale.isEmpty && !deviceLanguage.isEmpty {
                    currentLocale = Locale(identifier: deviceLanguage).identifier
                }

                if !currentLocale.isEmpty {
                    app.launchArguments += ["-AppleLocale", "\"\(currentLocale)\""]
                }
            }

            class func setLaunchArguments(_ app: XCUIApplication) {
                guard let cacheDirectory = self.cacheDirectory else {
                    NSLog("CacheDirectory is not set - probably running on a physical device?")
                    return
                }

                let path = cacheDirectory.appendingPathComponent("snapshot-launch_arguments.txt")
                app.launchArguments += ["-FASTLANE_SNAPSHOT", "YES", "-ui_testing"]

                do {
                    let launchArguments = try String(contentsOf: path, encoding: String.Encoding.utf8)
                    let regex = try NSRegularExpression(pattern: "(\\\".+?\\\"|\\S+)", options: [])
                    let matches = regex.matches(in: launchArguments, options: [], range: NSRange(location: 0, length: launchArguments.count))
                    let results = matches.map { result -> String in
                        (launchArguments as NSString).substring(with: result.range)
                    }
                    app.launchArguments += results
                } catch {
                    NSLog("Couldn't detect/set launch_arguments...")
                }
            }

            open class func snapshot(_ name: String, timeWaitingForIdle timeout: TimeInterval = 20) {
                if timeout > 0 {
                    waitForLoadingIndicatorToDisappear(within: timeout)
                }

                NSLog("snapshot: \(name)") // more information about this, check out https://docs.fastlane.tools/actions/snapshot/#how-does-it-work

                if Snapshot.waitForAnimations {
                    sleep(1) // Waiting for the animation to be finished (kind of)
                }

                #if os(OSX)
                    guard let app = self.app else {
                        NSLog("XCUIApplication is not set. Please call setupSnapshot(app) before snapshot().")
                        return
                    }

                    app.typeKey(XCUIKeyboardKeySecondaryFn, modifierFlags: [])
                #else

                    guard self.app != nil else {
                        NSLog("XCUIApplication is not set. Please call setupSnapshot(app) before snapshot().")
                        return
                    }

                    let screenshot = XCUIScreen.main.screenshot()
                    #if os(iOS) && !targetEnvironment(macCatalyst)
                    let image = XCUIDevice.shared.orientation.isLandscape ?  fixLandscapeOrientation(image: screenshot.image) : screenshot.image
                    #else
                    let image = screenshot.image
                    #endif

                    guard var simulator = ProcessInfo().environment["SIMULATOR_DEVICE_NAME"], let screenshotsDir = screenshotsDirectory else { return }

                    do {
                        // The simulator name contains "Clone X of " inside the screenshot file when running parallelized UI Tests on concurrent devices
                        let regex = try NSRegularExpression(pattern: "Clone [0-9]+ of ")
                        let range = NSRange(location: 0, length: simulator.count)
                        simulator = regex.stringByReplacingMatches(in: simulator, range: range, withTemplate: "")

                        let path = screenshotsDir.appendingPathComponent("\(simulator)-\(name).png")
                        #if swift(<5.0)
                            try UIImagePNGRepresentation(image)?.write(to: path, options: .atomic)
                        #else
                            try image.pngData()?.write(to: path, options: .atomic)
                        #endif
                    } catch let error {
                        NSLog("Problem writing screenshot: \(name) to \(screenshotsDir)/\(simulator)-\(name).png")
                        NSLog(error.localizedDescription)
                    }
                #endif
            }

            class func fixLandscapeOrientation(image: UIImage) -> UIImage {
                #if os(watchOS)
                    return image
                #else
                    if #available(iOS 10.0, *) {
                        let format = UIGraphicsImageRendererFormat()
                        format.scale = image.scale
                        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
                        return renderer.image { context in
                            image.draw(in: CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height))
                        }
                    } else {
                        return image
                    }
                #endif
            }

            class func waitForLoadingIndicatorToDisappear(within timeout: TimeInterval) {
                #if os(tvOS)
                    return
                #endif

                guard let app = self.app else {
                    NSLog("XCUIApplication is not set. Please call setupSnapshot(app) before snapshot().")
                    return
                }

                let networkLoadingIndicator = app.otherElements.deviceStatusBars.networkLoadingIndicators.element
                let networkLoadingIndicatorDisappeared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: networkLoadingIndicator)
                _ = XCTWaiter.wait(for: [networkLoadingIndicatorDisappeared], timeout: timeout)
            }

            class func getCacheDirectory() throws -> URL {
                let cachePath = "Library/Caches/tools.fastlane"
                // on OSX config is stored in /Users/<username>/Library
                // and on iOS/tvOS/WatchOS it's in simulator's home dir
                #if os(OSX)
                    let homeDir = URL(fileURLWithPath: NSHomeDirectory())
                    return homeDir.appendingPathComponent(cachePath)
                #elseif arch(i386) || arch(x86_64) || arch(arm64)
                    guard let simulatorHostHome = ProcessInfo().environment["SIMULATOR_HOST_HOME"] else {
                        throw SnapshotError.cannotFindSimulatorHomeDirectory
                    }
                    let homeDir = URL(fileURLWithPath: simulatorHostHome)
                    return homeDir.appendingPathComponent(cachePath)
                #else
                    throw SnapshotError.cannotRunOnPhysicalDevice
                #endif
            }
        }

        private extension XCUIElementAttributes {
            var isNetworkLoadingIndicator: Bool {
                if hasAllowListedIdentifier { return false }

                let hasOldLoadingIndicatorSize = frame.size == CGSize(width: 10, height: 20)
                let hasNewLoadingIndicatorSize = frame.size.width.isBetween(46, and: 47) && frame.size.height.isBetween(2, and: 3)

                return hasOldLoadingIndicatorSize || hasNewLoadingIndicatorSize
            }

            var hasAllowListedIdentifier: Bool {
                let allowListedIdentifiers = ["GeofenceLocationTrackingOn", "StandardLocationTrackingOn"]

                return allowListedIdentifiers.contains(identifier)
            }

            func isStatusBar(_ deviceWidth: CGFloat) -> Bool {
                if elementType == .statusBar { return true }
                guard frame.origin == .zero else { return false }

                let oldStatusBarSize = CGSize(width: deviceWidth, height: 20)
                let newStatusBarSize = CGSize(width: deviceWidth, height: 44)

                return [oldStatusBarSize, newStatusBarSize].contains(frame.size)
            }
        }

        private extension XCUIElementQuery {
            var networkLoadingIndicators: XCUIElementQuery {
                let isNetworkLoadingIndicator = NSPredicate { (evaluatedObject, _) in
                    guard let element = evaluatedObject as? XCUIElementAttributes else { return false }

                    return element.isNetworkLoadingIndicator
                }

                return self.containing(isNetworkLoadingIndicator)
            }

            @MainActor
            var deviceStatusBars: XCUIElementQuery {
                guard let app = Snapshot.app else {
                    fatalError("XCUIApplication is not set. Please call setupSnapshot(app) before snapshot().")
                }

                let deviceWidth = app.windows.firstMatch.frame.width

                let isStatusBar = NSPredicate { (evaluatedObject, _) in
                    guard let element = evaluatedObject as? XCUIElementAttributes else { return false }

                    return element.isStatusBar(deviceWidth)
                }

                return self.containing(isStatusBar)
            }
        }

        private extension CGFloat {
            func isBetween(_ numberA: CGFloat, and numberB: CGFloat) -> Bool {
                return numberA...numberB ~= self
            }
        }

        // Please don't remove the lines below
        // They are used to detect outdated configuration files
        // SnapshotHelperVersion [1.30]
        """#

    private static let iosFastlaneAppfile = #"""
        # Who and what to ship. Values come from the environment so nothing personal is committed.
        app_identifier(ENV["APP_IDENTIFIER"]) # e.g. com.example.app
        team_id(ENV["APPLE_TEAM_ID"])         # Developer Portal team ID
        """#

    private static let iosFastlaneFastfile = #"""
        # iOS lanes. Auth uses an App Store Connect API key (no Apple ID password).
        # Secrets and paths come from CI environment variables; see https://kinhin.dev/guide/mobile-fastlane.
        require "shellwords"

        default_platform(:ios)

        # Stop before any store call when a required variable is missing, with the name of the variable.
        def require_env!(*names)
          missing = names.select { |name| ENV[name].to_s.strip.empty? }
          UI.user_error!("Missing environment variables: #{missing.join(', ')}. See https://kinhin.dev/guide/mobile-fastlane#secrets") unless missing.empty?
        end

        # The project folder (the parent of fastlane/). fastlane runs lanes from fastlane/, so build paths from here.
        def project_root
          File.expand_path("..", __dir__)
        end

        # An empty secret (for example an unset repository secret) means "use the default", not an empty scheme name.
        def presence(value)
          value.to_s.strip.empty? ? nil : value
        end

        # frameit needs ImageMagick. Install it with Homebrew when it is missing, so enabling frames just works. Homebrew itself
        # is not installed by this lane: that needs an admin password, so the lane stops with a clear message instead.
        def ensure_imagemagick
          return if system("command -v magick >/dev/null 2>&1") || system("command -v convert >/dev/null 2>&1")

          UI.user_error!("frameit needs ImageMagick, and Homebrew is not installed to install it. Install Homebrew from https://brew.sh, or install ImageMagick yourself.") unless system("command -v brew >/dev/null 2>&1")
          UI.important("ImageMagick is missing; installing it with Homebrew for frameit")
          sh("brew install imagemagick")
          UI.user_error!("brew finished, but no magick or convert command is available") unless system("command -v magick >/dev/null 2>&1")
        end

        # The App Store Connect API key. Only lanes that talk to Apple call this, so local screenshots need no secrets.
        def app_store_api_key
          require_env!("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_FILEPATH", "APP_IDENTIFIER", "APPLE_TEAM_ID")
          UI.user_error!("ASC_KEY_FILEPATH does not exist: #{ENV['ASC_KEY_FILEPATH']}") unless File.exist?(ENV["ASC_KEY_FILEPATH"])

          app_store_connect_api_key(
            key_id: ENV["ASC_KEY_ID"],
            issuer_id: ENV["ASC_ISSUER_ID"],
            key_filepath: ENV["ASC_KEY_FILEPATH"]
          )
        end

        # Options for build_app. IOS_PROJECT or IOS_WORKSPACE point at a project that is not at the default place (Capacitor keeps
        # its Xcode project in ios/App). Unset variables are left out, so the default lookup stays the same.
        def build_options
          options = { scheme: presence(ENV["IOS_SCHEME"]), export_method: "app-store" }
          options[:project] = presence(ENV["IOS_PROJECT"]) if presence(ENV["IOS_PROJECT"])
          options[:workspace] = presence(ENV["IOS_WORKSPACE"]) if presence(ENV["IOS_WORKSPACE"])
          options
        end

        # IPA_PATH uploads an IPA that another step already built and signed (for example .NET MAUI's dotnet publish).
        # Refuse one older than IPA_MAX_AGE_HOURS (default 24), so a stale file left in a runner does not get uploaded.
        def prebuilt_ipa_path
          path = presence(ENV["IPA_PATH"])
          return nil unless path
          UI.user_error!("No IPA at #{path}. Check IPA_PATH.") unless File.exist?(path)
          max_age = (presence(ENV["IPA_MAX_AGE_HOURS"]) || "24").to_f * 3600
          UI.user_error!("IPA at #{path} is older than #{max_age / 3600} hours. Rebuild it or raise IPA_MAX_AGE_HOURS.") if Time.now - File.mtime(path) > max_age
          path
        end

        # .NET MAUI: dotnet publish builds and signs the IPA. The signing certificate comes from match, so this runs after it.
        # MAUI_PROJECT is the .csproj, relative to the app folder; MAUI_CODESIGN_KEY and MAUI_PROVISIONING_PROFILE name the identity
        # and profile that match installed.
        def build_maui_ipa
          # The fastlane folder is ios/fastlane, so the app folder is two levels up. MAUI_PROJECT is relative to it.
          project = File.expand_path(ENV["MAUI_PROJECT"], File.expand_path("../..", __dir__))
          require_env!("MAUI_CODESIGN_KEY", "MAUI_PROVISIONING_PROFILE")
          framework = File.read(project)[/net[0-9.]+-ios/] || UI.user_error!("No net*-ios target in #{project}")
          sh(Shellwords.join(["dotnet", "publish", project, "-f", framework, "-c", "Release", "-p:BuildIpa=true",
                              "-p:CodesignKey=#{ENV['MAUI_CODESIGN_KEY']}", "-p:CodesignProvision=#{ENV['MAUI_PROVISIONING_PROFILE']}"]),
             log: false)
          ipa = Dir.glob(File.join(File.dirname(project), "bin/**/*.ipa")).max_by { |f| File.mtime(f) }
          UI.user_error!("dotnet publish wrote no IPA under #{File.dirname(project)}/bin") unless ipa
          ipa
        end

        platform :ios do
          before_all do
            setup_ci if ENV["CI"] # temporary keychain on CI runners
          end

          desc "Build a signed IPA and upload it to TestFlight"
          lane :beta do
            api_key = app_store_api_key
            require_env!("MATCH_GIT_URL", "MATCH_PASSWORD")
            match(api_key: api_key, readonly: true)

            ipa = prebuilt_ipa_path || (presence(ENV["MAUI_PROJECT"]) ? build_maui_ipa : nil)
            build_app(build_options) unless ipa

            upload = { api_key: api_key, skip_waiting_for_build_processing: true }
            upload[:ipa] = ipa if ipa
            upload_to_testflight(upload)
          end

          desc "Upload the latest processed build to the App Store (metadata and screenshots skipped)"
          lane :release do
            upload_to_app_store(
              api_key: app_store_api_key,
              skip_metadata: true,
              skip_screenshots: true,
              submit_for_review: false
            )
          end

          desc "Capture localized screenshots with snapshot. FRAME_SCREENSHOTS=1 frames them; UPLOAD_SCREENSHOTS=1 uploads them"
          lane :screenshots do
            # Snapfile is written with the screenshot setup. A project without it (for example .NET MAUI) has no UI test target to run.
            UI.user_error!("No fastlane/Snapfile here, so screenshots are not set up. Add the UI test target and Snapfile to use this lane.") unless File.exist?(File.expand_path("Snapfile", __dir__))
            snapshot

            # snapshot can exit 0 when every UI test failed to build or run, so check the output directly.
            screenshots = File.join(project_root, "fastlane/screenshots")
            UI.user_error!("snapshot wrote no screenshots. Check the UI test target and the scheme in fastlane/Snapfile.") if Dir.glob(File.join(screenshots, "**/*.png")).empty?

            if ENV["FRAME_SCREENSHOTS"] == "1"
              ensure_imagemagick
              shots = File.join(project_root, "fastlane/screenshots")
              before = Dir.glob(File.join(shots, "**/*.png")).to_h { |f| [f, File.mtime(f)] }
              frameit(path: shots)
              # frameit can exit 0 without framing a file (a failed ImageMagick step is only logged), so every file must change.
              after = Dir.glob(File.join(shots, "**/*.png")).to_h { |f| [f, File.mtime(f)] }
              unchanged = after.keys.select { |f| before[f] == after[f] }
              UI.user_error!("frameit left #{unchanged.size} of #{after.size} screenshots unframed (#{unchanged.map { |f| File.basename(f) }.join(', ')}). Check the ImageMagick output above.") if unchanged.any?
            end

            if ENV["UPLOAD_SCREENSHOTS"] == "1"
              # Framed images without titles keep the full device resolution, and App Store Connect rejects them. Refuse
              # unless you have set titles in Framefile.json and say so explicitly.
              if ENV["FRAME_SCREENSHOTS"] == "1" && ENV["ALLOW_FRAMED_UPLOAD"] != "1"
                UI.user_error!("Framed screenshots can be rejected by App Store Connect without titles. Set ALLOW_FRAMED_UPLOAD=1 once Framefile.json has titles, or drop FRAME_SCREENSHOTS.")
              end

              upload_to_app_store(
                api_key: app_store_api_key,
                skip_binary_upload: true,
                skip_metadata: true,
                skip_app_version_update: true,
                overwrite_screenshots: true,
                screenshots_path: screenshots,
                submit_for_review: false
              )
            end
          end
        end
        """#

    private static let iosFastlaneFramefileJson = #"""
        {
          "device_frame_version": "latest",
          "default": {
            "frame": "BLACK",
            "padding": 50,
            "show_complete_frame": false
          },
          "data": []
        }
        """#

    private static let iosFastlaneMatchfile = #"""
        # Code signing via fastlane match. The certificates repo is private and encrypted with MATCH_PASSWORD.
        git_url(ENV["MATCH_GIT_URL"])         # e.g. git@github.com:your-org/certificates.git
        storage_mode("git")
        type("appstore")
        # CI runs readonly, so it never creates or rotates certificates. To create them once, from your own Mac, run:
        #   MATCH_READONLY=false bundle exec fastlane match appstore
        readonly(ENV["MATCH_READONLY"] != "false")
        """#

    private static let iosFastlaneSnapfile = #"""
        # Screenshot settings for `fastlane snapshot` (iOS). Reference: https://docs.fastlane.tools/actions/snapshot/
        # Each value can be overridden from the environment, so CI can change them without editing this file.

        # The scheme that runs your UI test target. The UI tests live in ios/UITests (see docs/mobile-screenshots.md).
        # An empty variable (an unset repository variable arrives as "") means "not set", not an empty name.
        scheme([ENV["SNAPSHOT_SCHEME"], ENV["IOS_SCHEME"]].map { |v| v.to_s.strip }.find { |v| !v.empty? })

        # Simulators to capture on. Use the names `xcrun simctl list devices available` prints.
        # Without a device list snapshot uses a generic destination, and Xcode may boot several simulators, which is slow.
        devices(ENV["SNAPSHOT_DEVICES"].to_s.split(",").map(&:strip).reject(&:empty?).then { |list| list.empty? ? ["iPhone 17e"] : list })

        # Languages to capture. Each one gets its own folder under output_directory.
        languages(ENV["SNAPSHOT_LANGUAGES"].to_s.split(",").map(&:strip).reject(&:empty?).then { |list| list.empty? ? ["en-US"] : list })

        # Where screenshots are written. The screenshots lane uploads from here.
        output_directory("./fastlane/screenshots")

        # Remove earlier screenshots first, so a screen you deleted does not stay in the upload.
        clear_previous_screenshots(true)

        # Stop after the first device fails, instead of running the rest.
        stop_after_first_error(false)
        # Xcode project or workspace, when it is not at the default place (Capacitor keeps its project in ios/App).
        project(ENV["IOS_PROJECT"]) unless ENV["IOS_PROJECT"].to_s.strip.empty?
        """#

}
