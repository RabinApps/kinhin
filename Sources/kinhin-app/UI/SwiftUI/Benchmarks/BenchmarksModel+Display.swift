import Foundation
import KinhinKit

// The strings and tables the Benchmarks view shows, derived from a report.
// Durations and sizes go through the system formatters; phase and step names
// are measurement identifiers and stay verbatim.

extension BenchmarkOptions.Suite {
    var label: String {
        switch self {
        case .boot: return String(localized: "Boot", bundle: .l10n, comment: "Benchmark suite name")
        case .casual: return String(localized: "Casual", bundle: .l10n, comment: "Benchmark suite name")
        case .xcode:
            return String(
                localized: "Xcode", bundle: .l10n, comment: "Benchmark suite name; the product name stays verbatim")
        case .large: return String(localized: "Large", bundle: .l10n, comment: "Benchmark suite name")
        case .toolchains: return String(localized: "Toolchains", bundle: .l10n, comment: "Benchmark suite name")
        case .video: return String(localized: "Video", bundle: .l10n, comment: "Benchmark suite name")
        }
    }

    /// One line under the toggle saying what the suite measures.
    var summary: String {
        switch self {
        case .boot:
            return String(
                localized: "How long each runtime takes to boot", bundle: .l10n, comment: "Benchmark suite description")
        case .casual:
            return String(
                localized: "File I/O, git and a Swift build in one guest", bundle: .l10n,
                comment: "Benchmark suite description; Swift and git stay verbatim")
        case .xcode:
            return String(
                localized: "Clean and incremental xcodebuild builds", bundle: .l10n,
                comment: "Benchmark suite description; xcodebuild stays verbatim")
        case .large:
            return String(
                localized: "Multi-gigabyte disk and multi-core CPU throughput", bundle: .l10n,
                comment: "Benchmark suite description")
        case .toolchains:
            return String(
                localized: "Install, verify and build with every catalog toolchain", bundle: .l10n,
                comment: "Benchmark suite description")
        case .video:
            return String(
                localized: "Image pull and clean and cached video builds in a container", bundle: .l10n,
                comment: "Benchmark suite description")
        }
    }
}

extension BenchmarkOptions.Intensity {
    var label: String {
        switch self {
        case .quick: return String(localized: "Quick", bundle: .l10n, comment: "Benchmark intensity")
        case .thorough: return String(localized: "Thorough", bundle: .l10n, comment: "Benchmark intensity")
        }
    }
}

extension BenchmarksModel.ToolchainSort {
    var label: String {
        switch self {
        case .tool: return String(localized: "Tool", bundle: .l10n, comment: "Toolchains benchmark column")
        case .install: return String(localized: "Install", bundle: .l10n, comment: "Toolchains benchmark column")
        case .verify: return String(localized: "Verify", bundle: .l10n, comment: "Toolchains benchmark column")
        case .workload: return String(localized: "Workload", bundle: .l10n, comment: "Toolchains benchmark column")
        }
    }
}

/// One measured line of a suite.
struct BenchmarkDisplayLine: Identifiable, Equatable {
    let id: String
    let name: String
    let value: String
    let detail: String?
    let skipped: Bool
}

/// One runtime's row of the cross-runtime boot comparison.
struct BootComparisonRow: Identifiable, Equatable {
    var id: String { runtime }
    let runtime: String
    let platform: String?
    /// Phase name → formatted median, in `columns` order ("—" where the runtime has no such phase).
    let cells: [String]
    /// Why the row has no numbers (skipped or failed).
    let note: String?
}

struct BootComparison: Equatable {
    let columns: [String]
    let rows: [BootComparisonRow]
}

/// One row of the toolchains table.
struct ToolchainDisplayRow: Identifiable, Equatable {
    var id: String { "\(runtime)/\(tool)" }
    let tool: String
    let runtime: String
    let platform: String
    let installer: String
    let install: String
    let verify: String
    let workload: String
    let note: String?
    let failed: Bool
}

extension BenchmarksModel {
    // MARK: - Formatting

