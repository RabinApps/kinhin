import Foundation
import KinhinKit

/// `kinhin jobs` and `kinhin queue`: which jobs are running and which are waiting, and where each came from.
/// The queue is first in, first out by the date the forge created each job.
enum JobsCommand {
    enum View: Equatable {
        case all, running, queued
    }

    struct Options: Equatable {
        var view: View = .all
        var forge: String?
        var json = false
        var watch = false
    }

    /// `kinhin jobs --json`: whether a daemon answered, and the report when one did.
    struct Document: Codable, Equatable {
        var daemonRunning: Bool
        var jobs: FleetJobsReport?
    }

    /// Parses the command line, `args` starting with the command word. `defaultView` is `.queued` for `queue`.
    static func parse(_ args: [String], defaultView: View = .all) -> Options? {
        var options = Options(view: defaultView)
        var rest = Array(args.dropFirst())
        while !rest.isEmpty {
            switch rest.removeFirst() {
            case "--json": options.json = true
            case "--watch": options.watch = true
            case "--running" where defaultView == .all: options.view = .running
            case "--queued" where defaultView == .all: options.view = .queued
            case "--forge":
                guard !rest.isEmpty else { return nil }
                options.forge = rest.removeFirst()
            default: return nil
            }
        }
        return options
    }

    static func run(_ args: [String], defaultView: View = .all) async throws {
        guard let options = parse(args, defaultView: defaultView) else {
            let flags = defaultView == .all ? "[--running | --queued] " : ""
            fail("usage: kinhin \(args.first ?? "jobs") \(flags)[--forge NAME] [--watch] [--json]", exit: .usage)
        }
        repeat {
            let status: FleetStatus?
            do {
                status = try RPCClient().status()
            } catch RPCError.connectionFailed {
                status = nil
            } catch {
                fail(error.localizedDescription, exit: .runtime)
            }
            let report = status.map {
                limited(filtered(FleetJobsReport(status: $0), forge: options.forge), to: options.view)
            }
            if options.watch, !options.json { print("\u{1B}[2J\u{1B}[H", terminator: "") }
            if options.json {
                try emitJSON(Document(daemonRunning: status != nil, jobs: report), dates: .iso8601)
            } else if let report {
                print(render(report, options: options, now: Date()))
            } else {
                print("daemon: not running")
            }
            if !options.watch {
                ExitRule.finish(healthy: status != nil)
                return
            }
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return  // cancelled: stop watching
            }
        } while true
    }

    // MARK: - Rendering

    /// The report limited to one forge account (case-insensitive); nil keeps everything.
    static func filtered(_ report: FleetJobsReport, forge: String?) -> FleetJobsReport {
        guard let forge else { return report }
        func keep(_ entry: FleetJobsReport.Entry) -> Bool { entry.forge.caseInsensitiveCompare(forge) == .orderedSame }
        var out = report
        out.running = report.running.filter(keep)
        out.queued = FleetJobsReport.fifo(report.queued.filter(keep))
        out.queueByForge = report.queueByForge.filter { $0.key.caseInsensitiveCompare(forge) == .orderedSame }
        out.queueDepth = out.queueByForge.values.reduce(0, +)
        out.unattributedBusy = []
        return out
    }

    /// The report cut down to the one half `--running` or `--queued` asked for; `.all` keeps both.
    static func limited(_ report: FleetJobsReport, to view: View) -> FleetJobsReport {
        var out = report
        switch view {
        case .all:
            break
        case .running:
            out.queued = []
            out.queueDepth = 0
            out.queueByForge = [:]
        case .queued:
            out.running = []
            out.unattributedBusy = []
        }
        return out
    }

    static func render(_ report: FleetJobsReport, options: Options, now: Date) -> String {
        var sections: [String] = []
        if options.view != .queued { sections.append(runningSection(report, now: now)) }
        if options.view != .running { sections.append(queuedSection(report, now: now)) }
        return sections.joined(separator: "\n\n")
    }

    private static func runningSection(_ report: FleetJobsReport, now: Date) -> String {
        var lines = ["running (\(report.running.count + report.unattributedBusy.count))"]
        var rows = [["JOB", "REPO", "FORGE", "ON", "RUNNING"]]
        for job in report.running {
            rows.append([
                job.name, job.repo ?? "-", job.forge.isEmpty ? "-" : job.forge, job.runner ?? job.vm ?? "-",
                job.startedAt.map { duration(now.timeIntervalSince($0)) } ?? "-",
            ])
        }
        for vm in report.unattributedBusy { rows.append(["(job not named yet)", "-", "-", vm, "-"]) }
        if rows.count == 1 { return "running (0)\n  none" }
        lines.append(contentsOf: table(rows))
        return lines.joined(separator: "\n")
    }

    private static func queuedSection(_ report: FleetJobsReport, now: Date) -> String {
        let heading = "queued (\(report.queueDepth)) · oldest first"
        guard report.queueDepth > 0 || !report.queued.isEmpty else { return "queued (0)\n  none" }
        guard !report.queued.isEmpty else {
            return heading
                + "\n  \(report.queueDepth) waiting; this daemon does not list them (update kinhin to see them)"
        }
        var rows = [["#", "JOB", "REPO", "FORGE", "WAITING"]]
        for job in report.queued {
            rows.append([
                job.position.map { "#\($0)" } ?? "-", job.name, job.repo ?? "-", job.forge,
                job.enqueuedAt.map { duration(now.timeIntervalSince($0)) } ?? "-",
            ])
        }
        var lines = [heading] + table(rows)
        let hidden = report.queueDepth - report.queued.count
        if hidden > 0, !report.queueByForge.isEmpty { lines.append("  … and \(hidden) more") }
        return lines.joined(separator: "\n")
    }

    /// Left-aligned columns, two spaces between, the whole table indented two.
    static func table(_ rows: [[String]]) -> [String] {
        guard let columns = rows.first?.count else { return [] }
        let widths = (0..<columns).map { column in rows.map { $0[column].count }.max() ?? 0 }
        return rows.map { row in
            "  "
                + row.enumerated().map { $1.padding(toLength: widths[$0], withPad: " ", startingAt: 0) }
                .joined(separator: "  ").trimmingCharacters(in: .whitespaces)
        }
    }

    /// "45s", "3m12s", "2h05m": how long ago, never negative.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m\(String(format: "%02d", total % 60))s" }
        return "\(total / 3600)h\(String(format: "%02d", total % 3600 / 60))m"
    }
}
