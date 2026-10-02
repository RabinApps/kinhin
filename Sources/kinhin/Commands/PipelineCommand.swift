import Foundation
import KinhinKit

/// `kinhin pipeline [VM] [--job NAME|ID] [--watch] [--json]`: the live
/// pipeline a busy VM is running. Talks to the daemon (the fleet owns the
/// forge connections), like pause/resume.
enum PipelineCommand {
    /// One VM's answer: its pipeline, or nil when it runs no job.
    struct Entry: Codable, Equatable {
        var vm: String
        var pipeline: PipelineDetail?
    }

    struct Options: Equatable {
        var vm: String?
        var job: String?
        var watch = false
        var json = false
        /// A step to show the output of (its 1-based number, or its name).
        var step: String?
        /// Show the whole job's output.
        var log = false
        /// Keep printing output until the step (or job) finishes.
        var follow = false

        var wantsOutput: Bool { step != nil || log }
    }

    static func parse(_ args: [String]) -> Options? {
        var options = Options()
        var rest = Array(args.dropFirst())  // the command word
        while !rest.isEmpty {
            let arg = rest.removeFirst()
            switch arg {
            case "--watch": options.watch = true
            case "--json": options.json = true
            case "--log": options.log = true
            case "--follow", "-f": options.follow = true
            case "--step":
                guard !rest.isEmpty else { return nil }
                options.step = rest.removeFirst()
            case "--job":
                guard !rest.isEmpty else { return nil }
                options.job = rest.removeFirst()
            default:
                guard !arg.hasPrefix("-"), options.vm == nil else { return nil }
                options.vm = arg
            }
        }
        return options
    }

