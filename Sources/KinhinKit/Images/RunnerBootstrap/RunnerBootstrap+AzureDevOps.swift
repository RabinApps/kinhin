import Foundation

// MARK: - Azure Pipelines agent

extension RunnerBootstrap {
    /// How a runtime copies the installed agent into a per-runner directory:
    /// an agent keeps its registration in its own directory, so every runner
    /// needs its own copy.
    enum AgentCopy {
        /// APFS clone (`cp -c`): instant and free on macOS.
        case apfsClone
        /// Plain archive copy (Linux).
        case archive

        var command: String {
            switch self {
            case .apfsClone: return "cp -cR"
            case .archive: return "cp -a"
            }
        }
    }

    /// Starts one single-job Azure Pipelines agent per runner name. Each runner
    /// copies the installed agent (`template`) into `baseDir/<name>`, writes
    /// the PAT to a private file, and in the background registers
    /// (`config.sh --unattended`, the token read from `VSTS_AGENT_INPUT_TOKEN`,
    /// never a command line), runs one job (`run.sh --once`), and removes
    /// itself from the pool: the "deregistered" signal the engine's ephemeral
    /// watch waits for. `capabilities` (`name=value`) are exported so the agent
    /// advertises them; `extraEnvironment` is for the runtime (e.g. allowing
    /// root in containers).
    ///
    /// `template` and `baseDir` are shell words (already quoted, or `$HOME/…`).
    static func azureRegistrationScript(
        organization: String, token: String, pool: String, runnerNames: [String], capabilities: [String],
        template: String, baseDir: String, copy: AgentCopy, extraEnvironment: [String] = []
    ) -> String {
        let exports = (extraEnvironment + capabilities).map { "export \(shellQuote($0))" }.joined(separator: "\n  ")
        var blocks = ""
        for (index, runner) in runnerNames.enumerated() {
            let dir = "\(baseDir)/\(shellQuote(runner))"
            blocks += """
                # Azure Pipelines agent \(index + 1) of \(runnerNames.count)
                mkdir -p \(baseDir)
                rm -rf \(dir)
                \(copy.command) \(template) \(dir)
                cd \(dir)
                (umask 077 && printf '%s' \(shellQuote(token)) > .pat)
                nohup /bin/bash -c '
                  \(exports.isEmpty ? ":" : exports)
                  VSTS_AGENT_INPUT_TOKEN="$(cat .pat)"
                  export VSTS_AGENT_INPUT_TOKEN
                  ./config.sh --unattended --url "$1" --auth pat --pool "$2" --agent "$3" \\
                    --replace --acceptTeeEula --work "$PWD/_work" || exit 1
                  ./run.sh --once || true
                  ./config.sh remove --unattended --auth pat
                ' azure-agent \(shellQuote(organization)) \(shellQuote(pool)) \(shellQuote(runner)) \\
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
