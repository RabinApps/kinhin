import Foundation

/// A raw signal from a project file, before it is mapped onto the catalog.
struct ToolchainHit: Equatable {
    /// How trustworthy the version is; lower wins.
    enum Precedence: Int, Comparable {
        case versionFile = 0
        case manifest = 1
        case workflow = 2

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// A catalog tool or stack id (probes map ecosystem aliases such as `nodejs`).
    let id: String
    let isStack: Bool
    /// As written in the file; the normalizer cleans it.
    let version: String?
    let source: String
    let reason: String
    let precedence: Precedence

    init(
        _ id: String, stack: Bool = false, version: String? = nil, source: String, reason: String,
        precedence: Precedence
    ) {
        self.id = id
        self.isStack = stack
        self.version = version
        self.source = source
        self.reason = reason
        self.precedence = precedence
    }
}

protocol ToolchainProbe: Sendable {
    var name: String { get }
    func hits(in reader: ProjectFileReading) throws -> [ToolchainHit]
}
