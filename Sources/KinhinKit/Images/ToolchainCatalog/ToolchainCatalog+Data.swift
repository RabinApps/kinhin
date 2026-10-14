import Foundation

extension ToolchainCatalog {
    // MARK: - Tools

    /// `mise` is the cross-platform installer (macOS and Linux); prefer it for
    /// new entries. Homebrew entries need a `linuxInstaller` to reach Linux
    /// images (`CatalogInvariantTests` enforces this).
    public static let tools: [ToolchainEntry] = [
        // --- mise-managed languages & runtimes ---
        ToolchainEntry(
            id: "node", summary: "JavaScript runtime (npm included)", installer: .mise,
            cacheEnvs: [ToolchainCacheEnv(variable: "NPM_CONFIG_CACHE", subdirectory: "npm")],
            verify: "node --version && npm --version", defaultSpec: "node@22.23.3", category: .languages),
        ToolchainEntry(
            id: "go", summary: "Go toolchain", installer: .mise,
            cacheEnvs: [
                ToolchainCacheEnv(variable: "GOMODCACHE", subdirectory: "go/mod"),
                ToolchainCacheEnv(variable: "GOCACHE", subdirectory: "go/build"),
            ], verify: "go version", defaultSpec: "go@1.27.2", category: .languages),
        ToolchainEntry(
            id: "rust", summary: "Rust toolchain (rustc + cargo)", installer: .mise,
            // No CARGO_HOME redirect: rustup writes its env file and proxies into CARGO_HOME and
            // fails on the virtiofs cache share ("Inappropriate ioctl for device"), so the
            // toolchain could never install. Cargo's registry stays per-VM.
            cacheEnvs: [], verify: "cargo --version",
            defaultSpec: "rust@stable", category: .languages),
        ToolchainEntry(
            id: "python", summary: "Python (mise-managed)", installer: .mise,
            cacheEnvs: [
                ToolchainCacheEnv(variable: "UV_CACHE_DIR", subdirectory: "uv"),
                ToolchainCacheEnv(variable: "PIP_CACHE_DIR", subdirectory: "pip"),
            ], verify: "python --version", defaultSpec: "python@3.13.16", category: .languages),
        ToolchainEntry(
            id: "ruby", summary: "Ruby (mise-managed)", installer: .mise, verify: "ruby --version",
            defaultSpec: "ruby@4.0.7", category: .languages),
        ToolchainEntry(
            id: "java", summary: "JDK (Temurin via mise)", installer: .mise,
            cacheEnvs: [ToolchainCacheEnv(variable: "GRADLE_USER_HOME", subdirectory: "gradle")],
            verify: "java -version", defaultSpec: "java@temurin-21", category: .languages),
        ToolchainEntry(
            id: "bun", summary: "Bun runtime and package manager", installer: .mise,
            cacheEnvs: [ToolchainCacheEnv(variable: "BUN_INSTALL_CACHE_DIR", subdirectory: "bun")],
            verify: "bun --version", defaultSpec: "bun@latest", category: .languages),
        ToolchainEntry(
            id: "deno", summary: "Deno runtime", installer: .mise,
            cacheEnvs: [ToolchainCacheEnv(variable: "DENO_DIR", subdirectory: "deno")], verify: "deno --version",
            defaultSpec: "deno@2", category: .languages),
        ToolchainEntry(
            id: "uv", summary: "Astral uv Python package manager", installer: .mise,
            cacheEnvs: [ToolchainCacheEnv(variable: "UV_CACHE_DIR", subdirectory: "uv")], verify: "uv --version",
            defaultSpec: "uv@latest", category: .languages),
        ToolchainEntry(
            id: "zig", summary: "Zig compiler and build system", installer: .mise, verify: "zig version",
            defaultSpec: "zig@latest", category: .languages),
        ToolchainEntry(
            id: "erlang", summary: "Erlang/OTP", installer: .mise, verify: "erl -noshell -eval 'halt().'",
            defaultSpec: "erlang@latest", category: .languages),
        ToolchainEntry(
            id: "elixir", summary: "Elixir (mise installs Erlang alongside it)", installer: .mise,
            verify: "elixir --version", defaultSpec: "elixir@latest", category: .languages),
        ToolchainEntry(
            id: "kotlin", summary: "Kotlin compiler", installer: .mise, requires: [.java], verify: "kotlin -version",
            defaultSpec: "kotlin@latest", category: .languages),
        ToolchainEntry(
            id: "scala", summary: "Scala 3", installer: .mise, requires: [.java], verify: "scala --version",
            defaultSpec: "scala@latest", category: .languages),
        ToolchainEntry(
            id: "clojure", summary: "Clojure CLI tools", installer: .mise, requires: [.java],
            verify: "clojure --version", defaultSpec: "clojure@latest", category: .languages),
        ToolchainEntry(
            id: "dart", summary: "Dart SDK", installer: .mise, verify: "dart --version", defaultSpec: "dart@latest",
            category: .languages),
        ToolchainEntry(
            id: "swift", summary: "Swift toolchain (Linux and macOS)", installer: .mise, verify: "swift --version",
            defaultSpec: "swift@6.4.0",
            // The Swift toolchain links these; without them a Linux bake fails (docs/plans/beta-test-log.md).
            // Names checked against Ubuntu 24.04 and Debian 13 indexes; libpython3-dev pulls the matching minor.
            // libcurl was renamed by the 64-bit time_t transition: Ubuntu 22.04 and Debian 12 still call it libcurl4.
            linuxAptPackages: [
                "build-essential", "libcurl4t64|libcurl4", "libedit2", "libncurses6", "libpython3-dev", "libsqlite3-0",
                "libxml2", "tzdata",
            ], category: .languages),
        ToolchainEntry(
            id: "lua", summary: "Lua and LuaRocks", installer: .mise, verify: "lua -v", defaultSpec: "lua@latest",
            category: .languages),
        ToolchainEntry(
            id: "julia", summary: "Julia", installer: .mise, verify: "julia --version", defaultSpec: "julia@latest",
            category: .languages),
        ToolchainEntry(
            id: "php", summary: "PHP runtime: Homebrew on macOS, apt on Linux (no @version)",
            installer: .brew(formula: "php", isCask: false), verify: "php --version",
            linuxInstaller: .apt(packages: ["php-cli"]), category: .languages),
        ToolchainEntry(
            id: "dotnet", summary: ".NET SDK (C#/F#/VB): brew cask on macOS, apt on Linux; no @version",
            installer: .brew(formula: "dotnet-sdk", isCask: true),
            cacheEnvs: [
                ToolchainCacheEnv(variable: "NUGET_PACKAGES", subdirectory: "nuget")
            ], verify: "dotnet --list-sdks", linuxInstaller: .apt(packages: ["dotnet-sdk-10.0"]),
            category: .languages),

        // --- npm globals (require node, validated — never auto-installed) ---
        ToolchainEntry(
            id: "pnpm", summary: "pnpm package manager (global)", installer: .npm(package: "pnpm"), requires: [.node],
            cacheEnvs: [ToolchainCacheEnv(variable: "npm_config_store_dir", subdirectory: "pnpm-store")],
            verify: "pnpm --version", category: .javascript),
        ToolchainEntry(
            id: "yarn", summary: "Yarn classic (global)", installer: .npm(package: "yarn"), requires: [.node],
            cacheEnvs: [ToolchainCacheEnv(variable: "YARN_CACHE_FOLDER", subdirectory: "yarn")],
            verify: "yarn --version", category: .javascript),
        ToolchainEntry(
            id: "playwright", summary: "Playwright e2e runner + browsers cache", installer: .npm(package: "playwright"),
            requires: [.node],
            cacheEnvs: [ToolchainCacheEnv(variable: "PLAYWRIGHT_BROWSERS_PATH", subdirectory: "playwright")],
            verify: "playwright --version", category: .javascript),
        ToolchainEntry(
            id: "cypress", summary: "Cypress e2e runner + binary cache", installer: .npm(package: "cypress"),
            requires: [.node],
            cacheEnvs: [ToolchainCacheEnv(variable: "CYPRESS_CACHE_FOLDER", subdirectory: "cypress")],
            verify: "cypress --version", category: .javascript),
        ToolchainEntry(
            id: "netlify-cli", summary: "Netlify deploy CLI", installer: .npm(package: "netlify-cli"),
            requires: [.node], verify: "netlify --version", category: .javascript),
        ToolchainEntry(
            id: "firebase-tools", summary: "Firebase deploy CLI", installer: .npm(package: "firebase-tools"),
            requires: [.node], verify: "firebase --version", category: .javascript),
        ToolchainEntry(
            id: "typescript", summary: "TypeScript compiler (tsc)", installer: .npm(package: "typescript"),
            requires: [.node], verify: "tsc --version", category: .javascript),
        ToolchainEntry(
            id: "eslint", summary: "ESLint", installer: .npm(package: "eslint"), requires: [.node],
            verify: "eslint --version", category: .javascript),
        ToolchainEntry(
            id: "prettier", summary: "Prettier formatter", installer: .npm(package: "prettier"), requires: [.node],
            verify: "prettier --version", category: .javascript),
        ToolchainEntry(
            id: "turbo", summary: "Turborepo build system", installer: .npm(package: "turbo"), requires: [.node],
            verify: "turbo --version", category: .javascript),
        ToolchainEntry(
            id: "nx", summary: "Nx monorepo build system", installer: .npm(package: "nx"), requires: [.node],
            verify: "nx --version", category: .javascript),

        // --- build & quality tools ---
        ToolchainEntry(
            id: "cmake", summary: "CMake", installer: .mise, verify: "cmake --version", defaultSpec: "cmake@latest",
            category: .build),
        ToolchainEntry(
            id: "ninja", summary: "Ninja build system", installer: .mise, verify: "ninja --version",
            defaultSpec: "ninja@latest", category: .build),
        ToolchainEntry(
            id: "maven", summary: "Apache Maven", installer: .mise, requires: [.java], verify: "mvn --version",
            defaultSpec: "maven@latest", category: .build),
        ToolchainEntry(
            id: "gradle", summary: "Gradle", installer: .mise, requires: [.java], verify: "gradle --version",
            defaultSpec: "gradle@latest", category: .build),
        ToolchainEntry(
            id: "sbt", summary: "sbt (Scala build tool)", installer: .mise, requires: [.java], verify: "sbt --version",
            defaultSpec: "sbt@latest", category: .build),
        ToolchainEntry(
            id: "just", summary: "just command runner", installer: .mise, verify: "just --version",
            defaultSpec: "just@latest", category: .build),
        ToolchainEntry(
            id: "task", summary: "Task (go-task) runner", installer: .mise, verify: "task --version",
            defaultSpec: "task@latest", category: .build),
        ToolchainEntry(
            id: "jq", summary: "jq JSON processor", installer: .mise, verify: "jq --version", defaultSpec: "jq@latest",
            category: .build),
        ToolchainEntry(
            id: "yq", summary: "yq YAML processor", installer: .mise, verify: "yq --version", defaultSpec: "yq@latest",
            category: .build),
        ToolchainEntry(
            id: "direnv", summary: "direnv", installer: .mise, verify: "direnv version", defaultSpec: "direnv@latest",
            category: .build),
        ToolchainEntry(
            id: "shellcheck", summary: "ShellCheck shell linter", installer: .mise, verify: "shellcheck --version",
            defaultSpec: "shellcheck@latest", category: .build),
        ToolchainEntry(
            id: "hadolint", summary: "hadolint Dockerfile linter", installer: .mise, verify: "hadolint --version",
            defaultSpec: "hadolint@latest", category: .build),
        ToolchainEntry(
            id: "yamllint", summary: "YAML linter: Homebrew on macOS, apt on Linux (no @version)",
            installer: .brew(formula: "yamllint", isCask: false), verify: "yamllint --version",
            linuxInstaller: .apt(packages: ["yamllint"]), category: .build),
        ToolchainEntry(
            id: "composer", summary: "PHP dependency manager: Homebrew on macOS, apt on Linux (no @version)",
            installer: .brew(formula: "composer", isCask: false), verify: "composer --version",
            linuxInstaller: .apt(packages: ["composer"]), category: .build),
        ToolchainEntry(
            id: "fastlane", summary: "iOS/Android release automation (gem; needs Ruby, apt provides it on Linux)",
            installer: .gem(name: "fastlane"), verify: "fastlane --version", category: .build),

        // --- cloud & DevOps ---
        ToolchainEntry(
            id: "terraform", summary: "Terraform CLI", installer: .mise, verify: "terraform version",
            defaultSpec: "terraform@latest", category: .cloud),
        ToolchainEntry(
            id: "opentofu", summary: "OpenTofu (Terraform-compatible CLI)", installer: .mise, verify: "tofu --version",
            defaultSpec: "opentofu@latest", category: .cloud),
        ToolchainEntry(
            id: "kubectl", summary: "Kubernetes CLI", installer: .mise, verify: "kubectl version --client",
            defaultSpec: "kubectl@latest", category: .cloud),
        ToolchainEntry(
            id: "helm", summary: "Helm (Kubernetes package manager)", installer: .mise, verify: "helm version --short",
            defaultSpec: "helm@latest", category: .cloud),
        ToolchainEntry(
            id: "kustomize", summary: "Kustomize", installer: .mise, verify: "kustomize version",
            defaultSpec: "kustomize@latest", category: .cloud),
        ToolchainEntry(
            id: "k9s", summary: "k9s Kubernetes TUI", installer: .mise, verify: "k9s version --short",
            defaultSpec: "k9s@latest", category: .cloud),
        ToolchainEntry(
            id: "pulumi", summary: "Pulumi CLI", installer: .mise, verify: "pulumi version",
            defaultSpec: "pulumi@latest", category: .cloud),
        ToolchainEntry(
            id: "packer", summary: "HashiCorp Packer", installer: .mise, verify: "packer --version",
            defaultSpec: "packer@latest", category: .cloud),
        ToolchainEntry(
            id: "vault", summary: "HashiCorp Vault CLI", installer: .mise, verify: "vault version",
            defaultSpec: "vault@latest", category: .cloud),
        ToolchainEntry(
            id: "gh", summary: "GitHub CLI (auth via $GH_TOKEN per job)", installer: .mise, verify: "gh --version",
            defaultSpec: "gh@latest", category: .cloud),
        ToolchainEntry(
            id: "awscli", summary: "AWS CLI v2: Homebrew on macOS, mise on Linux (no @version on macOS)",
            installer: .brew(formula: "awscli", isCask: false), verify: "aws --version", linuxInstaller: .mise,
            category: .cloud),
        ToolchainEntry(
            id: "gcloud", summary: "Google Cloud SDK: Homebrew on macOS, mise on Linux (no @version on macOS)",
            installer: .brew(formula: "google-cloud-sdk", isCask: true), verify: "gcloud --version",
            linuxInstaller: .mise, category: .cloud),
        ToolchainEntry(
            id: "supabase", summary: "Supabase CLI: Homebrew on macOS, mise on Linux (no @version on macOS)",
            installer: .brew(formula: "supabase", isCask: false), verify: "supabase --version", linuxInstaller: .mise,
            category: .cloud),
        ToolchainEntry(
            id: "flyctl", summary: "Fly.io deploy CLI: Homebrew on macOS, mise on Linux (no @version on macOS)",
            installer: .brew(formula: "flyctl", isCask: false), verify: "flyctl version", linuxInstaller: .mise,
            category: .cloud),
    ]

