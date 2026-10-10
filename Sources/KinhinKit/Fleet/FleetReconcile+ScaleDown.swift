import Foundation

// FleetEngine — the forge check every scale-down passes before it deletes.
extension FleetEngine {
    /// Whether a planned scale-down of `id` may go ahead.
    ///
    /// The plan reads record phases, which the exit watch sets from a cached runner list (seconds old). A runner
    /// that picked a job up since then still reads `.ready`, and on a forge whose queue lists only waiting jobs
    /// (Gitea 1.25+, GitLab, GitHub) that same pickup is what empties the queue and makes the instance look surplus.
    /// Without this check the pass right after a pickup deleted the runner mid-job (found by the e2e suite on Gitea
    /// 1.26 with `min_runners: 0`). So, like the exit watch, a delete is confirmed against the forge: a busy runner
    /// re-phases its record and is kept, and an unreadable list keeps it too.
    func confirmIdleForScaleDown(_ id: String) async -> Bool {
        guard let record = store.all.first(where: { $0.id == id }), record.phase == .ready else { return false }
        // No account (never bound) or a detached forge: nothing can be running on its behalf.
        guard let account = record.platform, let forge = forgeState.withLock({ $0.byPlatform[account] }) else {
            return true
        }
        let expected = Self.runnerNames(for: id, count: config.runnersPerVM)
        do {
            let runners = try await observedRunners(of: forge, expected: expected, fresh: true)
            guard !runners.contains(where: \.busy) else {
                Log.info(id, "keeping: its runner took a job since the pass began")
                updateRecord(id) { $0.phase = .busy }
                return false
            }
            return true
        } catch {
            Log.warn(id, "holding scale-down: \(forge.name) runner list failed (\(error.localizedDescription))")
            return false
        }
    }
}
