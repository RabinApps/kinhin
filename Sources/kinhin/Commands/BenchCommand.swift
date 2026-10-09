import Foundation
import KinhinKit

/// `kinhin bench [suite…]` — measures, on this Mac, how fast every runtime
/// boots, how fast representative workloads run in them, and how fast the
/// toolchain catalog installs and builds; writes a JSON report and removes
/// everything it created. The measuring lives in `BenchmarkRunner` (KinhinKit);
/// this file is flags, the fleet-pause confirmation and output.
enum BenchCommand {
    /// What the command line asked for.
    struct Request: Equatable {
        var options: BenchmarkOptions
        var json: Bool
        var yes: Bool
    }

    private static let valueFlags: Set<String> = [
        "--iterations", "--runtime", "--toolchains", "--network", "--project",
    ]

    // MARK: - Parsing

    /// Turns the tokens after `bench` into options. Suites are the bare words; flags were already validated
    /// against the command table, so what is checked here is what the table cannot say (values, combinations).
    static func parse(_ rest: [String]) throws -> Request {
        var suites: [BenchmarkOptions.Suite] = []
        var options = BenchmarkOptions()
        var quick = false, thorough = false
        var json = false, yes = false
        var runtimes: [RuntimeID] = []
        var runtimeAll = false
        var index = 0
        while index < rest.count {
            let token = rest[index]
            index += 1
            if token.hasPrefix("-") {
                if valueFlags.contains(token) {
                    guard index < rest.count else { throw CLIError("option '\(token)' needs a value", exit: .usage) }
                    let value = rest[index]
                    index += 1
                    switch token {
                    case "--iterations":
                        guard let count = Int(value) else {
                            throw CLIError("--iterations needs a whole number, got '\(value)'", exit: .usage)
                        }
                        options.iterations = count
                    case "--runtime":
                        for name in value.split(separator: ",").map(String.init) {
                            if name == "all" { runtimeAll = true; continue }
                            guard let runtime = runtime(named: name) else {
                                throw CLIError(
                                    "unknown runtime '\(name)': use tart, appleContainer, docker, host or all",
                                    exit: .usage)
                            }
                            runtimes.append(runtime)
                        }
                    case "--toolchains":
                        options.toolchains += value.split(separator: ",").map {
                            String($0).trimmingCharacters(in: .whitespaces)
                        }
                        .filter { !$0.isEmpty }
                    case "--network": options.networkURL = value
                    default: options.projectPath = value
                    }
                    continue
                }
                switch token {
                case "--quick": quick = true
                case "--thorough": thorough = true
                case "--all-toolchains": options.allToolchains = true
                case "--include-host": options.includeHost = true
                case "--keep": options.keep = true
                case "--force": options.force = true
                case "--yes": yes = true
                case "--json": json = true
                default: break
                }
                continue
            }
            guard let suite = BenchmarkOptions.Suite(rawValue: token) else {
                let names = BenchmarkOptions.Suite.allCases.map(\.rawValue).joined(separator: ", ")
                throw CLIError("unknown suite '\(token)': use \(names)", exit: .usage)
            }
            if !suites.contains(suite) { suites.append(suite) }
        }
        if quick && thorough { throw CLIError("--quick and --thorough exclude each other", exit: .usage) }
        options.intensity = thorough ? .thorough : .quick
        options.runtimes = runtimeAll || runtimes.isEmpty ? nil : runtimes
        // Toolchain scoping asks for the toolchains suite; a bare `bench` leaves it out.
        let scoped = !options.toolchains.isEmpty || options.allToolchains
        if suites.isEmpty {
            suites = scoped ? [.toolchains] : BenchmarkOptions.Suite.defaults
        } else if scoped, !suites.contains(.toolchains) {
            suites.append(.toolchains)
        }
        options.suites = BenchmarkOptions.Suite.allCases.filter { suites.contains($0) }
        return Request(options: options, json: json, yes: yes)
    }

    /// `container` is accepted for `appleContainer`, as `image list --runtime` does.
    static func runtime(named name: String) -> RuntimeID? {
        name == "container" ? .appleContainer : RuntimeID(rawValue: name)
    }

    // MARK: - Run