    // MARK: - Stacks

    public static let stacks: [ToolchainStack] = [
        ToolchainStack(
            id: "flutter",
            summary: "Flutter SDK via fvm (+ CocoaPods for iOS builds)",
            brewTaps: ["leoafarias/fvm"],
            brewFormulas: ["fvm", "cocoapods"],
            cacheEnvs: [ToolchainCacheEnv(variable: "FVM_CACHE_PATH", subdirectory: "fvm")],
            verify: "fvm flutter --version && fvm list",
            versionKind: "Flutter SDK version (installed and pinned via fvm; default: stable)",
            defaultVersion: "stable",
            versionHint: "flutter@3.24.0",
            postInstall: ["fvm install <version>", "fvm global <version>"],
            platforms: [.macOS, .linux],
            // Linux: a plain git install of the SDK (Flutter's documented
            // manual install; no snap, no fvm, no Homebrew). Git rather than
            // the release tarball because the tarball is x64-only while the
            // Linux containers are arm64 — the flutter script fetches the
            // right Dart SDK for the host on first run. No CocoaPods: iOS
            // builds need macOS, so a Linux image builds Android, web and Linux desktop.
            // Flutter's documented prerequisites, plus its Linux desktop
            // build toolchain (`flutter build linux`: clang, CMake, Ninja,
            // pkg-config, GTK 3 headers, liblzma).
            linuxAptPackages: [
                "curl", "git", "unzip", "xz-utils", "zip", "libglu1-mesa",
                "clang", "cmake", "ninja-build", "pkg-config", "libgtk-3-dev", "liblzma-dev",
            ],
            linuxSteps: [
                """
                # Flutter SDK (git install into /opt/flutter; blobless clone keeps history + tags small). /opt is
                # root's, so the directory is made and handed to the installing user first (a tart guest installs
                # as its admin user through sudo; a container bake runs as root).
                flutter_ref=<version>
                if [ ! -x /opt/flutter/bin/flutter ]; then
                  <sudo>mkdir -p /opt/flutter && <sudo>chown "$(id -u):$(id -g)" /opt/flutter
                  git clone --filter=blob:none https://github.com/flutter/flutter.git /opt/flutter
                fi
                git -C /opt/flutter fetch --tags --force --quiet origin
                if git -C /opt/flutter rev-parse --verify --quiet "origin/$flutter_ref" >/dev/null; then
                  git -C /opt/flutter checkout --quiet -B "$flutter_ref" "origin/$flutter_ref"
                else
                  git -C /opt/flutter checkout --quiet "$flutter_ref"
                fi
                """,
                """
                # PATH for this script and for every runner login shell
                export PATH="/opt/flutter/bin:$PATH"
                printf '%s\\n' 'export PATH="/opt/flutter/bin:$PATH"' | <sudo>tee /etc/profile.d/kinhin-flutter.sh >/dev/null
                """,
                """
                # fetch the Dart SDK plus web and Linux-desktop artifacts now, not during the first job
                flutter config --no-analytics --no-cli-animations >/dev/null 2>&1 || true
                flutter --version
                flutter precache --universal --web --linux
                """,
            ],
            linuxVerify: "/opt/flutter/bin/flutter --version"
        ),
        ToolchainStack(
            id: "expo",
            summary: "Expo application services CLI (eas-cli)",
            requires: [.node],
            npmPackages: [ToolchainStack.NPMPackage(name: "eas-cli")],
            verify: "eas --version",
            versionKind: "eas-cli version",
            defaultVersion: "",
            versionHint: "latest"
        ),
        ToolchainStack(
            id: "react-native",
            summary: "Direct React Native (no Expo): watchman, CocoaPods, JDK 17 — add node yourself",
            brewFormulas: ["watchman", "cocoapods"],
            miseSpecs: ["java@temurin-17"],
            verify: "watchman --version && pod --version && java -version",
            platforms: [.macOS]
        ),
        ToolchainStack(
            id: "vercel",
            summary: "Vercel deploy CLI (auth via $VERCEL_TOKEN per job)",
            requires: [.node],
            npmPackages: [ToolchainStack.NPMPackage(name: "vercel")],
            verify: "vercel --version",
            versionKind: "Vercel CLI version",
            defaultVersion: "",
            versionHint: "latest"
        ),
        ToolchainStack(
            id: "cloudflare",
            summary: "Cloudflare Workers deploy CLI (auth via $CLOUDFLARE_API_TOKEN per job)",
            requires: [.node],
            npmPackages: [ToolchainStack.NPMPackage(name: "wrangler")],
            verify: "wrangler --version",
            versionKind: "Wrangler version",
            defaultVersion: ""
        ),
    ]
}