    static func milliseconds(_ value: Double) -> String {
        let (amount, unit): (Double, UnitDuration) =
            value < 1000
            ? (value, .milliseconds) : value < 60_000 ? (value / 1000, .seconds) : (value / 60_000, .minutes)
        return Measurement(value: amount, unit: unit).formatted(
            .measurement(
                width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0...1))))
    }

    static func throughput(_ bytesPerSecond: Double) -> String {
        let size = AppFormat.bytes(Int64(bytesPerSecond))
        return String(
            localized: "\(size)/s", bundle: .l10n, comment: "Benchmark throughput; %@ is a size such as 245 MB")
    }

    static func line(of step: BenchmarkStep) -> BenchmarkDisplayLine {
        if step.skipped == true {
            return BenchmarkDisplayLine(
                id: step.name, name: step.name,
                value: String(localized: "skipped", bundle: .l10n, comment: "Benchmark step that did not run"),
                detail: step.note, skipped: true)
        }
        var parts: [String] = []
        if let min = step.minMs, let max = step.maxMs, (step.samples ?? 1) > 1 {
            parts.append("\(milliseconds(min)) – \(milliseconds(max))")
        }
        if let throughput = step.throughput { parts.append(Self.throughput(throughput)) }
        if let note = step.note { parts.append(note) }
        return BenchmarkDisplayLine(
            id: step.name, name: step.name, value: milliseconds(step.durationMs),
            detail: parts.isEmpty ? nil : parts.joined(separator: " · "), skipped: false)
    }

    // MARK: - Sections

    /// The results on screen: the live run's finished suites, or the report's.
    var visibleSuites: [BenchmarkSuiteResult] { report?.suites ?? partials }

    /// Suites other than Boot (which has its own comparison table) and Toolchains (its own table).
    var stepSuites: [BenchmarkSuiteResult] {
        visibleSuites.filter { $0.name != "boot" && $0.toolchains == nil }
    }

    var toolchainSuites: [BenchmarkSuiteResult] { visibleSuites.filter { $0.toolchains != nil } }

    func title(of suite: BenchmarkSuiteResult) -> String {
        let name = BenchmarkOptions.Suite(rawValue: suite.name)?.label ?? suite.name
        return suite.platform.map { "\(name) — \(suite.runtime) (\($0))" } ?? "\(name) — \(suite.runtime)"
    }

    func lines(of suite: BenchmarkSuiteResult) -> [BenchmarkDisplayLine] {
        suite.steps.map(Self.line(of:))
    }

    /// Why a suite has no numbers, or nil when it ran.
    func problem(of suite: BenchmarkSuiteResult) -> StatusLine? {
        switch suite.status {
        case .ran: return nil
        case .skipped:
            return StatusLine(
                text: String(
                    localized: "Skipped — \(suite.skipReason ?? "")", bundle: .l10n,
                    comment: "Benchmark suite that did not run; %@ is the reason"))
        case .failed:
            return StatusLine(
                text: String(
                    localized: "Failed — \(suite.error ?? "")", bundle: .l10n,
                    comment: "Benchmark suite that failed; %@ is the reason"),
                style: .error)
        }
    }

    /// Per-runtime phase columns for the Boot suite, the answer to "which runtime boots fastest here".
    var bootComparison: BootComparison? {
        let boots = visibleSuites.filter { $0.name == "boot" }
        guard !boots.isEmpty else { return nil }
        var columns: [String] = []
        for suite in boots { for step in suite.steps where !columns.contains(step.name) { columns.append(step.name) } }
        let rows = boots.map { suite -> BootComparisonRow in
            let cells = columns.map { column in
                suite.steps.first { $0.name == column }.map { Self.milliseconds($0.durationMs) } ?? "—"
            }
            return BootComparisonRow(
                runtime: suite.platform.map { "\(suite.runtime) · \($0)" } ?? suite.runtime,
                platform: suite.platform, cells: cells, note: problem(of: suite)?.text)
        }
        return BootComparison(columns: columns, rows: rows)
    }

    /// The toolchains table, ordered by the chosen column.
    func toolchainRows(of suite: BenchmarkSuiteResult) -> [ToolchainDisplayRow] {
        let raw = suite.toolchains ?? []
        let ordered = raw.sorted { lhs, rhs in
            let ascending: Bool
            switch toolchainSort {
            case .tool: ascending = lhs.tool < rhs.tool
            case .install: ascending = (lhs.installMs ?? .infinity) < (rhs.installMs ?? .infinity)
            case .verify: ascending = (lhs.verifyMs ?? .infinity) < (rhs.verifyMs ?? .infinity)
            case .workload: ascending = (lhs.workloadMs ?? .infinity) < (rhs.workloadMs ?? .infinity)
            }
            return toolchainSortAscending ? ascending : !ascending
        }
        let none = "—"
        return ordered.map { row in
            let note: String?
            switch row.status {
            case .ran: note = row.note ?? row.skipReason
            case .skipped: note = row.skipReason
            case .failed: note = row.note
            }
            return ToolchainDisplayRow(
                tool: row.tool, runtime: row.runtime, platform: row.platform, installer: row.installer,
                install: row.installMs.map(Self.milliseconds) ?? none,
                verify: row.verifyMs.map(Self.milliseconds) ?? none,
                workload: row.workloadMs.map(Self.milliseconds) ?? none, note: note, failed: row.status == .failed)
        }
    }

    func sortToolchains(by column: ToolchainSort) {
        if toolchainSort == column {
            toolchainSortAscending.toggle()
        } else {
            toolchainSort = column
            toolchainSortAscending = true
        }
    }

    // MARK: - Summaries

    /// "Boot: tart 14 s · docker 3.2 s — 2 hours ago", for the Fleet tab's card.
    func summary(of report: BenchmarkReport) -> String {
        let when = AppFormat.relative(report.finishedAt)
        return String(
            localized: "Last run \(when) on \(report.host.chip)", bundle: .l10n,
            comment: "Fleet tab benchmark card; %1$@ is a relative time such as 2 hours ago, %2$@ the Mac's chip")
    }

    /// The live run's one-line progress ("boot › docker › exec-ready").
    var progressLine: String? {
        guard let progress, isRunning else { return nil }
        let line = progress.line
        return line.isEmpty ? nil : line
    }

    func historyTitle(_ entry: BenchmarkReportStore.Entry) -> String {
        entry.startedAt.formatted(date: .abbreviated, time: .shortened)
    }
}
