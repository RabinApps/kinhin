import Foundation

// MARK: - Buildkite agent

extension RunnerBootstrap {
    /// Installs the Buildkite agent binary into the macOS base image.
    static func buildkiteAgentInstallScript(version: String) -> String {
        """
        set -euo pipefail

        # Buildkite agent (one job per agent: --disconnect-after-job).
        if [ ! -x "$HOME/buildkite-agent/buildkite-agent" ]; then
          mkdir -p "$HOME/buildkite-agent"
          cd "$HOME/buildkite-agent"
          \(buildkiteAgentDownloadScript(version: version, platform: "darwin-arm64", file: "agent.tar.gz").replacingOccurrences(of: "\n", with: "\n  "))
          \(buildkiteAgentExtractScript(archive: "agent.tar.gz").replacingOccurrences(of: "\n", with: "\n  "))
          ./buildkite-agent --version
          echo "buildkite agent v\(version) installed"
        else
          echo "buildkite agent already installed"
        fi
        """
    }

    /// Installs the Buildkite agent binary into a Linux image (`arch` is
    /// "arm64", or "amd64" for emulated bakes).
    static func linuxBuildkiteAgentInstallScript(version: String, arch: String = "arm64") -> String {
        """
        set -euo pipefail
        \(linuxPrerequisitesScript(tools: [("curl", "curl"), ("git", "git")]))
        if [ ! -x /opt/buildkite-agent/buildkite-agent ]; then
          mkdir -p /opt/buildkite-agent
          cd /opt/buildkite-agent
          \(buildkiteAgentDownloadScript(version: version, platform: "linux-\(arch)", file: "agent.tar.gz").replacingOccurrences(of: "\n", with: "\n  "))
          \(buildkiteAgentExtractScript(archive: "agent.tar.gz").replacingOccurrences(of: "\n", with: "\n  "))
          ./buildkite-agent --version
        fi
        echo "linux buildkite-agent v\(version) installed"
        """
    }

    /// Unpacks the release archive in the current directory and asserts the
    /// binary landed at `./buildkite-agent`. The member name is not relied on
    /// (`./buildkite-agent` or `buildkite-agent`, depending on how the release
    /// was tarred): everything is extracted, then the result is checked.
    static func buildkiteAgentExtractScript(archive: String) -> String {
        """
        tar xzf \(archive)
        rm -f \(archive)
        if [ ! -x ./buildkite-agent ]; then
          echo "buildkite-agent is missing from the release archive" >&2
          exit 1
        fi
        """
    }

    /// Starts one single-job Buildkite agent per runner name. The cluster
    /// agent token is written to a private file (never on a command line), read
    /// and deleted by the agent's shell, and handed to `buildkite-agent start`
    /// through `BUILDKITE_AGENT_TOKEN`, so job steps never find it on disk. With
    /// `--disconnect-after-job` the agent leaves after its one job, which
    /// drops it from the connected-agent list: the "deregistered" signal the
    /// engine's ephemeral watch waits for. A non-ephemeral pool (`ephemeral:
    /// false`) keeps its agents connected across jobs instead.
    ///
    /// Residual exposure (not changed, cannot be verified without a real
    /// agent): the agent needs its token for its whole life, so it stays in
    /// the agent process's environment, which a job running as the same user can
    /// read with `ps eww`. Use a cluster token scoped to this pool.
    ///
    /// Each agent is given `settleSeconds` to register; one that has exited by
    /// then (bad token, unknown queue, bad flags) fails the script with its
    /// own `agent.log` and stops the others, instead of looking started. An
    /// agent that exited 0 already finished its one job, which is success.
    ///
    /// `binary` and `baseDir` are shell words (already quoted, or `$HOME/…`);
    /// each agent lives in `baseDir/<name>` with its builds, plugins, log and
    /// the pid of its background job.
    static func buildkiteRegistrationScript(
        token: String, tags: [String], runnerNames: [String], ephemeral: Bool = true, binary: String,
        baseDir: String, settleSeconds: Int = 5
    ) -> String {
        let tagList = tags.joined(separator: ",")
        let lifetime = ephemeral ? " --disconnect-after-job" : ""
        var blocks = ""
        for (index, runner) in runnerNames.enumerated() {
            blocks += """
                # Buildkite agent \(index + 1) of \(runnerNames.count)
                mkdir -p \(baseDir)/\(shellQuote(runner))
                cd \(baseDir)/\(shellQuote(runner))
                (umask 077 && printf '%s' \(shellQuote(token)) > token)
                nohup /bin/bash -c '
                  BUILDKITE_AGENT_TOKEN="$(cat token)"
                  rm -f token
                  export BUILDKITE_AGENT_TOKEN
                  exec "$0" start --name "$1" --tags "$2"\(lifetime) \\
                    --build-path "$PWD/builds" --plugins-path "$PWD/plugins"
                ' \(binary) \(shellQuote(runner)) \(shellQuote(tagList)) > agent.log 2>&1 < /dev/null &
                pid_\(index)=$!
                echo "$pid_\(index)" > agent.pid

                """
        }
        let pids = runnerNames.indices.map { "\"$pid_\($0)\"" }.joined(separator: " ")
        var checks = ""
        for (index, runner) in runnerNames.enumerated() {
            checks += """
                if ! kill -0 "$pid_\(index)" 2>/dev/null; then
                  status=0
                  wait "$pid_\(index)" || status=$?
                  if [ "$status" -ne 0 ]; then
                    echo "buildkite agent '\(runner)' exited immediately (status $status):"
                    tail -n 20 \(baseDir)/\(shellQuote(runner))/agent.log
                    kill \(pids) 2>/dev/null || true
                    exit 1
                  fi
                fi

                """
        }
        return """
            set -euo pipefail

            \(blocks)# An agent that cannot register dies within seconds: fail with its log.
            sleep \(settleSeconds)
            \(checks)echo "\(runnerNames.count) buildkite agent(s) started"
            """
    }

    /// The agents' tags: the account's labels, plus the pool's `key=value`
    /// labels whose key the account does not set already, plus the pool's
    /// runtime marker (`kinhin-docker`, ...) as a `kinhin-runtime=docker` tag,
    /// the only form an agent query rule can target. Other pool labels
    /// without a key are GitHub-style and mean nothing here.
    static func buildkiteTags(accountLabels: [String], poolLabels: [String]?) -> [String] {
        var tags = accountLabels
        var keys = Set(accountLabels.compactMap { BuildkiteForge.split($0)?.key })
        for label in poolLabels ?? [] {
            if let tag = BuildkiteForge.runtimeTag(forMarker: label) {
                if keys.insert(BuildkiteForge.runtimeTagKey).inserted { tags.append(tag) }
                continue
            }
            guard let key = BuildkiteForge.split(label)?.key, keys.insert(key).inserted else { continue }
            tags.append(label)
        }
        return tags
    }
}
