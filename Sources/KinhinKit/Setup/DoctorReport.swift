import Foundation

/// Machine-readable `kinhin doctor --json` contract: one document merging the
/// host/capacity probes, runtime health (CLT, tart, Apple container), the
/// stored-token state of every forge (`AuthStatusReport`), and the first-run
/// checklist (`SetupStatus`) — one-shot CI diagnostics.
/// Field names are a stable API: add, never rename. No secret beyond the
/// masked 4-character token prefixes ever appears in the document.
public struct DoctorReport: Codable, Equatable, Sendable {
    public struct CLTSection: Codable, Equatable, Sendable {
        /// "ok" | "outdated" | "missing" | "unselected" (the CLTState cases).
        public let state: String
        public let version: String?
        public let ok: Bool
        /// Repair command line for a broken state, null when ok.
        public let fixCommand: String?
        /// Extra fallback advice (present for the outdated state only).
        let fixHint: String?
    }

    public struct TartSection: Codable, Equatable, Sendable {
        /// "healthy" | "missing" | "killedOnLaunch" | "broken".
        public let state: String
        public let ok: Bool
        /// Failure reason when not healthy, null otherwise.
        public let reason: String?
        /// Ordered repair command lines (same plans the human doctor prints).
        public let repairCommands: [String]
    }

    public struct ContainerSection: Codable, Equatable, Sendable {
        /// "ready" | "missing" | "broken".
        public let state: String
        public let ok: Bool
        /// Install/start command or breakage reason, null when ready.
        public let fix: String?
        /// The configured Linux OCI image.
        public let image: String
        /// Whether that image is available locally.
        public let imageFound: Bool
    }

    /// Docker runtime state — present only when config.yaml declares a
    /// `docker:` section (same shape as the container section).
    public struct DockerSection: Codable, Equatable, Sendable {
        /// "ready" | "missing" | "broken".
        public let state: String
        public let ok: Bool
        /// Install/start command or breakage reason, null when ready.
        public let fix: String?
        /// The configured Linux OCI image.
        public let image: String
        /// Whether that image is available locally.
        public let imageFound: Bool
    }

    public struct CapacitySection: Codable, Equatable, Sendable {
        /// Upper bound on simultaneous VMs on this host (user max applied).
        public let maxConcurrent: Int
        /// Human-readable explanation of the binding constraint.
        public let bindingConstraint: String
        /// Whether the configured single-VM shape fits at all.
        public let fits: Bool
        /// maxConcurrent × runners_per_vm — concurrent jobs.
        public let jobSlots: Int
    }

    /// Shared toolchain cache state (the mount `image prepare` writes
    /// through and runner VMs/containers bind when `share_cache: true`).
    public struct ToolchainCacheSection: Codable, Equatable, Sendable {
        public struct Ecosystem: Codable, Equatable, Sendable {
            /// Cache subdirectory under the cache root, e.g. "npm", "go/mod".
            public let directory: String
            /// Total bytes currently cached in that subdirectory.
            public let bytes: Int64

            public init(directory: String, bytes: Int64) {
                self.directory = directory
                self.bytes = bytes
            }
        }

        /// Always true — the host cache root is created on demand.
        public let root: String
        /// Whether the cache root directory exists (and is writable).
        public let usable: Bool
        /// True when the config's `toolchains.share_cache` mounts the cache
        /// into every runner VM/container.
        let sharedWithRunners: Bool
        /// True when `sharedWithRunners` is on but the cache holds nothing —
        /// runners would mount an empty directory until a prepare populates it.
        public let warning: Bool
        /// Total bytes across every ecosystem subdirectory.
        public let totalBytes: Int64
        /// Per-ecosystem breakdown for the directories actually selected in
        /// the config's `toolchains:` (top-level subdirectories with content
        /// when nothing is selected).
        public let ecosystems: [Ecosystem]

        public init(
            root: String, usable: Bool, sharedWithRunners: Bool, warning: Bool, totalBytes: Int64,
            ecosystems: [Ecosystem]
        ) {
            self.root = root
            self.usable = usable
            self.sharedWithRunners = sharedWithRunners
            self.warning = warning
            self.totalBytes = totalBytes
            self.ecosystems = ecosystems
        }
    }

    /// Host snapshot (cores, memory, free disk, arm64).
    public let host: HostResources
    /// Command Line Tools state + repair command.
    public let clt: CLTSection
    /// Tart binary health + ordered repair command lines.
    public let tart: TartSection
    /// Apple-container runtime — present only when config.yaml declares a
    /// `container:` section (mirrors the checklist rows).
    public let container: ContainerSection?
    /// Docker runtime — present only when config.yaml declares a `docker:`
    /// section (same presence rule as the checklist's docker rows).
    public let docker: DockerSection?
    /// Shared toolchain cache state.
    public let toolchainCache: ToolchainCacheSection
    /// Stored-token state for every forge (static, no network probes).
    public let auth: AuthStatusReport
    /// The full first-run checklist (same rows `setup-status --json` emits).
    public let checks: [SetupCheckResult]
    /// True only when the checklist is green *and* `auth.allGood`.
    public let ready: Bool
    /// Computed host budget — present only when the config parsed.
    public let capacity: CapacitySection?

    public init(
        host: HostResources, clt: CLTSection, tart: TartSection, container: ContainerSection?,
        docker: DockerSection?, toolchainCache: ToolchainCacheSection, auth: AuthStatusReport,
        checks: [SetupCheckResult], ready: Bool, capacity: CapacitySection?
    ) {
        self.host = host
        self.clt = clt
        self.tart = tart
        self.container = container
        self.docker = docker
        self.toolchainCache = toolchainCache
        self.auth = auth
        self.checks = checks
        self.ready = ready
        self.capacity = capacity
    }
}
