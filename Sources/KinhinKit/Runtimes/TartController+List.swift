import Foundation

/// `tart list` and the parsers for its two output formats.
extension TartController {
    public func list() async throws -> [TartVM] {
        // Newer tart builds print only names for `--quiet`, so ask for JSON.
        let json = try await exec(["list", "--format", "json"])
        var jsonError: Error?
        if json.succeeded {
            do { return try Self.parseListJSON(json.stdout) } catch { jsonError = error }
        }
        let res = try await exec(["list", "--quiet"])
        guard res.succeeded else { throw TartError.commandFailed(what: "list", stderr: res.stderr) }
        let vms = Self.parseList(res.stdout)
        // Newer tart prints bare names for `--quiet`, which parse to nothing:
        // an empty result from non-empty output is unreadable, not "no VMs".
        if vms.isEmpty, !res.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let why = jsonError.map { ": \($0.localizedDescription)" } ?? ""
            throw TartError.commandFailed(what: "list", stderr: "could not read the output\(why)")
        }
        return vms
    }

    /// Parse `tart list --format json`; throws when the output isn't that JSON.
    static func parseListJSON(_ text: String) throws -> [TartVM] {
        struct Entry: Decodable {
            let Name: String
            let Source: String
            let State: String
            let Disk: Int?
            let Size: Int?
            let SizeOnDisk: Int?  // newer tart: the allocated size; older tart reports it as `Size`
        }
        let entries = try JSONDecoder().decode([Entry].self, from: Data(text.utf8))
        return entries.map {
            TartVM(
                name: $0.Name, source: $0.Source, status: $0.State, diskGB: $0.Disk, sizeGB: $0.SizeOnDisk ?? $0.Size)
        }
    }

    /// Parse `tart list --quiet` output: lines of "name \t source \t status".
    static func parseList(_ text: String) -> [TartVM] {
        text.split(separator: "\n").compactMap { line in
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 3 else { return nil }
            let mem =
                cols.count > 4
                ? Int(cols[4].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "GB", with: "")) : nil
            let cpu = cols.count > 3 ? Int(cols[3].trimmingCharacters(in: .whitespaces)) : nil
            return TartVM(
                name: String(cols[0]).trimmingCharacters(in: .whitespaces),
                source: String(cols[1]).trimmingCharacters(in: .whitespaces),
                status: String(cols[2]).trimmingCharacters(in: .whitespaces),
                cpu: cpu,
                memoryMB: mem.map { $0 * 1024 }
            )
        }
    }
}
