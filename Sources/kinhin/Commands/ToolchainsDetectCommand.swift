import Foundation
import KinhinKit

/// `kinhin toolchains detect [path] [--json] [--write] [--force]`: scans a
/// checkout and proposes its `.kinhin.yml`. stdout carries only the YAML (or
/// the JSON document); the evidence goes to stderr so the output pipes cleanly.
enum ToolchainsDetectCommand {
    /// `args` are the arguments after `toolchains detect`.
    static func run(_ args: [String]) {
        do {
            let output = try execute(args)
            print(output.stdout, terminator: "")
            if !output.stderr.isEmpty { printError(output.stderr) }
        } catch {
            fail(error)
        }
    }

    /// The text a run prints, split by stream. Separate from `run` so tests can
    /// assert the split without spawning the binary.
    struct Output: Equatable {
        var stdout: String
        var stderr: String
    }

    static func execute(_ args: [String]) throws -> Output {
        let directory = URL(fileURLWithPath: args.first { !$0.hasPrefix("--") } ?? ".").standardizedFileURL
        let detection = try ProjectToolchainDetector().detect(at: directory)

        if hasFlag("--json", in: args) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return Output(stdout: String(decoding: try encoder.encode(detection), as: UTF8.self) + "\n", stderr: "")
        }

        var notes = evidenceTable(detection)
        if hasFlag("--write", in: args) {
            guard !detection.isEmpty else { throw ConfigError.invalid("nothing detected, so no file was written") }
            let target = directory.appendingPathComponent(ProjectFileLoader.fileName)
            if FileManager.default.fileExists(atPath: target.path), !hasFlag("--force", in: args) {
                throw ConfigError.invalid("\(target.path) already exists (use --force to overwrite)")
            }
            try Data(detection.yaml().utf8).write(to: target, options: .atomic)
            notes += "\nWrote \(target.path)"
            return Output(stdout: "", stderr: notes)
        }
        return Output(stdout: detection.yaml(), stderr: notes)
    }

    static func evidenceTable(_ detection: ToolchainDetection) -> String {
        var lines: [String] = []
        let width = min(24, (detection.evidence.map(\.spec.count).max() ?? 0) + 2)
        for finding in detection.evidence {
            let spec = finding.spec.padding(toLength: max(width, finding.spec.count + 2), withPad: " ", startingAt: 0)
            lines.append("  \(spec)\(finding.source): \(finding.reason)")
        }
        if !detection.unmatched.isEmpty {
            lines.append("not in the catalog (skipped): \(detection.unmatched.joined(separator: ", "))")
        }
        for advice in detection.recommendations { lines.append("recommendation: \(advice)") }
        if detection.isEmpty && detection.recommendations.isEmpty { lines.append("no toolchains detected") }
        return lines.joined(separator: "\n")
    }
}
