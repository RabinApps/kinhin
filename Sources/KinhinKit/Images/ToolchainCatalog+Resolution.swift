import Foundation

extension ToolchainCatalog {
    /// Resolves a validated `toolchains:` config into install steps.
    ///
    /// Selection surfaces:
    /// - `specs` entries resolve by root id against the catalog: mise tools
    ///   install via `mise use --global`, npm tools via `npm install -g`,
    ///   gems via `gem install`; unknown roots pass through to mise.
    /// - `brew` entries are Homebrew formulas/casks; known ones contribute
    ///   their cache envs and verification.
    /// - `stacks` contribute their recipe pieces (with pinned versions).
    ///
    /// Platform-aware: entries that don't list the requested platform are
    /// skipped (recorded in `skippedEntries`, never an error). Defaults to
    /// macOS for the existing VM bake path.
    public static func selection(
        from config: KinhinConfig.ToolchainsConfig,
        platform: ToolchainPlatform = .macOS,
        mountPath: String? = nil
    ) -> ManagedToolchainSelection {
        var out = ManagedToolchainSelection()

        func collect(_ entry: ToolchainEntry, version: String?) {
            guard entry.platforms.contains(platform) else {
                if !out.skippedEntries.contains(entry.id) { out.skippedEntries.append(entry.id) }
                return
            }
            switch entry.installer(for: platform) {
            case .mise:
                out.miseSpecs.append(version.map { "\(entry.id)@\($0)" } ?? entry.defaultSpec)
            case .brew(let formula, let isCask):
                let target = BrewFormula(name: formula, isCask: isCask)
                if !out.brewFormulas.contains(target) { out.brewFormulas.append(target) }
            case .npm(let package):
                out.npmPackages.append(.init(name: package, version: version ?? ""))
            case .gem(let gem):
                if !out.gems.contains(gem) { out.gems.append(gem) }
            case .apt(let packages):
                for package in packages where !out.aptPackages.contains(package) {
                    out.aptPackages.append(package)
                }
            }
            for env in entry.cacheEnvs where !out.cacheEnvs.contains(env) {
                out.cacheEnvs.append(env)
            }
            if !entry.verify.isEmpty, !out.verifications.contains(entry.verify) {
                out.verifications.append(entry.verify)
            }
        }

        // 1. specs: tool id (optionally @version) → catalog installer.
        for spec in config.specs ?? [] {
            let root = rootTool(of: spec)
            let version = ToolchainStack.splitSpec(spec).version
            if let tool = ToolchainCatalog.tool(id: root) {
                collect(tool, version: version)
            } else {
                // Pass-through: unknown roots go to mise verbatim.
                out.miseSpecs.append(spec)
            }
        }

        // 2. brew: raw formulas; known tools contribute caches/verification.
        for formula in config.brew ?? [] {
            if let tool = ToolchainCatalog.tool(id: formula) {
                // Known tool: on Linux, use its Linux installer when it has
                // one (e.g. dotnet via apt); otherwise skip with a note.
                if !tool.platforms.contains(platform) {
                    if !out.skippedEntries.contains(tool.id) { out.skippedEntries.append(tool.id) }
                    continue
                }
                if case .brew(let name, let isCask) = tool.installer(for: platform) {
                    let target = BrewFormula(name: name, isCask: isCask)
                    if !out.brewFormulas.contains(target) { out.brewFormulas.append(target) }
                } else if case .apt(let packages) = tool.installer(for: platform) {
                    for package in packages where !out.aptPackages.contains(package) {
                        out.aptPackages.append(package)
                    }
                }
                for env in tool.cacheEnvs where !out.cacheEnvs.contains(env) {
                    out.cacheEnvs.append(env)
                }
                if !tool.verify.isEmpty, !out.verifications.contains(tool.verify) {
                    out.verifications.append(tool.verify)
                }
                continue
            }
            if platform == .linux {
                // Homebrew is macOS-only: raw brew entries are skipped on
                // Linux with a note (never an error).
                if !out.skippedEntries.contains(formula) { out.skippedEntries.append(formula) }
                continue
            }
            if let tool = ToolchainCatalog.tool(id: formula),
                case .brew(let name, let isCask) = tool.installer
            {
                let target = BrewFormula(name: name, isCask: isCask)
                if !out.brewFormulas.contains(target) { out.brewFormulas.append(target) }
                for env in tool.cacheEnvs where !out.cacheEnvs.contains(env) {
                    out.cacheEnvs.append(env)
                }
                if !tool.verify.isEmpty, !out.verifications.contains(tool.verify) {
                    out.verifications.append(tool.verify)
                }
            } else if let tool = ToolchainCatalog.tools.first(where: {
                if case .brew(let name, _) = $0.installer { return name == formula }
                return false
            }) {
                // A known formula under its package name (e.g. "dotnet-sdk").
                if case .brew(let name, let isCask) = tool.installer {
                    let target = BrewFormula(name: name, isCask: isCask)
                    if !out.brewFormulas.contains(target) { out.brewFormulas.append(target) }
                    for env in tool.cacheEnvs where !out.cacheEnvs.contains(env) {
                        out.cacheEnvs.append(env)
                    }
                    if !tool.verify.isEmpty, !out.verifications.contains(tool.verify) {
                        out.verifications.append(tool.verify)
                    }
                }
            } else {
                // Pass-through formula.
                let target = BrewFormula(name: formula, isCask: false)
                if !out.brewFormulas.contains(target) { out.brewFormulas.append(target) }
            }
        }

        // 3. stacks: recipe pieces in declared order.
        for name in config.stacks ?? [] {
            let (id, pinned) = ToolchainStack.splitSpec(name)
            guard let stack = ToolchainCatalog.stack(id: id) else { continue }  // validated earlier
            guard stack.platforms.contains(platform) else {
                if !out.skippedEntries.contains(stack.id) { out.skippedEntries.append(stack.id) }
                continue
            }
            out.brewTaps.append(contentsOf: stack.brewTaps)
            for formula in stack.brewFormulas {
                let target = BrewFormula(name: formula, isCask: false)
                if !out.brewFormulas.contains(target) { out.brewFormulas.append(target) }
            }
            out.miseSpecs.append(contentsOf: stack.miseSpecs)
            for var package in stack.npmPackages {
                let version = stack.effectiveVersion(pinned: pinned)
                if !version.isEmpty { package = .init(name: package.name, version: version) }
                if !out.npmPackages.contains(package) { out.npmPackages.append(package) }
            }
            // Post-install steps (fvm SDK pin): emitted only when the step
            // carries a concrete version — with the host cache unmounted the
            // SDK would land inside the throwaway scratch VM, so the pin is
            // skipped (the install steps above still no-op safely).
            let version = stack.effectiveVersion(pinned: pinned)
            let hasMount = mountPath != nil
            for step in stack.postInstall where step.contains("<version>") {
                guard hasMount, !version.isEmpty else { continue }
                out.stackSteps.append(step.replacingOccurrences(of: "<version>", with: version))
            }
            for step in stack.postInstall where !step.contains("<version>") {
                out.stackSteps.append(step)
            }
            for env in stack.cacheEnvs where !out.cacheEnvs.contains(env) {
                out.cacheEnvs.append(env)
            }
            if !stack.verify.isEmpty, !out.verifications.contains(stack.verify) {
                out.verifications.append(stack.verify)
            }
        }

        // Umbrella caches: mise (whenever any mise tool is selected) and
        // Homebrew's download cache (macOS brew installs only). These were
        // documented in the README's cache map but previously missing from
        // the resolved selection.
        if !out.miseSpecs.isEmpty {
            let mise = ToolchainCacheEnv(variable: "MISE_CACHE_DIR", subdirectory: "mise")
            if !out.cacheEnvs.contains(mise) { out.cacheEnvs.insert(mise, at: 0) }
        }
        if platform == .macOS, !out.brewFormulas.isEmpty {
            let brew = ToolchainCacheEnv(variable: "HOMEBREW_CACHE", subdirectory: "brew")
            if !out.cacheEnvs.contains(brew) {
                out.cacheEnvs.insert(brew, at: out.miseSpecs.isEmpty ? 0 : 1)
            }
        }

        return out
    }
}
