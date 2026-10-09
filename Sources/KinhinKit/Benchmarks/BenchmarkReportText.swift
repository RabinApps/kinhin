import Foundation

/// The plain-text rendering of a report for a terminal (the CLI). The app
/// builds its own localized tables from the same fields.
public enum BenchmarkFormat {
    /// `812 ms`, `12.4 s`, `3 m 12 s`, `1 h 04 m`.
    public static func duration(milliseconds: Double) -> String {
        if milliseconds < 1000 { return String(format: "%.0f ms", milliseconds) }
        let seconds = milliseconds / 1000
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        let whole = Int(seconds.rounded())
        if whole < 3600 { return "\(whole / 60) m \(String(format: "%02d", whole % 60)) s" }
        return "\(whole / 3600) h \(String(format: "%02d", (whole % 3600) / 60)) m"
    }

    /// `245 MB/s` (decimal units, like the disks' own labels).
    public static func throughput(bytesPerSecond: Double) -> String {
        let units = [("GB/s", 1e9), ("MB/s", 1e6), ("KB/s", 1e3)]
        for (label, size) in units where bytesPerSecond >= size {
            return String(format: bytesPerSecond / size >= 100 ? "%.0f %@" : "%.1f %@", bytesPerSecond / size, label)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }
}

extension BenchmarkReport {
    /// One block per suite result: boot phases, workload steps, the toolchains table.
    public func textSummary() -> String {
        var lines: [String] = [
            "benchmark \(runID) — \(host.chip), \(host.cores) cores, \(host.memoryGB) GB, \(intensity)",
            "took \(BenchmarkFormat.duration(milliseconds: elapsedSeconds * 1000)) · kinhin \(kinhinVersion)",
        ]
        for suite in suites {
            lines.append("")
            lines.append(Self.heading(of: suite))
            switch suite.status {
            case .skipped:
                lines.append("  skipped: \(suite.skipReason ?? "")")
            case .failed:
                lines.append("  failed: \(suite.error ?? "")")
                lines.append(contentsOf: Self.stepLines(suite.steps))
            case .ran:
                lines.append(contentsOf: Self.stepLines(suite.steps))
                if let rows = suite.toolchains { lines.append(contentsOf: Self.toolchainLines(rows)) }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func heading(of suite: BenchmarkSuiteResult) -> String {
        var parts = ["\(suite.name) › \(suite.runtime)"]
        if let platform = suite.platform { parts.append("(\(platform))") }
        parts.append(contentsOf: suite.notes.map { "[\($0)]" })
        return parts.joined(separator: " ")
    }

    private static func stepLines(_ steps: [BenchmarkStep]) -> [String] {
        let width = (steps.map(\.name.count).max() ?? 0) + 2
        return steps.map { step in
            let name = step.name.padding(toLength: width, withPad: " ", startingAt: 0)
            if step.skipped == true { return "  \(name)skipped — \(step.note ?? "")" }
            var detail = BenchmarkFormat.duration(milliseconds: step.durationMs)
            if let min = step.minMs, let max = step.maxMs, (step.samples ?? 1) > 1 {
                detail +=
                    "  (min \(BenchmarkFormat.duration(milliseconds: min)), max \(BenchmarkFormat.duration(milliseconds: max)), n=\(step.samples ?? 0))"
            }
            if let throughput = step.throughput {
                detail += "  \(BenchmarkFormat.throughput(bytesPerSecond: throughput))"
            }
            if let note = step.note { detail += "  — \(note)" }
            return "  \(name)\(detail)"
        }
    }

    private static func toolchainLines(_ rows: [ToolchainBenchRow]) -> [String] {
        let width = (rows.map(\.tool.count).max() ?? 4) + 2
        func cell(_ value: Double?) -> String {
            (value.map { BenchmarkFormat.duration(milliseconds: $0) } ?? "—").padding(
                toLength: 10, withPad: " ", startingAt: 0)
        }
        var lines = [
            "  " + "TOOL".padding(toLength: width, withPad: " ", startingAt: 0)
                + "INSTALL     VERIFY      WORKLOAD    STATUS"
        ]
        for row in rows {
            let status: String
            switch row.status {
            case .ran: status = row.note ?? row.skipReason.map { "verify only — \($0)" } ?? "ok"
            case .skipped: status = "skipped — \(row.skipReason ?? "")"
            case .failed: status = "failed — \(row.note ?? "")"
            }
            lines.append(
                "  " + row.tool.padding(toLength: width, withPad: " ", startingAt: 0) + cell(row.installMs) + "  "
                    + cell(row.verifyMs) + "  " + cell(row.workloadMs) + "  " + status)
        }
        return lines
    }
}
