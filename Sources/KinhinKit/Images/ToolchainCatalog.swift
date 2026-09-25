import Foundation

// MARK: - Shared cache mount

/// Where the shared toolchain cache lives on the host and inside guests.
/// `image prepare` always mounts it (faster re-prepares); runner VMs mount
/// it when `toolchains.share_cache` is on.
public enum ToolchainCacheMount {
    /// tart auto-mounts virtiofs shares under this path inside macOS guests.
    public static let guestSharesRoot = "/Volumes/My Shared Files"
    /// Directory (under `Paths.appSupport`) holding the host cache.
    public static let hostDirectoryName = "toolchain-cache"
    /// Directory (inside the virtiofs share) holding the cache. A distinct
    /// name keeps the share safe if other shares ever join the same mount.
    public static let guestDirectoryName = "kinhin-cache"

    /// Absolute guest-side path of the shared cache in macOS guests.
    public static var guestPath: String { guestSharesRoot + "/" + guestDirectoryName }
    /// Absolute guest-side path of the shared cache in Linux guests
    /// (apple/container bind mounts). Chosen to be writable by root, which
    /// is the default user in runner containers.
    public static let linuxGuestPath = "/var/kinhin-cache"

    /// The `-v/--volume` spec for binding the host cache into a Linux
    /// container (`container run -v <host>:<guest>` — the syntax documented
    /// by apple/container's command reference).
    public static func volumeSpec(host: String) -> String {
        "\(host):\(linuxGuestPath)"
    }
}

// MARK: - Platforms

/// Which execution platforms a catalog entry supports. Entries list the
/// platforms they install on; selection filters by target so e.g. a
/// Linux container bake never sees CocoaPods.
public enum ToolchainPlatform: String, Sendable, Equatable, CaseIterable {
    case macOS
    case linux
}

// MARK: - Requirements

/// A runtime a catalog entry needs but does NOT install itself. Enforced at
/// config validation: the user selects the requirement explicitly — kinhin
/// never adds tools implicitly.
public enum ToolchainRequirement: String, Sendable, CaseIterable {
    case node
    case dotnet
}

// MARK: - Cache map

/// One environment variable pointed into the shared cache. The value is
/// `<cache mount>/<subdirectory>` — created on demand by the install script
/// and skipped gracefully when the cache mount is absent.
public struct ToolchainCacheEnv: Sendable, Equatable {
    public let variable: String
    public let subdirectory: String

    public init(variable: String, subdirectory: String) {
        self.variable = variable
        self.subdirectory = subdirectory
    }
}

// MARK: - Tools

/// A single installable tool. `installer` says how `image prepare` installs
/// it; `verify` must exit 0 afterwards or the prepare aborts (old image kept
/// intact). Unknown specs beyond this table still pass through to mise/brew.
public protocol _CatalogEntry: Sendable, Equatable {}
extension _CatalogEntry {}

public struct ToolchainEntry: Sendable, Equatable, _CatalogEntry {
    public enum Installer: Sendable, Equatable {
        /// A mise spec — the config entry itself (e.g. "go@1.23.4").
        case mise
        /// A Homebrew formula (or cask name when `isCask`).
        case brew(formula: String, isCask: Bool)
        /// An npm package installed globally with `npm install -g`.
        case npm(package: String)
        /// A Ruby gem installed into the user's gem dir.
        case gem(name: String)
        /// Debian/Ubuntu packages installed with apt-get (Linux guests only;
        /// the runner containers run as root so no sudo is needed).
        case apt(packages: [String])
    }

    public let id: String
    public let summary: String
    public let installer: Installer
    /// Explicit runtime prerequisites (validated, never auto-installed).
    public let requires: [ToolchainRequirement]
    /// Cache envs exported when this tool is selected.
    public let cacheEnvs: [ToolchainCacheEnv]
    /// Shell command that must succeed after install ("" = nothing).
    public let verify: String
    /// The mise spec shown by `kinhin toolchains` when the user doesn't pin.
    public let defaultSpec: String
    /// Platforms this tool installs on. Entries absent from the target
    /// platform are skipped at selection time (not an error — e.g. brew
    /// tools simply don't apply inside Linux containers).
    public let platforms: [ToolchainPlatform]
    /// Alternative installer used on Linux guests (e.g. dotnet via apt
    /// instead of the Homebrew cask). nil = the primary installer serves
    /// every supported platform.
    public let linuxInstaller: Installer?

