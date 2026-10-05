import Foundation

/// Scripts injected into VMs over SSH to turn them into GitHub, Gitea, GitLab, Buildkite, Azure DevOps and Bitbucket runners.
enum RunnerBootstrap {
    /// POSIX single-quote escaping for values interpolated into the scripts
    /// below (config-supplied URLs, names and labels, and the token). A value
    /// with a quote, space or `$(…)` stays one literal argument.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Register and start one runner using an already-generated scale-set JIT config.
    /// The config is secret material and is shell-quoted so it never becomes executable syntax.
    static func jitRegistrationScript(
        encodedJitConfig: String,
        name: String,
        workFolder: String = "_work",
        agentDirectory: String = "~/actions-runner",
        agentTemplate: String? = nil,
        pidFile: String? = nil,
        caBundlePath: String? = nil
    ) -> String {
        let agentDirectoryCommand = agentDirectory.hasPrefix("~/")
            ? "agent_dir=\"$HOME\"/\(shellQuote(String(agentDirectory.dropFirst(2))))"
            : "agent_dir=\(shellQuote(agentDirectory))"
        let agentMaterialization: String
        if let template = agentTemplate {
            agentMaterialization = """
                if [ ! -x "$agent_dir/config.sh" ]; then
                  mkdir -p "$agent_dir"
                  cp -a \(shellQuote(template) + "/.") "$agent_dir/" 2>/dev/null || true
                fi

                """
        } else {
            agentMaterialization = ""
        }
        let pidSetup = pidFile.map {
            "mkdir -p \(shellQuote(URL(fileURLWithPath: $0).deletingLastPathComponent().path)); echo $! > \(shellQuote($0))"
        } ?? ""
        let caEnvExports: String
        if let caBundlePath = caBundlePath {
            caEnvExports = """
                if [ -f \(shellQuote(caBundlePath)) ]; then
                  cp \(shellQuote(caBundlePath)) /etc/ssl/certs/kinhin-ca.pem 2>/dev/null || true
                  export NODE_EXTRA_CA_CERTS=/etc/ssl/certs/kinhin-ca.pem
                  export GIT_SSL_CAINFO=/etc/ssl/certs/kinhin-ca.pem
                  export SSL_CERT_FILE=/etc/ssl/certs/kinhin-ca.pem
                fi

                """
        } else {
            caEnvExports = ""
        }
        return """
            set -euo pipefail
            \(agentDirectoryCommand)
            \(agentMaterialization)
            \(caEnvExports)cd "$agent_dir"
            ./config.sh --jitconfig \(shellQuote(encodedJitConfig)) \\
                        --unattended \\
                        --replace \\
                        --work \(shellQuote(workFolder)) >/dev/null
            nohup ./run.sh > run.log 2>&1 &
            \(pidSetup)
            echo "runner started"
            """
    }

    /// Installer for the GitHub Actions runner on macOS (called by
    /// `kinhin image prepare` when a GitHub credential exists).
    static func installScript(runnerVersion: String, runnerCount: Int = 1) -> String {
        """
        set -euo pipefail
        # Download and install the GitHub Actions runner
        \(githubRunnerDownloadScript(version: runnerVersion, platform: "osx", file: "runner.tar.gz"))
        tar xzf runner.tar.gz
        rm runner.tar.gz
        ./bin/installdependencies.sh
        """
    }

    /// Installer for the Gitea runner on macOS (called by
    /// `kinhin image prepare` when a Gitea credential exists).
    static func giteaRunnerInstallScript(version: String) -> String {
        """
        set -euo pipefail
        \(giteaRunnerDownloadScript(version: version, platform: "osx", file: "runner.tar.gz"))
        tar xzf runner.tar.gz
        rm runner.tar.gz
        """
    }

