import Foundation

/// Host-side view of one VM's `tart run` process.
public struct ProcessSample: Sendable, Equatable {
    public var rssMB: Int
    /// Cumulative CPU time (user + system) since the process started.
    public var cpuSeconds: Double

    public init(rssMB: Int, cpuSeconds: Double) {
        self.rssMB = rssMB
        self.cpuSeconds = cpuSeconds
    }
}

extension TartController {
    public func processSamples(of names: [String]) async throws -> [String: ProcessSample] {
        guard !names.isEmpty else { return [:] }
        let res = try await shell.run(["/bin/ps", "-axo", "rss=,time=,command="], cwd: nil, timeout: 15)
        guard res.succeeded else { throw TartError.commandFailed(what: "ps", stderr: res.stderr) }
        return Self.parseProcessSamples(res.stdout, names: Set(names))
    }

    /// Parses `ps -axo rss=,time=,command=` lines, keeping those whose command
    /// is `… tart run <flags> <name>` for a wanted VM name. `rss` is in KiB.
    static func parseProcessSamples(_ text: String, names: Set<String>) -> [String: ProcessSample] {
        var result: [String: ProcessSample] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let rssKB = Int(fields[0]), let cpu = parseCPUTime(String(fields[1])) else {
                continue
            }
            let argv = fields[2].split(separator: " ").map(String.init)
            guard let last = argv.last, names.contains(last), let exe = argv.first,
                exe.hasSuffix("/tart") || exe == "tart", argv.dropFirst().first == "run"
            else { continue }
            result[last] = ProcessSample(rssMB: rssKB / 1024, cpuSeconds: cpu)
        }
        return result
    }

    /// `ps` TIME: "M:SS.ss", "H:MM:SS.ss" or "D-HH:MM:SS".
    static func parseCPUTime(_ text: String) -> Double? {
        var rest = Substring(text)
        var days = 0.0
        if let dash = rest.firstIndex(of: "-") {
            guard let d = Double(rest[..<dash]) else { return nil }
            days = d
            rest = rest[rest.index(after: dash)...]
        }
        let parts = rest.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, !parts.contains(where: { $0 == nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 } + days * 86400
    }
}
