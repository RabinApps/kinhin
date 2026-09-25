import Foundation

/// Scripts injected into VMs over SSH to turn them into GitHub Actions runners.
public enum RunnerBootstrap {
    /// Register and start `runnerCount` runner processes in the VM. GitHub's
    /// model is one job per runner process, so density (many-to-one) comes
    /// from registering several runners, each with its own agent directory
    /// and work directory. `runnerCount = 1` produces exactly the classic
    /// single-runner script. `run.sh` runs in the foreground; because the
    /// SSH session must return, each runner is launched detached with nohup.
    public static func registrationScript(
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
                  ./config.sh remove --token '\(token)' >/dev/null 2>&1 || true
                fi
                ./config.sh --url \(configureURL) \\
                            --token '\(token)' \\
                            --labels '\(labelList)' \\
                            --name '\(name)' \\
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
                  ./config.sh remove --token '\(token)' >/dev/null 2>&1 || true
                fi
                ./config.sh --url \(configureURL) \\
                            --token '\(token)' \\
                            --labels '\(labelList)' \\
                            --name '\(runnerName)' \\
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
    public static func installScript(runnerVersion: String, runnerCount: Int = 1) -> String {
        var dirs = "if [ ! -d \"$HOME/actions-runner\" ]; then"
        for index in 1...max(1, runnerCount) {
            let dir = index == 1 ? "actions-runner" : "actions-runner-\(index)"
            dirs += """

                  mkdir -p "$HOME/\(dir)"
                  cd "$HOME/\(dir)"
                  ARCH="arm64"
                  curl -sL "https://github.com/actions/runner/releases/download/v\(runnerVersion)/actions-runner-osx-arm64-\(runnerVersion).tar.gz" -o runner.tar.gz
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
    public static func giteaRunnerInstallScript(version: String) -> String {
        """
        set -euo pipefail

        # Gitea runner (host-mode jobs; no Docker needed on macOS).
        if [ ! -x "$HOME/gitea-runner/gitea-runner" ]; then
          mkdir -p "$HOME/gitea-runner"
          cd "$HOME/gitea-runner"
          curl -sL "https://gitea.com/gitea/runner/releases/download/v\(version)/gitea-runner-\(version)-darwin-arm64.xz" -o runner.xz
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
    public static func giteaRegistrationScript(
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
                  --instance \(instance) \
                  --token '\(token)' \
                  --name '\(runnerName)' \
                  --labels '\(labelList)' >/dev/null
                nohup ./gitea-runner daemon > daemon-\(index).log 2>&1 &

                """
        }
        return """
            set -euo pipefail

            \(blocks)echo "\(max(1, runnerCount)) gitea runner(s) started"
            """
    }

    // MARK: - Managed toolchains (toolchains: config section)

    /// Shell exports pointing every selected ecosystem's download/package
    /// cache at the host-mounted cache share. Each export is guarded: when
    /// the share is not mounted (or the path is missing) the variable is
    /// left at its default — caching is best-effort and never fails a
    /// prepare or a runner boot.
    public static func cacheEnvExports(cacheEnvs: [ToolchainCacheEnv], mountPath: String) -> String {
        guard !cacheEnvs.isEmpty else { return "" }
        let lines = cacheEnvs.map { env -> String in
            """
            if [ -d \(mountPath) ]; then
              export \(env.variable)="\(mountPath)/\(env.subdirectory)"
              mkdir -p "\(mountPath)/\(env.subdirectory)" 2>/dev/null || true
            fi
            """
        }
        return "# Shared toolchain cache (skipped gracefully when the host share is absent)\n"
            + lines.joined(separator: "\n")
    }

    /// The managed-toolchains script baked by `image prepare` when a
    /// `toolchains:` section is configured: cache exports, brew taps +
    /// formulas (idempotent), mise pins (`mise use --global`), npm globals,
    /// gems, then every verify command — a failing verify aborts the prepare
    /// with the previous image left intact.
    public static func managedToolchainsInstallScript(selection: ManagedToolchainSelection, mountPath: String?)
        -> String
    {
        var lines: [String] = ["set -euo pipefail"]

        if let mountPath {
            lines.append(Self.cacheEnvExports(cacheEnvs: selection.cacheEnvs, mountPath: mountPath))
        }

        if !selection.brewTaps.isEmpty {
            let taps = selection.brewTaps.joined(separator: " ")
            lines.append(
                """
                # Homebrew taps
                for tap in \(taps); do
                  brew tap "$tap" 2>/dev/null || true
                done
                """)
        }

        if !selection.brewFormulas.isEmpty {
            let formulas = selection.brewFormulas.map(\.name).joined(separator: " ")
            lines.append(
                """
                # Homebrew formulas (casks included; guarded so re-runs no-op)
                for f in \(formulas); do
                  if ! brew list --versions "$f" >/dev/null 2>&1; then
                    brew install "$f"
                  fi
                done
                """)
        }

        if !selection.miseSpecs.isEmpty {
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
                    """
                )
            }
            lines.append("# corepack: packageManager-field support (pnpm/yarn per project)")
            lines.append("corepack enable 2>/dev/null || true")
        }

        if !selection.gems.isEmpty {
            let gems = selection.gems.joined(separator: " ")
            lines.append(
                """
                # Ruby gems (user install; guarded so re-runs no-op)
                for g in \(gems); do
                  if ! gem list -i "^$g$" >/dev/null 2>&1; then
                    gem install --user-install "$g"
                """)
            lines.append("  fi")
            lines.append("done")
        }
        // NOTE: fvm's per-SDK installs are guarded internally by fvm itself
        // (re-installing an existing SDK is a no-op), so no guard needed.

        if !selection.stackSteps.isEmpty {
            lines.append("# Stack steps (version-pinned installs, e.g. fvm)")
            lines.append(contentsOf: selection.stackSteps)
        }

        if !selection.verifications.isEmpty {
            lines.append("# Audit trail: verify every managed tool (output is logged)")
            lines.append(selection.verifications.joined(separator: " && "))
        }

        return lines.joined(separator: "\n\n")
    }

    /// Base-image tweaks: disable sleep, enable SSH, autologin hint.
    public static func prepareScript() -> String {
        """
        set -euo pipefail

        # Disable sleep so runner VMs never stall mid-job.
        sudo pmset -a disablesleep 1 || true

        # Make sure Remote Login (SSH) is on.
        sudo systemsetup -setremotelogin on 2>/dev/null || true

        echo "base image prepared"
        """
    }

    // MARK: - Linux (Apple container runtime)

    /// The agent architecture inside Linux containers: `container` on Apple
    /// silicon runs arm64 Linux images.
    public static let linuxRunnerArch = "arm64"

    /// Installs the GitHub Actions runner agent into a Linux image for the
    /// Apple-container runtime (baked during `kinhin image prepare` when a
    /// GitHub credential exists). Mirrors installScript but for Linux tarballs.
    public static func linuxGitHubAgentInstallScript(runnerVersion: String) -> String {
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
    public static func linuxManagedToolchainsInstallScript(selection: ManagedToolchainSelection, mountPath: String?)
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
    public static func linuxGiteaRunnerInstallScript(version: String) -> String {
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
    public static func linuxGitHubRegistrationScript(
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
    public static func linuxGiteaRegistrationScript(
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
