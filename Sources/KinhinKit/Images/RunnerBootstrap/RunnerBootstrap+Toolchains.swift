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

    /// The managed-toolchains script baked by `image prepare` when a
    /// `toolchains:` section is configured: cache exports, brew taps +
    /// formulas (idempotent), mise pins (`mise use --global`), npm globals,
    /// gems, then every verify command — a failing verify aborts the prepare
    /// with the previous image left intact.
    static func managedToolchainsInstallScript(selection: ManagedToolchainSelection, mountPath: String?)
        -> String
    {
        var lines: [String] = ["set -euo pipefail"]

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

        if !selection.miseSpecs.isEmpty {
            let specs = selection.miseSpecs.map(shellQuote).joined(separator: " ")
            lines.append(
                """
                # mise pins — installed AND set globally so every runner shell sees them
                mise use --global \(specs)
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
}
