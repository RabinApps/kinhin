import Foundation

/// The prefix on every instance name kinhin mints, and the test for names that belong to this fleet. Release builds
/// always use `kinhin-`; a debug build can override it so the e2e suite's daemon mints and recognises only its own.
public enum InstanceNaming {
    /// The pre-rename prefix. Recognised as ours, but only alongside the default prefix.
    static let legacyPrefix = "orchard-"
    static let defaultPrefix = "kinhin-"
    /// Read once, at first use. Only a debug build honours `KINHIN_INSTANCE_PREFIX`.
    public static let prefix = resolvePrefix(environment: ProcessInfo.processInfo.environment)

    /// The prefix for `environment`. An invalid override stops the process rather than falling back: a fallback to
    /// `kinhin-` would let a debug daemon adopt and delete the fleet's own instances.
    static func resolvePrefix(environment: [String: String]) -> String {
        #if DEBUG
            guard let override = environment["KINHIN_INSTANCE_PREFIX"], !override.isEmpty else { return defaultPrefix }
            precondition(
                override.range(of: #"^[a-z][a-z0-9]{1,15}-$"#, options: .regularExpression) != nil,
                "KINHIN_INSTANCE_PREFIX must be 2-16 lowercase letters or digits ending in '-', got '\(override)'")
            return override
        #else
            return defaultPrefix
        #endif
    }

    /// Whether a runtime instance name belongs to this fleet: the current prefix, or the pre-rename one.
    public static func isOurs(_ name: String) -> Bool {
        name.hasPrefix(prefix) || (prefix == defaultPrefix && name.hasPrefix(legacyPrefix))
    }

    /// What a generated instance name matches: `<prefix><unix-ts>-<hex>`.
    static let generatedNamePattern = #"^\#(prefix)\d{9,11}-[0-9a-f]{4,8}$"#
}

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
    /// `runtime` as a known `RuntimeID`; nil when unrecorded or from a newer daemon's unknown runtime.
    /// `runtime` stays a `String` on the wire so such records still decode.
    public var runtimeID: RuntimeID? {
        get { runtime.flatMap(RuntimeID.init(rawValue:)) }
        set { runtime = newValue?.rawValue }
    }
    public var job: String?
    /// Spawned into the warm pool: the lifecycle stops at `warm` after boot instead of registering.
    /// Cleared when a job claims the instance.
    public var pooled: Bool?
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
        id.range(of: #"^\#(InstanceNaming.prefix)[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
            && !id.contains("..")
    }

    static func newName(now: Date = Date()) -> String {
        let ts = Int(now.timeIntervalSince1970)
        // 32 bits of entropy: names are drawn in bursts (scale-up) within the
        // same second, so 16 bits collided observably under test.
        let suffix = String(format: "%08x", UInt32.random(in: 0..<UInt32.max))
        return "\(InstanceNaming.prefix)\(ts)-\(suffix)"
    }
}