    public init(id: String, summary: String, installer: Installer, requires: [ToolchainRequirement] = [], cacheEnvs: [ToolchainCacheEnv] = [], verify: String, defaultSpec: String = "", platforms: [ToolchainPlatform] = ToolchainPlatform.allCases, linuxInstaller: Installer? = nil) {
        self.id = id
        self.summary = summary
        self.installer = installer
        self.requires = requires
        self.cacheEnvs = cacheEnvs
        self.verify = verify
        self.defaultSpec = defaultSpec
        self.platforms = platforms
        self.linuxInstaller = linuxInstaller
    }

    /// True when the tool installs exclusively via Homebrew (formula or
    /// cask) — i.e. it has no Linux equivalent in the catalog.
    public var isBrewOnly: Bool {
        if case .brew = installer { return true }
        return false
    }

    /// The installer for the given platform (the Linux override when set).
    public func installer(for platform: ToolchainPlatform) -> Installer {
        platform == .linux ? (linuxInstaller ?? installer) : installer
    }
}

// MARK: - Stacks

/// A curated multi-tool recipe (mobile/web workflow in one entry). Stacks
/// expand ONLY to their own pieces — a stack that needs node or dotnet
/// declares it in `requires`, and config validation demands the user select
/// that runtime too.
public struct ToolchainStack: Sendable, Equatable, _CatalogEntry {
    /// An npm dependency with an optional pinned version.
    public struct NPMPackage: Sendable, Equatable {
        public let name: String
        public let version: String // "" = latest
        public init(name: String, version: String = "") {
            self.name = name
            self.version = version
        }
    }

    public let id: String
    public let summary: String
    public let requires: [ToolchainRequirement]
    public let brewTaps: [String]
    public let brewFormulas: [String]
    public let miseSpecs: [String]
    public let npmPackages: [NPMPackage]
    public let cacheEnvs: [ToolchainCacheEnv]
    public let verify: String
    /// What `@version` means for this stack; nil = version unsupported.
    public let versionKind: String?
    /// Short note shown under the version field in the Advanced → Toolchains UI.
    public let versionHint: String?
    /// The version applied when the config doesn't pin one ("" = none).
    public let defaultVersion: String
    /// Extra shell steps run after installs. The literal `<version>` is
    /// replaced with the effective version; steps still containing the
    /// placeholder are dropped when no version is pinned.
    public let postInstall: [String]
    /// Platforms this stack installs on (macOS-only for the iOS-adjacent
    /// recipes: CocoaPods, watchman, and fvm do not exist on Linux).
    public let platforms: [ToolchainPlatform]

    public init(id: String, summary: String, requires: [ToolchainRequirement] = [], brewTaps: [String] = [], brewFormulas: [String] = [], miseSpecs: [String] = [], npmPackages: [NPMPackage] = [], cacheEnvs: [ToolchainCacheEnv] = [], verify: String, versionKind: String? = nil, defaultVersion: String = "", versionHint: String? = nil, postInstall: [String] = [], platforms: [ToolchainPlatform] = ToolchainPlatform.allCases) {
        self.id = id
        self.summary = summary
        self.requires = requires
        self.brewTaps = brewTaps
        self.brewFormulas = brewFormulas
        self.miseSpecs = miseSpecs
        self.npmPackages = npmPackages
        self.cacheEnvs = cacheEnvs
        self.verify = verify
        self.versionKind = versionKind
        self.versionHint = versionHint
        self.defaultVersion = defaultVersion
        self.postInstall = postInstall
        self.platforms = platforms
    }

    /// Splits "flutter@3.24.0" into ("flutter", "3.24.0"); a bare id or a
    /// trailing "@" yields a nil version.
    public static func splitSpec(_ name: String) -> (id: String, version: String?) {
        guard let at = name.firstIndex(of: "@") else { return (name, nil) }
        let id = String(name[..<at])
        let version = String(name[name.index(after: at)...])
        guard !version.isEmpty else { return (id, nil) }
        return (id, version)
    }

    /// The effective version: the pinned one, else the stack default.
    public func effectiveVersion(pinned: String?) -> String {
        pinned ?? defaultVersion
    }
}

