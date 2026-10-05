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
    /// The `runs-on:` labels (or token expression / group mapping) this job asks for.
    public let runsOn: WorkflowRunsOn

    public init(
        id: String, name: String, needs: [String] = [], env: [String: String] = [:],
        defaults: WorkflowDefaults? = nil, timeoutMinutes: Int? = nil, continueOnError: Bool = false,
        hasMatrix: Bool = false, steps: [WorkflowStep] = [], runsOn: WorkflowRunsOn = .absent
    ) {
        self.id = id; self.name = name; self.needs = needs; self.env = env
        self.defaults = defaults; self.timeoutMinutes = timeoutMinutes
        self.continueOnError = continueOnError; self.hasMatrix = hasMatrix
        self.steps = steps; self.runsOn = runsOn
    }
}

public struct WorkflowDefaults: Sendable, Equatable {
    public let run: WorkflowRunDefaults?

    public struct WorkflowRunDefaults: Sendable, Equatable {
        public let workingDirectory: String?
        public let shell: String?
    }

    public init(run: WorkflowRunDefaults? = nil) { self.run = run }
}

/// What a job's `runs-on:` entry looks like. Kinohin can only reliably route
/// by explicit labels; a `${{ }}` expression or a `{group:, labels:}` mapping
/// can be evaluated by the forge only at queue time, so routing a job to a
/// specific runtime is refused and must go through a config route instead.
public enum WorkflowRunsOn: Sendable, Equatable, CustomStringConvertible {
    /// No `runs-on:` key.
    case absent
    /// A scalar (GitHub-hosted name, or any single label a user typed).
    case scalar(String)
    /// A list of labels: `[self-hosted, macos, arm64]`.
    case labels([String])
    /// A token expression the forge evaluates, e.g. `${{ matrix.os }}`.
    case expression(String)
    /// A label-group mapping (legacy GitHub host-selection form).
    case groupMap(group: String?, labels: [String])

    public var description: String {
        switch self {
        case .absent: return "absent"
        case .scalar(let value): return "\(value)"
        case .labels(let labels): return "[" + labels.joined(separator: ", ") + "]"
        case .expression(let value): return "\(value)"
        case .groupMap(let group, let labels):
            let groupPrefix = group.map { "\($0): " } ?? ""
            return groupPrefix + "[" + labels.joined(separator: ", ") + "]"
        }
    }
}

/// Parse `runs-on:` across every form GitHub writes. Keeping everything
/// distinguishable here keeps the routing/editor rules explicit instead of
/// pretending all jobs are label lists.
private func parseRunsOn(_ node: Node?) -> WorkflowRunsOn {
    guard let node else { return .absent }
    if let scalar = node.string {
        // A scalar the forge must evaluate is an expression, not a label —
        // `runs-on: ${{ matrix.os }}` can't be routed by editing labels.
        return scalar.contains("${{") ? .expression(scalar) : .scalar(scalar)
    }
    if let sequence = node.sequence {
        let labels = sequence.compactMap(\.string)
        if labels.isEmpty { return .absent }
        if labels.contains(where: { $0.contains("${{") }) {
            return .expression(labels.joined(separator: " "))
        }
        return .labels(labels)
    }
    if let mapping = node.mapping {
        if mapping["expression"]?.string != nil {
            return .expression(mapping["expression"]?.string ?? "")
        }
        let labels = stringMap(mapping["labels"] ?? mapping["label"] ?? mapping["run"])
            .mapValues { $0.replacingOccurrences(of: " ", with: "") }
        let groupKeys = mapping.keys.filter { $0.string != nil && ["os", "labels", "label", "run"].contains($0.string?.lowercased() ?? "") == false }
        if mapping["labels"] != nil || mapping["label"] != nil || !labels.isEmpty {
            return .groupMap(group: groupKeys.first?.string, labels: labels.mapValues { $0.split(whereSeparator: \.isWhitespace).map(String.init) }.values.flatMap { $0 })
        }
        return .groupMap(group: nil, labels: [])
    }
    return .absent
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
        let runsOn = parseRunsOn(job["runs-on"])
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
            steps: steps,
            runsOn: runsOn
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
