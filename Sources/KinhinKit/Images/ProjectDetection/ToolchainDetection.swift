import Foundation

/// What `ProjectToolchainDetector` found in a checkout: a valid `.kinhin.yml`
/// selection plus the evidence behind each pick.
public struct ToolchainDetection: Codable, Sendable, Equatable {
    /// One reason a spec is in the result.
    public struct Finding: Codable, Sendable, Equatable {
        public let spec: String
        /// The file (or `implied`) that led to the pick.
        public let source: String
        public let reason: String
    }

    public let specs: [String]
    public let stacks: [String]
    public let evidence: [Finding]
    /// Things the scan recognised but the catalog cannot install, so a repo
    /// file cannot name them.
    public let unmatched: [String]
    /// Advice that cannot be expressed in `.kinhin.yml`, such as a base image with Xcode.
    public let recommendations: [String]

    public var isEmpty: Bool { specs.isEmpty && stacks.isEmpty }

    /// The `.kinhin.yml` text for this result.
    public func yaml() -> String {
        guard !isEmpty else { return "# kinhin: no toolchains detected\n" }
        var lines = ["toolchains:"]
        if !specs.isEmpty { lines.append("  specs: [\(specs.map { "\"\($0)\"" }.joined(separator: ", "))]") }
        if !stacks.isEmpty { lines.append("  stacks: [\(stacks.map { "\"\($0)\"" }.joined(separator: ", "))]") }
        return lines.joined(separator: "\n") + "\n"
    }
}
