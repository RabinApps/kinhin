import Foundation
import KinhinKit
import Observation

/// State and actions behind the VM capacity cards of Advanced → Capacity:
/// how many VMs the fleet runs and how big they are. (This Mac's own form in
/// that section is `MacToolsModel`.)
///
/// Nothing is written while the user types or clicks a stepper. Edits collect
/// as pending changes and are written together, once, when the user presses
/// **Apply** — which also means the running fleet restarts at most once
/// (instead of after every stepper click). Every write goes through
/// `GeneralConfigEditor` (comments preserved, engine-validated).
///
/// Account, repository and runtime choices live in the Setup tab; labels and
/// routing live in Advanced → Routing.
@MainActor
@Observable
final class CapacityModel: ConfigFormModel {
    typealias Snapshot = GeneralConfigEditor.Snapshot
    typealias Field = GeneralConfigEditor.Field

    /// The config file this form edits (tests point it at a scratch file).
    @ObservationIgnored var configURL: URL = Paths.config
    /// Fired once after an Apply wrote at least one change.
    @ObservationIgnored var onChanged: (() -> Void)?
    /// How many times the config was loaded (tests: the hosting section must
    /// have loaded at least once, or the form renders blank forever).
    @ObservationIgnored private(set) var loads = 0

    /// What the controls show, including unapplied edits. Nil until loaded.
    private(set) var draft: Snapshot?
    /// What is on disk, as of the last load or Apply.
    private var baseline: Snapshot?
    /// Pending edits keyed by control id (last edit wins), in staging order.
    private var pending: [String: Field] = [:]
    private var pendingOrder: [String] = []
    /// The outcome of the last load or Apply; cleared by the next edit.
    private var result = StatusLine(text: "")

    var hasPendingChanges: Bool { !pending.isEmpty }

    var status: StatusLine {
        if !result.text.isEmpty { return result }
        let count = pending.count
        guard count > 0 else { return result }
        return StatusLine(
            text: "\(count) unapplied change\(count == 1 ? "" : "s") — Apply restarts the fleet if needed.",
            style: .warn)
    }

    // MARK: - Loading

    func reload() {
        loads += 1
        result = StatusLine(text: "")
        do {
            guard let loaded = try ConfigStore.snapshot(at: configURL) else {
                throw ConfigError.notFound(configURL.path)
            }
            baseline = loaded
            draft = loaded
            clearPending()
        } catch {
            result = StatusLine(
                text:
                    "config.yaml has a problem — \(error.localizedDescription). Use Advanced → App → Open config file.",
                style: .error)
        }
    }

    // MARK: - Editing

    /// Sets a numeric control (clamped to its range) and stages the edit when
    /// the value changed.
    func set(
        _ id: String, _ path: WritableKeyPath<Snapshot, Int>, to value: Int, in range: ClosedRange<Int>,
        make: (Int) -> Field
    ) {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        guard let current = draft?[keyPath: path] else { return }
        // Assigned even when unchanged, so a field showing an out-of-range
        // number snaps back to the clamped one.
        draft?[keyPath: path] = clamped
        if clamped != current { stage(id, make(clamped)) }
    }

    func setEphemeral(_ on: Bool) {
        draft?.vmEphemeral = on
        stage("ephemeral", .vmEphemeral(on))
    }

    func setAutoResume(_ on: Bool) {
        draft?.autoResume = on
        stage("auto-resume", .autoResume(on))
    }

    func setImage(_ text: String) {
        draft?.image = text
        let value = text.trimmingCharacters(in: .whitespaces)
        if value.isEmpty || value == baseline?.image {
            unstage("image")
        } else {
            stage("image", .image(value))
        }
    }

    func stage(_ id: String, _ field: Field) {
        result = StatusLine(text: "")
        if pending[id] == nil { pendingOrder.append(id) }
        pending[id] = field
    }

    private func unstage(_ id: String) {
        pending[id] = nil
        pendingOrder.removeAll { $0 == id }
    }

    private func clearPending() {
        pending.removeAll()
        pendingOrder.removeAll()
    }

    func revert() { reload() }

    /// Writes every pending edit. Fields validate against each other (Max ≥
    /// Min), so a rejected write is retried after the others land.
    func applyPending() {
        var remaining = pendingOrder.compactMap { id in pending[id].map { (id, $0) } }
        var lastError: Error?
        var wroteAny = false
        for _ in 0..<max(1, remaining.count) {
            var failed: [(String, Field)] = []
            lastError = nil
            for (id, field) in remaining {
                do {
                    _ = try GeneralConfigEditor.apply(field, to: configURL)
                    wroteAny = true
                } catch {
                    failed.append((id, field))
                    lastError = error
                }
            }
            remaining = failed
            if remaining.isEmpty { break }
        }
        if let lastError, !remaining.isEmpty {
            // Keep only what failed pending, so the user can fix and retry.
            let failedIDs = Set(remaining.map(\.0))
            pending = pending.filter { failedIDs.contains($0.key) }
            pendingOrder = pendingOrder.filter { failedIDs.contains($0) }
            result = StatusLine(text: "Not applied — \(lastError.localizedDescription)", style: .error)
        } else {
            clearPending()
            result = StatusLine(text: "Applied ✓", style: .ok)
        }
        do {
            if let snap = try ConfigStore.snapshot(at: configURL) { baseline = snap }
        } catch {
            result = .unreadableConfig(error)
        }
        if wroteAny { onChanged?() }
    }
}
