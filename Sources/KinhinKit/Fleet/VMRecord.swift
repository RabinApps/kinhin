import Foundation

/// Tracked state for one VM. Persisted as JSON for crash recovery.
public struct VMRecord: Codable, Sendable, Identifiable, Equatable {
    public let id: String  // tart VM name, e.g. "kinhin-1717000000-a1b2"
    public var phase: VMPhase
    public var createdAt: Date
    public var updatedAt: Date
    public var runnerName: String?
    public var ip: String?
    /// Forge this VM serves ("github" | "gitea").
    public var platform: String?
    /// Execution runtime backing this instance (a `RuntimeID` raw value:
    /// "tart", "appleContainer", "docker", "host"). Nil on old records → treated as tart on read.
    public var runtime: String?
    public var job: String?
    /// The derived per-project image this instance was cloned from (nil =
    /// the fleet's base image). Recovery re-derives the route from it.
    public var image: String?
    /// Repositories with a job currently executing on this VM (org scope
    /// attribution, stamped by the reconcile loop from in-progress jobs;
    /// nil when nothing is running or the scope is a single repo).
    public var repos: [String]?
    /// Live CPU/RAM, stamped onto status reads only (never persisted). Nil
    /// when not measurable or from a daemon predating the field.
    public var usage: ResourceUsage?
    /// Forge response bodies and guest stderr end up here; they are masked on
    /// assignment so status RPCs, the UI and Shortcuts never carry a token.
    public var error: String? {
        didSet { if let error, LogRedactor.redact(error) != error { self.error = LogRedactor.redact(error) } }
    }

    public init(id: String, phase: VMPhase = .cloning, createdAt: Date = Date()) {
        self.id = id
        self.phase = phase
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    /// Ids kinhin generates are `kinhin-<ts>-<hex>`; anything else (a stray
    /// runner name, `..` segments) is never an instance of ours.
    static func isValidID(_ id: String) -> Bool {
        id.range(of: #"^kinhin-[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil && !id.contains("..")
    }

    static func newName(now: Date = Date()) -> String {
        let ts = Int(now.timeIntervalSince1970)
        // 32 bits of entropy: names are drawn in bursts (scale-up) within the
        // same second, so 16 bits collided observably under test.
        let suffix = String(format: "%08x", UInt32.random(in: 0..<UInt32.max))
        return "kinhin-\(ts)-\(suffix)"
    }
}
