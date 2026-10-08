import Foundation
import KinhinKit

// MARK: - Budget editing and label fields

@MainActor
extension RuntimesModel {
    /// `budget` with an explicit 0 for every pool that was never budgeted
    /// (absent = 0 in the dict), so a drag can split a share with pools
    /// that had none — otherwise a default that owns everything has
    /// nothing to give.
    private func seededBudget(_ budget: [String: Double]) -> [String: Double] {
        var seeded = budget
        for pool in budgetRuntimeIDs where seeded[pool.rawValue] == nil {
            seeded[pool.rawValue] = 0
        }
        return seeded
    }

    /// Slider moved: update the live cap previews on every drag tick. During
    /// a managed drag (`budgetDragEditingChanged`) the write waits for the
    /// release; a tick outside one (keyboard, VoiceOver) debounces ~400ms.
    /// Every pool is eligible — including the default — locked pools hold
    /// their share, and the shares always come back totaling 100%.
    func budgetSliderChanged(runtime: RuntimeID, fraction: Double) {
        guard let rc = currentRuntimeConfig else { return }
        budgetNotice = ""
        // A drag rescales from the split it started with, not from the
        // previous tick: proportions survive 2dp rounding and a mid-drag
        // pause can never move the baseline under the user's hand.
        let base = dragBaseline ?? seededBudget(rc.budget)
        let budget = BudgetEditor.setShare(
            of: runtime, to: fraction, current: base, defaultRuntime: defaultRuntimeID,
            locked: lockedRuntimes)
        refreshBudgetPreviews(budget: budget)
        pendingBudget = budget

        previewCommitTask?.cancel()
        guard !isDraggingBudget else { return }  // the release commits
        previewCommitTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))  // debounce; cancellation just skips the write
            guard !Task.isCancelled else { return }
            // refreshPane: false — the on-screen values already match what
            // we're writing.
            self?.commitPendingBudget()
        }
    }

    /// The slider's press/release (`Slider(onEditingChanged:)`): a press
    /// freezes the baseline and holds back writes and reloads; the release
    /// commits the final split once.
    func budgetDragEditingChanged(_ editing: Bool) {
        if editing {
            guard let rc = currentRuntimeConfig else { return }
            isDraggingBudget = true
            dragBaseline = seededBudget(rc.budget)
            previewCommitTask?.cancel()
            return
        }
        isDraggingBudget = false
        previewCommitTask?.cancel()
        commitPendingBudget()
        dragBaseline = nil
        if reloadDeferredDuringDrag {
            reloadDeferredDuringDrag = false
            reload()
        }
    }

    private func commitPendingBudget() {
        guard let budget = pendingBudget, let rc = currentRuntimeConfig else { return }
        pendingBudget = nil
        commit(budget: budget, defaultRuntime: rc.defaultRuntime, refreshPane: false)
    }

    // MARK: - Locks and typed shares

    /// The split on screen right now (live draft first, disk second).
    private var liveShares: [String: Double] {
        percentShares.isEmpty
            ? BudgetEditor.displayShares(current: currentRuntimeConfig?.budget ?? [:], defaultRuntime: defaultRuntimeID)
            : percentShares
    }

    func isLocked(_ runtime: RuntimeID) -> Bool { lockedRuntimes.contains(runtime) }

    func toggleLock(_ runtime: RuntimeID) {
        if !lockedRuntimes.insert(runtime).inserted { lockedRuntimes.remove(runtime) }
        budgetNotice = ""
    }

    /// Whether this row's slider and field can change anything: it must be
    /// unlocked and have at least one unlocked neighbour to trade with.
    func canMoveBudget(_ runtime: RuntimeID) -> Bool {
        BudgetEditor.canMove(runtime: runtime, locked: lockedRuntimes, pools: budgetRuntimeIDs)
    }

    /// The most this pool can hold with the current locks.
    func maxBudgetShare(for runtime: RuntimeID) -> Double {
        BudgetEditor.maxShare(
            for: runtime, locked: lockedRuntimes, current: liveShares, defaultRuntime: defaultRuntimeID)
    }

    /// Parses a typed percent: "35", "35%", " 35.5 % ". nil for anything else
    /// (empty, words, negatives, non-finite).
    static func parsePercent(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(trimmed), value.isFinite, value >= 0 else { return nil }
        return value
    }

    /// A typed share: same engine path as the slider, committed at once.
    /// Junk reverts silently; a number above what the locks allow is capped
    /// with a note saying why.
    func budgetPercentTyped(runtime: RuntimeID, text: String) {
        budgetNotice = ""
        guard let rc = currentRuntimeConfig else { return }
        guard canMoveBudget(runtime), let percent = Self.parsePercent(text) else {
            refreshBudgetPreviews(budget: pendingBudget ?? rc.budget)  // rebuild so the field reverts
            return
        }
        let wanted = min(percent, 100) / 100
        let ceiling = maxBudgetShare(for: runtime)
        let budget = BudgetEditor.setShare(
            of: runtime, to: wanted, current: seededBudget(rc.budget), defaultRuntime: defaultRuntimeID,
            locked: lockedRuntimes)
        if (wanted * 100).rounded() / 100 > ceiling + 0.000_001 {
            let held = lockedRuntimes.map(\.rawValue).sorted().joined(separator: ", ")
            budgetNotice =
                "Capped at \(Int((ceiling * 100).rounded()))% — \(held.isEmpty ? "the others are" : "\(held) \(lockedRuntimes.count == 1 ? "is" : "are")") locked."
        }
        previewCommitTask?.cancel()
        pendingBudget = nil
        refreshBudgetPreviews(budget: budget)
        commit(budget: budget, defaultRuntime: rc.defaultRuntime, refreshPane: false)
    }

    /// Recompute "N inst" previews, percent labels, the Budget card's rows,
    /// and the starved-route warning from a candidate budget — the same
    /// partition math the engine uses.
    func refreshBudgetPreviews(budget: [String: Double]) {
        guard let parsed = parsedConfig, let rc = currentRuntimeConfig else { return }
        let def = defaultRuntimeID
        let caps = BudgetEditor.previewCaps(
            config: parsed, host: hostSnapshot(), weights: budget, defaultRuntime: def)
        capPreviews = caps
        // Percent labels and slider shares update live (they were rendered
        // for the old split). The default's share is always the remainder
        // the engine will hand it — never the stored weight.
        let shares = BudgetEditor.displayShares(current: budget, defaultRuntime: def)
        percentShares = shares
        // Starved-route strip: recomputed on every tick so a drag that would
        // strand a route shows the warning before the user lets go. With no
        // budget on disk the fleet isn't partitioned ("cap n/a"), so nothing
        // can be starved yet.
        let configured = Set(viewModel?.pools.map(\.runtime) ?? [])
        lockedRuntimes.formIntersection(configured)  // a pool that left the config can't stay locked
        let isPartitioned = !(rc.budget.isEmpty && budget.isEmpty)
        starvedRoutes = BudgetEditor.starvedRoutes(
            routes: rc.routes, caps: caps, configuredRuntimes: configured,
            isPartitioned: isPartitioned)
        budgetRows = (viewModel?.pools ?? []).map { pool in
            let cap: Int?
            if pool.runtime == .host {
                cap = caps[.host]  // host slots draw budget only when budgeted
            } else if isPartitioned {
                cap = caps[pool.runtime] ?? 0  // budgeted away = no instances
            } else {
                cap = nil  // no split yet: the card reads "n/a", like pool cards
            }
            return BudgetRow(
                id: pool.runtime,
                share: shares[pool.runtime.rawValue] ?? 0,
                cap: cap,
                isDefault: pool.runtime == def)
        }
    }

    func percentText(for runtime: RuntimeID) -> String {
        let share = percentShares[runtime.rawValue] ?? budgetShare(for: runtime)
        return "\(Int((share * 100).rounded()))%"
    }

    /// Default switched: only `default:` moves — every pool keeps the share
    /// it already had (the dict is re-derived so the new default's stored
    /// weight matches the remainder the engine will compute).
    func defaultRuntimeChanged(to rawValue: String) {
        guard let rc = currentRuntimeConfig else { return }
        let newDefault = RuntimeID(rawValue: rawValue) ?? defaultRuntimeID
        let shares = BudgetEditor.displayShares(current: rc.budget, defaultRuntime: newDefault)
        commit(budget: shares, defaultRuntime: rawValue)
    }

    func commit(budget: [String: Double], defaultRuntime: String, refreshPane: Bool = true) {
        guard var rc = currentRuntimeConfig else { return }
        // Zero shares are spelled by omission upstream (ConfigLoader
        // rejects an explicit 0); drop any that slip through before the
        // validation gate.
        let budget = BudgetEditor.sanitized(budget)
        if let problem = BudgetEditor.validate(budget) {
            presentError(ConfigEditError.validation(problem))
            reload()  // snap sliders back to the on-disk truth
            return
        }
        rc.budget = budget
        rc.defaultRuntime = defaultRuntime
        do {
            try RuntimesConfigEditor.apply(rc, to: configURL)
            currentRuntimeConfig = rc  // next drag starts from the new baseline
            if refreshPane { reload() }
            onChanged?()
        } catch {
            presentError(error)
            reload()
        }
    }

    // MARK: - Labels

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
            onChanged?()
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