    static func run(_ rest: [String]) async throws {
        let request: Request
        do {
            request = try parse(rest)
            try request.options.validate()
        } catch let error as BenchmarkError {
            fail(error)
        }
        Paths.ensureSupportDirectories()
        let config = loadConfigOrExit()
        let report: BenchmarkReport
        if let backend = await FleetBackend.attachToDaemon() {
            report = try await runThroughDaemon(
                request, backend: backend, interactive: isInteractive, confirm: confirm, progress: progressSink(request)
            )
        } else {
            report = try await runHere(request, config: config)
        }
        print(output(for: report, json: request.json))
        if !request.json { print("\nreport: \(BenchmarkReportStore().url(for: report).path)") }
        ExitRule.finish(healthy: !report.hasFailures)
    }

    /// Progress lines go to stderr (never under `--json`, which keeps the terminal to the one document).
    private static func progressSink(_ request: Request) -> @Sendable (String) -> Void {
        let quiet = request.json
        return { line in if !quiet { printError("… \(line)") } }
    }

    /// No daemon: nothing else uses this Mac's runtimes, so the runner works in this process.
    private static func runHere(_ request: Request, config: KinhinConfig) async throws -> BenchmarkReport {
        let sink = BenchmarkProgressSink(onLine: progressSink(request))
        let environment = try BenchmarkEnvironment.production(config: config)
        return try await BenchmarkRunner(environment: environment, progress: sink).run(request.options)
    }

    /// A daemon owns the fleet: it pauses itself for the run and the CLI polls for progress. Ctrl-C (a
    /// cancelled task) stops the run in the daemon too, or it would carry on unattended.
    static func runThroughDaemon(
        _ request: Request, backend: any FleetServing, interactive: Bool, confirm: (String) -> Bool,
        progress: @Sendable (String) -> Void, poll: Duration = .seconds(2)
    ) async throws -> BenchmarkReport {
        var options = request.options
        let impact = BenchmarkFleetImpact(try await backend.status(includeUsage: false))
        if impact.active > 0, !request.yes {
            guard interactive else {
                throw CLIError(
                    "the fleet has \(impact.active) live VM(s) (\(impact.busy) busy) and a benchmark pauses it; "
                        + "pass --yes to allow that when not running in a terminal",
                    exit: .usage)
            }
            guard
                confirm(
                    "the fleet has \(impact.active) live VM(s) (\(impact.busy) busy). Pause it while the benchmark runs?"
                )
            else {
                throw CLIError("cancelled: the fleet was left running", exit: .general)
            }
        }
        options.confirmed = true
        let runID = try await backend.benchStart(options)
        progress("started \(runID) in the daemon (Ctrl-C cancels it)")
        var lastLine = ""
        do {
            while true {
                try await Task.sleep(for: poll)
                let run = try await backend.benchStatus(runID: runID)
                let line = run.progress.line
                if line != lastLine, !line.isEmpty {
                    progress(line)
                    lastLine = line
                }
                switch run.state {
                case .running: continue
                case .finished:
                    guard let report = run.report else {
                        throw BenchmarkError.stepFailed(step: "report", detail: "the daemon returned no report")
                    }
                    return report
                case .failed:
                    throw BenchmarkError.stepFailed(step: "benchmark", detail: run.error ?? "unknown error")
                case .cancelled:
                    throw CancellationError()
                }
            }
        } catch is CancellationError {
            // Best effort: the daemon may already have finished or lost the run.
            _ = try? await backend.benchCancel(runID: runID)
            throw CancellationError()
        }
    }

    // MARK: - Output

    /// What goes to stdout: the report as the one JSON document, or the text tables.
    static func output(for report: BenchmarkReport, json: Bool) -> String {
        if json {
            do {
                return try CLIJSON.string(report, dates: .iso8601)
            } catch {
                return "{\"error\": \"could not encode the report\", \"code\": \(CLIExit.runtime.rawValue)}"
            }
        }
        return report.textSummary()
    }

    private static var isInteractive: Bool { isatty(STDIN_FILENO) == 1 }

    private static func confirm(_ question: String) -> Bool {
        print("\(question) [y/N] ", terminator: "")
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
        return answer == "y" || answer == "yes"
    }
}
