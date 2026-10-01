import Foundation

/// Scripts injected into VMs over SSH to turn them into GitHub/GitLab/Gitea/BitBucket/Azure, Actions runners.
enum RunnerBootstrap {
    /// POSIX single-quote escaping for values interpolated into the scripts
    /// below (config-supplied URLs, names and labels, and the token). A value
    /// with a quote, space or `$(…)` stays one literal argument.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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

        var registrations = ""
        for index in 1...runnerCount {
            let runnerName = "\(name)-r\(index)"
            let dir = "~/actions-runner-\(index)"
            registrations += """
                # Runner \(index) of \(runnerCount).
                cd \(dir)
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

                nohup ./run.sh > run-\(index).log 2>&1 &

                """
        }
        return """
            set -euo pipefail

            # One runner agent directory per process (config.sh refuses shared dirs).
            \(registrations)echo "\(runnerCount) runners started"
            """
    }

    /// Installs the GitHub Actions runner agent into a base image (used by
    /// `kinhin image prepare`). `runnerCount` pre-creates one agent directory
    /// per concurrent runner so first boot doesn't download N times.
    static func installScript(runnerVersion: String, runnerCount: Int = 1) -> String {
        var dirs = "if [ ! -d \"$HOME/actions-runner\" ]; then"
        for index in 1...max(1, runnerCount) {
            let dir = index == 1 ? "actions-runner" : "actions-runner-\(index)"
            dirs += """

                  mkdir -p "$HOME/\(dir)"
                  cd "$HOME/\(dir)"
                  \(githubRunnerDownloadScript(version: runnerVersion, platform: "osx-arm64", file: "runner.tar.gz").replacingOccurrences(of: "\n", with: "\n      "))
                  tar xzf runner.tar.gz
                  rm runner.tar.gz
                """
        }
        dirs += """

                echo "runner agent v\(runnerVersion) installed"
              else
                echo "runner agent already installed"
              fi
            """

        return """
            set -euo pipefail

            RUNNER_VERSION=\(runnerVersion)

            \(dirs)

            # Runners need full disk access for some workloads; document, don't force.
            # Ensure autologin-friendly settings for the admin user.
            sudo -n true 2>/dev/null || echo "note: sudo may prompt for password once"
            """
    }

    /// Installs the Gitea runner binary (gitea-runner, formerly act_runner)
    /// into the base image so any VM can serve Gitea Actions. Kept separate
    /// from the GitHub agent install; both run during `kinhin image prepare`.
    static func giteaRunnerInstallScript(version: String) -> String {
        """
        set -euo pipefail

        # Gitea runner (host-mode jobs; no Docker needed on macOS).
        if [ ! -x "$HOME/gitea-runner/gitea-runner" ]; then
          mkdir -p "$HOME/gitea-runner"
          cd "$HOME/gitea-runner"
          \(giteaRunnerDownloadScript(version: version, platform: "darwin-arm64", file: "runner.xz").replacingOccurrences(of: "\n", with: "\n  "))
          xz -d runner.xz
          chmod +x runner
          mv runner gitea-runner
          ./gitea-runner --version
          echo "gitea runner v\(version) installed"
        else
          echo "gitea runner already installed"
        fi
        """
    }

    /// Registers and starts N Gitea runner processes in a VM via
    /// `act_runner register --no-interactive` + `daemon`. Gitea has no
    /// --ephemeral, so the registration writes .runner once and the daemon
    /// runs until the lifecycle watch tears the VM down after the job.
    static func giteaRegistrationScript(
        instance: String, token: String, labels: [String], name: String, runnerCount: Int = 1
    ) -> String {
        let labelList = labels.joined(separator: ",")
        var blocks = ""
        for index in 1...max(1, runnerCount) {
            let runnerName = runnerCount == 1 ? name : "\(name)-r\(index)"
            let dir = runnerCount == 1 ? "$HOME/gitea-runner" : "$HOME/gitea-runner-\(index)"
            blocks += """
                # Gitea runner \(index) of \(runnerCount)
                mkdir -p \(dir)
                cd \(dir)
                if [ ! -x gitea-runner ]; then
                  cp "$HOME/gitea-runner/gitea-runner" gitea-runner
                fi
                rm -f .runner
                ./gitea-runner register --no-interactive \
                  --instance \(shellQuote(instance)) \
                  --token \(shellQuote(token)) \
                  --name \(shellQuote(runnerName)) \
                  --labels \(shellQuote(labelList)) >/dev/null
                nohup ./gitea-runner daemon > daemon-\(index).log 2>&1 &

                """
        }
        return """
            set -euo pipefail

            \(blocks)echo "\(max(1, runnerCount)) gitea runner(s) started"
            """
    }
}