    static func run(_ args: [String]) async throws {
        guard let options = parse(args) else {
            fail(
                "usage: kinhin pipeline [VM] [--job NAME|ID] [--step N|NAME | --log [--follow]] [--watch] [--json]",
                exit: .usage)
        }
        guard RPCClient.isDaemonAlive() else {
            fail("no daemon running; pipelines are read from a running daemon (kinhin daemon install)", exit: .runtime)
        }
        if options.watch && options.json {
            fail("--watch and --json cannot be combined", exit: .usage)
        }
        if options.follow && !options.wantsOutput {
            fail("--follow needs --step or --log (use --watch to refresh the pipeline view)", exit: .usage)
        }
        if options.wantsOutput && (options.watch || (options.follow && options.json)) {
            fail("output is followed with --follow, and not as --json or with --watch", exit: .usage)
        }
        if options.wantsOutput {
            do {
                try await showOutput(options, client: RPCClient())
            } catch {
                fail(error)
            }
            return
        }
        repeat {
            let output: String
            do {
                output = try render(options, client: RPCClient())
            } catch {
                fail(error)
            }
            if options.watch { print("\u{1B}[2J\u{1B}[H") }
            print(output)
            if options.watch {
                print("(refreshing every 2s — Ctrl-C to exit)")
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return  // cancelled
                }
            }
        } while options.watch
    }

    // MARK: - Output

    /// Prints one step's (or job's) output; with `--follow`, keeps printing
    /// new output until the step finishes or the job ends.
    static func showOutput(_ options: Options, client: RPCClient) async throws {
        let status = try client.status()
        let vm = try resolveVM(options, status: status)
        var follower = LogFollower()
        var announced = false
        while true {
            guard let detail = try client.pipelineDetail(vmID: vm) else {
                if announced { printError("(job finished)") } else { printError("\(vm): no job is running.") }
                return
            }
            let target = try resolveTarget(options, in: detail)
            let log = try client.pipelineLog(vmID: vm, jobID: target.job.id, stepIndex: target.stepIndex)
            if options.json {
                print(String(decoding: try jsonEncoder().encode(log), as: UTF8.self))
                return
            }
            if !announced {
                announced = true
                printError("── \(target.title) · \(PipelineFormatter.label(for: target.state).lowercased()) ──")
                if log == nil {
                    printError(
                        "\(detail.forge.displayName) has no output for this \(target.stepIndex == nil ? "job" : "step") (yet)."
                    )
                }
            }
            if let log {
                if log.truncated && follower.isEmpty { printError("(showing only the most recent output)") }
                let fresh = follower.delta(log.text)
                if !fresh.isEmpty { print(fresh, terminator: fresh.hasSuffix("\n") ? "" : "\n") }
            }
            if !options.follow || target.state.isFinished {
                if options.follow { printError("── \(PipelineFormatter.label(for: target.state).lowercased()) ──") }
                return
            }
            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch {
                return  // cancelled
            }
        }
    }

    /// The VM whose output to show: the one named, else the only busy VM.
    static func resolveVM(_ options: Options, status: FleetStatus) throws -> String {
        if let vm = options.vm {
            guard status.records.contains(where: { $0.id == vm }) else { throw PipelineCommandError.unknownVM(vm) }
            return vm
        }
        let busy = status.records.filter { $0.phase == .busy || $0.job != nil }.map(\.id)
        guard busy.count == 1 else { throw PipelineCommandError.ambiguousVM(busy) }
        return busy[0]
    }

    struct Target {
        var job: PipelineJob
        var stepIndex: Int?
        var state: PipelineStepState
        var title: String
    }

    /// The job (`--job`, else the VM's own) and, with `--step`, the step.
    static func resolveTarget(_ options: Options, in detail: PipelineDetail) throws -> Target {
        let job: PipelineJob
        if let query = options.job {
            guard let match = PipelineFormatter.job(matching: query, in: detail) else {
                throw PipelineCommandError.unknownJob(query, detail.jobs.map(\.name))
            }
            job = match
        } else if let current = detail.currentJob {
            job = current
        } else {
            throw PipelineCommandError.unknownJob("", [])
        }
        guard let query = options.step else {
            return Target(job: job, stepIndex: nil, state: job.state, title: job.name)
        }
        guard let index = stepIndex(matching: query, in: job) else {
            throw PipelineCommandError.unknownStep(query, job.steps.map(\.name))
        }
        let step = job.steps[index]
        return Target(job: job, stepIndex: index, state: step.state, title: "\(job.name) › \(step.name)")
    }

    /// A step's position by 1-based number, exact name (any case), or unique
    /// part of its name.
    static func stepIndex(matching query: String, in job: PipelineJob) -> Int? {
        if let number = Int(query) { return job.steps.indices.contains(number - 1) ? number - 1 : nil }
        let lowered = query.lowercased()
        if let exact = job.steps.firstIndex(where: { $0.name.lowercased() == lowered }) { return exact }
        let partial = job.steps.indices.filter { job.steps[$0].name.lowercased().contains(lowered) }
        return partial.count == 1 ? partial[0] : nil
    }

    static func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// What of a growing log is new since the last print. Anchors on the tail
    /// already printed, so a log whose start was cut (it only keeps its most
    /// recent part) continues cleanly instead of reprinting.
    struct LogFollower {
        private var tail = ""
        private static let anchor = 200

        var isEmpty: Bool { tail.isEmpty }

        mutating func delta(_ text: String) -> String {
            defer { tail = String(text.suffix(Self.anchor)) }
            guard !tail.isEmpty else { return text }
            if let found = text.range(of: tail, options: .backwards) { return String(text[found.upperBound...]) }
            return "\n… output restarted …\n" + text
        }
    }

    /// The text (or JSON) for one pass. Throws a usage-style error for an
    /// unknown VM or job so `fail` classifies it.
    static func render(_ options: Options, client: RPCClient) throws -> String {
        let status = try client.status()
        let busy = status.records.filter { $0.phase == .busy || $0.job != nil }
        let targets: [String]
        if let vm = options.vm {
            guard status.records.contains(where: { $0.id == vm }) else { throw PipelineCommandError.unknownVM(vm) }
            targets = [vm]
        } else {
            targets = busy.map(\.id)
        }
        let entries = try targets.map { Entry(vm: $0, pipeline: try client.pipelineDetail(vmID: $0)) }
        return try format(entries, options: options, requested: options.vm != nil)
    }

    static func format(_ entries: [Entry], options: Options, requested: Bool, now: Date = Date()) throws -> String {
        if options.json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return String(decoding: try encoder.encode(entries), as: UTF8.self)
        }
        if entries.isEmpty { return "no VM is running a job." }
        var blocks: [String] = []
        for entry in entries {
            guard let pipeline = entry.pipeline else {
                blocks.append("\(entry.vm): no job is running.")
                continue
            }
            var selected: PipelineJob?
            if let query = options.job {
                guard let match = PipelineFormatter.job(matching: query, in: pipeline) else {
                    // With several VMs a job may live on only one of them.
                    if requested || entries.count == 1 {
                        throw PipelineCommandError.unknownJob(query, pipeline.jobs.map(\.name))
                    }
                    continue
                }
                selected = match
            }
            blocks.append(PipelineFormatter.report(pipeline, vm: entry.vm, job: selected, now: now))
        }
        return blocks.isEmpty ? "no job matches '\(options.job ?? "")'." : blocks.joined(separator: "\n\n")
    }
}

enum PipelineCommandError: LocalizedError, Equatable {
    case unknownVM(String)
    case unknownJob(String, [String])
    case unknownStep(String, [String])
    case ambiguousVM([String])

    var errorDescription: String? {
        switch self {
        case .unknownVM(let id): return "no VM '\(id)' (see: kinhin status)"
        case .unknownJob(let query, let names):
            return "no job matches '\(query)'; jobs: \(names.joined(separator: ", "))"
        case .unknownStep(let query, let names):
            return "no step matches '\(query)'; steps: \(names.joined(separator: ", "))"
        case .ambiguousVM(let busy):
            return busy.isEmpty
                ? "no VM is running a job"
                : "name a VM (kinhin pipeline VM …); busy: \(busy.joined(separator: ", "))"
        }
    }
}
