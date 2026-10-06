import Foundation

/// The Docker-compatible CLI both Linux container runtimes drive — `docker`
/// and Apple's `container` take the same run/exec/start flags and differ only
/// in a few verbs (the `Dialect`). `DockerRuntime` and `AppleContainerRuntime`
/// keep their health probes and public surface; everything a runner
/// container goes through (provision, registration, readiness, teardown,
/// enumeration) lives here once.
struct LinuxContainerCLI: Sendable {
    /// Where the two CLIs differ.
    struct Dialect: Sendable {
        /// Log tag ("docker", "container").
        let tag: String
        /// Lists containers: `docker ps` / `container list`.
        let listVerb: String
        /// Removes a container: `docker rm` / `container delete`.
        let removeVerb: String
        /// Flags that make the list command print one container *name* per line
        /// (`docker ps --quiet` prints ids, which never match the `kinhin-` names).
        let listNameArguments: [String]
        /// Lists local image references, one per line.
        let imageListArguments: [String]
        /// Removes one local image (`docker image rm` / `container image delete`).
        let imageRemoveArguments: [String]
        /// Extra `run` flags (Docker's `--platform`).
        let runFlags: [String]
        /// Shown in the provision log line (Docker's platform).
        let shapeNote: String?
    }

    let shell: ShellRunning
    let bin: String
    let dialect: Dialect
    /// Linux image baked with the runner agents.
    let image: String
    let cpus: Int
    let memoryBytes: Int64

    var memoryLabel: String { "\(memoryBytes / 1_048_576)M" }

    // MARK: - Provision

    /// Starts the runner container (or restarts an existing one: recovery).
    func provision(id: String, route: RepoRoute) async throws {
        if try await containerIDs(all: true).contains(id) {
            Log.info(id, "container already exists; starting it (recovery)")
            try await require(run([bin, "start", id]), "starting container \(id)")
            return
        }
        let shape = ["\(cpus) vCPU", "\(memoryBytes / 1_073_741_824) GB"] + [dialect.shapeNote].compactMap { $0 }
        Log.info(id, "starting Linux container from \(image) (\(shape.joined(separator: ", ")))")
        var argv = [bin, "run", "--detach"]
        // Opt-in shared cache: bind-mount the host toolchain cache so per-job
        // installs reuse warm downloads. Best-effort: create the host dir
        // first so a fresh install cannot fail the run.
        if route.cacheMount {
            bestEffort(dialect.tag, "creating the toolchain cache directory") {
                try FileManager.default.createDirectory(at: Paths.toolchainCache, withIntermediateDirectories: true)
            }
            argv += ["--volume", ToolchainCacheMount.volumeSpec(host: Paths.toolchainCache.path)]
        }
        argv += ["--name", id, "--cpus", String(cpus), "--memory", memoryLabel] + dialect.runFlags
        argv += [
            "--rm",  // agent exit removes the container: belt + suspenders
            image,
            "/bin/bash", "-lc", "while true; do sleep 3600; done",
        ]
        try await require(run(argv), "starting a container from \(image)")
    }

    // MARK: - Registration

    /// The Linux bootstrap script for the forge, run inside the container.
    func registrationScript(
        forge: Forge, token: String, runnerTokens: [String: String], name: String,
        runnerCount: Int, route: RepoRoute, labels: [String]?
    ) throws -> String {
        // Linux platform: macOS-only entries (brew, fvm, CocoaPods) never appear.
        let selection = route.toolchains.map { ToolchainCatalog.selection(from: $0, platform: .linux) }
        let cachePrefix = RunnerBootstrap.cachePrefix(
            mounted: route.cacheMount, selection: selection, mountPath: ToolchainCacheMount.linuxGuestPath)
        switch forge.credentials.forge {
        case .github:
            if case .jitConfig = forge.registration {
                let names = FleetEngine.runnerNames(for: name, count: runnerCount)
                guard names.allSatisfy({ runnerTokens[$0] != nil }), runnerTokens.count == names.count else {
                    throw EngineError.registrationFailed(vm: name, stderr: "forge returned incomplete JIT configs")
                }
                let scripts = names.enumerated().map { index, runnerName in
                    // Match the layout `kinhin image prepare` bakes for Linux: runner 1
                    // lives in /opt/actions-runner; runners 2..N live in
                    // /opt/actions-runner-2..N. The previous mapping used
                    // /opt/actions-runner-(index+1), which produced a missing
                    // /opt/actions-runner-1 for the first multi-runner container.
                    let runnerNumber = index + 1
                    let directory: String
                    let workFolder: String
                    if runnerCount == 1 {
                        directory = "/opt/actions-runner"
                        workFolder = "/opt/work"
                    } else {
                        directory =
                            runnerNumber == 1
                            ? "/opt/actions-runner"
                            : "/opt/actions-runner-\(runnerNumber)"
                        workFolder =
                            runnerNumber == 1
                            ? "/opt/work"
                            : "/opt/work-\(runnerNumber)"
                    }
                    return RunnerBootstrap.linuxJitRegistrationScript(
                        encodedJitConfig: runnerTokens[runnerName] ?? "", name: runnerName,
                        workFolder: workFolder, agentDirectory: directory,
                        pidFile: "/var/run/kinhin-\(name)-r\(runnerNumber).pid")
                }
                return cachePrefix + scripts.joined(separator: "\n")
            }
            return cachePrefix
                + RunnerBootstrap.linuxGitHubRegistrationScript(
                    configureURL: forge.registrationURL(), token: token, labels: labels ?? forge.labels,
                    ephemeral: route.ephemeral, name: name, runnerCount: runnerCount)
        case .gitea, .forgejo:
            // Forgejo shares Gitea's runner binary and registration flow.
            return cachePrefix
                + RunnerBootstrap.linuxGiteaRegistrationScript(
                    instance: forge.registrationURL(), token: token, labels: forge.labels, name: name,
                    runnerCount: runnerCount)
        case .gitlab:
            return cachePrefix
                + RunnerBootstrap.gitlabRegistrationScript(
                    instance: forge.registrationURL(),
                    runners: try RunnerBootstrap.gitlabRunners(
                        name: name, runnerCount: runnerCount, tokens: runnerTokens),
                    binary: "/opt/gitlab-runner/gitlab-runner",
                    baseDir: "/opt/gitlab-runner")
        case .buildkite:
            return cachePrefix
                + RunnerBootstrap.buildkiteRegistrationScript(
                    token: token,
                    tags: RunnerBootstrap.buildkiteTags(accountLabels: forge.labels, poolLabels: labels),
                    runnerNames: FleetEngine.runnerNames(for: name, count: runnerCount),
                    ephemeral: route.ephemeral,
                    binary: "/opt/buildkite-agent/buildkite-agent",
                    baseDir: "/opt/buildkite-agent")
        case .azuredevops:
            // Containers run as root, which the agent refuses unless allowed.
            return cachePrefix
                + RunnerBootstrap.azureRegistrationScript(
                    organization: forge.registrationURL(), token: token, pool: forge.scope,
                    runnerNames: FleetEngine.runnerNames(for: name, count: runnerCount),
                    capabilities: AzureDevOpsForge.capabilityEnvironment(forge.labels),
                    template: "/opt/azure-agent", baseDir: "/opt/azure-agents", copy: .archive,
                    extraEnvironment: ["AGENT_ALLOW_RUNASROOT=1"])
        case .bitbucket:
            return cachePrefix
                + RunnerBootstrap.bitbucketRegistrationScript(
                    runners: try RunnerBootstrap.bitbucketRunners(
                        name: name, runnerCount: runnerCount, tokens: runnerTokens),
                    runtime: "linux-shell",
                    runnerCommand: "/opt/bitbucket-runner/runner.sh",
                    baseDir: "/opt/bitbucket-runners")
        }
    }

