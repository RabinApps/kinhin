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
        public let state: RuntimeSectionState
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
        public let state: RuntimeSectionState
        public let ok: Bool
        /// Install/start command or breakage reason, null when ready.
        public let fix: String?
        /// The configured Linux OCI image.
        public let image: String
        /// Whether that image is available locally.
        public let imageFound: Bool
        /// Configured container platform (`linux/arm64` or `linux/amd64`).
        public let platform: String
        /// Architecture the local image was built for, when known.
        public let imageArchitecture: String?
        /// Emulation disclosure, present only for `linux/amd64`.
        public let note: String?
    }

    /// Whether Docker is installed and can run on this Mac, reported whether
    /// or not the config enables it.
    public struct DockerAvailabilitySection: Codable, Equatable, Sendable {
        /// Whether the `docker` CLI was found.
        public let installed: Bool
        /// Whether at least one Docker install option can run on this Mac.
        public let supported: Bool
        /// Why Docker can't run here, null when supported.
        public let reason: String?

        public init(installed: Bool, supported: Bool, reason: String?) {
            self.installed = installed
            self.supported = supported
            self.reason = reason
        }
    }

    /// Host runtime state — present only when a `runtimes.routes` entry
    /// targets `host` (same presence rule as the checklist's host row).
    public struct HostSection: Codable, Equatable, Sendable {
        /// "ready" | "missing" | "broken".
        public let state: RuntimeSectionState
        public let ok: Bool
        /// Install command or breakage reason, null when ready.
        public let fix: String?
        /// The repo/workflow patterns routed to host execution.
        public let routes: [String]
        /// Always present: host jobs run unisolated on this Mac.
        public let warning: String
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

    /// The configured top-level `base_image:` — what `image prepare` starts
    /// from. Present only when the key is set (absent = the default macOS
    /// base, nothing to check).
    public struct TartBaseImageSection: Codable, Equatable, Sendable {
        /// The configured reference verbatim.
        public let reference: String
        /// "known" (pre-configured image) | "local" (local VM) | "unknown"
        /// (neither — the next prepare would fail mid-clone).
        public let state: String
        public let ok: Bool
        /// Rewriting advice for the "unknown" state, null otherwise.
        public let fix: String?
        /// True when the reference pins a digest (`ref@sha256:…`) — bakes
        /// are reproducible.
        public let pinned: Bool
        /// Reproducibility warning for a mutable tag (`:latest` or untagged),
        /// null when pinned or immutable.
        public let warning: String?

        public init(reference: String, state: String, ok: Bool, fix: String?, pinned: Bool, warning: String?) {
            self.reference = reference
            self.state = state
            self.ok = ok
            self.fix = fix
            self.pinned = pinned
            self.warning = warning
        }
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

    /// Isolation and transport settings that decide how far a hostile job
    /// can reach: Softnet, plain-http accounts, the shared toolchain cache.
    /// Advisories (`warnings`) never make the report not-ready; only a
    /// Softnet setting the fleet cannot honour does (`ok` false).
    public struct SecuritySection: Codable, Equatable, Sendable {
        /// `tart_softnet: true` in the config.
        public let softnetEnabled: Bool
        /// Whether the `softnet` binary was found.
        public let softnetInstalled: Bool
        /// False only when Softnet is enabled but not installed: the fleet
        /// refuses to start rather than boot VMs on the shared network.
        public let ok: Bool
        /// Repair command for the not-ok state, null otherwise.
        public let fix: String?
        /// Accounts that opted in to a non-loopback `http://` instance.
        public let insecureHTTPAccounts: [String]
        /// `toolchains.share_cache` is on: the cache is writable by every job.
        public let sharedCacheWritable: Bool
        /// Human-readable advisories, ready to print.
        public let warnings: [String]
        /// Why the guest's SSH host key could not be pinned on the last VM boot
        /// (connections then skip host key verification); null when pinning works.
        public let hostKeyUnpinned: String?

        public init(
            softnetEnabled: Bool, softnetInstalled: Bool, ok: Bool, fix: String?, insecureHTTPAccounts: [String],
            sharedCacheWritable: Bool, warnings: [String], hostKeyUnpinned: String? = nil
        ) {
            self.hostKeyUnpinned = hostKeyUnpinned
            self.softnetEnabled = softnetEnabled
            self.softnetInstalled = softnetInstalled
            self.ok = ok
            self.fix = fix
            self.insecureHTTPAccounts = insecureHTTPAccounts
            self.sharedCacheWritable = sharedCacheWritable
            self.warnings = warnings
        }
    }

    /// Unused local images `kinhin image prune` would sweep in one confirmed
    /// pass — present only when something is actually wasting disk. Pure
    /// advice: it never affects `ready`. The selection is the prune plan's
    /// own, computed from the listings this report was built from, so the
    /// numbers match what `kinhin image prune` prints for the same Mac.
    public struct ImagePruneSection: Codable, Equatable, Sendable {
        /// Installed unused images the sweep would remove (stale index
        /// records are not counted — they waste no disk).
        public let count: Int
        /// Whole GB those images occupy; nil when no target reported a size.
        public let reclaimGB: Int?
        /// The command that reviews the sweep (deletes only with `--yes`).
        public let command: String

        public init(count: Int, reclaimGB: Int?, command: String) {
            self.count = count
            self.reclaimGB = reclaimGB
            self.command = command
        }
    }

    /// Free disk below what the next instance needs — the engine's own
    /// pre-spawn guard (one instance's footprint + the reserve vs free
    /// disk), surfaced by doctor *before* the fleet holds spawns. Advice:
    /// it never affects `ready`; the rendered line adds how much the images
    /// hold and what `kinhin image prune` would reclaim.
    public struct DiskPressureSection: Codable, Equatable, Sendable {
        /// Free disk on the host right now, in GB.
        public let freeGB: Int
        /// The runtime whose next instance is being planned (the config's
        /// primary runtime — demand decides at spawn time).
        public let runtime: String
        /// One instance's disk footprint (config `disk_gb`, else the
        /// runtime's default estimate).
        public let instanceDiskGB: Int
        /// Reserved headroom the scaler never spends.
        public let reserveGB: Int

        public init(freeGB: Int, runtime: String, instanceDiskGB: Int, reserveGB: Int) {
            self.freeGB = freeGB
            self.runtime = runtime
            self.instanceDiskGB = instanceDiskGB
            self.reserveGB = reserveGB
        }
    }

    /// One account's live token verdict from `kinhin doctor --check-tokens`.
    public struct TokenCheck: Codable, Equatable, Sendable {
        public let account: String
        public let forge: String
        public let ok: Bool
        /// The probe's verdict line (what worked, or why it failed).
        public let message: String
        /// The command that stores a fresh token; null when ok.
        public let fix: String?

        public init(account: String, forge: String, ok: Bool, message: String, fix: String?) {
            self.account = account
            self.forge = forge
            self.ok = ok
            self.message = message
            self.fix = fix
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
    /// Docker install state and host support, present even when the config
    /// has no `docker:` section.
    public let dockerAvailability: DockerAvailabilitySection?
    /// Host runtime — present only when a route targets `host`.
    public let hostRuntime: HostSection?
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
    /// The configured tart `base_image:` — present only when the key is set.
    public let tartBaseImage: TartBaseImageSection?
    /// Isolation/transport posture — present only when the config parsed.
    public let security: SecuritySection?
    /// Per-runtime disk usage of the local images in GB, keyed "tart" /
    /// "container" / "docker" — the same totals `kinhin image list --json`
    /// prints under `totalGB`, so image bloat is visible in diagnostics too.
    /// A runtime whose sizes could not be read has no key; nil when nothing
    /// was measured (the config did not parse, so no listing ran).
    public let imageTotalGB: [String: Int]?
    /// The prune suggestion — nil when nothing is wasting disk.
    public let imagePrune: ImagePruneSection?
    /// The disk-pressure advisory — nil when free disk covers the next
    /// instance plus the reserve.
    public let diskPressure: DiskPressureSection?
    /// Live per-account token verdicts, in config order. Present only for
    /// `doctor --check-tokens` (a network probe); null means the tokens were
    /// not checked — `auth` above only says whether one is stored. Any failed
    /// entry makes `ready` false.
    public let tokenChecks: [TokenCheck]?

    public init(
        host: HostResources, clt: CLTSection, tart: TartSection, container: ContainerSection?,
        docker: DockerSection?, dockerAvailability: DockerAvailabilitySection? = nil, hostRuntime: HostSection? = nil,
        toolchainCache: ToolchainCacheSection,
        auth: AuthStatusReport, checks: [SetupCheckResult], ready: Bool, capacity: CapacitySection?,
        tartBaseImage: TartBaseImageSection? = nil, security: SecuritySection? = nil,
        imageTotalGB: [String: Int]? = nil, imagePrune: ImagePruneSection? = nil,
        diskPressure: DiskPressureSection? = nil, tokenChecks: [TokenCheck]? = nil
    ) {
        self.tokenChecks = tokenChecks
        self.host = host
        self.clt = clt
        self.tart = tart
        self.container = container
        self.docker = docker
        self.dockerAvailability = dockerAvailability
        self.hostRuntime = hostRuntime
        self.toolchainCache = toolchainCache
        self.auth = auth
        self.checks = checks
        self.ready = ready
        self.capacity = capacity
        self.tartBaseImage = tartBaseImage
        self.security = security
        self.imageTotalGB = imageTotalGB
        self.imagePrune = imagePrune
        self.diskPressure = diskPressure
    }
}
