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
    }

    static func parse(_ args: [String]) -> Options? {
        var options = Options()
        var rest = Array(args.dropFirst())  // the command word
        while !rest.isEmpty {
            let arg = rest.removeFirst()
            switch arg {
            case "--watch": options.watch = true
            case "--json": options.json = true
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
            fail("usage: kinhin pipeline [VM] [--job NAME|ID] [--watch] [--json]", exit: .usage)
        }
        guard RPCClient.isDaemonAlive() else {
            fail("no daemon running; pipelines are read from a running daemon (kinhin daemon install)", exit: .runtime)
        }
        if options.watch && options.json {
            fail("--watch and --json cannot be combined", exit: .usage)
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

    static func format(_ entries: [Entry], options: Options, requested: Bool) throws -> String {
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
            blocks.append(PipelineFormatter.report(pipeline, vm: entry.vm, job: selected))
        }
        return blocks.isEmpty ? "no job matches '\(options.job ?? "")'." : blocks.joined(separator: "\n\n")
    }
}

enum PipelineCommandError: LocalizedError, Equatable {
    case unknownVM(String)
    case unknownJob(String, [String])

    var errorDescription: String? {
        switch self {
        case .unknownVM(let id): return "no VM '\(id)' (see: kinhin status)"
        case .unknownJob(let query, let names):
            return "no job matches '\(query)'; jobs: \(names.joined(separator: ", "))"
        }
    }
}
