import Foundation

// MARK: - Gitea / Forgejo on the host

extension HostRuntime {
    /// The Gitea agent binary installed by `HostAgentInstaller`.
    var giteaRunnerBinary: URL { agentDir.appendingPathComponent("gitea-runner") }

    /// Gitea-family registration on the Mac itself: per runner, a private
    /// directory inside the instance's scrubbed work dir holds the `.runner`
    /// file, a config that redirects job workspaces there, a log, and the
    /// daemon's pid (so teardown can stop it — Gitea daemons have no
    /// `--ephemeral` and would otherwise outlive the job).
    func giteaRegistrationScript(
        instance: String, token: String, labels: [String], name: String, runnerCount: Int
    ) -> String {
        let count = max(1, runnerCount)
        let workDir = workDirectory(for: name)
        let bin = RunnerBootstrap.shellQuote(giteaRunnerBinary.path)
        let labelList = Self.hostLabels(labels).joined(separator: ",")
        var blocks = ""
        for index in 1...count {
            let runnerName = count == 1 ? name : "\(name)-r\(index)"
            let dir = workDir.appendingPathComponent("gitea-\(index)", isDirectory: true)
            let quotedDir = RunnerBootstrap.shellQuote(dir.path)
            let quotedWork = RunnerBootstrap.shellQuote(dir.appendingPathComponent("work").path)
            blocks += """
                # Gitea runner \(index) of \(count)
                mkdir -p \(quotedDir)
                cd \(quotedDir)
                printf 'host:\\n  workdir_parent: %s\\n' \(quotedWork) > config.yaml
                rm -f .runner
                \(bin) -c config.yaml register --no-interactive \\
                  --instance \(RunnerBootstrap.shellQuote(instance)) \\
                  --token \(RunnerBootstrap.shellQuote(token)) \\
                  --name \(RunnerBootstrap.shellQuote(runnerName)) \\
                  --labels \(RunnerBootstrap.shellQuote(labelList)) >/dev/null
                nohup \(bin) -c config.yaml daemon > daemon.log 2>&1 < /dev/null &
                echo $! > daemon.pid

                """
        }
        return """
            set -euo pipefail

            \(blocks)echo "\(count) gitea runner(s) started on the host"
            """
    }

    /// Host runners execute jobs directly on the Mac, so every label must use
    /// Gitea's `:host` scheme (a bare or `:docker://…` label would make the
    /// daemon try a container). Adds the `kinhin-host` opt-in marker.
    static func hostLabels(_ labels: [String]) -> [String] {
        var result: [String] = []
        for label in labels + ["kinhin-host"] {
            let name = label.split(separator: ":", maxSplits: 1).first.map(String.init) ?? label
            let hostLabel = "\(name):host"
            if !name.isEmpty, !result.contains(hostLabel) { result.append(hostLabel) }
        }
        return result
    }

    /// SIGTERMs this instance's Gitea daemons. A recorded pid is only killed
    /// while it still looks like a gitea-runner daemon (pids get reused).
    func stopGiteaDaemons(id: String) async {
        let workDir = workDirectory(for: id)
        // An absent (or unreadable) dir means nothing was registered here,
        // so there is nothing to stop.
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: workDir.path)) ?? []
        guard entries.contains(where: { $0.hasPrefix("gitea-") }) else { return }
        let script = """
            for f in \(RunnerBootstrap.shellQuote(workDir.path))/gitea-*/daemon.pid; do
              [ -f "$f" ] || continue
              pid="$(cat "$f")"
              if ps -p "$pid" -o command= | grep -q 'gitea-runner.* daemon'; then kill "$pid" || true; fi
            done
            """
        await bestEffortAsync(id, "stopping gitea daemons") {
            _ = try await shell.run(["/bin/bash", "-c", script], cwd: nil, timeout: 30)
        }
    }
}