    /// Register and start `runnerCount` runner processes in the VM. GitHub's
    /// model is one job per runner process, so density (many-to-one) comes
    /// from registering several runners, each with its own agent directory
    /// and work directory. `runnerCount = 1` produces exactly the classic
    /// single-runner script. `run.sh` runs in the foreground; because the
    /// SSH session must return, each runner is launched detached with nohup.
    static func registrationScript(
        configureURL: String,
        token: String,
        labels: [String],
        ephemeral: Bool,
        name: String,
        runnerCount: Int = 1
    ) -> String {
        let labelList = labels.joined(separator: ",")
        let ephemeralFlag = ephemeral ? "--ephemeral " : ""

        guard runnerCount > 1 else {
            return """
                set -euo pipefail
                cd ~/actions-runner

                # Register (idempotent: remove stale config first).
                if [ -f .runner ]; then
                  ./config.sh remove --token \(shellQuote(token)) >/dev/null 2>&1 || true
                fi
                ./config.sh --url \(shellQuote(configureURL)) \\
                            --token \(shellQuote(token)) \\
                            --labels \(shellQuote(labelList)) \\
                            --name \(shellQuote(name)) \\
                            --unattended \\
                            --replace \\
                            \(ephemeralFlag)--work _work >/dev/null

                # Start serving jobs, detached from this SSH session.
                nohup ./run.sh > run.log 2>&1 &
                echo "runner started"
                """
        }

        // Every runner is registered before any is started: a started runner is
        // already executing job code as this user, and `config.sh --token` puts
        // the registration token in the argv `ps` shows. Registering first keeps
        // that token away from job processes.
        var registrations = ""
        var starts = ""
        for index in 1...runnerCount {
            let runnerName = "\(name)-r\(index)"
            let dir = "~/actions-runner-\(index)"
            registrations += """
                # Runner \(index) of \(runnerCount).
                cd \(dir)
                # Materialize the per-runner agent directory from the baked template — `kinhin image prepare` creates `$HOME/actions-runner` plus `$HOME/actions-runner-2..N` only, so `$HOME/actions-runner-N` for N<=1 is missing.

                # no Swift interpolation here: this is literal bash, not a Swift
                # string; the '(' and ')' are from the bash variable $dir.
                if [ ! -x "$dir/config.sh" ]; then
                  mkdir -p "$dir"
                  cp -a ~/actions-runner/. "$dir" 2>/dev/null || true
                fi
                if [ -f .runner ]; then
                  ./config.sh remove --token \(shellQuote(token)) >/dev/null 2>&1 || true
                fi
                ./config.sh --url \(shellQuote(configureURL)) \\
                            --token \(shellQuote(token)) \\
                            --labels \(shellQuote(labelList)) \\
                            --name \(shellQuote(runnerName)) \\
                            --unattended \\
                            --replace \\
                            \(ephemeralFlag)--work _work-\(index) >/dev/null

                """
            starts += """
                cd \(dir)
                nohup ./run.sh > run-\(index).log 2>&1 &

                """
        }
        return """
            set -euo pipefail

            # One runner agent directory per process (config.sh refuses shared dirs).
            \(registrations)# All registered; now start serving jobs.
            \(starts)            echo "\(runnerCount) runners started"
            """
    }

    /// Register and start a Gitea runner in a macOS VM. Mirrors `registrationScript`
    /// but for Gitea's runner binary and registration flow.
    static func giteaRegistrationScript(
        instance: String,
        token: String,
        labels: [String],
        name: String,
        runnerCount: Int = 1
    ) -> String {
        let labelList = labels.joined(separator: ",")
        return """
            set -euo pipefail
            cd ~/gitea-runner

            # Register (idempotent: remove stale config first).
            if [ -f .runner ]; then
              ./gitea-runner remove --token \(shellQuote(token)) >/dev/null 2>&1 || true
            fi
            ./gitea-runner register --instance \(shellQuote(instance)) \\
                                    --token \(shellQuote(token)) \\
                                    --labels \(shellQuote(labelList)) \\
                                    --name \(shellQuote(name)) \\
                                    --ephemeral=\(runnerCount == 1 ? "true" : "false") >/dev/null

            # Start serving jobs, detached from this SSH session.
            nohup ./gitea-runner run > run.log 2>&1 &
            echo "gitea runner started"
            """
    }

}


