import Foundation

/// How a suite (or a toolchain row) ended.
public enum BenchmarkOutcome: String, Codable, Sendable, Equatable {
    case ran, skipped, failed
}

/// One timed measurement. `durationMs` is the median over `samples` runs
/// (the value itself when a step ran once); `minMs`/`maxMs` bracket it.
public struct BenchmarkStep: Codable, Sendable, Equatable {
    public var name: String
    public var durationMs: Double
    public var minMs: Double?
    public var maxMs: Double?
    public var samples: Int?
    /// Bytes per second, for steps that move data.
    public var throughput: Double?
    public var note: String?
    /// A step that did not run (a missing tool); `note` says why.
    public var skipped: Bool?

    public init(
        name: String, durationMs: Double, minMs: Double? = nil, maxMs: Double? = nil, samples: Int? = nil,
        throughput: Double? = nil, note: String? = nil, skipped: Bool? = nil
    ) {
        self.name = name
        self.durationMs = durationMs
        self.minMs = minMs
        self.maxMs = maxMs
        self.samples = samples
        self.throughput = throughput
        self.note = note
        self.skipped = skipped
    }

    /// Median/min/max over repeated runs of one phase.
    static func summarizing(_ name: String, milliseconds: [Double], note: String? = nil) -> BenchmarkStep {
        let sorted = milliseconds.sorted()
        guard !sorted.isEmpty else { return BenchmarkStep(name: name, durationMs: 0, note: note) }
        let mid = sorted.count / 2
        let median = sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
        return BenchmarkStep(
            name: name, durationMs: median, minMs: sorted.first, maxMs: sorted.last, samples: sorted.count,
            note: note)
    }
}

/// One row of the toolchains suite: a catalog tool or stack on one platform.
public struct ToolchainBenchRow: Codable, Sendable, Equatable {
    public var tool: String
    public var platform: String
    public var runtime: String
    public var installer: String
    public var status: BenchmarkOutcome
    public var installMs: Double?
    public var verifyMs: Double?
    public var workloadMs: Double?
    public var workload: String?
    public var skipReason: String?
    public var note: String?

    public init(
        tool: String, platform: String, runtime: String, installer: String, status: BenchmarkOutcome,
        installMs: Double? = nil, verifyMs: Double? = nil, workloadMs: Double? = nil, workload: String? = nil,
        skipReason: String? = nil, note: String? = nil
    ) {
        self.tool = tool
        self.platform = platform
        self.runtime = runtime
        self.installer = installer
        self.status = status
        self.installMs = installMs
        self.verifyMs = verifyMs
        self.workloadMs = workloadMs
        self.workload = workload
        self.skipReason = skipReason
        self.note = note
    }
}

/// What one suite measured on one runtime.
public struct BenchmarkSuiteResult: Codable, Sendable, Equatable {
    public var name: String
    public var runtime: String
    public var platform: String?
    public var status: BenchmarkOutcome
    public var skipReason: String?
    /// Why a `failed` suite stopped.
    public var error: String?
    /// Tags such as `unisolated`.
    public var notes: [String]
    public var steps: [BenchmarkStep]
    /// Set for the toolchains suite instead of `steps`.
    public var toolchains: [ToolchainBenchRow]?

    public init(
        name: String, runtime: String, platform: String? = nil, status: BenchmarkOutcome, skipReason: String? = nil,
        error: String? = nil, notes: [String] = [], steps: [BenchmarkStep] = [], toolchains: [ToolchainBenchRow]? = nil
    ) {
        self.name = name
        self.runtime = runtime
        self.platform = platform
        self.status = status
        self.skipReason = skipReason
        self.error = error
        self.notes = notes
        self.steps = steps
        self.toolchains = toolchains
    }

    static func skipped(_ name: String, runtime: RuntimeID, reason: String) -> BenchmarkSuiteResult {
        BenchmarkSuiteResult(name: name, runtime: runtime.rawValue, status: .skipped, skipReason: reason)
    }
}

/// The machine-readable record of one run, written to the bench history directory.
public struct BenchmarkReport: Codable, Sendable, Equatable {
    public struct Host: Codable, Sendable, Equatable {
        public var chip: String
        public var cores: Int
        public var memoryGB: Int
        public var freeDiskGB: Int
        public var arm64: Bool
        public var os: String

