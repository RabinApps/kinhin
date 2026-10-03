import Foundation

extension RunnerBootstrap {
    // MARK: - Linux (Apple container runtime)

    /// Installs, via apt, whichever of the given tools the base image lacks.
    /// Minimal images (ubuntu:24.04) ship neither curl nor CA certificates,
    /// and every download step below needs them. `tools` pairs a command
    /// to look for with the package that provides it. Idempotent: a no-op
    /// once everything is present (containers run as root — no sudo).
    static func linuxPrerequisitesScript(tools: [(command: String, package: String)]) -> String {
        let checks = tools.map { "command -v \($0.command) >/dev/null 2>&1 || need=\"$need \($0.package)\"" }
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

    /// Installs the GitHub Actions runner agent into a Linux image for the
    /// Apple-container runtime (baked during `kinhin image prepare` when a
    /// GitHub credential exists). Mirrors installScript but for Linux tarballs.
    static func linuxGitHubAgentInstallScript(runnerVersion: String, arch: String = "arm64") -> String {
        """
        set -euo pipefail
        \(linuxPrerequisitesScript(tools: [("curl", "curl"), ("tar", "tar"), ("gzip", "gzip")]))
        mkdir -p /opt/actions-runner
        cd /opt/actions-runner
        if [ ! -x ./config.sh ]; then
          \(githubRunnerDownloadScript(version: runnerVersion, platform: "linux-\(arch)", file: "runner.tar.gz").replacingOccurrences(of: "\n", with: "\n  "))
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
    /// - Parameters:
    ///   - runsAsRoot: The Linux container bake runs as root (plain apt, no
    ///     sudo); a tart Linux VM guest runs an admin user and goes through
    ///     passwordless sudo for apt and /usr/local/bin.
    static func linuxManagedToolchainsInstallScript(
        selection: ManagedToolchainSelection, mountPath: String?, runsAsRoot: Bool = true
    )
        -> String
    {
        // Root (containers) runs everything directly; a tart VM's admin user
        // elevates with passwordless sudo.
        let s = runsAsRoot ? "" : "sudo "
        var lines: [String] = [
            "set -euo pipefail",
            // A VM guest's admin user needs sudo for apt; containers run as root.
            runsAsRoot
                ? linuxPrerequisitesScript(tools: [("curl", "curl"), ("git", "git"), ("xz", "xz-utils")])
                : tartLinuxPrerequisitesScript(tools: [("curl", "curl"), ("git", "git"), ("xz", "xz-utils")]),
        ]

        if let mountPath {
            lines.append(Self.cacheEnvExports(cacheEnvs: selection.cacheEnvs, mountPath: mountPath))
        }

        if !selection.aptPackages.isEmpty {
            let packages = selection.aptPackages.map(shellQuote).joined(separator: " ")
            lines.append(
                """
                # apt packages (guarded so re-runs no-op)
                export DEBIAN_FRONTEND=noninteractive
                for p in \(packages); do
                  if ! dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed'; then
                    \(s)apt-get update -qq
                    \(s)apt-get install -y --no-install-recommends "$p"
                  fi
                done
                """)
        }

        if !selection.miseSpecs.isEmpty {
            lines.append(
                """
                # mise bootstrap (Linux base images don't ship it) + shims on PATH
                if ! command -v mise >/dev/null 2>&1; then
                  curl --proto-redir '=https' --tlsv1.2 -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh
                fi
                export PATH="$HOME/.local/share/mise/shims:$PATH"
                # persist it: runners start from a login shell, so job steps only see
                # the pinned tools if the shims are on PATH there too
                printf '%s\\n' 'export PATH="$HOME/.local/share/mise/shims:$PATH"' | \(s)tee /etc/profile.d/kinhin-mise.sh > /dev/null
                """)
            // mise's rust install writes rustup-init into MISE_CACHE_DIR, which fails on
            // bind/virtiofs mounts ("Inappropriate ioctl for device"), so rust installs with
            // mise's default (guest-local) cache — same bypass as the macOS script.
            let rustSpecs = selection.miseSpecs.filter { ToolchainCatalog.rootTool(of: $0) == "rust" }
            let otherSpecs = selection.miseSpecs.filter { ToolchainCatalog.rootTool(of: $0) != "rust" }
            if !otherSpecs.isEmpty {
                let specs = otherSpecs.map(shellQuote).joined(separator: " ")
                lines.append(
                    """
                    # mise pins — installed AND set globally so every runner shell sees them
                    mise use --global \(specs)
                    """)
            }
            if !rustSpecs.isEmpty {
                let specs = rustSpecs.map(shellQuote).joined(separator: " ")
                lines.append(
                    """
                    # rust: guest-local mise cache (see above)
                    env -u MISE_CACHE_DIR mise use --global \(specs)
                    """)
            }
        }

        if !selection.npmPackages.isEmpty {
            lines.append("# npm globals (guarded so re-runs no-op)")
            for package in selection.npmPackages {
                let spec = shellQuote(package.version.isEmpty ? package.name : "\(package.name)@\(package.version)")
                lines.append(
                    """
                    if ! npm ls -g --depth=0 \(shellQuote(package.name)) >/dev/null 2>&1; then
                      \(s)npm install -g \(spec)
                    fi
                    """)
            }
        }

        if !selection.gems.isEmpty {
            let gems = selection.gems.map(shellQuote).joined(separator: " ")
            lines.append(
                """
                # Ruby gems (system install; guarded so re-runs no-op)
                for g in \(gems); do
                  if ! gem list -i "^$g$" >/dev/null 2>&1; then
                    \(s)gem install "$g"
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
    /// formerly act_runner — arm64 by default, amd64 for emulated bakes).
    static func linuxGiteaRunnerInstallScript(version: String, arch: String = "arm64") -> String {
        """
        set -euo pipefail
        \(linuxPrerequisitesScript(tools: [("curl", "curl"), ("xz", "xz-utils")]))
        if [ ! -x /opt/gitea-runner/gitea-runner ]; then
          mkdir -p /opt/gitea-runner
          cd /opt/gitea-runner
          \(giteaRunnerDownloadScript(version: version, platform: "linux-\(arch)", file: "runner.xz").replacingOccurrences(of: "\n", with: "\n  "))
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
                  ./config.sh remove --token \(shellQuote(token)) >/dev/null 2>&1 || true
                fi
                ./config.sh --url \(shellQuote(configureURL)) \\
                            --token \(shellQuote(token)) \\
                            --labels \(shellQuote(labelList)) \\
                            --name \(shellQuote(runnerName)) \\
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
        // Register every runner before starting any (see `giteaRegistrationScript`).
        var blocks = ""
        var starts = ""
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
                  --instance \(shellQuote(instance)) \\
                  --token \(shellQuote(token)) \\
                  --name \(shellQuote(runnerName)) \\
                  --labels \(shellQuote(labelList)) >/dev/null

                """
            starts += """
                cd "\(dir)"
                nohup ./gitea-runner daemon > daemon-\(index).log 2>&1 &

                """
        }
        return """
            set -euo pipefail

            \(blocks)# All registered; now start serving jobs.
            \(starts)echo "\(max(1, runnerCount)) linux gitea runner(s) started"
            """
    }
}
