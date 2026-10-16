import Foundation

/// Hard caps that apply whatever the flags say: a benchmark can never ask a
/// guest for more than this.
public enum BenchmarkLimits {
    public static let maxIterations = 10
    /// Largest generated payload (the Large suite's blob), in MB.
    public static let maxPayloadMB = 4096
    /// Largest `--project` archive copied into a guest, in MB.
    public static let maxProjectArchiveMB = 128
    /// Reports kept in the history directory.
    public static let keptReports = 20
    /// Seconds the fleet gets to drain busy VMs before a run gives up.
    public static let drainSeconds: TimeInterval = 600
}

/// What a benchmark run measures and how hard. Codable: it is the `bench_start` RPC payload.
public struct BenchmarkOptions: Codable, Sendable, Equatable {
    public enum Suite: String, Codable, Sendable, CaseIterable {
        case boot, casual, xcode, large, toolchains, video

        /// The suites a bare `kinhin bench` runs: everything except the slow toolchains and video passes.
        public static var defaults: [Suite] { [.boot, .casual, .xcode, .large] }
    }

    public enum Intensity: String, Codable, Sendable {
        case quick, thorough
    }

    public var suites: [Suite]
    public var intensity: Intensity
    /// Overrides the boot iteration count (1…`BenchmarkLimits.maxIterations`).
    public var iterations: Int?
    /// Runtimes to measure; nil = every healthy one for Boot, the fleet's primary for the workload suites.
    public var runtimes: [RuntimeID]?
    /// Toolchain ids (tools or stacks) for the toolchains suite.
    public var toolchains: [String]
    public var allToolchains: Bool
    /// Consent to benchmark the unisolated host runtime.
    public var includeHost: Bool
    /// A git URL to time a shallow clone of (Large suite).
    public var networkURL: String?
    /// A checkout to copy into the guest and build (Xcode suite).
    public var projectPath: String?
    /// Keep the host scratch directory for debugging.
    public var keep: Bool
    /// Do not wait for busy VMs to drain before pausing.
    public var force: Bool
    /// The caller has agreed to pause a fleet that has live VMs.
    public var confirmed: Bool

    public init(
        suites: [Suite] = Suite.defaults, intensity: Intensity = .quick, iterations: Int? = nil,
        runtimes: [RuntimeID]? = nil, toolchains: [String] = [], allToolchains: Bool = false,
        includeHost: Bool = false, networkURL: String? = nil, projectPath: String? = nil, keep: Bool = false,
        force: Bool = false, confirmed: Bool = false
    ) {
        self.suites = suites
        self.intensity = intensity
        self.iterations = iterations
        self.runtimes = runtimes
        self.toolchains = toolchains
        self.allToolchains = allToolchains
        self.includeHost = includeHost
        self.networkURL = networkURL
        self.projectPath = projectPath
        self.keep = keep
        self.force = force
        self.confirmed = confirmed
    }

    /// Throws `BenchmarkError.invalidOption` for anything that must not run.
    public func validate() throws {
        if suites.isEmpty { throw BenchmarkError.invalidOption("no suite selected") }
        if let iterations, !(1...BenchmarkLimits.maxIterations).contains(iterations) {
            throw BenchmarkError.invalidOption("--iterations must be 1 to \(BenchmarkLimits.maxIterations)")
        }
        if let networkURL { _ = try Self.validatedGitURL(networkURL) }
        if let projectPath { _ = try Self.validatedProjectDirectory(projectPath) }
        if runtimes?.contains(.host) == true, !includeHost {
            throw BenchmarkError.invalidOption(
                "benchmarking the host runtime needs --include-host (jobs run unisolated)")
        }
        for id in toolchains where ToolchainCatalog.tool(id: id) == nil && ToolchainCatalog.stack(id: id) == nil {
            throw BenchmarkError.invalidOption("unknown toolchain '\(id)' (see `kinhin toolchains`)")
        }
        if suites.contains(.toolchains), intensity == .thorough, toolchains.isEmpty, !allToolchains {
            throw BenchmarkError.invalidOption(
                "a thorough toolchains run installs every tool and takes 15 to 30 minutes or more: scope it with --toolchains <id,…> or pass --all-toolchains"
            )
        }
    }

    // MARK: - Validation helpers

    /// Only `https`, `ssh` and `git` URLs: no `ext::`, no `file:`, no plain `http`, nothing option-shaped.
    public static func validatedGitURL(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("-"),
            !value.contains(where: { $0.isWhitespace || $0.isNewline || $0.asciiValue.map { $0 < 0x20 } == true })
        else { throw BenchmarkError.invalidOption("--network needs a git URL without spaces or a leading '-'") }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
            ["https", "ssh", "git"].contains(scheme), let host = url.host, !host.isEmpty
        else { throw BenchmarkError.invalidOption("--network accepts only https://, ssh:// or git:// URLs") }
        return value
    }

    /// An existing directory, standardized; refuses newlines (the path is quoted into scripts).
    public static func validatedProjectDirectory(_ raw: String) throws -> URL {
        guard !raw.contains("\n"), !raw.isEmpty else {
            throw BenchmarkError.invalidOption("--project needs a directory path")
        }
        let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BenchmarkError.invalidOption("--project '\(raw)' is not a directory")
        }
        return url
    }
}

// MARK: - Sizing

/// The payload sizes and loop counts an intensity maps to, after the hard caps.
struct BenchmarkProfile: Sendable, Equatable {
    let iterations: Int
    let overheadLoops: Int
    let treeMB: Int
    let gitFiles: Int
    let swiftFiles: Int
    let xcodeFiles: Int
    let blobMB: Int
    let cpuMB: Int

    static func make(_ intensity: BenchmarkOptions.Intensity, iterations override: Int?) -> BenchmarkProfile {
        let thorough = intensity == .thorough
        let iterations = min(max(override ?? (thorough ? 3 : 1), 1), BenchmarkLimits.maxIterations)
        return BenchmarkProfile(
            iterations: iterations,
            overheadLoops: thorough ? 50 : 20,
            treeMB: thorough ? 256 : 64,
            gitFiles: thorough ? 1000 : 300,
            swiftFiles: thorough ? 200 : 60,
            xcodeFiles: thorough ? 400 : 120,
            blobMB: min(thorough ? 3072 : 512, BenchmarkLimits.maxPayloadMB),
            cpuMB: thorough ? 128 : 32)
    }
}
