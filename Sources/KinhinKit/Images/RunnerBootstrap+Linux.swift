import Foundation

extension RunnerBootstrap {
    // MARK: - Linux (Apple container runtime)

    /// Installs the GitHub Actions runner agent into a Linux image for the
    /// Apple-container runtime (baked during `kinhin image prepare` when a
    /// GitHub credential exists). Mirrors installScript but for Linux tarballs.
    static func linuxGitHubAgentInstallScript(runnerVersion: String) -> String {
        """
        set -euo pipefail
        mkdir -p /opt/actions-runner
        cd /opt/actions-runner
        if [ ! -x ./config.sh ]; then
          curl -sL "https://github.com/actions/runner/releases/download/v\(runnerVersion)/actions-runner-linux-arm64-\(runnerVersion).tar.gz" -o runner.tar.gz
          tar xzf runner.tar.gz
          rm runner.tar.gz
          ./bin/installdependencies.sh || echo "warning: installdependencies.sh reported issues"
        fi
        echo "linux actions-runner v\(runnerVersion) installed"
        """
    }

    /// The managed-toolchains script baked into Linux images by
    /// `kinhin image prepare --container` when a `toolchains:` section is
    /// configured. Mirrors managedToolchainsInstallScript for the ubuntu-based
    /// runner containers: guarded apt installs (running as root — no sudo),
    /// a mise bootstrap (Linux base images don't ship it), `mise use --global`
    /// pins, npm globals, and verify-gated completion. Cache exports point at
    /// the container-side bind mount when present.
    static func linuxManagedToolchainsInstallScript(selection: ManagedToolchainSelection, mountPath: String?)
        -> String
    {
        var lines: [String] = ["set -euo pipefail"]

        if let mountPath {
            lines.append(Self.cacheEnvExports(cacheEnvs: selection.cacheEnvs, mountPath: mountPath))
        }

        if !selection.aptPackages.isEmpty {
            let packages = selection.aptPackages.joined(separator: " ")
            lines.append(
                """
                # apt packages (guarded so re-runs no-op; containers run as root)
                export DEBIAN_FRONTEND=noninteractive
                for p in \(packages); do
                  if ! dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed'; then
                    apt-get update -qq
                    apt-get install -y --no-install-recommends "$p"
                  fi
                done
                """)
        }

        if !selection.miseSpecs.isEmpty {
            lines.append(
                """
                # mise bootstrap (Linux base images don't ship it) + shims on PATH
                if ! command -v mise >/dev/null 2>&1; then
                  curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh
                fi
                export PATH="$HOME/.local/share/mise/shims:$PATH"
                """)
            let specs = selection.miseSpecs.joined(separator: " ")
            lines.append(
                """
                # mise pins — installed AND set globally so every runner shell sees them
                mise use --global \(specs)
                """)
        }

        if !selection.npmPackages.isEmpty {
            lines.append("# npm globals (guarded so re-runs no-op)")
            for package in selection.npmPackages {
                let spec = package.version.isEmpty ? "\(package.name)" : "\(package.name)@\(package.version)"
                lines.append(
                    """
                    if ! npm ls -g --depth=0 \(package.name) >/dev/null 2>&1; then
                      npm install -g \(spec)
                    fi
                    """)
            }
        }

        if !selection.gems.isEmpty {
            let gems = selection.gems.joined(separator: " ")
            lines.append(
                """
                # Ruby gems (system install; guarded so re-runs no-op)
                for g in \(gems); do
                  if ! gem list -i "^$g$" >/dev/null 2>&1; then
                    gem install "$g"
                  fi
                done
                """)
        }

        if !selection.stackSteps.isEmpty {
            lines.append("# Stack steps (version-pinned installs)")
            lines.append(contentsOf: selection.stackSteps)
        }

        if !selection.verifications.isEmpty {
            lines.append("# Audit trail: verify every managed tool (output is logged)")
            lines.append(selection.verifications.joined(separator: " && "))
        }

        return lines.joined(separator: "\n\n")
    }

    /// Installs the Gitea runner binary into a Linux image (gitea-runner,
    /// formerly act_runner — linux-arm64 build).
    static func linuxGiteaRunnerInstallScript(version: String) -> String {
        """
        set -euo pipefail
        if [ ! -x /opt/gitea-runner/gitea-runner ]; then
          mkdir -p /opt/gitea-runner
          cd /opt/gitea-runner
          curl -sL "https://gitea.com/gitea/runner/releases/download/v\(version)/gitea-runner-\(version)-linux-arm64.xz" -o runner.xz
          xz -d runner.xz
          chmod +x runner
          mv runner gitea-runner
          ./gitea-runner --version
        fi
        echo "linux gitea-runner v\(version) installed"
        """
    }

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
                  ./config.sh remove --token '\(token)' >/dev/null 2>&1 || true
                fi
                ./config.sh --url \(configureURL) \\
                            --token '\(token)' \\
                            --labels '\(labelList)' \\
                            --name '\(runnerName)' \\
                            --unattended \\
                            --replace \\
                            \(ephemeralFlag)--work /opt/work-\(index) >/dev/null
                nohup ./run.sh > run-\(index).log 2>&1 &

                """
        }
        return """
            set -euo pipefail

            \(blocks)echo "\(max(1, runnerCount)) linux runner(s) started"
            """
    }

    /// Gitea registration inside a Linux container (gitea-runner register
    /// --no-interactive + daemon; no --ephemeral exists upstream).
    static func linuxGiteaRegistrationScript(
        instance: String, token: String, labels: [String], name: String, runnerCount: Int = 1
    ) -> String {
        let labelList = labels.joined(separator: ",")
        var blocks = ""
        for index in 1...max(1, runnerCount) {
            let runnerName = runnerCount == 1 ? name : "\(name)-r\(index)"
            let dir = runnerCount == 1 ? "/opt/gitea-runner" : "/opt/gitea-runner-\(index)"
            blocks += """
                # Gitea runner \(index) of \(max(1, runnerCount))
                mkdir -p "\(dir)"
                cd "\(dir)"
                if [ ! -x gitea-runner ]; then
                  cp /opt/gitea-runner/gitea-runner gitea-runner
                fi
                rm -f .runner
                ./gitea-runner register --no-interactive \\
                  --instance \(instance) \\
                  --token '\(token)' \\
                  --name '\(runnerName)' \\
                  --labels '\(labelList)' >/dev/null
                nohup ./gitea-runner daemon > daemon-\(index).log 2>&1 &

                """
        }
        return """
            set -euo pipefail

            \(blocks)echo "\(max(1, runnerCount)) linux gitea runner(s) started"
            """
    }
}
