import Foundation

// MARK: - Azure Pipelines agent

extension RunnerBootstrap {
    /// Installs the Azure Pipelines agent into the macOS base image, as the
    /// template every runner copies.
    static func azureAgentInstallScript(version: String) -> String {
        """
        set -euo pipefail

        # Azure Pipelines agent (each runner clones it; one job per run.sh --once).
        if [ ! -x "$HOME/azure-agent/config.sh" ]; then
          mkdir -p "$HOME/azure-agent"
          cd "$HOME/azure-agent"
          \(azureAgentDownloadScript(version: version, platform: "osx-arm64", file: "agent.tar.gz").replacingOccurrences(of: "\n", with: "\n  "))
          tar xzf agent.tar.gz
          rm agent.tar.gz
          echo "azure pipelines agent v\(version) installed"
        else
          echo "azure pipelines agent already installed"
        fi
        """
    }

    /// Installs the Azure Pipelines agent and its system dependencies (ICU and
    /// friends, via the agent's own script) into a Linux image. `platform` is
    /// "linux-arm64", or "linux-x64" for emulated bakes.
    static func linuxAzureAgentInstallScript(version: String, platform: String = "linux-arm64") -> String {
        """
        set -euo pipefail
        \(linuxPrerequisitesScript(tools: [("curl", "curl"), ("git", "git")]))
        if [ ! -x /opt/azure-agent/config.sh ]; then
          mkdir -p /opt/azure-agent
          cd /opt/azure-agent
          \(azureAgentDownloadScript(version: version, platform: platform, file: "agent.tar.gz").replacingOccurrences(of: "\n", with: "\n  "))
          tar xzf agent.tar.gz
          rm agent.tar.gz
          ./bin/installdependencies.sh
        fi
        echo "linux azure pipelines agent v\(version) installed"
        """
    }

    /// How a runtime copies the installed agent into a per-runner directory:
    /// an agent keeps its registration in its own directory, so every runner
    /// needs its own copy.
    enum AgentCopy {
        /// APFS clone (`cp -c`): instant and free on macOS.
        case apfsClone
        /// Plain archive copy (Linux).
        case archive
        /// Guest-adaptive (tart VMs can be macOS or Linux guests): try the
        /// APFS clone and fall back to a plain copy when the guest rejects
        /// it. The fallback wipes the target first — a failed `cp` may have
        /// left a partial directory behind.
        case vmGuest

        /// The shell that copies `template` to `dir` (both shell words).
        func copyLine(template: String, dir: String) -> String {
            switch self {
            case .apfsClone:
                return "cp -cR \(template) \(dir)"
            case .archive:
                return "cp -a \(template) \(dir)"
            case .vmGuest:
                return """
                    if ! cp -cR \(template) \(dir) 2>/dev/null; then
                      rm -rf \(dir)
                      cp -a \(template) \(dir)
                    fi
                    """
            }
        }
    }

    /// Starts one single-job Azure Pipelines agent per runner name. Each runner
    /// copies the installed agent (`template`) into `baseDir/<name>`, writes
    /// the PAT to a private file, and in the background reads and deletes that
    /// file, registers (`config.sh --unattended`, the token handed over in
    /// `VSTS_AGENT_INPUT_TOKEN` for that one command only, never a command
    /// line), runs one job (`run.sh --once`), and removes
    /// itself from the pool: the "deregistered" signal the engine's ephemeral
    /// watch waits for. `capabilities` (`name=value`) are exported so the agent
    /// advertises them; `extraEnvironment` is for the runtime (e.g. allowing
    /// root in containers).
    ///
    /// Residual exposure (not changed, cannot be verified without a real
    /// agent): the PAT stays in the agent shell's *unexported* variable `tok`
    /// until the final `config.sh remove`, because the engine's ephemeral watch
    /// treats the agent leaving the pool as "job finished", so removal has to
    /// stay in the guest. `tok` is in no environment and no argv; the file is
    /// deleted before the agent starts.
    ///
    /// `template` and `baseDir` are shell words (already quoted, or `$HOME/…`).
    static func azureRegistrationScript(
        organization: String, token: String, pool: String, runnerNames: [String], capabilities: [String],
        template: String, baseDir: String, copy: AgentCopy, extraEnvironment: [String] = []
    ) -> String {
        // Passed to the agent shell as positional arguments (after the three
        // fixed ones) and exported there with `export "$kv"`: the single-quoted
        // `bash -c` body can't carry shellQuote'd values, whose quotes would
        // end the outer string and leave the value unquoted.
        let environment = (extraEnvironment + capabilities).map(shellQuote).joined(separator: " ")
        var blocks = ""
        for (index, runner) in runnerNames.enumerated() {
            let dir = "\(baseDir)/\(shellQuote(runner))"
            blocks += """
                # Azure Pipelines agent \(index + 1) of \(runnerNames.count)
                mkdir -p \(baseDir)
                rm -rf \(dir)
                \(copy.copyLine(template: template, dir: dir))
                cd \(dir)
                (umask 077 && printf '%s' \(shellQuote(token)) > .pat)
                nohup /bin/bash -c '
                  for kv in "${@:4}"; do export "$kv"; done
                  tok="$(cat .pat)"
                  rm -f .pat
                  VSTS_AGENT_INPUT_TOKEN="$tok" ./config.sh --unattended --url "$1" --auth pat --pool "$2" --agent "$3" \\
                    --replace --acceptTeeEula --work "$PWD/_work" || exit 1
                  ./run.sh --once || true
                  VSTS_AGENT_INPUT_TOKEN="$tok" ./config.sh remove --unattended --auth pat
                ' azure-agent \(shellQuote(organization)) \(shellQuote(pool)) \(shellQuote(runner)) \(environment) \\
                  > agent.log 2>&1 < /dev/null &
                echo $! > agent.pid

                """
        }
        return """
            set -euo pipefail

            \(blocks)echo "\(runnerNames.count) azure pipelines agent(s) started"
            """
    }
}
