import Foundation

/// Runs a parsed GitHub Actions workflow on the current Mac, using the shared
/// host shell abstraction. Matrix expansion and non-checkout actions are not
/// supported in this version.
public actor LocalWorkflowRunner {
    /// Reported once per run: nothing here is sandboxed.
    public static let isolationNotice =
        "steps run directly on this Mac with your privileges (not isolated like a runner VM or container)"

    private let shell: ShellRunning
    private let onEvent: @Sendable (LocalRunEvent) -> Void

    public init(shell: ShellRunning, onEvent: @escaping @Sendable (LocalRunEvent) -> Void = { _ in }) {
        self.shell = shell
        self.onEvent = onEvent
    }

    public func run(
        document: WorkflowDocument,
        jobs requestedJobs: [String] = [],
        workingDirectory: URL
    ) async throws -> LocalRunReport {
        let byID = Dictionary(uniqueKeysWithValues: document.jobs.map { ($0.id, $0) })
        let requested = requestedJobs.isEmpty ? document.jobs.map(\.id) : requestedJobs
        for id in requested where byID[id] == nil {
            throw WorkflowError.unknownJob(id, document.jobs.map(\.id))
        }
        // A selected job is intentionally isolated: its dependencies are
        // reported but not implicitly executed. Full runs retain needs order.
        let ordered = requestedJobs.isEmpty ? try topologicalOrder(requested, jobs: byID) : requested
        let started = Date()
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-workflow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            bestEffort("workflow", "remove temporary environment files") {
                try FileManager.default.removeItem(at: tempDirectory)
            }
        }

        var results: [LocalJobResult] = []
        var jobOutcomes: [String: PipelineStepState] = [:]
        var failedEarlierJob = false
        var notices: [String] = [Self.isolationNotice]
        if !requestedJobs.isEmpty, let first = byID[requestedJobs[0]], !first.needs.isEmpty {
            notices.append("--job \(first.id) selected; its needs were not run")
            onEvent(.needSkipped(first.id))
        }

        for id in ordered {
            try Task.checkCancellation()
            guard let job = byID[id] else { continue }
            if failedEarlierJob
                || job.needs.contains(where: {
                    jobOutcomes[$0] == .failed || jobOutcomes[$0] == .cancelled || jobOutcomes[$0] == .skipped
                })
            {
                let skipped = LocalJobResult(
                    name: job.name, id: job.id, state: .skipped, startedAt: nil, finishedAt: nil,
                    duration: nil, steps: [], notices: ["skipped because a dependency did not succeed"])
                results.append(skipped)
                jobOutcomes[id] = .skipped
                onEvent(.jobFinished(id, state: .skipped))
                continue
            }
            let result = try await run(job: job, workflow: document, root: workingDirectory, temp: tempDirectory)
            results.append(result)
            jobOutcomes[id] = result.state
            if result.state == .failed || result.state == .cancelled { failedEarlierJob = true }
        }
        let unsupported = LocalRunReport.unsupportedSkips(in: results)
        if !unsupported.isEmpty {
            notices.append(
                "\(unsupported.count) job/step(s) skipped as unsupported: the result is partial, not a pass")
        }
        let report = LocalRunReport(
            workflowPath: document.path,
            workflowName: document.name,
            workingDirectory: workingDirectory.path,
            startedAt: started,
            finishedAt: Date(),
            jobs: results,
            notices: notices
        )
        return report
    }

    private func run(
        job: WorkflowJob, workflow: WorkflowDocument, root: URL, temp: URL
    ) async throws -> LocalJobResult {
        let started = Date()
        onEvent(.jobStarted(job.id))
        var jobNotices: [String] = []
        if job.hasMatrix {
            let notice = "matrix job skipped (matrix expansion is not supported)"
            jobNotices.append(notice)
            onEvent(.matrixSkipped(job.id))
            onEvent(.jobFinished(job.id, state: .skipped))
            return LocalJobResult(
                name: job.name, id: job.id, state: .skipped, startedAt: started, finishedAt: Date(), duration: 0,
                steps: [], notices: jobNotices, skippedAsUnsupported: true)
        }

        let expressions = ExpressionEvaluator(root: root)
        var env = baselineEnvironment(root: root, temp: temp)
        env["PATH"] = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        env.merge(workflow.env) { _, new in new }
        env.merge(job.env) { _, new in new }
        var stepResults: [LocalStepResult] = []
        var previousFailure = false
        let originalPath = env["PATH"] ?? "/usr/bin:/bin"
        var envFileValues: [String: String] = [:]
        var pathEntries: [String] = []

        for step in job.steps {
            try Task.checkCancellation()
            let condition = expressions.evaluate(condition: step.condition, previousFailure: previousFailure)
            guard condition.shouldRun else {
                let note = condition.notice ?? "condition is not supported; skipped"
                stepResults.append(
                    LocalStepResult(
                        name: step.name, state: .skipped, startedAt: nil, finishedAt: nil, duration: nil,
                        notices: [note], skippedAsUnsupported: condition.unsupported))
                onEvent(.stepSkipped(step.name, notice: note))
                continue
            }
            if previousFailure && !condition.forceRun {
                let note = "skipped after a previous step failed"
                stepResults.append(
                    LocalStepResult(
                        name: step.name, state: .skipped, startedAt: nil, finishedAt: nil, duration: nil,
                        notices: [note]))
                onEvent(.stepSkipped(step.name, notice: note))
                continue
            }

            var stepEnv = env
            stepEnv.merge(envFileValues) { _, new in new }
            if !pathEntries.isEmpty { stepEnv["PATH"] = (pathEntries + [originalPath]).joined(separator: ":") }
            stepEnv.merge(step.env) { _, new in new }
            var stepNotices: [String] = []
            let stepShell = step.shell ?? job.defaults?.run?.shell ?? workflow.defaults?.run?.shell ?? "bash"
            guard ["bash", "sh", "zsh", "bash -e", "sh -e", "zsh -e"].contains(stepShell) else {
                throw WorkflowError.unsupportedShell(stepShell)
            }
            let script: String
            // A `uses:` other than checkout is not run; the run is then partial.
            var unsupportedUse = false
            if let run = step.run {
                let expanded = expressions.expand(run, env: stepEnv, notices: &stepNotices)
                script = exportPreamble(stepEnv) + expanded
            } else if let uses = step.uses {
                if uses == "actions/checkout" || uses.hasPrefix("actions/checkout@") {
                    let notice = "uses: \(uses) treated as a no-op (working tree already present)"
                    stepNotices.append(notice)
                    script = ""
                } else {
                    let notice = "uses: \(uses) skipped (third-party actions are not supported)"
                    stepNotices.append(notice)
                    unsupportedUse = true
                    script = ""
                }
            } else {
                let notice = "step has neither run nor uses"
                stepNotices.append(notice)
                script = ""
            }
            for notice in stepNotices { onEvent(.stepNotice(step.name, notice: notice)) }
            guard !script.isEmpty else {
                let state: PipelineStepState = step.uses?.hasPrefix("actions/checkout") == true ? .succeeded : .skipped
                stepResults.append(
                    LocalStepResult(
                        name: step.name, state: state, startedAt: nil, finishedAt: Date(), duration: 0,
                        notices: stepNotices, skippedAsUnsupported: unsupportedUse))
                onEvent(.stepFinished(step.name, state: state))
                continue
            }

            let started = Date()
            onEvent(.stepStarted(step.name))
            let directory = resolvedDirectory(
                step.workingDirectory ?? job.defaults?.run?.workingDirectory
                    ?? workflow.defaults?.run?.workingDirectory,
                relativeTo: root)
            let timeout = TimeInterval(step.timeoutMinutes ?? job.timeoutMinutes ?? 30) * 60
            let command: [String]
            switch stepShell.split(separator: " ").first.map(String.init) ?? stepShell {
            case "bash": command = ["/bin/bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-s"]
            case "sh": command = ["/bin/sh", "-e", "-s"]
            case "zsh": command = ["/bin/zsh", "-e", "-s"]
            default: throw WorkflowError.unsupportedShell(stepShell)
            }
            let shellResult: ShellResult
            do {
                shellResult = try await shell.run(command, input: Data(script.utf8), cwd: directory, timeout: timeout)
            } catch is CancellationError {
                onEvent(.stepFinished(step.name, state: .cancelled))
                throw CancellationError()
            } catch {
                let finished = Date()
                let message = error.localizedDescription
                let failed = LocalStepResult(
                    name: step.name, state: .failed, startedAt: started, finishedAt: finished,
                    duration: finished.timeIntervalSince(started), notices: ["shell failed: \(message)"])
                stepResults.append(failed)
                previousFailure = !step.continueOnError
                onEvent(.stepFinished(step.name, state: .failed))
                continue
            }
            let finished = Date()
            let output = boundedOutput(
                shellResult.stdout + (shellResult.stderr.isEmpty ? "" : "\n" + shellResult.stderr))
            let failed = !shellResult.succeeded
            let result = LocalStepResult(
                name: step.name,
                state: failed ? .failed : .succeeded,
                startedAt: started,
                finishedAt: finished,
                duration: finished.timeIntervalSince(started),
                output: output,
                notices: stepNotices
            )
            if let output { onEvent(.stepOutput(step.name, output: output)) }
            stepResults.append(result)
            if failed && !step.continueOnError { previousFailure = true }
            applyEnvironmentFiles(temp: temp, values: &envFileValues, paths: &pathEntries, notices: &stepNotices)
            onEvent(.stepFinished(step.name, state: result.state))
        }
        let failed = previousFailure
        let state: PipelineStepState =
            failed ? (job.continueOnError ? .succeeded : .failed) : (stepResults.isEmpty ? .skipped : .succeeded)

        let finished = Date()
        onEvent(.jobFinished(job.id, state: state))
        return LocalJobResult(
            name: job.name, id: job.id, state: state, startedAt: started, finishedAt: finished,
            duration: finished.timeIntervalSince(started), steps: stepResults, notices: jobNotices)
    }

    private func topologicalOrder(_ requested: [String], jobs: [String: WorkflowJob]) throws -> [String] {
        var visited: Set<String> = []
        var active: Set<String> = []
        var ordered: [String] = []
        func visit(_ id: String, chain: [String]) throws {
            if visited.contains(id) { return }
            guard active.insert(id).inserted else { throw WorkflowError.cyclicNeeds(chain + [id]) }
            guard let job = jobs[id] else { throw WorkflowError.unknownJob(id, Array(jobs.keys).sorted()) }
            for need in job.needs {
                guard jobs[need] != nil else { throw WorkflowError.unknownJob(need, Array(jobs.keys).sorted()) }
                try visit(need, chain: chain + [id])
            }
            active.remove(id)
            visited.insert(id)
            ordered.append(id)
        }
        for id in requested { try visit(id, chain: []) }
        return ordered
    }

    private func baselineEnvironment(root: URL, temp: URL) -> [String: String] {
        [
            "CI": "true", "GITHUB_ACTIONS": "true", "GITHUB_WORKSPACE": root.path,
            "RUNNER_OS": "macOS", "RUNNER_ARCH": "arm64",
            "GITHUB_ENV": temp.appendingPathComponent("env").path,
            "GITHUB_PATH": temp.appendingPathComponent("path").path,
        ]
    }

    private func exportPreamble(_ values: [String: String]) -> String {
        values.keys.sorted().filter(isValidEnvironmentName).map {
            "export \($0)='\(shellQuote(values[$0] ?? ""))'"
        }.joined(separator: "\n") + "\n"
    }

    private func isValidEnvironmentName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }

    private func shellQuote(_ value: String) -> String { value.replacingOccurrences(of: "'", with: "'\\''") }

    private func resolvedDirectory(_ path: String?, relativeTo root: URL) -> URL {
        guard let path, !path.isEmpty else { return root }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path, isDirectory: true) }
        return root.appendingPathComponent(path, isDirectory: true).standardizedFileURL
    }

    private func boundedOutput(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        if text.count <= 200_000 { return text }
        return String(text.suffix(200_000))
    }

    private func applyEnvironmentFiles(
        temp: URL, values: inout [String: String], paths: inout [String], notices: inout [String]
    ) {
        let envFile = temp.appendingPathComponent("env")
        // The step wrote no GITHUB_ENV file (the usual case): nothing to apply.
        if let text = try? String(contentsOf: envFile, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                guard let separator = line.firstIndex(of: "=") else {
                    if !notices.contains("multiline GITHUB_ENV entries are not supported") {
                        notices.append("multiline GITHUB_ENV entries are not supported")
                    }
                    continue
                }
                let key = String(line[..<separator])
                let value = String(line[line.index(after: separator)...])
                if isValidEnvironmentName(key) { values[key] = value }
            }
        }
        let pathFile = temp.appendingPathComponent("path")
        // The step wrote no GITHUB_PATH file (the usual case): nothing to apply.
        if let text = try? String(contentsOf: pathFile, encoding: .utf8) {
            let added = text.split(separator: "\n").map(String.init)
            if !added.isEmpty { paths.append(contentsOf: added) }
        }
    }
}
