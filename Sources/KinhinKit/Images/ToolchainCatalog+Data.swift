import Foundation

extension ToolchainCatalog {
    // MARK: Tools

    public static let tools: [ToolchainEntry] = [
        // --- mise-managed runtimes ---
        ToolchainEntry(
            id: "node", summary: "JavaScript runtime (npm included)", installer: .mise,
            cacheEnvs: [
                ToolchainCacheEnv(variable: "NPM_CONFIG_CACHE", subdirectory: "npm")
            ], verify: "node --version && npm --version", defaultSpec: "node@22"),
        ToolchainEntry(
            id: "go", summary: "Go toolchain", installer: .mise,
            cacheEnvs: [
                ToolchainCacheEnv(variable: "GOMODCACHE", subdirectory: "go/mod"),
                ToolchainCacheEnv(variable: "GOCACHE", subdirectory: "go/build"),
            ], verify: "go version", defaultSpec: "go@latest"),
        ToolchainEntry(
            id: "rust", summary: "Rust toolchain (rustc + cargo)", installer: .mise,
            cacheEnvs: [
                ToolchainCacheEnv(variable: "CARGO_HOME", subdirectory: "cargo")
            ], verify: "cargo --version", defaultSpec: "rust@stable"),
        ToolchainEntry(
            id: "python", summary: "Python (mise-managed)", installer: .mise,
            cacheEnvs: [
                ToolchainCacheEnv(variable: "UV_CACHE_DIR", subdirectory: "uv"),
                ToolchainCacheEnv(variable: "PIP_CACHE_DIR", subdirectory: "pip"),
            ], verify: "python --version", defaultSpec: "python@3.13"),
        ToolchainEntry(
            id: "ruby", summary: "Ruby (mise-managed)", installer: .mise, verify: "ruby --version",
            defaultSpec: "ruby@latest"),
        ToolchainEntry(
            id: "java", summary: "JDK (Temurin via mise)", installer: .mise,
            cacheEnvs: [
                ToolchainCacheEnv(variable: "GRADLE_USER_HOME", subdirectory: "gradle")
            ], verify: "java -version", defaultSpec: "java@temurin-21"),
        ToolchainEntry(
            id: "bun", summary: "Bun runtime and package manager", installer: .mise,
            cacheEnvs: [
                ToolchainCacheEnv(variable: "BUN_INSTALL_CACHE_DIR", subdirectory: "bun")
            ], verify: "bun --version", defaultSpec: "bun@latest"),
        ToolchainEntry(
            id: "deno", summary: "Deno runtime", installer: .mise,
            cacheEnvs: [
                ToolchainCacheEnv(variable: "DENO_DIR", subdirectory: "deno")
            ], verify: "deno --version", defaultSpec: "deno@2"),
        ToolchainEntry(
            id: "uv", summary: "Astral uv Python package manager", installer: .mise,
            cacheEnvs: [
                ToolchainCacheEnv(variable: "UV_CACHE_DIR", subdirectory: "uv")
            ], verify: "uv --version", defaultSpec: "uv@latest"),
        ToolchainEntry(
            id: "terraform", summary: "Terraform CLI", installer: .mise, verify: "terraform version",
            defaultSpec: "terraform@latest"),
        ToolchainEntry(
            id: "kubectl", summary: "Kubernetes CLI", installer: .mise, verify: "kubectl version --client",
            defaultSpec: "kubectl@latest"),

        // --- npm globals (require node, validated — never auto-installed) ---
        ToolchainEntry(
            id: "pnpm", summary: "pnpm package manager (global)", installer: .npm(package: "pnpm"), requires: [.node],
            cacheEnvs: [
                ToolchainCacheEnv(variable: "npm_config_store_dir", subdirectory: "pnpm-store")
            ], verify: "pnpm --version"),
        ToolchainEntry(
            id: "yarn", summary: "Yarn classic (global)", installer: .npm(package: "yarn"), requires: [.node],
            cacheEnvs: [
                ToolchainCacheEnv(variable: "YARN_CACHE_FOLDER", subdirectory: "yarn")
            ], verify: "yarn --version"),
        ToolchainEntry(
            id: "playwright", summary: "Playwright e2e runner + browsers cache", installer: .npm(package: "playwright"),
            requires: [.node],
            cacheEnvs: [
                ToolchainCacheEnv(variable: "PLAYWRIGHT_BROWSERS_PATH", subdirectory: "playwright")
            ], verify: "playwright --version"),
        ToolchainEntry(
            id: "cypress", summary: "Cypress e2e runner + binary cache", installer: .npm(package: "cypress"),
            requires: [.node],
            cacheEnvs: [
                ToolchainCacheEnv(variable: "CYPRESS_CACHE_FOLDER", subdirectory: "cypress")
            ], verify: "cypress --version"),
        ToolchainEntry(
            id: "netlify-cli", summary: "Netlify deploy CLI", installer: .npm(package: "netlify-cli"),
            requires: [.node], verify: "netlify --version"),
        ToolchainEntry(
            id: "firebase-tools", summary: "Firebase deploy CLI", installer: .npm(package: "firebase-tools"),
            requires: [.node], verify: "firebase --version"),

        // --- Homebrew (macOS guests only; no Linux equivalent in the catalog) ---
        ToolchainEntry(
            id: "yamllint", summary: "YAML linter", installer: .brew(formula: "yamllint", isCask: false),
            verify: "yamllint --version", platforms: [.macOS]),
        ToolchainEntry(
            id: "awscli", summary: "AWS CLI", installer: .brew(formula: "awscli", isCask: false),
            verify: "aws --version", platforms: [.macOS]),
        ToolchainEntry(
            id: "supabase", summary: "Supabase CLI", installer: .brew(formula: "supabase", isCask: false),
            verify: "supabase --version", platforms: [.macOS]),
        ToolchainEntry(
            id: "flyctl", summary: "Fly.io deploy CLI", installer: .brew(formula: "flyctl", isCask: false),
            verify: "flyctl version", platforms: [.macOS]),
        ToolchainEntry(
            id: "gcloud", summary: "Google Cloud SDK", installer: .brew(formula: "google-cloud-sdk", isCask: true),
            verify: "gcloud --version", platforms: [.macOS]),
        ToolchainEntry(
            id: "php", summary: "PHP runtime (Composer via the composer tool)",
            installer: .brew(formula: "php", isCask: false), verify: "php --version", platforms: [.macOS]),
        ToolchainEntry(
            id: "composer", summary: "PHP dependency manager", installer: .brew(formula: "composer", isCask: false),
            verify: "composer --version", platforms: [.macOS]),
        ToolchainEntry(
            id: "dotnet", summary: ".NET SDK (C#/F#/VB): brew cask on macOS, apt on Linux; no @version",
            installer: .brew(formula: "dotnet-sdk", isCask: true),
            cacheEnvs: [
                ToolchainCacheEnv(variable: "NUGET_PACKAGES", subdirectory: "nuget")
            ], verify: "dotnet --list-sdks", linuxInstaller: .apt(packages: ["dotnet-sdk-8.0"])),

        // --- gems (macOS guests; Linux bakes use mise-managed ruby + plain gem) ---
        ToolchainEntry(
            id: "fastlane", summary: "iOS/Android release automation (uses the system Ruby)",
            installer: .gem(name: "fastlane"), verify: "fastlane --version", platforms: [.macOS]),
    ]

    // MARK: Stacks

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
            platforms: [.macOS]
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
