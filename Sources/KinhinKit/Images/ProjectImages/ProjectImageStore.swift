import Foundation
import Synchronization

/// One derived per-project image kinhin built.
public struct ProjectImageRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    /// The tart image name, e.g. `tahoe-base-p3a9f12c4`.
    public let name: String
    public let key: String
    /// The global image it was cloned from.
    public let base: String
    /// Human summary of the baked set, e.g. `go@1.22.5, node@20`.
    public let summary: String
    public let createdAt: Date
    public var lastUsedAt: Date
    /// What the image was baked with (cache envs for runners come from it).
    public let toolchains: StoredToolchains
    /// The project cache share the image's runners mount (scoped by `key`).
    public let shareCache: Bool

    /// Codable form of `KinhinConfig.ToolchainsConfig`.
    public struct StoredToolchains: Codable, Sendable, Equatable {
        public let specs: [String]
        public let brew: [String]
        public let stacks: [String]

        init(_ config: KinhinConfig.ToolchainsConfig) {
            specs = config.specs ?? []
            brew = config.brew ?? []
            stacks = config.stacks ?? []
        }

        var config: KinhinConfig.ToolchainsConfig {
            KinhinConfig.ToolchainsConfig(
                specs: specs.isEmpty ? nil : specs, brew: brew.isEmpty ? nil : brew,
                stacks: stacks.isEmpty ? nil : stacks)
        }
    }
}

/// Index of the derived images kinhin owns (`project-images.json` in the
/// state directory), used for LRU pruning and the app/CLI listings. The
/// images themselves live in tart; this only remembers which are ours.
public final class ProjectImageStore: Sendable {
    private let url: URL
    private let mutex: Mutex<[ProjectImageRecord]>

    public init(directory: URL = Paths.stateDirectory) {
        let file = directory.appendingPathComponent("project-images.json")
        self.url = file
        let loaded: [ProjectImageRecord] = {
            guard FileManager.default.fileExists(atPath: file.path) else { return [] }
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode([ProjectImageRecord].self, from: Data(contentsOf: file))
            } catch {
                Log.warn("images", "could not read \(file.path) (\(error.localizedDescription)); starting empty")
                return []
            }
        }()
        self.mutex = Mutex(loaded)
    }

    public var all: [ProjectImageRecord] { mutex.withLock { $0 } }

    func record(named name: String) -> ProjectImageRecord? { all.first { $0.name == name } }

    func upsert(_ record: ProjectImageRecord) {
        mutex.withLock { list in
            if let idx = list.firstIndex(where: { $0.name == record.name }) {
                list[idx] = record
            } else {
                list.append(record)
            }
        }
        persist()
    }

    /// Marks `name` used. Writes the index only when the stored stamp is more
    /// than `minInterval` old: pruning works in days, and a queue of jobs
    /// asks for the same image on every poll.
    func touch(_ name: String, now: Date = Date(), minInterval: TimeInterval = 600) {
        let changed = mutex.withLock { list -> Bool in
            guard let idx = list.firstIndex(where: { $0.name == name }),
                now.timeIntervalSince(list[idx].lastUsedAt) > minInterval
            else { return false }
            list[idx].lastUsedAt = now
            return true
        }
        if changed { persist() }
    }

    public func remove(name: String) {
        mutex.withLock { $0.removeAll { $0.name == name } }
        persist()
    }

    /// Images to delete: everything unused for `maxAgeDays` (0 = no age
    /// limit), then least-recently-used beyond `maxImages`. `protected`
    /// names (images a live VM was cloned from) are never selected.
    func pruneCandidates(maxImages: Int, maxAgeDays: Int, protected: Set<String>, now: Date = Date()) -> [String] {
        let eligible = all.filter { !protected.contains($0.name) }.sorted { $0.lastUsedAt < $1.lastUsedAt }
        var doomed: [String] = []
        if maxAgeDays > 0 {
            let cutoff = now.addingTimeInterval(-Double(maxAgeDays) * 86_400)
            doomed += eligible.filter { $0.lastUsedAt < cutoff }.map(\.name)
        }
        let remaining = all.count - doomed.count
        if maxImages > 0, remaining > maxImages {
            let extra = remaining - maxImages
            doomed += eligible.filter { !doomed.contains($0.name) }.prefix(extra).map(\.name)
        }
        return doomed
    }

    private func persist() {
        let records = all
        bestEffort("images", "persisting \(records.count) project image record(s)") {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(records).write(to: url, options: .atomic)
        }
    }
}
