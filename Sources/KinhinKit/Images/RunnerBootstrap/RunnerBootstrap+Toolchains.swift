import Foundation

extension RunnerBootstrap {
    // MARK: - Managed toolchains (toolchains: config section)

    /// The cache-env prefix a registration script starts with when its route
    /// mounts the shared toolchain cache: the selection's exports plus a
    /// blank line, or "" when the cache isn't mounted or nothing is selected.
    static func cachePrefix(mounted: Bool, selection: ManagedToolchainSelection?, mountPath: String) -> String {
        guard mounted, let selection else { return "" }
        return cacheEnvExports(cacheEnvs: selection.cacheEnvs, mountPath: mountPath) + "\n\n"
    }

    /// Shell exports pointing every selected ecosystem's download/package
    /// cache at the host-mounted cache share. Each export is guarded: when
    /// the share is not mounted (or the path is missing) the variable is
    /// left at its default — caching is best-effort and never fails a
    /// prepare or a runner boot.
    static func cacheEnvExports(cacheEnvs: [ToolchainCacheEnv], mountPath: String) -> String {
        guard !cacheEnvs.isEmpty else { return "" }
        let lines = cacheEnvs.map { env -> String in
            """
            if [ -d "\(mountPath)" ]; then
              export \(env.variable)="\(mountPath)/\(env.subdirectory)"
              mkdir -p "\(mountPath)/\(env.subdirectory)" 2>/dev/null || true
            fi
            """
        }
        return "# Shared toolchain cache (skipped gracefully when the host share is absent)\n"
            + lines.joined(separator: "\n")
    }

    /// How the managed-toolchains script reaches its guest, which decides
    /// what its PATH setup must do.
    enum ToolchainSessionKind {
        /// An SSH exec: a bare shell that skips the guest's login profile, so
        /// brew and mise are not on PATH and must be put there.
        case ssh
        /// A runner job step: the runner already exports its PATH; adding
        /// brew's bin here would shadow the job's own tools.
        case job
    }

    /// The managed-toolchains script baked by `image prepare` when a
    /// `toolchains:` section is configured: cache exports, brew taps +
    /// formulas (idempotent), mise pins (`mise use --global`), npm globals,
    /// gems, then every verify command — a failing verify aborts the prepare
    /// with the previous image left intact.
    static func managedToolchainsInstallScript(
        selection: ManagedToolchainSelection, mountPath: String?, session: ToolchainSessionKind = .ssh
    )
        -> String
    {
        var lines: [String] = ["set -euo pipefail"]
        switch session {
        case .ssh:
            // ssh starts a bare shell that skips the guest's login profile, so brew and
            // mise are not on PATH: put them there. Shims go first so a mise pin beats a
            // Homebrew copy of the same tool the base image ships (node, python).
            lines.append(
                """
                export PATH="$HOME/.local/share/mise/shims:/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"
                export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
                """)
        case .job:
            // The runner's PATH already carries everything the base image ships
            // (mise shims via the login profile). Don't prepend brew: in a job
            // step that would shadow the job's own PATH entries (a stubbed or
            // project-local tool would silently lose to brew's). If an image
            // somehow lacks them, fall back — checked, never prepended.
            lines.append(
                """
                command -v brew >/dev/null 2>&1 || export PATH="$PATH:/opt/homebrew/bin:/opt/homebrew/sbin"
                command -v mise >/dev/null 2>&1 || export PATH="$PATH:$HOME/.local/share/mise/shims"
                export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
                """)
        }

        if let mountPath {
            lines.append(Self.cacheEnvExports(cacheEnvs: selection.cacheEnvs, mountPath: mountPath))
        }

        if !selection.brewTaps.isEmpty {
            let taps = selection.brewTaps.map(shellQuote).joined(separator: " ")
            lines.append(
                """
                # Homebrew taps
                for tap in \(taps); do
                  brew tap "$tap" 2>/dev/null || true
                done
                """)
        }

        if !selection.brewFormulas.isEmpty {
            let formulas = selection.brewFormulas.map(\.name).map(shellQuote).joined(separator: " ")
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

        // mise's rust install writes rustup-init into MISE_CACHE_DIR, which fails on the
        // virtiofs cache share ("Inappropriate ioctl for device"), so rust installs with
        // mise's default (guest-local) cache and every other spec uses the shared one.
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

        if !selection.npmPackages.isEmpty {
            lines.append("# npm globals (guarded so re-runs no-op)")
            for package in selection.npmPackages {
                let spec = shellQuote(package.version.isEmpty ? package.name : "\(package.name)@\(package.version)")
                lines.append(
                    """
                    if ! npm ls -g --depth=0 \(shellQuote(package.name)) >/dev/null 2>&1; then
                      npm install -g \(spec)
                    fi
                    """
                )
            }
            lines.append("# corepack: packageManager-field support (pnpm/yarn per project)")
            lines.append("corepack enable 2>/dev/null || true")
        }

        if !selection.gems.isEmpty {
            let gems = selection.gems.map(shellQuote).joined(separator: " ")
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
    static func prepareScript() -> String {
        """
        set -euo pipefail

        # Disable sleep so runner VMs never stall mid-job.
        sudo pmset -a disablesleep 1 || true

        # Make sure Remote Login (SSH) is on.
        sudo systemsetup -setremotelogin on 2>/dev/null || true

        \(sshHardeningScript())

        echo "base image prepared"
        """
    }

    /// The managed-toolchains script baked by `image prepare --container` when a
    /// `toolchains:` section is configured. The Linux container bake runs as root
    /// (plain apt, no sudo); a tart Linux VM guest runs an admin user and goes
    /// through passwordless sudo for apt and /usr/local/bin.
    static func linuxManagedToolchainsInstallScript(
        selection: ManagedToolchainSelection, mountPath: String?, runsAsRoot: Bool = true
    ) -> String {
        let s = runsAsRoot ? "" : "sudo "
        var lines: [String] = [
            "set -euo pipefail",
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
                printf '%s\\n' 'export PATH="$HOME/.local/share/mise/shims:$PATH"' | \(s)tee /etc/profile.d/kinhin-mise.sh > /dev/null
                """)
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
                # Ruby globals (guarded so re-runs no-op)
                if ! command -v gem >/dev/null 2>&1; then
                  \(s)apt-get update -qq
                  \(s)apt-get install -y --no-install-recommends ruby
                fi
                if ! gem list --local \(gems) —exact >/dev/null 2>&1; then
                  \(s)gem install --no-document \(gems)
                fi
                """)
        }
        // Same tail as the macOS script: version-pinned stack installs, then
        // the verification commands that gate the bake (a toolchain that
        // cannot run fails `image prepare`, not the first job).
        if !selection.stackSteps.isEmpty {
            lines.append("# Stack steps (version-pinned installs, e.g. flutter)")
            lines.append(contentsOf: selection.stackSteps)
        }
        if !selection.verifications.isEmpty {
            lines.append("# Audit trail: verify every managed tool (output is logged)")
            lines.append(selection.verifications.joined(separator: " && "))
        }
        let epilogue: String
        if let mountPath {
            epilogue = Self.cacheEnvExports(cacheEnvs: selection.cacheEnvs, mountPath: mountPath)
        } else {
            epilogue = ""
        }
        lines.append(epilogue)
        return lines.joined(separator: "\n")
    }
}
