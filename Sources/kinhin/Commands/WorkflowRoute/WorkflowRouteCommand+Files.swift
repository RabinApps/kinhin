import Foundation
import KinhinKit

// MARK: - File resolution

extension WorkflowRouteCommand {
    static func resolveFile(_ options: Options) throws -> URL {
        if let file = options.file {
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw WorkflowRouteCLIError.usage("no workflow file at \(file.path)")
            }
            return file
        }
        let cwd = FileManager.default.currentDirectoryPath
        let dir = URL(fileURLWithPath: cwd)
        guard let name = options.workflowName else {
            throw WorkflowRouteCLIError.usage(
                "no workflow file given — pass a path or a workflow name; run `kinhin workflow test --list` to see names"
            )
        }
        let workflowsDir = dir.appendingPathComponent(".github/workflows")
        guard FileManager.default.fileExists(atPath: workflowsDir.path) else {
            throw WorkflowRouteCLIError.usage("no .github/workflows/ in \(cwd) — run from a repo checkout")
        }
        let candidates = try FileManager.default
            .contentsOfDirectory(at: workflowsDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "yml" || $0.pathExtension == "yaml" }
        let matches = candidates.filter { candidate in
            (try? loadWorkflow(at: candidate))?.name.caseInsensitiveCompare(name) == .orderedSame
        }
        guard matches.count == 1 else {
            if matches.isEmpty {
                throw WorkflowRouteCLIError.usage("no workflow named '\(name)' in \(workflowsDir.path)")
            }
            let names = matches.map(\.lastPathComponent).sorted().joined(separator: ", ")
            throw WorkflowRouteCLIError.usage(
                "more than one workflow named '\(name)': \(names) — pass a file path instead")
        }
        return matches[0]
    }

    static func loadWorkflow(at url: URL) throws -> WorkflowDocument {
        let data = try Data(contentsOf: url)
        return try parseWorkflow(data, at: url)
    }
}

// MARK: - Job scoping

extension WorkflowRouteCommand {
    static func resolveJobIDs(_ options: Options, in document: WorkflowDocument) throws -> Set<String> {
        guard !document.jobs.isEmpty else {
            throw WorkflowRouteCLIError.usage("workflow '\(document.name)' has no jobs — nothing to route")
        }
        if let job = options.job {
            guard
                let found = document.jobs.first(where: {
                    $0.id.caseInsensitiveCompare(job) == .orderedSame
                        || $0.name.caseInsensitiveCompare(job) == .orderedSame
                })
            else {
                let known = document.jobs.map { "\($0.id) (\($0.name))" }.joined(separator: ", ")
                throw WorkflowRouteCLIError.usage("no job named '\(job)'; known jobs: \(known)")
            }
            return [found.id]
        }
        return Set(document.jobs.map(\.id))
    }
}