        public init(chip: String, cores: Int, memoryGB: Int, freeDiskGB: Int, arm64: Bool, os: String) {
            self.chip = chip
            self.cores = cores
            self.memoryGB = memoryGB
            self.freeDiskGB = freeDiskGB
            self.arm64 = arm64
            self.os = os
        }
    }

    /// The configuration the numbers belong to.
    public struct Setup: Codable, Sendable, Equatable {
        public var image: String
        public var containerImage: String?
        public var dockerImage: String?
        public var runtimes: [String]
        public var vmCPU: Int
        public var vmMemoryGB: Int
        public var softnet: Bool

        public init(
            image: String, containerImage: String?, dockerImage: String?, runtimes: [String], vmCPU: Int,
            vmMemoryGB: Int, softnet: Bool
        ) {
            self.image = image
            self.containerImage = containerImage
            self.dockerImage = dockerImage
            self.runtimes = runtimes
            self.vmCPU = vmCPU
            self.vmMemoryGB = vmMemoryGB
            self.softnet = softnet
        }
    }

    public var runID: String
    public var startedAt: Date
    public var finishedAt: Date
    public var kinhinVersion: String
    public var host: Host
    public var setup: Setup
    public var intensity: String
    public var suites: [BenchmarkSuiteResult]

    public init(
        runID: String, startedAt: Date, finishedAt: Date, kinhinVersion: String, host: Host, setup: Setup,
        intensity: String, suites: [BenchmarkSuiteResult]
    ) {
        self.runID = runID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.kinhinVersion = kinhinVersion
        self.host = host
        self.setup = setup
        self.intensity = intensity
        self.suites = suites
    }

    public var elapsedSeconds: Double { finishedAt.timeIntervalSince(startedAt) }

    /// Whether anything that should have worked did not: a suite that failed, or a toolchain that did not
    /// install, verify or build. Skipped work is not a failure. The CLI exits 1 on this.
    public var hasFailures: Bool {
        suites.contains { suite in
            suite.status == .failed || (suite.toolchains ?? []).contains { $0.status == .failed }
        }
    }
}

// MARK: - History

/// The reports on disk: `results-<timestamp>.json` under the bench directory (0700, files 0600).
public struct BenchmarkReportStore: Sendable {
    public struct Entry: Sendable, Equatable {
        public let url: URL
        public let runID: String
        public let startedAt: Date
    }

    public let directory: URL

    public init(directory: URL = BenchmarkReportStore.defaultDirectory) {
        self.directory = directory
    }

    public static var defaultDirectory: URL { Paths.appSupport.appendingPathComponent("bench", isDirectory: true) }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Writes the report and prunes the history to the newest `keep`.
    @discardableResult
    public func write(_ report: BenchmarkReport, keep: Int = BenchmarkLimits.keptReports) throws -> URL {
        try Paths.createPrivateDirectory(directory)
        let url = self.url(for: report)
        try Paths.writePrivateFile(Self.encoder().encode(report), to: url)
        prune(keep: keep)
        return url
    }

    /// Where `report` is (or would be) stored.
    public func url(for report: BenchmarkReport) -> URL {
        let stamp = Self.stampFormatter.string(from: report.startedAt)
        return directory.appendingPathComponent("results-\(stamp)-\(report.runID.suffix(4)).json")
    }

    /// Reports newest first. An unreadable file is skipped, not fatal.
    public func list() -> [Entry] {
        let files =
            // No results folder yet means no history.
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("results-") && $0.pathExtension == "json" }
            // Unreadable reports are skipped (documented above), not fatal to the list.
            .compactMap { url -> Entry? in
                // Skipped like the line above says.
                guard let report = try? load(url) else { return nil }
                return Entry(url: url, runID: report.runID, startedAt: report.startedAt)
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func load(_ url: URL) throws -> BenchmarkReport {
        try Self.decoder().decode(BenchmarkReport.self, from: Data(contentsOf: url))
    }

    public func latest() -> BenchmarkReport? {
        // list() already decoded this file; a race with its deletion reads as no report.
        list().first.flatMap { try? load($0.url) }
    }

    func prune(keep: Int) {
        for entry in list().dropFirst(max(keep, 1)) {
            bestEffort("bench", "pruning \(entry.url.lastPathComponent)") {
                try FileManager.default.removeItem(at: entry.url)
            }
        }
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
