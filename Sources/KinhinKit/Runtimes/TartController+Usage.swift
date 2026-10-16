import Foundation

/// Host-side view of one VM's guest: the process that actually carries it.
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
    /// The binary of the process macOS hosts Virtualization.framework guests
    /// in. On recent systems `tart run` is only a client: the guest's memory
    /// and CPU live in this XPC process, so sampling the client reports a
    /// near-constant stub.
    static let virtualMachineHostMarker = "com.apple.Virtualization.VirtualMachine"

    public func processSamples(of names: [String]) async throws -> [String: ProcessSample] {
        guard !names.isEmpty else { return [:] }
        let res = try await shell.run(["/bin/ps", "-axo", "pid=,rss=,time=,command="], cwd: nil, timeout: 15)
        guard res.succeeded else { throw TartError.commandFailed(what: "ps", stderr: res.stderr) }
        let lines = Self.parseProcessLines(res.stdout)
        let clients = Self.tartClients(lines, names: Set(names))
        guard !clients.isEmpty else { return [:] }
        // One lsof scan resolves every running VM to the process hosting it;
        // failures (or a system without a separate host) simply fall back to
        // the client below.
        let hosts = await Self.virtualMachineHosts(clients: clients, lines: lines, shell: shell)
        return Self.preferredSamples(clients: clients, hosts: hosts)
    }

    /// Prints the page size, then `vm_stat`, for `parseGuestMemoryUsedMB`.
    static let guestMemoryScript = "sysctl -n hw.pagesize; vm_stat"

    public func guestMemoryUsedMB(of name: String) async -> Int? {
        // Usage display only: a guest that cannot answer shows no memory figure.
        guard let res = try? await exec(["exec", name, "bash", "-c", Self.guestMemoryScript], timeout: 5),
            res.succeeded
        else { return nil }
        return Self.parseGuestMemoryUsedMB(res.stdout)
    }

    // MARK: - Parsing

    /// Page size line + `vm_stat` output → MB in use: active + wired +
    /// compressor pages (what Activity Monitor counts as used, less cache).
    static func parseGuestMemoryUsedMB(_ text: String) -> Int? {
        let rows = text.split(whereSeparator: \.isNewline)
        guard let first = rows.first, let pageSize = Int(first.trimmingCharacters(in: .whitespaces)), pageSize > 0
        else { return nil }
        let wanted = ["Pages active", "Pages wired down", "Pages occupied by compressor"]
        var pages = 0
        var found = false
        for row in rows.dropFirst() {
            guard let colon = row.firstIndex(of: ":"), wanted.contains(String(row[..<colon])) else { continue }
            let digits = row[row.index(after: colon)...].filter(\.isNumber)
            guard let count = Int(digits) else { continue }
            pages += count
            found = true
        }
        return found ? pages * pageSize / 1_048_576 : nil
    }

    /// One `ps -axo pid=,rss=,time=,command=` line (`rss` in KiB).
    struct PsLine: Equatable {
        let pid: Int
        let rssKB: Int
        let cpuSeconds: Double
        let command: String
    }

    static func parseProcessLines(_ text: String) -> [PsLine] {
        text.split(whereSeparator: \.isNewline).compactMap { row in
            let fields = row.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let pid = Int(fields[0]), let rssKB = Int(fields[1]),
                let cpu = parseCPUTime(String(fields[2]))
            else { return nil }
            return PsLine(pid: pid, rssKB: rssKB, cpuSeconds: cpu, command: String(fields[3]))
        }
    }

    /// The `tart run … <name>` client of each wanted VM, keyed by name.
    static func tartClients(_ lines: [PsLine], names: Set<String>) -> [String: PsLine] {
        var out: [String: PsLine] = [:]
        for line in lines {
            let argv = line.command.split(separator: " ").map(String.init)
            guard let last = argv.last, names.contains(last), let exe = argv.first,
                exe.hasSuffix("/tart") || exe == "tart", argv.dropFirst().first == "run"
            else { continue }
            out[last] = line
        }
        return out
    }

    /// `<tart home>/vms/<name>/disk.img` — the guest's disk, held open by the
    /// hosting process for the VM's lifetime (the only identity `ps` shows
    /// for it: no argv, no parent, its own process group).
    static func diskImage(
        for name: String, tartHome: String? = ProcessInfo.processInfo.environment["TART_HOME"]
    ) -> String {
        "\(tartHome ?? NSHomeDirectory() + "/.tart")/vms/\(name)/disk.img"
    }

    /// `lsof -Fpn -- <disks>` field output → VM name to the pids holding its
    /// disk (client and host both may). Output that carries no wanted path
    /// reads as `[:]`.
    static func diskHolders(from text: String, disks: [String: String]) -> [String: [Int]] {
        let nameByPath = Dictionary(disks.map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var out: [String: [Int]] = [:]
        var pid: Int?
        for row in text.split(whereSeparator: \.isNewline) {
            switch row.first {
            case "p"?:
                pid = Int(row.dropFirst())
            case "n"?:
                guard let pid, let name = nameByPath[String(row.dropFirst())] else { continue }
                out[name, default: []].append(pid)
            default:
                continue
            }
        }
        return out
    }

    /// Among the pids holding the VM's disk, the one hosting the guest — nil
    /// when none is the host (older systems run the guest in the client).
    static func virtualMachineHost(_ holders: [Int], lines: [PsLine]) -> PsLine? {
        let byPid = Dictionary(uniqueKeysWithValues: lines.map { ($0.pid, $0) })
        return holders.lazy.compactMap { byPid[$0] }.first { $0.command.contains(virtualMachineHostMarker) }
    }

    /// Maps each running client to its guest host, one `lsof` call for all
    /// wanted disks. lsof's exit code is ignored: with several paths it
    /// exits nonzero as soon as one is unheld, while still listing the rest.
    static func virtualMachineHosts(
        clients: [String: PsLine], lines: [PsLine], shell: ShellRunning
    ) async -> [String: PsLine] {
        let disks = Dictionary(uniqueKeysWithValues: clients.keys.map { ($0, diskImage(for: $0)) })
        guard
            // Usage display only: no lsof answer means no per-VM host samples.
            let res = try? await shell.run(
                ["/usr/sbin/lsof", "-Fpn", "--"] + disks.values.sorted(), cwd: nil, timeout: 15)
        else { return [:] }
        var out: [String: PsLine] = [:]
        for (name, holders) in diskHolders(from: res.stdout, disks: disks) {
            if let host = virtualMachineHost(holders, lines: lines) { out[name] = host }
        }
        return out
    }

    /// The host's numbers where the guest has one; the client's otherwise —
    /// an in-process guest (older systems) makes the client the right answer.
    static func preferredSamples(clients: [String: PsLine], hosts: [String: PsLine]) -> [String: ProcessSample] {
        var out: [String: ProcessSample] = [:]
        for (name, client) in clients {
            let line = hosts[name] ?? client
            out[name] = ProcessSample(rssMB: line.rssKB / 1024, cpuSeconds: line.cpuSeconds)
        }
        return out
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
