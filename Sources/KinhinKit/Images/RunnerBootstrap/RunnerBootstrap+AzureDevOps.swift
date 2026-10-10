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
          ./bin/Agent.Listener --version
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

    /// Starts one Azure Pipelines agent per runner name. Each runner copies
    /// the installed agent (`template`) into `baseDir/<name>` and registers it
    /// in the foreground (`config.sh --unattended`, the PAT handed over in
    /// `VSTS_AGENT_INPUT_TOKEN` for that one command only, never a command
    /// line), so a registration failure fails this script: it exits non-zero
    /// with the tail of `agent.log` on stderr instead of vanishing into a
    /// background shell. The registered agent then runs in the background
    /// (`run.sh --once` when `ephemeral`, plain `run.sh` otherwise) and removes
    /// itself from the pool afterwards: the "deregistered" signal the engine's
    /// ephemeral watch waits for. `capabilities` (`name=value`, names already
    /// valid environment variable names) and `extraEnvironment` (for the
    /// runtime, e.g. allowing root in containers) are exported before
    /// registration so the agent advertises them.
    ///
    /// Residual exposure (not changed, cannot be verified without a real
    /// agent): the background shell keeps the PAT in its *unexported*
    /// variable `tok` until the final `config.sh remove`, because the engine's
    /// ephemeral watch treats the agent leaving the pool as "job finished", so
    /// removal has to stay in the guest. The PAT reaches that shell through a
    /// pipe (a shell builtin writes it, so it is on no command line), `tok` is
    /// in no environment, and no file holds it.
    ///
    /// `template` and `baseDir` are shell words (already quoted, or `$HOME/…`).
    static func azureRegistrationScript(
        organization: String, token: String, pool: String, runnerNames: [String], capabilities: [String],
        template: String, baseDir: String, copy: AgentCopy, ephemeral: Bool = true, extraEnvironment: [String] = []
    ) -> String {
        let exports = (extraEnvironment + capabilities).map { "export \(shellQuote($0))" }.joined(separator: "\n")
        let run = ephemeral ? "./run.sh --once < /dev/null || true" : "./run.sh < /dev/null || true"
        var blocks = ""
        for (index, runner) in runnerNames.enumerated() {
            let dir = "\(baseDir)/\(shellQuote(runner))"
            blocks += """
                # Azure Pipelines agent \(index + 1) of \(runnerNames.count)
                mkdir -p \(baseDir)
                rm -rf \(dir)
                \(copy.copyLine(template: template, dir: dir))
                cd \(dir)
                tok=\(shellQuote(token))
                rc=0
                VSTS_AGENT_INPUT_TOKEN="$tok" ./config.sh --unattended --url \(shellQuote(organization)) --auth pat \\
                  --pool \(shellQuote(pool)) --agent \(shellQuote(runner)) --replace --acceptTeeEula \\
                  --work "$PWD/_work" > agent.log 2>&1 < /dev/null || rc=$?
                if [ "$rc" -ne 0 ]; then
                  echo "error: azure pipelines agent \(shellQuote(runner)) failed to register (config.sh exit $rc):" >&2
                  tail -n 40 agent.log >&2
                  exit 1
                fi
                printf '%s\\n' "$tok" | nohup /bin/bash -c '
                  IFS= read -r tok
                  \(run)
                  VSTS_AGENT_INPUT_TOKEN="$tok" ./config.sh remove --unattended --auth pat
                ' azure-agent >> agent.log 2>&1 &
                echo $! > agent.pid
                unset tok

                """
        }
        return """
            set -euo pipefail
            \(exports)

            \(blocks)echo "\(runnerNames.count) azure pipelines agent(s) started"
            """
    }
}
