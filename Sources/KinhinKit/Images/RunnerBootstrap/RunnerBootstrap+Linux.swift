import Foundation

/// Scripts injected into Linux VMs and containers over SSH to turn them into
/// GitHub, Gitea, GitLab, Buildkite, Azure DevOps and Bitbucket runners.
extension RunnerBootstrap {
    // MARK: - Linux (Apple container runtime)

    /// Installs, via apt, whichever of the given tools the base image lacks.
    /// Minimal images (ubuntu:24.04) ship neither curl nor CA certificates,
    /// and every download step below needs them. `tools` pairs a command
    /// to look for with the package that provides it. Idempotent: a no-op
    /// once everything is present (containers run as root — no sudo).
    ///
    /// The append must stay a *single* assignment word: `need="$need pkg"`.
    /// Written as two words (`need=""$need "pkg"`) bash reads the first as an
    /// assignment prefix and runs `pkg` itself — so a bare base image dies with
    /// `curl: command not found` (127) instead of installing curl.
    static func linuxPrerequisitesScript(tools: [(command: String, package: String)]) -> String {
        let checks = tools.map { t in
            "command -v \(t.command) >/dev/null 2>&1 || need=\"$need \(t.package)\""
        }
        return
            ([
                "# prerequisites (minimal base images lack them)",
                "need=\"\"",
            ] + checks + [
                "[ -e /etc/ssl/certs/ca-certificates.crt ] || need=\"$need ca-certificates\"",
                "if [ -n \"$need\" ]; then",
                "  export DEBIAN_FRONTEND=noninteractive",
                "  apt-get update -qq",
                "  apt-get install -y --no-install-recommends $need",
                "fi",
            ]).joined(separator: "\n")
    }

    // MARK: - Linux runner agent installers (baked into images)

    /// Installs the GitHub Actions runner agent into a Linux image for the
    /// Apple-container runtime (baked during `kinhin image prepare` when a
    /// GitHub credential exists). Mirrors installScript but for Linux tarballs.
    static func linuxGitHubAgentInstallScript(version: String, arch: String = "arm64", caBundlePath: String? = nil)
        -> String
    {
        let caExport: String
        if let caBundlePath = caBundlePath {
            caExport = """
                if [ -f \(shellQuote(caBundlePath)) ]; then
                  cp \(shellQuote(caBundlePath)) /etc/ssl/certs/kinhin-ca.pem 2>/dev/null || true
                  export NODE_EXTRA_CA_CERTS=/etc/ssl/certs/kinhin-ca.pem
                  export GIT_SSL_CAINFO=/etc/ssl/certs/kinhin-ca.pem
                  export SSL_CERT_FILE=/etc/ssl/certs/kinhin-ca.pem
                fi

                """
        } else {
            caExport = ""
        }
        // The density copies run in the *guest's* bash, so `{2..10}` and
        // `$index` must reach it verbatim. Swift's spelling (`2...10`,
        // `\(index)`) bakes a single `/opt/actions-runner-(Function)`
        // directory instead: `index` resolves to Darwin's C function.
        return """
            set -euo pipefail
            \(linuxPrerequisitesScript(tools: [("curl", "curl"), ("tar", "tar"), ("gzip", "gzip")]))
            mkdir -p /opt/actions-runner
            cd /opt/actions-runner
            if [ ! -x config.sh ]; then
              if [ ! -x ./config.sh ]; then
                \(githubRunnerDownloadScript(version: version, platform: "linux-\(arch)", file: "runner.tar.gz").replacingOccurrences(of: "\n", with: "\n  "))
                tar xzf runner.tar.gz
                rm runner.tar.gz
                ./bin/installdependencies.sh || echo "warning: installdependencies.sh reported issues"
              fi
            fi
            \(caExport)cd /opt/actions-runner
            for index in {2..10}; do
              mkdir -p "/opt/actions-runner-$index"
              cp -a /opt/actions-runner/. "/opt/actions-runner-$index/"
            done
            echo "linux actions-runner v\(version) installed"
            """
    }

    /// Installs the Gitea runner into a Linux image for the Apple-container
    /// runtime (baked during `kinhin image prepare` when a Gitea credential
    /// exists). Mirrors installScript but for Linux xz-compressed runners.
    static func linuxGiteaRunnerInstallScript(version: String, arch: String = "arm64") -> String {
        """
        set -euo pipefail
        \(linuxPrerequisitesScript(tools: [("curl", "curl"), ("xz", "xz-utils")]))
        if [ ! -x /opt/gitea-runner/gitea-runner ]; then
          mkdir -p /opt/gitea-runner
          cd /opt/gitea-runner
          \(giteaRunnerDownloadScript(version: version, platform: "linux-\(arch)", file: "runner.xz").replacingOccurrences(of: "\n", with: "\n  "))
          xz -d --no-sparse runner.xz
          chmod +x runner
          mv runner gitea-runner
          ./gitea-runner --version
        fi
        echo "linux gitea-runner v\(version) installed"
        """
    }

    // MARK: - Linux container registration scripts

