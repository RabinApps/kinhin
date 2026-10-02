import Foundation

// MARK: - Live usage

extension ContainerManager {
    /// Live CPU/RAM of running containers, keyed by container name.
    public func stats() async throws -> [String: ResourceUsage] {
        switch tool {
        case .docker:
            let out = try await run(
                ["stats", "--no-stream", "--no-trunc", "--format", "{{json .}}"], what: "reading container stats")
            return Self.parseDockerStats(out)
        case .appleContainer:
            let out = try await run(["stats", "--no-stream", "--format", "json"], what: "reading container stats")
            return Self.parseAppleStats(out)
        }
    }

    /// Docker `stats --format '{{json .}}'`: `Name`, `CPUPerc` ("12.34%") and
    /// `MemUsage` ("512MiB / 2GiB").
    static func parseDockerStats(_ text: String) -> [String: ResourceUsage] {
        var result: [String: ResourceUsage] = [:]
        for row in jsonLines(text) {
            guard let name = row["Name"] as? String else { continue }
            let cpu = (row["CPUPerc"] as? String).flatMap { Double($0.trimmingCharacters(in: .whitespaces).dropLast()) }
            let parts = (row["MemUsage"] as? String)?.components(separatedBy: "/").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            result[name] = ResourceUsage(
                cpuPercent: cpu,
                memoryUsedMB: parts?.first.flatMap(megabytes(fromSize:)),
                memoryLimitMB: parts.flatMap { $0.count > 1 ? megabytes(fromSize: $0[1]) : nil })
        }
        return result
    }

    /// Apple `container stats --format json`: an array of `{id, memoryUsageBytes,
    /// memoryLimitBytes, cpuUsageUsec, …}`. CPU is a cumulative counter, not a
    /// rate, so it is left nil here; memory is reported.
    static func parseAppleStats(_ text: String) -> [String: ResourceUsage] {
        var result: [String: ResourceUsage] = [:]
        for row in jsonArray(text) {
            guard let id = row["id"] as? String else { continue }
            result[id] = ResourceUsage(
                memoryUsedMB: (row["memoryUsageBytes"] as? NSNumber).map { $0.intValue / 1_048_576 },
                memoryLimitMB: (row["memoryLimitBytes"] as? NSNumber).map { $0.intValue / 1_048_576 })
        }
        return result
    }

    /// "512MiB", "1.5GiB", "900kB" → MB. Nil for anything unparsable.
    static func megabytes(fromSize text: String) -> Int? {
        let units: [(String, Double)] = [
            ("TiB", 1_048_576), ("GiB", 1024), ("MiB", 1), ("KiB", 1.0 / 1024),
            ("TB", 1_000_000), ("GB", 1000), ("MB", 1), ("kB", 0.001), ("B", 1.0 / 1_048_576),
        ]
        for (suffix, factor) in units where text.hasSuffix(suffix) {
            guard let value = Double(text.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            return Int((value * factor).rounded())
        }
        return nil
    }
}