    /// Runs a script inside the running container (`exec`), which surfaces
    /// the script's exit status directly — the exec analogue of SSH.
    func exec(_ id: String, _ script: String, timeout: TimeInterval = 600) async throws -> ShellResult {
        // `-i` + a login shell reading stdin: the script (registration tokens
        // included) stays out of the docker/container CLI's argv.
        try await shell.run(
            [bin, "exec", "-i", id, "/bin/bash", "-ls"], input: Data(script.utf8), cwd: nil, timeout: timeout)
    }

    /// Polls until the container is running so `exec` can proceed.
    func awaitRunning(_ id: String, timeout: TimeInterval, pollInterval: TimeInterval = 1) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if try await containerIDs(all: false).contains(id) { return }
            try await Task.sleep(for: .seconds(pollInterval))
        }
        throw RuntimeWatchError.registrationTimeout(vm: id)
    }

    // MARK: - Teardown

    /// Removes the container. `--rm` usually got there first, so an already
    /// missing container is fine; any other failure is logged.
    func teardown(id: String) async {
        await bestEffortAsync(id, "removing container") {
            let result = try await run([bin, dialect.removeVerb, "--force", id])
            let gone =
                result.stderr.localizedCaseInsensitiveContains("no such container")
                || result.stderr.localizedCaseInsensitiveContains("not found")
            if !gone { try require(result, "removing container \(id)") }
        }
    }

    // MARK: - Enumeration

    /// Container ids known to the CLI (`all`: stopped ones too). Throws when
    /// the CLI fails: a dead daemon must not read as "no containers".
    func containerIDs(all: Bool) async throws -> [String] {
        let argv = [bin, dialect.listVerb] + (all ? ["--all"] : []) + dialect.listNameArguments
        let result = try await run(argv)
        try require(result, "listing containers")
        return result.outputLines
    }

    /// Local image references (the checklist's image row and the doctor);
    /// empty, with a warning, when the CLI can't list them.
    func localImageNames() async -> [String] {
        do {
            let result = try await run([bin] + dialect.imageListArguments)
            try require(result, "listing images")
            return result.outputLines
        } catch {
            Log.warn(dialect.tag, "could not list images: \(error.localizedDescription)")
            return []
        }
    }

    /// Removes one local image reference. An image that is already gone is
    /// success — deleting is idempotent, like `teardown`.
    func deleteImage(_ name: String) async throws {
        let result = try await run([bin] + dialect.imageRemoveArguments + [name])
        let gone =
            result.stderr.localizedCaseInsensitiveContains("no such image")
            || result.stderr.localizedCaseInsensitiveContains("not found")
            || result.stderr.localizedCaseInsensitiveContains("does not exist")
        guard result.succeeded || gone else {
            throw ContainerManagerError.commandFailed(
                what: "\(dialect.tag): removing image \(name)", stderr: result.failureExcerpt)
        }
    }

    func run(_ argv: [String], timeout: TimeInterval = 120) async throws -> ShellResult {
        try await shell.run(argv, cwd: nil, timeout: timeout)
    }

    private func require(_ result: ShellResult, _ what: String) throws {
        guard result.succeeded else {
            throw ContainerManagerError.commandFailed(what: "\(dialect.tag): \(what)", stderr: result.stderr)
        }
    }
}
