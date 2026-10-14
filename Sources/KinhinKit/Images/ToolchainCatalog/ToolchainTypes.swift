import Foundation

// MARK: - Shared cache mount

/// Where the shared toolchain cache lives on the host and inside guests.
/// `image prepare` always mounts it (faster re-prepares); runner VMs mount
/// it when the project sets `share_cache`.
public enum ToolchainCacheMount {
    /// tart auto-mounts virtiofs shares under this path inside macOS guests.
    static let guestSharesRoot = "/Volumes/My Shared Files"
    /// Directory (under `Paths.appSupport`) holding the host cache.
    static let hostDirectoryName = "toolchain-cache"
    /// Directory (inside the virtiofs share) holding the cache. A distinct
    /// name keeps the share safe if other shares ever join the same mount.
    static let guestDirectoryName = "kinhin-cache"

    /// The `tart run --dir` argument sharing the host cache (`name:hostpath`). tart
    /// mounts a share at `/Volumes/My Shared Files/<name>` in macOS guests, which is
    /// where `guestPath` points, and under the virtiofs automount tag in Linux guests.
    public static var tartDirectorySpec: String { tartDirectorySpec(scope: nil) }

    /// The `--dir` spec sharing the host cache, or, with a `scope` (a
    /// project image key), only that project's own subdirectory, so repos
    /// that opt into the cache never see each other's downloads. The
    /// directory is created on demand.
    public static func tartDirectorySpec(scope: String?) -> String {
        guard let scope else { return guestDirectoryName + ":" + Paths.toolchainCache.path }
        let directory = Paths.toolchainCache.appendingPathComponent(scope, isDirectory: true)
        bestEffort("cache", "creating the cache directory for \(scope)") {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return guestDirectoryName + ":" + directory.path
    }

    /// Absolute guest-side path of the shared cache in macOS guests.
    public static var guestPath: String { guestSharesRoot + "/" + guestDirectoryName }
    /// Absolute guest-side path of the shared cache in Linux guests
    /// (apple/container bind mounts). Chosen to be writable by root, which
    /// is the default user in runner containers.
    public static let linuxGuestPath = "/var/kinhin-cache"
    /// Where a tart Linux guest mounts the virtiofs automount tag (Linux
    /// guests do not auto-mount like macOS ones); `linuxGuestPath` is then a
    /// symlink to the cache directory inside it.
    static let linuxVirtiofsRoot = "/mnt/shared"

    /// The `-v/--volume` spec for binding the host cache into a Linux
    /// container (`container run -v <host>:<guest>` — the syntax documented
    /// by apple/container's command reference).
    static func volumeSpec(host: String) -> String {
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
    case java

    /// The catalog tool id that satisfies this requirement.
    public var toolID: String { rawValue }

    /// A `toolchains.specs` entry that satisfies it, for error messages.
    public var example: String {
        switch self {
        case .node: return "node@22"
        case .dotnet: return "dotnet"
        case .java: return "java@temurin-21"
        }
    }
}

// MARK: - Categories

/// How the Toolchains UI groups tools. Purely presentational.
public enum ToolchainCategory: String, Sendable, CaseIterable {
    case languages
    case javascript
    case build
    case cloud

    public var title: String {
        switch self {
        case .languages: return "Languages & runtimes"
        case .javascript: return "JavaScript tools (need Node)"
        case .build: return "Build & quality tools"
        case .cloud: return "Cloud & DevOps"
        }
    }
}

// MARK: - Cache map

/// One environment variable pointed into the shared cache. The value is
/// `<cache mount>/<subdirectory>` — created on demand by the install script
/// and skipped gracefully when the cache mount is absent.
public struct ToolchainCacheEnv: Sendable, Equatable {
    public let variable: String
    let subdirectory: String

    public init(variable: String, subdirectory: String) {
        self.variable = variable
        self.subdirectory = subdirectory
    }
}

// MARK: - Tools

/// A single installable tool. `installer` says how `image prepare` installs
/// it; `verify` must exit 0 afterwards or the prepare aborts (old image kept
/// intact). Unknown specs beyond this table still pass through to mise/brew.

public struct ToolchainEntry: Sendable, Equatable {
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
    let cacheEnvs: [ToolchainCacheEnv]
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
    /// Apt packages the tool needs on Linux beyond its own installer (shared libraries it links).
    /// Added whenever the tool is selected on Linux. `a|b` names one package by alternatives: the first one the
    /// guest's apt knows is installed (for libraries whose name differs between base images).
    public let linuxAptPackages: [String]
    /// UI grouping.
    public let category: ToolchainCategory

    public init(
        id: String, summary: String, installer: Installer, requires: [ToolchainRequirement] = [],
        cacheEnvs: [ToolchainCacheEnv] = [], verify: String, defaultSpec: String = "",
        platforms: [ToolchainPlatform] = ToolchainPlatform.allCases, linuxInstaller: Installer? = nil,
        linuxAptPackages: [String] = [],
        category: ToolchainCategory = .build
    ) {
        self.category = category
        self.linuxAptPackages = linuxAptPackages
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

    /// The `mise use` spec for this entry: the pinned version, else the
    /// default, else `id@latest` (entries whose mise install is Linux-only
    /// carry no default so config files stay free of `@latest`).
    func miseSpec(version: String?) -> String {
        if let version { return "\(id)@\(version)" }
        return defaultSpec.isEmpty ? "\(id)@latest" : defaultSpec
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
public struct ToolchainStack: Sendable, Equatable {
    /// An npm dependency with an optional pinned version.
    public struct NPMPackage: Sendable, Equatable {
        public let name: String
        public let version: String  // "" = latest
        public init(name: String, version: String = "") {
            self.name = name
            self.version = version
        }
    }

    public let id: String
    public let summary: String
    public let requires: [ToolchainRequirement]
    let brewTaps: [String]
    let brewFormulas: [String]
    let miseSpecs: [String]
    let npmPackages: [NPMPackage]
    let cacheEnvs: [ToolchainCacheEnv]
    public let verify: String
    /// What `@version` means for this stack; nil = version unsupported.
    public let versionKind: String?
    /// Short note shown under the version field in the Advanced → Toolchains UI.
    let versionHint: String?
    /// The version applied when the config doesn't pin one ("" = none).
    public let defaultVersion: String
    /// Extra shell steps run after installs. The literal `<version>` is
    /// replaced with the effective version; steps still containing the
    /// placeholder are dropped when no version is pinned.
    let postInstall: [String]
    /// Platforms this stack installs on (macOS-only for the iOS-adjacent
    /// recipes: CocoaPods and watchman do not exist on Linux).
    public let platforms: [ToolchainPlatform]
    /// Linux guests have no Homebrew: a stack that supports Linux installs
    /// through these instead of `brewTaps`/`brewFormulas`. apt packages
    /// (guarded, run as root) ...
    let linuxAptPackages: [String]
    /// ... then these shell steps (`<version>` is replaced with the effective
    /// version, shell-quoted; the version is always applied — no cache mount
    /// is needed because the install lands inside the image) ...
    let linuxSteps: [String]
    /// ... and this verify command (nil = reuse `verify`).
    let linuxVerify: String?

    public init(
        id: String, summary: String, requires: [ToolchainRequirement] = [], brewTaps: [String] = [],
        brewFormulas: [String] = [], miseSpecs: [String] = [], npmPackages: [NPMPackage] = [],
        cacheEnvs: [ToolchainCacheEnv] = [], verify: String, versionKind: String? = nil, defaultVersion: String = "",
        versionHint: String? = nil, postInstall: [String] = [],
        platforms: [ToolchainPlatform] = ToolchainPlatform.allCases,
        linuxAptPackages: [String] = [], linuxSteps: [String] = [], linuxVerify: String? = nil
    ) {
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
        self.linuxAptPackages = linuxAptPackages
        self.linuxSteps = linuxSteps
        self.linuxVerify = linuxVerify
    }

    /// Splits "flutter@3.24.0" into ("flutter", "3.24.0"); a bare id or a
    /// trailing "@" yields a nil version.
    static func splitSpec(_ name: String) -> (id: String, version: String?) {
        guard let at = name.firstIndex(of: "@") else { return (name, nil) }
        let id = String(name[..<at])
        let version = String(name[name.index(after: at)...])
        guard !version.isEmpty else { return (id, nil) }
        return (id, version)
    }

    /// The effective version: the pinned one, else the stack default.
    func effectiveVersion(pinned: String?) -> String {
        pinned ?? defaultVersion
    }
}

// MARK: - Resolved selection

/// A Homebrew install target.
struct BrewFormula: Sendable, Equatable, Hashable {
    let name: String
    let isCask: Bool
    init(name: String, isCask: Bool) {
        self.name = name
        self.isCask = isCask
    }
}

/// Everything the managed-toolchain install script needs, resolved from a
/// validated `toolchains:` config. Only what the user selected appears here
/// — resolution maps ids to installers, caches, and verifications; it never
/// adds a tool.
public struct ManagedToolchainSelection: Sendable, Equatable {
    var brewTaps: [String] = []
    var brewFormulas: [BrewFormula] = []
    var miseSpecs: [String] = []
    var npmPackages: [ToolchainStack.NPMPackage] = []
    var gems: [String] = []
    /// apt packages for Linux guests (e.g. `dotnet-sdk-10.0`).
    var aptPackages: [String] = []
    /// Post-install steps emitted verbatim (e.g. `fvm install 3.24.0`).
    var stackSteps: [String] = []
    /// Deduped cache-env exports, in stable selection order.
    var cacheEnvs: [ToolchainCacheEnv] = []
    /// Verify commands appended to the install script (fail-fast).
    var verifications: [String] = []
    /// True when a selected entry was skipped because it does not support
    /// the requested platform (surfaced as a log line, never an error).
    var skippedEntries: [String] = []

    public init() {}
}
