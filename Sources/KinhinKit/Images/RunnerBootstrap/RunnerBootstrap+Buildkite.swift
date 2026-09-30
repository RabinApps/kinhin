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
          tar xzf agent.tar.gz ./buildkite-agent
          rm agent.tar.gz
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
          tar xzf agent.tar.gz ./buildkite-agent
          rm agent.tar.gz
          ./buildkite-agent --version
        fi
        echo "linux buildkite-agent v\(version) installed"
        """
    }

    /// Starts one single-job Buildkite agent per runner name. The cluster
    /// agent token is written to a private file (never on a command line) and
    /// handed to `buildkite-agent start` through `BUILDKITE_AGENT_TOKEN`. With
    /// `--disconnect-after-job` the agent leaves after its one job, which
    /// drops it from the connected-agent list: the "deregistered" signal the
    /// engine's ephemeral watch waits for. A non-ephemeral pool (`ephemeral:
    /// false`) keeps its agents connected across jobs instead.
    ///
    /// `binary` and `baseDir` are shell words (already quoted, or `$HOME/…`);
    /// each agent lives in `baseDir/<name>` with its builds, plugins, log and
    /// the pid of its background job.
    static func buildkiteRegistrationScript(
        token: String, tags: [String], runnerNames: [String], ephemeral: Bool = true, binary: String,
        baseDir: String
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
                  export BUILDKITE_AGENT_TOKEN
                  exec "$0" start --name "$1" --tags "$2"\(lifetime) \\
                    --build-path "$PWD/builds" --plugins-path "$PWD/plugins"
                ' \(binary) \(shellQuote(runner)) \(shellQuote(tagList)) > agent.log 2>&1 < /dev/null &
                echo $! > agent.pid

                """
        }
        return """
            set -euo pipefail

            \(blocks)echo "\(runnerNames.count) buildkite agent(s) started"
            """
    }

    /// The agents' tags: the account's labels, plus any `key=value` pool
    /// labels (runtime markers) whose key the account does not set already.
    /// Pool labels without a key are GitHub-style and mean nothing here.
    static func buildkiteTags(accountLabels: [String], poolLabels: [String]?) -> [String] {
        var tags = accountLabels
        var keys = Set(accountLabels.compactMap { BuildkiteForge.split($0)?.key })
        for label in poolLabels ?? [] {
            guard let key = BuildkiteForge.split(label)?.key, keys.insert(key).inserted else { continue }
            tags.append(label)
        }
        return tags
    }
}