// MARK: - Resolved selection

/// A Homebrew install target.
public struct BrewFormula: Sendable, Equatable, Hashable {
    public let name: String
    public let isCask: Bool
    public init(name: String, isCask: Bool) {
        self.name = name
        self.isCask = isCask
    }
}

/// Everything the managed-toolchain install script needs, resolved from a
/// validated `toolchains:` config. Only what the user selected appears here
/// — resolution maps ids to installers, caches, and verifications; it never
/// adds a tool.
public struct ManagedToolchainSelection: Sendable, Equatable {
    public var brewTaps: [String] = []
    public var brewFormulas: [BrewFormula] = []
    public var miseSpecs: [String] = []
    public var npmPackages: [ToolchainStack.NPMPackage] = []
    public var gems: [String] = []
    /// apt packages for Linux guests (e.g. `dotnet-sdk-8.0`).
    public var aptPackages: [String] = []
    /// Post-install steps emitted verbatim (e.g. `fvm install 3.24.0`).
    public var stackSteps: [String] = []
    /// Deduped cache-env exports, in stable selection order.
    public var cacheEnvs: [ToolchainCacheEnv] = []
    /// Verify commands appended to the install script (fail-fast).
    public var verifications: [String] = []
    /// True when a selected entry was skipped because it does not support
    /// the requested platform (surfaced as a log line, never an error).
    public var skippedEntries: [String] = []

    public init() {}
}

