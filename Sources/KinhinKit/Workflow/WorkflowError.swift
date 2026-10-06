import Foundation

/// Errors encountered while locating, parsing, or running a local workflow.
public enum WorkflowError: LocalizedError, Sendable, CategorizedError {
    case unreadable(URL, String)
    case invalidYAML(URL, String)
    case noJobs(URL)
    case noWorkflowFound(URL)
    case ambiguousWorkflow([String])
    case unknownJob(String, [String])
    case cyclicNeeds([String])
    case unsupportedShell(String)

    public var category: ErrorCategory { .config }

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url, let reason): return "could not read \(url.lastPathComponent): \(reason)"
        case .invalidYAML(let url, let reason): return "invalid YAML in \(url.lastPathComponent): \(reason)"
        case .noJobs(let url): return "\(url.lastPathComponent) defines no jobs"
        case .noWorkflowFound(let directory):
            return "no workflow found in \(directory.appendingPathComponent(".github/workflows").path)"
        case .ambiguousWorkflow(let names):
            return "more than one workflow found: \(names.joined(separator: ", ")) — pass a file path"
        case .unknownJob(let name, let jobs):
            return "no job named or keyed '\(name)'; jobs: \(jobs.joined(separator: ", "))"
        case .cyclicNeeds(let chain):
            return "circular or invalid `needs:` dependency: \(chain.joined(separator: " → "))"
        case .unsupportedShell(let shell): return "unsupported shell '\(shell)'; only bash, sh and zsh are supported"
        }
    }
}
