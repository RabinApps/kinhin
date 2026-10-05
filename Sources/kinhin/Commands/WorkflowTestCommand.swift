import Foundation
import KinhinKit

/// `kinhin workflow test [FILE] [--job NAME] [--list] [--json]`.
enum WorkflowTestCommand {
    struct Options: Sendable {
        var file: URL?
        var job: String?
        var list = false
        var json = false
    }

    @MainActor
    static func run(_ args: [String]) async throws {
        let options = try parse(args)
        let file = try options.file ?? locateWorkflow(in: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        let document = try load(file)
        if options.list {
            print("jobs:")
            for job in document.jobs {
                let matrix = job.hasMatrix ? " · matrix" : ""
                print("  \(job.id) — \(job.name) · \(job.steps.count) step(s)\(matrix) · runs-on: \(job.runsOn)")
            }
            return
        }

        let root = workingDirectory(for: file)
        let runner = LocalWorkflowRunner(shell: Shell()) { event in
            guard !options.json else { return }
            switch event {
            case .jobStarted(let id):
                print("▸ job '\(id)'")
            case .jobFinished(let id, let state):
                print("  job '\(id)': \(PipelineFormatter.label(for: state).lowercased())")
            case .stepStarted(let name):
                print("  ▸ \(name)")
            case .stepFinished(let name, let state):
                print("    \(PipelineFormatter.symbol(for: state)) \(name)")
            case .stepOutput(_, let output):
                if !output.isEmpty { print(output) }
            case .stepNotice(_, let notice), .stepSkipped(_, let notice):
                printError("  note: \(notice)")
            case .needSkipped(let id):
                printError("  note: selected job '\(id)' dependencies were not run")
            case .matrixSkipped(let id):
                printError("  note: matrix job '\(id)' is skipped in v1")
            }
        }
        let report = try await runner.run(
            document: document,
            jobs: options.job.map { [$0] } ?? [],
            workingDirectory: root
        )
        if options.json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(report)
            print(String(decoding: data, as: UTF8.self))
        } else {
            print("summary: \(PipelineFormatter.label(for: report.overallState).lowercased()) · \(report.jobs.count) job(s)")
        }
        if report.exitCode != 0 { exit(report.exitCode) }
    }

    static func parse(_ args: [String]) throws -> Options {
        var result = Options()
        var index = 0
        while index < args.count {
            let value = args[index]
            switch value {
            case "--list": result.list = true
            case "--json": result.json = true
            case "--job":
                index += 1
                guard index < args.count, !args[index].hasPrefix("-") else {
                    throw CLIError("option --job needs a name", exit: .usage)
                }
                result.job = args[index]
            case "--help", "-h":
                throw CLIError(help, exit: .usage)
            default:
                guard !value.hasPrefix("-"), result.file == nil else {
                    throw CLIError("unknown workflow test argument: \(value)", exit: .usage)
                }
                result.file = URL(fileURLWithPath: value)
            }
            index += 1
        }
        return result
    }

    private static func load(_ url: URL) throws -> WorkflowDocument {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw WorkflowError.unreadable(url, error.localizedDescription)
        }
        return try parseWorkflow(data, at: url)
    }

    private static func workingDirectory(for file: URL) -> URL {
        var current = file.deletingLastPathComponent()
        while current.path != "/" {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) { return current }
            current.deleteLastPathComponent()
        }
        return file.deletingLastPathComponent()
    }

    private static let help = """
    usage: kinhin workflow test [FILE] [--job NAME] [--list] [--json]

    Run GitHub Actions workflow scripts on this Mac. No VM, daemon, token or config is used.
    FILE defaults to the only workflow in .github/workflows; --job runs one job without its needs.
    --list prints jobs. --json prints the final report instead of step output.
    """
}