extension ToolchainCatalog {
    /// Resolves a validated `toolchains:` config into install steps.
    ///
    /// Selection surfaces:
    /// - `specs` entries resolve by root id against the catalog: mise tools
    ///   install via `mise use --global`, npm tools via `npm install -g`,
    ///   gems via `gem install`; unknown roots pass through to mise.
    /// - `brew` entries are Homebrew formulas/casks; known ones contribute
    ///   their cache envs and verification.
    /// - `stacks` contribute their recipe pieces (with pinned versions).
    ///
    /// Platform-aware: entries that don't list the requested platform are
    /// skipped (recorded in `skippedEntries`, never an error). Defaults to
    /// macOS for the existing VM bake path.
    public static func selection(
        from config: kinhinConfig.ToolchainsConfig,
        platform: ToolchainPlatform = .macOS,
        mountPath: String? = nil
    ) -> ManagedToolchainSelection {
        var out = ManagedToolchainSelection()

        func collect(_ entry: ToolchainEntry, version: String?) {
            guard entry.platforms.contains(platform) else {
                if !out.skippedEntries.contains(entry.id) { out.skippedEntries.append(entry.id) }
                return
            }
            switch entry.installer(for: platform) {
            case .mise:
                out.miseSpecs.append(version.map { "\(entry.id)@\($0)" } ?? entry.defaultSpec)
            case .brew(let formula, let isCask):
                let target = BrewFormula(name: formula, isCask: isCask)
                if !out.brewFormulas.contains(target) { out.brewFormulas.append(target) }
            case .npm(let package):
                out.npmPackages.append(.init(name: package, version: version ?? ""))
            case .gem(let gem):
                if !out.gems.contains(gem) { out.gems.append(gem) }
            case .apt(let packages):
                for package in packages where !out.aptPackages.contains(package) {
                    out.aptPackages.append(package)
                }
            }
            for env in entry.cacheEnvs where !out.cacheEnvs.contains(env) {
                out.cacheEnvs.append(env)
            }
            if !entry.verify.isEmpty, !out.verifications.contains(entry.verify) {
                out.verifications.append(entry.verify)
            }
        }

        // 1. specs: tool id (optionally @version) → catalog installer.
        for spec in config.specs ?? [] {
            let root = rootTool(of: spec)
            let version = ToolchainStack.splitSpec(spec).version
            if let tool = ToolchainCatalog.tool(id: root) {
                collect(tool, version: version)
            } else {
                // Pass-through: unknown roots go to mise verbatim.
                out.miseSpecs.append(spec)
            }
        }

        // 2. brew: raw formulas; known tools contribute caches/verification.
        for formula in config.brew ?? [] {
            if let tool = ToolchainCatalog.tool(id: formula) {
                // Known tool: on Linux, use its Linux installer when it has
                // one (e.g. dotnet via apt); otherwise skip with a note.
                if !tool.platforms.contains(platform) {
                    if !out.skippedEntries.contains(tool.id) { out.skippedEntries.append(tool.id) }
                    continue
                }
                if case .brew(let name, let isCask) = tool.installer(for: platform) {
                    let target = BrewFormula(name: name, isCask: isCask)
                    if !out.brewFormulas.contains(target) { out.brewFormulas.append(target) }
                } else if case .apt(let packages) = tool.installer(for: platform) {
                    for package in packages where !out.aptPackages.contains(package) {
                        out.aptPackages.append(package)
                    }
                }
                for env in tool.cacheEnvs where !out.cacheEnvs.contains(env) {
                    out.cacheEnvs.append(env)
                }
                if !tool.verify.isEmpty, !out.verifications.contains(tool.verify) {
                    out.verifications.append(tool.verify)
                }
                continue
            }
            if platform == .linux {
                // Homebrew is macOS-only: raw brew entries are skipped on
                // Linux with a note (never an error).
                if !out.skippedEntries.contains(formula) { out.skippedEntries.append(formula) }
                continue
            }
            if let tool = ToolchainCatalog.tool(id: formula),
               case .brew(let name, let isCask) = tool.installer {
                let target = BrewFormula(name: name, isCask: isCask)
                if !out.brewFormulas.contains(target) { out.brewFormulas.append(target) }
                for env in tool.cacheEnvs where !out.cacheEnvs.contains(env) {
                    out.cacheEnvs.append(env)
                }
                if !tool.verify.isEmpty, !out.verifications.contains(tool.verify) {
                    out.verifications.append(tool.verify)
                }
            } else if let tool = ToolchainCatalog.tools.first(where: {
                if case .brew(let name, _) = $0.installer { return name == formula }
                return false
            }) {
                // A known formula under its package name (e.g. "dotnet-sdk").
                if case .brew(let name, let isCask) = tool.installer {
                    let target = BrewFormula(name: name, isCask: isCask)
                    if !out.brewFormulas.contains(target) { out.brewFormulas.append(target) }
                    for env in tool.cacheEnvs where !out.cacheEnvs.contains(env) {
                        out.cacheEnvs.append(env)
                    }
                    if !tool.verify.isEmpty, !out.verifications.contains(tool.verify) {
                        out.verifications.append(tool.verify)
                    }
                }
            } else {
                // Pass-through formula.
                let target = BrewFormula(name: formula, isCask: false)
                if !out.brewFormulas.contains(target) { out.brewFormulas.append(target) }
            }
        }

        // 3. stacks: recipe pieces in declared order.
        for name in config.stacks ?? [] {
            let (id, pinned) = ToolchainStack.splitSpec(name)
            guard let stack = ToolchainCatalog.stack(id: id) else { continue } // validated earlier
            guard stack.platforms.contains(platform) else {
                if !out.skippedEntries.contains(stack.id) { out.skippedEntries.append(stack.id) }
                continue
            }
            out.brewTaps.append(contentsOf: stack.brewTaps)
            for formula in stack.brewFormulas {
                let target = BrewFormula(name: formula, isCask: false)
                if !out.brewFormulas.contains(target) { out.brewFormulas.append(target) }
            }
            out.miseSpecs.append(contentsOf: stack.miseSpecs)
            for var package in stack.npmPackages {
                let version = stack.effectiveVersion(pinned: pinned)
                if !version.isEmpty { package = .init(name: package.name, version: version) }
                if !out.npmPackages.contains(package) { out.npmPackages.append(package) }
            }
            // Post-install steps (fvm SDK pin): emitted only when the step
            // carries a concrete version — with the host cache unmounted the
            // SDK would land inside the throwaway scratch VM, so the pin is
            // skipped (the install steps above still no-op safely).
            let version = stack.effectiveVersion(pinned: pinned)
            let hasMount = mountPath != nil
            for step in stack.postInstall where step.contains("<version>") {
                guard hasMount, !version.isEmpty else { continue }
                out.stackSteps.append(step.replacingOccurrences(of: "<version>", with: version))
            }
            for step in stack.postInstall where !step.contains("<version>") {
                out.stackSteps.append(step)
            }
            for env in stack.cacheEnvs where !out.cacheEnvs.contains(env) {
                out.cacheEnvs.append(env)
            }
            if !stack.verify.isEmpty, !out.verifications.contains(stack.verify) {
                out.verifications.append(stack.verify)
            }
        }

        // Umbrella caches: mise (whenever any mise tool is selected) and
        // Homebrew's download cache (macOS brew installs only). These were
        // documented in the README's cache map but previously missing from
        // the resolved selection.
        if !out.miseSpecs.isEmpty {
            let mise = ToolchainCacheEnv(variable: "MISE_CACHE_DIR", subdirectory: "mise")
            if !out.cacheEnvs.contains(mise) { out.cacheEnvs.insert(mise, at: 0) }
        }
        if platform == .macOS, !out.brewFormulas.isEmpty {
            let brew = ToolchainCacheEnv(variable: "HOMEBREW_CACHE", subdirectory: "brew")
            if !out.cacheEnvs.contains(brew) {
                out.cacheEnvs.insert(brew, at: out.miseSpecs.isEmpty ? 0 : 1)
            }
        }

        return out
    }
}

