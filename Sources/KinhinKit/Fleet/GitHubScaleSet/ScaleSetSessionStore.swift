import Foundation

/// Remembers the message session a scale-set listener created, on disk, so a
/// run that dies without deleting it (crash, force quit, rebuild) can delete
/// it on the next start. GitHub allows one live session per scale set and
/// answers 409 to a second one until the first is deleted or its lease
/// lapses; without the id there is nothing to delete.
public struct ScaleSetSessionStore: Sendable {
    public struct Record: Codable, Equatable, Sendable {
        public let scaleSetId: Int
        public let sessionId: String
        public let ownerName: String
        public let createdAt: Date

        public init(scaleSetId: Int, sessionId: String, ownerName: String, createdAt: Date = Date()) {
            self.scaleSetId = scaleSetId
            self.sessionId = sessionId
            self.ownerName = ownerName
            self.createdAt = createdAt
        }
    }

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The store for one (account, scale set) under `directory`.
    public init(directory: URL, account: String, scaleSet: String) {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        func safe(_ text: String) -> String {
            String(text.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        }
        self.url = directory.appendingPathComponent("scaleset-session-\(safe(account))-\(safe(scaleSet)).json")
    }

    /// The recorded session, or nil when there is none. An unreadable file
    /// also reads as nil, after it is moved aside to a `.corrupt-` sibling
    /// and logged as an error (see `StateFile`).
    public func load() -> Record? {
        let result = StateFile.load(url, component: "scaleset") { data -> Record in
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Record.self, from: data)
        }
        guard case .loaded(let record) = result else { return nil }
        return record
    }

    public func save(_ record: Record) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try Paths.createPrivateDirectory(url.deletingLastPathComponent())
            try Paths.writePrivateFile(try encoder.encode(record), to: url)
        } catch {
            Log.warn("scaleset", "could not record the session for crash recovery: \(error.localizedDescription)")
        }
    }

    /// Forgets the recorded session. A missing file is already clear; a
    /// failed delete is logged (the next start then retries a stale session).
    public func clear() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        bestEffort("scaleset", "clearing the recorded session \(url.path)") {
            try FileManager.default.removeItem(at: url)
        }
    }
}
