import Foundation
import Yams

/// A parsed GitHub Actions workflow file.
public struct WorkflowDocument: Sendable, Equatable {
    public let name: String
    public let path: URL
    public let env: [String: String]
    public let defaults: WorkflowDefaults?
    public let jobs: [WorkflowJob]
}

/// One job of a workflow.
public struct WorkflowJob: Sendable, Identifiable, Equatable {
    /// YAML map key used by `needs:` and `--job`.
    public let id: String
    public let name: String
    public let needs: [String]
    public let env: [String: String]
    public let defaults: WorkflowDefaults?
    public let timeoutMinutes: Int?
    public let continueOnError: Bool
    public let hasMatrix: Bool
    public let steps: [WorkflowStep]
}

public struct WorkflowDefaults: Sendable, Equatable {
    public let run: WorkflowRunDefaults?

    public struct WorkflowRunDefaults: Sendable, Equatable {
        public let workingDirectory: String?
        public let shell: String?
    }

    public init(run: WorkflowRunDefaults? = nil) { self.run = run }
}

/// One step of a job.
public struct WorkflowStep: Sendable, Equatable {
    public let name: String
    public let uses: String?
    public let run: String?
    public let with: [String: String]?
    public let workingDirectory: String?
    public let shell: String?
    public let env: [String: String]
    public let id: String?
    public let continueOnError: Bool
    public let timeoutMinutes: Int?
    public let condition: String?

    public init(
        name: String, uses: String? = nil, run: String? = nil, with: [String: String]? = nil,
        workingDirectory: String? = nil, shell: String? = nil, env: [String: String] = [:],
        id: String? = nil, continueOnError: Bool = false, timeoutMinutes: Int? = nil, condition: String? = nil
    ) {
        self.name = name
        self.uses = uses
        self.run = run
        self.with = with
        self.workingDirectory = workingDirectory
        self.shell = shell
        self.env = env
        self.id = id
        self.continueOnError = continueOnError
        self.timeoutMinutes = timeoutMinutes
        self.condition = condition
    }
}

/// Locate the only `.yml` or `.yaml` workflow under `.github/workflows`.
public func locateWorkflow(in directory: URL) throws -> URL {
    let folder = directory.appendingPathComponent(".github/workflows", isDirectory: true)
    let candidates: [URL]
    do {
        candidates = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { ["yml", "yaml"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    } catch {
        throw WorkflowError.noWorkflowFound(directory)
    }
    guard !candidates.isEmpty else { throw WorkflowError.noWorkflowFound(directory) }
    guard candidates.count == 1 else {
        throw WorkflowError.ambiguousWorkflow(candidates.map(\.lastPathComponent))
    }
    return candidates[0]
}

/// Decode a GitHub Actions workflow document. Job names default to their YAML
/// keys; unnamed run steps use GitHub's `Run <first line>` rendering.
public func parseWorkflow(_ data: Data, at url: URL) throws -> WorkflowDocument {
    guard let yaml = String(data: data, encoding: .utf8) else {
        throw WorkflowError.unreadable(url, "file is not valid UTF-8")
    }
    let root: Node?
    do {
        root = try Yams.compose(yaml: yaml)
    } catch {
        throw WorkflowError.invalidYAML(url, error.localizedDescription)
    }
    guard let mapping = root?.mapping, let jobNodes = mapping["jobs"]?.mapping, !jobNodes.isEmpty else {
        throw WorkflowError.noJobs(url)
    }

    let jobs = jobNodes.compactMap { key, value -> WorkflowJob? in
        guard let id = key.string, let job = value.mapping else { return nil }
        let needs: [String]
        if let single = job["needs"]?.string {
            needs = [single]
        } else {
            needs = job["needs"]?.sequence?.compactMap(\.string) ?? []
        }
        let runDefaults = job["defaults"]?.mapping?["run"]?.mapping
        let defaults = runDefaults.map {
            WorkflowDefaults(run: WorkflowDefaults.WorkflowRunDefaults(
                workingDirectory: $0["working-directory"]?.string,
                shell: $0["shell"]?.string
            ))
        }
        let steps = (job["steps"]?.sequence ?? []).enumerated().map { index, node -> WorkflowStep in
            let step = node.mapping ?? [:]
            let run = step["run"]?.string
            let uses = step["uses"]?.string
            let firstLine = run?.split(separator: "\n").first.map(String.init)
            let fallbackName = run.map { "Run \(firstLine ?? $0)" } ?? uses ?? "Step \(index + 1)"
            let withValues = stringMap(step["with"])
            return WorkflowStep(
                name: step["name"]?.string ?? fallbackName,
                uses: uses,
                run: run,
                with: withValues.isEmpty ? nil : withValues,
                workingDirectory: step["working-directory"]?.string,
                shell: step["shell"]?.string,
                env: stringMap(step["env"]),
                id: step["id"]?.string,
                continueOnError: boolValue(step["continue-on-error"]),
                timeoutMinutes: intValue(step["timeout-minutes"]),
                condition: step["if"]?.string
            )
        }
        return WorkflowJob(
            id: id,
            name: job["name"]?.string ?? id,
            needs: needs,
            env: stringMap(job["env"]),
            defaults: defaults,
            timeoutMinutes: intValue(job["timeout-minutes"]),
            continueOnError: boolValue(job["continue-on-error"]),
            hasMatrix: job["strategy"]?.mapping?["matrix"] != nil,
            steps: steps
        )
    }
    guard !jobs.isEmpty else { throw WorkflowError.noJobs(url) }
    let workflowRunDefaults = mapping["defaults"]?.mapping?["run"]?.mapping
    let defaults = workflowRunDefaults.map {
        WorkflowDefaults(run: WorkflowDefaults.WorkflowRunDefaults(
            workingDirectory: $0["working-directory"]?.string,
            shell: $0["shell"]?.string
        ))
    }
    return WorkflowDocument(
        name: mapping["name"]?.string ?? url.deletingPathExtension().lastPathComponent,
        path: url,
        env: stringMap(mapping["env"]),
        defaults: defaults,
        jobs: jobs
    )
}

private func stringMap(_ node: Node?) -> [String: String] {
    guard let mapping = node?.mapping else { return [:] }
    return Dictionary(uniqueKeysWithValues: mapping.compactMap { key, value in
        guard let key = key.string, let value = value.string else { return nil }
        return (key, value)
    })
}

private func boolValue(_ node: Node?) -> Bool {
    guard let string = node?.string else { return false }
    return ["true", "yes", "on"].contains(string.lowercased())
}

private func intValue(_ node: Node?) -> Int? {
    guard let string = node?.string else { return nil }
    return Int(string)
}