// MARK: - Catalog

public enum ToolchainCatalog {
    /// Root tool of a mise spec: "go@1.23.4" → "go"; "java@temurin-17" → "java".
    public static func rootTool(of spec: String) -> String {
        guard let at = spec.firstIndex(of: "@") else { return spec }
        return String(spec[..<at])
    }

    public static func tool(id: String) -> ToolchainEntry? {
        tools.first { $0.id == id }
    }

    public static func stack(id: String) -> ToolchainStack? {
        stacks.first { $0.id == id }
    }

    // MARK: Tools

    public static let tools: [ToolchainEntry] = [
        // --- mise-managed runtimes ---
        ToolchainEntry(id: "node", summary: "JavaScript runtime (npm included)", installer: .mise, cacheEnvs: [
            ToolchainCacheEnv(variable: "NPM_CONFIG_CACHE", subdirectory: "npm"),
        ], verify: "node --version && npm --version", defaultSpec: "node@22"),
        ToolchainEntry(id: "go", summary: "Go toolchain", installer: .mise, cacheEnvs: [
            ToolchainCacheEnv(variable: "GOMODCACHE", subdirectory: "go/mod"),
            ToolchainCacheEnv(variable: "GOCACHE", subdirectory: "go/build"),
        ], verify: "go version", defaultSpec: "go@latest"),
        ToolchainEntry(id: "rust", summary: "Rust toolchain (rustc + cargo)", installer: .mise, cacheEnvs: [
            ToolchainCacheEnv(variable: "CARGO_HOME", subdirectory: "cargo"),
        ], verify: "cargo --version", defaultSpec: "rust@stable"),
        ToolchainEntry(id: "python", summary: "Python (mise-managed)", installer: .mise, cacheEnvs: [
            ToolchainCacheEnv(variable: "UV_CACHE_DIR", subdirectory: "uv"),
            ToolchainCacheEnv(variable: "PIP_CACHE_DIR", subdirectory: "pip"),
        ], verify: "python --version", defaultSpec: "python@3.13"),
        ToolchainEntry(id: "ruby", summary: "Ruby (mise-managed)", installer: .mise, verify: "ruby --version", defaultSpec: "ruby@latest"),
        ToolchainEntry(id: "java", summary: "JDK (Temurin via mise)", installer: .mise, cacheEnvs: [
            ToolchainCacheEnv(variable: "GRADLE_USER_HOME", subdirectory: "gradle"),
        ], verify: "java -version", defaultSpec: "java@temurin-21"),
        ToolchainEntry(id: "bun", summary: "Bun runtime and package manager", installer: .mise, cacheEnvs: [
            ToolchainCacheEnv(variable: "BUN_INSTALL_CACHE_DIR", subdirectory: "bun"),
        ], verify: "bun --version", defaultSpec: "bun@latest"),
        ToolchainEntry(id: "deno", summary: "Deno runtime", installer: .mise, cacheEnvs: [
            ToolchainCacheEnv(variable: "DENO_DIR", subdirectory: "deno"),
        ], verify: "deno --version", defaultSpec: "deno@2"),
        ToolchainEntry(id: "uv", summary: "Astral uv Python package manager", installer: .mise, cacheEnvs: [
            ToolchainCacheEnv(variable: "UV_CACHE_DIR", subdirectory: "uv"),
        ], verify: "uv --version", defaultSpec: "uv@latest"),
        ToolchainEntry(id: "terraform", summary: "Terraform CLI", installer: .mise, verify: "terraform version", defaultSpec: "terraform@latest"),
        ToolchainEntry(id: "kubectl", summary: "Kubernetes CLI", installer: .mise, verify: "kubectl version --client", defaultSpec: "kubectl@latest"),

        // --- npm globals (require node, validated — never auto-installed) ---
        ToolchainEntry(id: "pnpm", summary: "pnpm package manager (global)", installer: .npm(package: "pnpm"), requires: [.node], cacheEnvs: [
            ToolchainCacheEnv(variable: "npm_config_store_dir", subdirectory: "pnpm-store"),
        ], verify: "pnpm --version"),
        ToolchainEntry(id: "yarn", summary: "Yarn classic (global)", installer: .npm(package: "yarn"), requires: [.node], cacheEnvs: [
            ToolchainCacheEnv(variable: "YARN_CACHE_FOLDER", subdirectory: "yarn"),
        ], verify: "yarn --version"),
        ToolchainEntry(id: "playwright", summary: "Playwright e2e runner + browsers cache", installer: .npm(package: "playwright"), requires: [.node], cacheEnvs: [
            ToolchainCacheEnv(variable: "PLAYWRIGHT_BROWSERS_PATH", subdirectory: "playwright"),
        ], verify: "playwright --version"),
        ToolchainEntry(id: "cypress", summary: "Cypress e2e runner + binary cache", installer: .npm(package: "cypress"), requires: [.node], cacheEnvs: [
            ToolchainCacheEnv(variable: "CYPRESS_CACHE_FOLDER", subdirectory: "cypress"),
        ], verify: "cypress --version"),
        ToolchainEntry(id: "netlify-cli", summary: "Netlify deploy CLI", installer: .npm(package: "netlify-cli"), requires: [.node], verify: "netlify --version"),
        ToolchainEntry(id: "firebase-tools", summary: "Firebase deploy CLI", installer: .npm(package: "firebase-tools"), requires: [.node], verify: "firebase --version"),

        // --- Homebrew (macOS guests only; no Linux equivalent in the catalog) ---
        ToolchainEntry(id: "yamllint", summary: "YAML linter", installer: .brew(formula: "yamllint", isCask: false), verify: "yamllint --version", platforms: [.macOS]),
        ToolchainEntry(id: "awscli", summary: "AWS CLI", installer: .brew(formula: "awscli", isCask: false), verify: "aws --version", platforms: [.macOS]),
        ToolchainEntry(id: "supabase", summary: "Supabase CLI", installer: .brew(formula: "supabase", isCask: false), verify: "supabase --version", platforms: [.macOS]),
        ToolchainEntry(id: "flyctl", summary: "Fly.io deploy CLI", installer: .brew(formula: "flyctl", isCask: false), verify: "flyctl version", platforms: [.macOS]),
        ToolchainEntry(id: "gcloud", summary: "Google Cloud SDK", installer: .brew(formula: "google-cloud-sdk", isCask: true), verify: "gcloud --version", platforms: [.macOS]),
        ToolchainEntry(id: "php", summary: "PHP runtime (Composer via the composer tool)", installer: .brew(formula: "php", isCask: false), verify: "php --version", platforms: [.macOS]),
        ToolchainEntry(id: "composer", summary: "PHP dependency manager", installer: .brew(formula: "composer", isCask: false), verify: "composer --version", platforms: [.macOS]),
        ToolchainEntry(id: "dotnet", summary: ".NET SDK (C#/F#/VB): brew cask on macOS, apt on Linux; no @version", installer: .brew(formula: "dotnet-sdk", isCask: true), cacheEnvs: [
            ToolchainCacheEnv(variable: "NUGET_PACKAGES", subdirectory: "nuget"),
        ], verify: "dotnet --list-sdks", linuxInstaller: .apt(packages: ["dotnet-sdk-8.0"])),

        // --- gems (macOS guests; Linux bakes use mise-managed ruby + plain gem) ---
        ToolchainEntry(id: "fastlane", summary: "iOS/Android release automation (uses the system Ruby)", installer: .gem(name: "fastlane"), verify: "fastlane --version", platforms: [.macOS]),
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
