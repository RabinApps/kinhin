import Foundation

/// The deterministic rules: which fixes answer which problem, in the order to
/// try them, and which fixes the advisor may choose from when no rule
/// answers. Pure, so every rule is unit-tested without an engine.
enum HealingPlaybook {
    /// What the rules need to know beyond the signal.
    struct Context: Sendable, Equatable {
        /// `toolchain_cache.auto_prune`: the user lets kinhin prune the cache.
        var cacheAutoPrune: Bool
    }

    /// The fixes to try for `signal`, first to last. Empty: no rule covers it
    /// (the advisor may be asked, or the problem is surfaced as is).
    static func remediations(for signal: HealingSignal, context: Context) -> [Remediation] {
        switch signal.kind {
        case .instanceGone:
            return [Remediation(.recycleInstance, subject: signal.subject)]
        case .teardownStuck:
            return [Remediation(.inspectInstance, subject: signal.subject)]
        case .diskPressure:
            let images = Remediation(.pruneImages)
            return context.cacheAutoPrune ? [Remediation(.pruneToolchainCache), images] : [images]
        case .spawnFailures:
            return spawnFailureFixes(signal)
        case .accountDetached:
            if signal.evidence == .authRejected { return [Remediation(.replaceToken, subject: signal.subject)] }
            return [Remediation(.retryForgeAttach, subject: signal.subject)]
        case .credentials:
            return [Remediation(.replaceToken, subject: signal.subject)]
        case .queueUnreadable, .reconcileFailing:
            return []
        case .setupCheck:
            return setupFixes(signal)
        }
    }

    /// How long a problem must persist before anything acts on it: a queue
    /// read that fails once, or a teardown that fails once, heals by itself.
    static func minimumAge(of kind: HealingSignal.Kind) -> TimeInterval {
        switch kind {
        case .instanceGone, .diskPressure, .spawnFailures, .credentials, .setupCheck: return 0
        case .accountDetached: return 60
        case .queueUnreadable, .reconcileFailing: return 120
        case .teardownStuck: return 600
        }
    }

    /// The allowlist the advisor chooses from for `signal`: fixes that fit
    /// its subject. The advisor may also choose nothing.
    static func candidates(for signal: HealingSignal, context: Context) -> [Remediation] {
        switch signal.kind {
        case .instanceGone:
            return [Remediation(.recycleInstance, subject: signal.subject)]
        case .spawnFailures:
            guard let runtime = signal.subject.flatMap(RuntimeID.init(rawValue:)) else { return [] }
            var fixes = [Remediation(.repairRuntime, subject: runtime.rawValue)]
            if runtime == .appleContainer { fixes.append(Remediation(.startContainerSystem)) }
            if runtime == .tart { fixes.append(Remediation(.repairTart)) }
            fixes.append(Remediation(.pruneImages))
            return fixes
        case .accountDetached, .queueUnreadable:
            return [Remediation(.retryForgeAttach, subject: signal.subject)]
        case .diskPressure, .reconcileFailing:
            return context.cacheAutoPrune
                ? [Remediation(.pruneToolchainCache), Remediation(.pruneImages)] : [Remediation(.pruneImages)]
        case .credentials, .setupCheck, .teardownStuck:
            // Tokens, setup and a stuck teardown are the user's: nothing for a model to pick.
            return []
        }
    }

    // MARK: - Per-kind rules

    private static func spawnFailureFixes(_ signal: HealingSignal) -> [Remediation] {
        switch signal.evidence {
        case .runtimeMissing: return [Remediation(.repairRuntime, subject: signal.subject)]
        case .containerSystemStopped: return [Remediation(.startContainerSystem)]
        case .tartKilledOnLaunch, .tartBroken: return [Remediation(.repairTart)]
        default: return []
        }
    }

    /// Setup checks by their stable action ids (`SetupAction`).
    private static func setupFixes(_ signal: HealingSignal) -> [Remediation] {
        guard let action = signal.setupAction else { return [] }
        switch action {
        case "start_container_system": return [Remediation(.startContainerSystem)]
        case "install_tart": return [Remediation(.repairRuntime, subject: RuntimeID.tart.rawValue)]
        case "reinstall_tart", "rollback_tart": return [Remediation(.repairTart)]
        case "install_docker": return [Remediation(.repairRuntime, subject: RuntimeID.docker.rawValue)]
        case "install_container_cli":
            return [Remediation(.repairRuntime, subject: RuntimeID.appleContainer.rawValue)]
        case "install_host_agent": return [Remediation(.repairRuntime, subject: RuntimeID.host.rawValue)]
        case "enter_account_token", "replace_account_token":
            let account = signal.subject.map { $0.replacingOccurrences(of: "account-token-", with: "") }
            return [Remediation(.replaceToken, subject: account)]
        case "prepare_image", "prepare_container_image", "prepare_docker_image":
            return [Remediation(.prepareImage, subject: signal.subject)]
        default:
            return [Remediation(.reviewSetup, subject: action)]
        }
    }
}
