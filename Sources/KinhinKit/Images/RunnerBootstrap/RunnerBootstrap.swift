import Foundation

/// Scripts injected into VMs over SSH to turn them into GitHub, Gitea, GitLab, Buildkite, Azure DevOps and Bitbucket runners.
enum RunnerBootstrap {
    /// The tools every baked image needs that no agent download installs:
    /// `actions/checkout` and `git ls-files` run git, workflow scripts pipe
    /// through jq. Both Linux bake paths install them before any agent —
    /// `LinuxImageBaker` for the containers (plain apt, root) and the tart
    /// Linux guest in `ImagePreparer` (passwordless sudo, admin user) — so
    /// parity between the two lives in this one list.
    static let ciPrerequisiteTools: [(command: String, package: String)] = [("git", "git"), ("jq", "jq")]

    /// POSIX single-quote escaping for values interpolated into the scripts
    /// below (config-supplied URLs, names and labels, and the token). A value
    /// with a quote, space or `$(…)` stays one literal argument.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Register and start one runner using an already-generated scale-set JIT config.
    /// The config is secret material and is shell-quoted so it never becomes executable syntax.
    ///
    /// `agentDirectory` is the per-runner agent directory the script `cd`s into before
    /// running `config.sh --jitconfig`. For GitHub Actions Tart VMs it should match the
    /// layout `kinhin image prepare` bakes onto the base image: `~/actions-runner` for the
    /// first runner and `~/actions-runner-2..N` for the rest (the classic script and the
    /// image-bake step agree on this layout).
    ///
    /// `agentTemplate`, when non-nil, is the directory kinhin bakes as the runner template
    /// (usually `~/actions-runner`). If the target `agentDirectory` does not already contain
    /// a `config.sh`, the script copies the template into it. When the template copy fails
    /// (for example because the scale-set base image did not pre-bake `~/actions-runner`)
    /// *and* a `runnerVersion` is supplied, the script falls back to downloading the runner
    /// into `agentDirectory` instead of aborting — only the subsequent `config.sh --jitconfig`
    /// can still fail. When no `runnerVersion` is supplied and the template is missing, the
    /// script still aborts later at `config.sh`, which is the existing behavior.
    static func jitRegistrationScript(
        encodedJitConfig: String,
        name: String,
        workFolder: String = "_work",
        agentDirectory: String = "~/actions-runner",
        agentTemplate: String? = nil,
        pidFile: String? = nil,
        caBundlePath: String? = nil,
        runnerVersion: String? = nil
    ) -> String {
        let agentDirectoryCommand =
            agentDirectory.hasPrefix("~/")
            ? "agent_dir=\"$HOME\"/\(shellQuote(String(agentDirectory.dropFirst(2))))"
            : "agent_dir=\(shellQuote(agentDirectory))"
        let agentMaterialization: String
        if let template = agentTemplate {
            let fallbackBlock: String
            if let version = runnerVersion {
                // Apple-silicon guest: `osx-arm64` is the asset GitHub
                // publishes (a bare `osx` URL 404s, and its digest marker
                // would never match).
                let download = githubRunnerDownloadScript(
                    version: version, platform: "osx-arm64", file: "runner.tar.gz")
                fallbackBlock = """
                        # The template copy can fail on scale-set base images that did not
                        # pre-bake ~/actions-runner. When a runner version is available, download
                        # the runner into the target dir instead of aborting — only the later
                        # config.sh --jitconfig can still fail.
                        mkdir -p "$agent_dir"
                        cd "$agent_dir"
                        \(download)
                        tar xzf runner.tar.gz
                        rm -f runner.tar.gz
                        cd - >/dev/null
                    """
            } else {
                fallbackBlock = ""
            }
            agentMaterialization = """
                if [ ! -x "$agent_dir/config.sh" ]; then
                  mkdir -p "$agent_dir"
                  cp -a \(shellQuote(template) + "/.") "$agent_dir/" 2>/dev/null || {
                    \(fallbackBlock)
                  }
                fi

                """
        } else {
            agentMaterialization = ""
        }
        let pidSetup =
            pidFile.map {
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
            # JIT runners are already registered by the scale-set API; config.sh does not
            # take --jitconfig, run.sh does (the work folder was fixed at generate time).
            nohup ./run.sh --jitconfig \(shellQuote(encodedJitConfig)) > run.log 2>&1 &
            \(pidSetup)
            echo "runner started"
            """
    }

    /// Installer for the GitHub Actions runner on macOS (called by
    /// `kinhin image prepare` when a GitHub credential exists). The bake runs
    /// one SSH session that starts in `$HOME`, so the download cd's into the
    /// agent directory registration later uses — extracted at `$HOME` the
    /// runner lands *beside* `~/actions-runner`, not in it.
    static func installScript(runnerVersion: String, runnerCount: Int = 1) -> String {
        """
        set -euo pipefail
        # Download and install the GitHub Actions runner
        if [ ! -x "$HOME/actions-runner/config.sh" ]; then
          mkdir -p "$HOME/actions-runner"
          cd "$HOME/actions-runner"
          \(githubRunnerDownloadScript(version: runnerVersion, platform: "osx-arm64", file: "runner.tar.gz").replacingOccurrences(of: "\n", with: "\n  "))
          tar xzf runner.tar.gz
          rm runner.tar.gz
          ./bin/installdependencies.sh
        fi
        """
    }

    /// Installer for the Gitea runner on macOS (called by
    /// `kinhin image prepare` when a Gitea credential exists). Same contract
    /// as `installScript`: into the directory `giteaRegistrationScript` cd's.
    static func giteaRunnerInstallScript(version: String) -> String {
        """
        set -euo pipefail
        if [ ! -x "$HOME/gitea-runner/gitea-runner" ]; then
          mkdir -p "$HOME/gitea-runner"
          cd "$HOME/gitea-runner"
          \(giteaRunnerDownloadScript(version: version, platform: "darwin-arm64", file: "runner.xz").replacingOccurrences(of: "\n", with: "\n  "))
          xz -d runner.xz
          tar xf runner.tar
          rm -f runner.tar
          ./bin/installdependencies.sh || echo "warning: installdependencies.sh reported issues"
        fi
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
            // Runner 1 registers in the baked template; runners 2..N in their
            // own copies — the layout the JIT script and the Linux scripts use.
            // `~/actions-runner-1` is never created anywhere, so indexing
            // straight into a numbered directory fails at the very first `cd`.
            let dir = index == 1 ? "~/actions-runner" : "~/actions-runner-\(index)"
            // Materialize *before* the cd: the numbered copies only come into
            // existence by being copied out of the template, so `cd` first
            // aborts the whole script (`cd: …-2: No such file or directory`).
            let materialize =
                index == 1
                ? "mkdir -p ~/actions-runner"
                : """
                if [ ! -x \(dir)/config.sh ]; then
                  mkdir -p \(dir)
                  cp -a ~/actions-runner/. \(dir)/ 2>/dev/null || true
                fi
                """
            registrations += """
                # Runner \(index) of \(runnerCount).
                \(materialize)
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