    /// GitHub registration inside a Linux container. The agent directory is
    /// baked at /opt/actions-runner; registration runs as root (the default
    /// container user), so config.sh needs --runasservice=false semantics —
    /// plain unattended registration + foreground nohup run.sh, same shape
    /// as the VM script.
    static func linuxGitHubRegistrationScript(
        configureURL: String,
        token: String,
        labels: [String],
        ephemeral: Bool,
        name: String,
        runnerCount: Int = 1
    ) -> String {
        let labelList = labels.joined(separator: ",")
        let ephemeralFlag = ephemeral ? "--ephemeral " : ""
        var blocks = ""
        for index in 1...max(1, runnerCount) {
            let runnerName = runnerCount == 1 ? name : "\(name)-r\(index)"
            let dir = runnerCount == 1 ? "/opt/actions-runner" : "/opt/actions-runner-\(index)"
            blocks += """
                # GitHub runner \(index) of \(max(1, runnerCount))
                mkdir -p "\(dir)"
                cd "\(dir)"
                if [ ! -x ./config.sh ]; then
                  cp -a /opt/actions-runner/. "\(dir)" 2>/dev/null || true
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
                            \(ephemeralFlag)--work /opt/work-\(index) >/dev/null
                nohup ./run.sh > run-\(index).log 2>&1 < /dev/null &

                """
        }
        return """

            set -euo pipefail
            # Containers run as root, which the runner refuses unless allowed.
            export RUNNER_ALLOW_RUNASROOT=1
            # An agent left from an earlier registration (this container is being registered again) would hold
            # the runner's session and make the new one fail to connect.
            pkill -f '/bin/Runner.Listener' 2>/dev/null && sleep 1 || true

            \(blocks)
            """
    }

    /// Gitea/Forgejo registration inside a guest (a Linux container, or a Tart VM of either OS). Forgejo shares the
    /// Gitea runner binary. `agentDirectory` is where the bake put `gitea-runner` ("/opt/gitea-runner" in a
    /// container, "$HOME/gitea-runner" in a VM); it is expanded by the guest's shell. Each runner gets its own
    /// `run-N` directory beside the binary, because `register` writes `.runner` into the working directory and the
    /// daemon reads it from there. The `gitea-runner` CLI has `register` and `daemon` only (no `run`, no `remove`).
    static func linuxGiteaRegistrationScript(
        instance: String,
        token: String,
        labels: [String],
        name: String,
        runnerCount: Int = 1,
        agentDirectory: String = "/opt/gitea-runner"
    ) -> String {
        let labelList = labels.joined(separator: ",")
        let count = max(1, runnerCount)
        var blocks = ""
        for index in 1...count {
            let runnerName = count == 1 ? name : "\(name)-r\(index)"
            blocks += """
                # Gitea/Forgejo runner \(index) of \(count)
                mkdir -p "\(agentDirectory)/run-\(index)"
                cd "\(agentDirectory)/run-\(index)"
                rm -f .runner
                "\(agentDirectory)/gitea-runner" register --no-interactive \\
                    --instance \(shellQuote(instance)) \\
                    --token \(shellQuote(token)) \\
                    --labels \(shellQuote(labelList)) \\
                    --name \(shellQuote(runnerName)) >/dev/null
                nohup "\(agentDirectory)/gitea-runner" daemon > daemon.log 2>&1 < /dev/null &

                """
        }
        return """
            set -euo pipefail
            # A daemon left from an earlier registration would keep running beside the new one.
            pkill -f 'gitea-runner daemon' 2>/dev/null && sleep 1 || true

            \(blocks)
            """
    }

    // MARK: - Linux JIT registration (GitHub Actions scale-set tokens)

    /// JIT-config registration inside a Linux container (GitHub Actions
    /// scale-set tokens). Same shape as the VM script but rooted at
    /// /opt/actions-runner.
    static func linuxJitRegistrationScript(
        encodedJitConfig: String,
        name: String,
        workFolder: String = "/opt/work",
        agentDirectory: String = "/opt/actions-runner",
        pidFile: String? = nil
    ) -> String {
        let pidSetup =
            pidFile.map {
                "mkdir -p \(shellQuote(URL(fileURLWithPath: $0).deletingLastPathComponent().path)); echo $! > \(shellQuote($0))"
            } ?? ""
        return """
            set -euo pipefail
            # Containers run as root, which the runner refuses ("Must not run interactively
            # with sudo") unless allowed.
            export RUNNER_ALLOW_RUNASROOT=1
            mkdir -p \(shellQuote(agentDirectory))
            cd \(shellQuote(agentDirectory))
            if [ ! -x ./config.sh ]; then
              cp -a /opt/actions-runner/. . 2>/dev/null || true
            fi
            # JIT runners are already registered by the scale-set API; config.sh does not
            # take --jitconfig, run.sh does (the work folder was fixed at generate time).
            nohup ./run.sh --jitconfig \(shellQuote(encodedJitConfig)) > run.log 2>&1 &
            runner_pid=$!
            \(pidSetup)
            # A runner that dies at once (bad config, job already cancelled) must fail
            # registration with its own output, not look started.
            sleep 2
            if ! kill -0 "$runner_pid" 2>/dev/null; then
              echo "runner exited immediately:"
              tail -n 20 run.log
              exit 1
            fi
            echo "runner started"
            """
    }
}
