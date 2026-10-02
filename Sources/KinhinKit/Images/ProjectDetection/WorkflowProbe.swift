import Foundation
import Yams

/// GitHub Actions workflows: `setup-*` actions (with their version inputs)
/// and well-known CLIs invoked from `run:` steps. Only fills versions in
/// when no pin file or manifest has one.
struct WorkflowProbe: ToolchainProbe {
    let name = "GitHub workflows"

    private struct Action {
        let tool: String
        let stack: Bool
        /// `with:` keys that may carry a version, in order.
        let versionKeys: [String]
    }

    private static let actions: [String: Action] = [
        "actions/setup-node": Action(tool: "node", stack: false, versionKeys: ["node-version"]),
        "actions/setup-go": Action(tool: "go", stack: false, versionKeys: ["go-version"]),
        "actions/setup-python": Action(tool: "python", stack: false, versionKeys: ["python-version"]),
        "actions/setup-java": Action(tool: "java", stack: false, versionKeys: ["java-version"]),
        "actions/setup-dotnet": Action(tool: "dotnet", stack: false, versionKeys: []),
        "ruby/setup-ruby": Action(tool: "ruby", stack: false, versionKeys: ["ruby-version"]),
        "dtolnay/rust-toolchain": Action(tool: "rust", stack: false, versionKeys: ["toolchain"]),
        "subosito/flutter-action": Action(tool: "flutter", stack: true, versionKeys: ["flutter-version"]),
        "hashicorp/setup-terraform": Action(tool: "terraform", stack: false, versionKeys: ["terraform_version"]),
        "pnpm/action-setup": Action(tool: "pnpm", stack: false, versionKeys: ["version"]),
        "oven-sh/setup-bun": Action(tool: "bun", stack: false, versionKeys: ["bun-version"]),
        "denoland/setup-deno": Action(tool: "deno", stack: false, versionKeys: ["deno-version"]),
        "astral-sh/setup-uv": Action(tool: "uv", stack: false, versionKeys: ["version"]),
        "azure/setup-kubectl": Action(tool: "kubectl", stack: false, versionKeys: ["version"]),
        "azure/setup-helm": Action(tool: "helm", stack: false, versionKeys: ["version"]),
        "swift-actions/setup-swift": Action(tool: "swift", stack: false, versionKeys: ["swift-version"]),
    ]

    /// CLIs a `run:` line can invoke at command position.
    private static let commands = [
        "terraform", "kubectl", "helm", "playwright", "cypress", "gh", "fastlane", "shellcheck", "hadolint",
    ]

    private static let commandPattern: NSRegularExpression? = {
        let names = commands.joined(separator: "|")
        return try? NSRegularExpression(
            pattern: "(^|&&|;|\\||\\$\\(|\\bnpx|\\bsudo|\\bbunx|\\bexec|\\bbundle exec)\\s*(\(names))(\\s|$)")
    }()

    func hits(in reader: ProjectFileReading) throws -> [ToolchainHit] {
        var out: [ToolchainHit] = []
        let files = try reader.list(".github/workflows").filter { $0.hasSuffix(".yml") || $0.hasSuffix(".yaml") }
        for file in files {
            let path = ".github/workflows/\(file)"
            guard let text = try reader.text(path) else { continue }
            let root: Node?
            do {
                root = try Yams.compose(yaml: text)
            } catch {
                Log.warn("Detect", "skipping \(path): \(error.localizedDescription)")
                continue
            }
            guard let jobs = root?.mapping?["jobs"]?.mapping else { continue }
            for (_, job) in jobs {
                for step in job.mapping?["steps"]?.sequence ?? [] {
                    out.append(contentsOf: stepHits(step, source: path))
                }
            }
        }
        return out
    }

    private func stepHits(_ step: Node, source: String) -> [ToolchainHit] {
        var out: [ToolchainHit] = []
        if let uses = step.mapping?["uses"]?.string {
            let parts = uses.split(separator: "@", maxSplits: 1).map(String.init)
            if let action = Self.actions[parts[0]] {
                let with = step.mapping?["with"]?.mapping
                var version = action.versionKeys.compactMap { with?[$0]?.string }.first
                if version == nil, parts[0] == "dtolnay/rust-toolchain", parts.count > 1 { version = parts[1] }
                // Matrix and expression values are not a single version.
                if let v = version, v.contains("${{") || v.contains("\n") { version = nil }
                out.append(
                    ToolchainHit(
                        action.tool, stack: action.stack, version: version, source: source,
                        reason: "uses \(parts[0])", precedence: .workflow))
            }
        }
        if let run = step.mapping?["run"]?.string, let pattern = Self.commandPattern {
            for line in run.split(whereSeparator: \.isNewline) {
                let line = String(line)
                if line.trimmed().hasPrefix("#") { continue }
                let range = NSRange(line.startIndex..., in: line)
                for match in pattern.matches(in: line, range: range) {
                    guard let r = Range(match.range(at: 2), in: line) else { continue }
                    let command = String(line[r])
                    out.append(
                        ToolchainHit(
                            command, source: source, reason: "runs `\(command)`", precedence: .workflow))
                }
            }
        }
        return out
    }
}
