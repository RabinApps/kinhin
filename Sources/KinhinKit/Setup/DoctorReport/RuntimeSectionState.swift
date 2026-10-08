import Foundation

/// The `state` of the container / docker / host doctor sections. Raw values
/// are the JSON strings the document has always carried.
public enum RuntimeSectionState: String, Codable, Equatable, Sendable {
    case ready
    case missing
    case broken
}

/// A runtime health verdict mapped onto the doctor section fields
/// (`state`, `ok`, `fix`) — the one mapping the container, docker and host
/// sections share.
struct RuntimeSectionVerdict: Equatable, Sendable {
    let state: RuntimeSectionState
    let ok: Bool
    /// Install/start command or breakage reason; nil when ready.
    let fix: String?

    /// Maps `health`. `missingFix` overrides the advice for a missing tool
    /// (the host runtime has its own repair command); nil keeps the health's.
    static func from(health: RuntimeHealth, missingFix: String? = nil) -> RuntimeSectionVerdict {
        switch health {
        case .ready:
            return RuntimeSectionVerdict(state: .ready, ok: true, fix: nil)
        case .missing(_, let howToFix):
            return RuntimeSectionVerdict(state: .missing, ok: false, fix: missingFix ?? howToFix)
        case .broken(let why):
            return RuntimeSectionVerdict(state: .broken, ok: false, fix: why)
        }
    }
}
