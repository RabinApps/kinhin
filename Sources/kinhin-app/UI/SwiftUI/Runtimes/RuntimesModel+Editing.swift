import Foundation
import KinhinKit

// MARK: - Budget editing and label fields

@MainActor
extension RuntimesModel {
    /// Slider moved: update the live cap previews on every drag tick, and
    /// debounce the actual config write until the drag settles (~400ms).
    func budgetSliderChanged(runtime: RuntimeID, fraction: Double) {
        guard let rc = currentRuntimeConfig else { return }
        let defaultRuntime = defaultRuntimeID
        let budget = BudgetEditor.setShare(
            of: runtime, to: fraction, current: rc.budget, defaultRuntime: defaultRuntime)
        refreshBudgetPreviews(budget: budget)

        previewCommitTask?.cancel()
        previewCommitTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))  // drag debounce; cancellation just skips the write
            guard !Task.isCancelled else { return }
            // refreshPane: false — the on-screen values already match what
            // we're writing; a full rebuild mid-gesture would yank the
            // slider out from under the user's hand.
            self?.commit(budget: budget, defaultRuntime: rc.defaultRuntime, refreshPane: false)
        }
    }

    /// Recompute "N inst" previews, percent labels, and the starved-route
    /// warning from a candidate budget — the same partition math the engine
    /// uses.
    func refreshBudgetPreviews(budget: [String: Double]) {
        guard let parsed = parsedConfig, let rc = currentRuntimeConfig else { return }
        let def = defaultRuntimeID
        let caps = BudgetEditor.previewCaps(
            config: parsed, host: hostSnapshot(), weights: budget, defaultRuntime: def)
        capPreviews = caps
        // Percent labels update live (they were rendered for the old split).
        var shares: [String: Double] = [:]
        let total = budget.values.reduce(0, +)
        for (runtime, weight) in budget {
            let effective = runtime == def.rawValue ? max(0, 1 - (total - weight)) : weight
            shares[runtime] = effective
        }
        percentShares = shares
        // Starved-route strip: recomputed on every tick so a drag that would
        // strand a route shows the warning before the user lets go. With no
        // budget on disk the fleet isn't partitioned ("cap n/a"), so nothing
        // can be starved yet.
        let configured = Set(viewModel?.pools.map(\.runtime) ?? [])
        starvedRoutes = BudgetEditor.starvedRoutes(
            routes: rc.routes, caps: caps, configuredRuntimes: configured,
            isPartitioned: !(rc.budget.isEmpty && budget.isEmpty))
        let pct = Int(((budget[def.rawValue] ?? 0) * 100).rounded())
        remainderNote = String(format: "%@ keeps the remaining %d%% — %d inst", def.rawValue, pct, caps[def] ?? 0)
    }

    func percentText(for runtime: RuntimeID) -> String {
        let share = percentShares[runtime.rawValue] ?? budgetShare(for: runtime)
        return "\(Int((share * 100).rounded()))%"
    }

    /// Default switched: rewrite the section with the new default (weights
    /// stay; the remainder rule re-homes).
    func defaultRuntimeChanged(to rawValue: String) {
        guard let rc = currentRuntimeConfig else { return }
        commit(budget: rc.budget, defaultRuntime: rawValue)
    }

    func commit(budget: [String: Double], defaultRuntime: String, refreshPane: Bool = true) {
        guard var rc = currentRuntimeConfig else { return }
        if let problem = BudgetEditor.validate(budget) {
            presentError(NSError(domain: "kinhin", code: 2, userInfo: [NSLocalizedDescriptionKey: problem]))
            reload()  // snap sliders back to the on-disk truth
            return
        }
        rc.budget = budget
        rc.defaultRuntime = defaultRuntime
        do {
            try RuntimesConfigEditor.apply(rc, to: configURL)
            currentRuntimeConfig = rc  // next drag starts from the new baseline
            if refreshPane { reload() }
            onEdited?()
        } catch {
            presentError(error)
            reload()
        }
    }

    // MARK: Labels

    func refreshLabelFields() {
        let yaml = ConfigStore.textOrLog(at: configURL)
        do {
            fleetLabelsText = try LabelsConfigEditor.labels(in: yaml, scope: .fleet).joined(separator: ", ")
            containerLabelsText = try LabelsConfigEditor.labels(in: yaml, scope: .container).joined(separator: ", ")
        } catch {
            // Leave the fields as they were and say why they are not current.
            Log.warn("runtimes-pane", "could not read labels: \(error.localizedDescription)")
            labelsStatus = Line(text: "Labels not loaded — \(error.localizedDescription)", style: .error)
        }
    }

    /// Restores one label field from disk after a failed commit (the other
    /// field may hold the user's own edit, so it is left alone).
    private func snapBackLabelField(_ scope: LabelsConfigEditor.Scope) {
        let yaml = ConfigStore.textOrLog(at: configURL)
        do {
            let labels = try LabelsConfigEditor.labels(in: yaml, scope: scope).joined(separator: ", ")
            if scope == .fleet {
                fleetLabelsText = labels
            } else {
                containerLabelsText = labels
            }
        } catch {
            Log.warn("runtimes-pane", "could not re-read labels: \(error.localizedDescription)")
        }
    }

    /// Commit a label field edit (called on Enter or focus loss).
    func commitLabels(scope: LabelsConfigEditor.Scope, text: String) {
        let labels = Self.parseLabelList(text)
        do {
            try LabelsConfigEditor.apply(labels, scope: scope, to: configURL)
            Log.info("runtimes-pane", "\(scope == .fleet ? "fleet" : "container") labels updated")
            labelsStatus = Line(text: "")
            onEdited?()
        } catch {
            presentError(error)
            // Snap the field back to the on-disk truth.
            snapBackLabelField(scope)
        }
    }

    /// Parse a comma-separated label list.
    static func parseLabelList(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
