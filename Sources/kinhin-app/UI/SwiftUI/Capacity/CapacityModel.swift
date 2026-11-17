import Foundation
import KinhinKit
import Observation

/// State and actions behind the staged part of the Runtimes page: the Fleet capacity card (how many VMs the fleet
/// runs, how big they are, what stays free for the Mac) and every runtime's "Keep idle" floor. (The runtime cards'
/// tool and image controls are `MacToolsModel`; routes and pools are `RuntimesModel`.)
///
/// Nothing is written while the user types or clicks a stepper. Edits collect
/// as pending changes and are written together, once, when the user presses
/// **Apply** — which also means the running fleet restarts at most once
/// (instead of after every stepper click). Every write goes through
/// `GeneralConfigEditor` (comments preserved, engine-validated).
///
/// The `min_idle` floors are checked against the engine's own rules (`MinIdleValidation`) on the config the edits
/// would produce, so an impossible combination shows its error next to the control and cannot be applied.
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
    /// Pending `images[].min_idle` edits by image name (an image has no `Field`; they are written through
    /// `ImagesConfigEditor`).
    private var pendingImages: [String: Int] = [:]
    /// Every `min_idle` rule the staged values would break, recomputed on each edit. Empty with nothing staged.
    private(set) var minIdleIssues: [MinIdleIssue] = []
    /// The outcome of the last load or Apply; cleared by the next edit.
    private var result = StatusLine(text: "")

    var hasPendingChanges: Bool { pendingCount > 0 }
    var pendingCount: Int { pending.count + pendingImages.count }
    /// Apply needs something staged and no `min_idle` rule broken.
    var canApply: Bool { hasPendingChanges && minIdleIssues.isEmpty }

    var status: StatusLine {
        if !result.text.isEmpty { return result }
        if hasPendingChanges, let issue = minIdleIssues.first {
            return StatusLine(
                text: String(
                    localized: "Not applied — \(issue.message)", bundle: .l10n,
                    comment: "Capacity form status; %@ is the reason the edit wasn't applied"), style: .error)
        }
        let count = pendingCount
        guard count > 0 else { return result }
        return StatusLine(
            text: String(
                localized: "\(count) unapplied changes — Apply restarts the fleet if needed.", bundle: .l10n,
                comment: "Capacity form status; plural by number of pending edits"),
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
                    String(
                        localized:
                            "config.yaml has a problem — \(error.localizedDescription). Fix it with Edit YAML…",
                        bundle: .l10n, comment: "Capacity form status; %@ is the config error"),
                style: .error)
        }
    }

    /// Re-reads the config after something else wrote it (a runtime switch, an image edit, a route) and puts the
    /// staged edits back on top, so the page never shows stale untouched values and never loses unapplied ones.
    func refreshFromDisk() {
        // A config that no longer loads keeps the page as it is; the Runtimes model says why it is unreadable.
        guard let loaded = try? ConfigStore.snapshot(at: configURL) else { return }
        baseline = loaded
        draft = loaded
        for id in pendingOrder {
            if let field = pending[id] { Self.assign(field, to: &draft) }
        }
        for (name, value) in pendingImages {
            if let index = draft?.images.firstIndex(where: { $0.name == name }) {
                draft?.images[index].minIdle = value
            } else {
                pendingImages[name] = nil  // the image was removed meanwhile
            }
        }
        recomputeIssues()
    }

    // MARK: - Editing

    /// Sets a numeric control (clamped to its range): the draft always takes the clamped value (so a field showing
    /// an out-of-range number snaps back); the edit is staged unless it equals what is on disk, which un-stages it.
    func set(_ id: String, to value: Int, in range: ClosedRange<Int>, make: (Int) -> Field) {
        guard draft != nil else { return }
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        let field = make(clamped)
        Self.assign(field, to: &draft)
        if let base = baseline, Self.intValue(of: field, in: base) == clamped {
            unstage(id)
        } else {
            stage(id, field)
        }
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

    /// Stages `images[name].min_idle`; un-stages it when it equals what is on disk.
    func setImageMinIdle(_ name: String, to value: Int) {
        guard let index = draft?.images.firstIndex(where: { $0.name == name }) else { return }
        let clamped = min(max(value, Self.keepIdleRange.lowerBound), Self.keepIdleRange.upperBound)
        draft?.images[index].minIdle = clamped
        result = StatusLine(text: "")
        if baseline?.images.first(where: { $0.name == name })?.minIdle == clamped {
            pendingImages[name] = nil
        } else {
            pendingImages[name] = clamped
        }
        recomputeIssues()
    }

    func imageMinIdle(_ name: String) -> Int { draft?.images.first { $0.name == name }?.minIdle ?? 0 }

    func stage(_ id: String, _ field: Field) {
        result = StatusLine(text: "")
        if pending[id] == nil { pendingOrder.append(id) }
        pending[id] = field
        recomputeIssues()
    }

    private func unstage(_ id: String) {
        pending[id] = nil
        pendingOrder.removeAll { $0 == id }
        recomputeIssues()
    }

    private func clearPending() {
        pending.removeAll()
        pendingOrder.removeAll()
        pendingImages.removeAll()
        minIdleIssues = []
    }

    func revert() { reload() }

    // MARK: - Ranges

    /// The Keep idle steppers' range (the engine's own ceiling is `max_runners`; its rules say the rest).
    static let keepIdleRange = 0...32

    // MARK: - Validation

    /// The config the staged values would produce, checked by the engine's own `min_idle` rules. A config that does
    /// not load today has nothing to compare against, so it reports nothing here (the page says it is unreadable).
    private func recomputeIssues() {
        minIdleIssues = []
        guard hasPendingChanges, let draft else { return }
        // try?: a config that does not load has no floors to check; the page already says it is unreadable.
        guard let text = try? ConfigStore.text(at: configURL) else { return }
        // try?: same reason as above.
        guard var config = try? ConfigLoader.parse(text) else { return }
        config.maxRunners = draft.maxRunners
        config.minRunners = draft.minRunners
        config.warmPool = draft.warmPool
        config.imageMinIdle = draft.imageMinIdle
        for index in config.images.indices {
            if let staged = draft.images.first(where: { $0.name == config.images[index].name }) {
                config.images[index].minIdle = staged.minIdle
            }
        }
        if let staged = draft.container { config.container?.minIdle = staged.minIdle }
        if let staged = draft.docker {
            config.docker?.minIdle = staged.minIdle
            config.docker?.maxSlots = staged.maxSlots
        }
        minIdleIssues = MinIdleValidation.issues(for: config)
    }

    /// The first rule broken for one floor, for the error text under its stepper.
    func issue(for field: MinIdleIssue.Field) -> String? {
        guard hasPendingChanges else { return nil }
        return minIdleIssues.first { $0.field == field }?.message
    }

    // MARK: - Applying

    /// Writes every pending edit. Fields validate against each other (Max ≥
    /// Min), so a rejected write is retried after the others land.
    func applyPending() {
        guard canApply else { return }
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
        var imagesFailed = false
        if !pendingImages.isEmpty {
            do {
                var images = try ConfigStore.snapshot(at: configURL)?.images ?? []
                for index in images.indices {
                    if let value = pendingImages[images[index].name] { images[index].minIdle = value }
                }
                try ImagesConfigEditor.apply(images, to: configURL)
                wroteAny = true
                pendingImages.removeAll()
            } catch {
                imagesFailed = true
                lastError = error
            }
        }
        if let lastError, !remaining.isEmpty || imagesFailed {
            // Keep only what failed pending, so the user can fix and retry.
            let failedIDs = Set(remaining.map(\.0))
            pending = pending.filter { failedIDs.contains($0.key) }
            pendingOrder = pendingOrder.filter { failedIDs.contains($0) }
            result = StatusLine(
                text: String(
                    localized: "Not applied — \(lastError.localizedDescription)", bundle: .l10n,
                    comment: "Capacity form status; %@ is the reason the edit wasn't applied"), style: .error)
        } else {
            clearPending()
            result = StatusLine(
                text: String(
                    localized: "Applied ✓", bundle: .l10n, comment: "Capacity form status after a successful apply"),
                style: .ok)
        }
        do {
            if let snap = try ConfigStore.snapshot(at: configURL) {
                baseline = snap
                if !hasPendingChanges { draft = snap }
            }
        } catch {
            result = .unreadableConfig(error)
        }
        recomputeIssues()
        if wroteAny { onChanged?() }
    }

    // MARK: - Field plumbing

    /// The number a numeric field carries in `snapshot` (nil for a field this form does not stage, or a section
    /// the config does not have).
    static func intValue(of field: Field, in snapshot: Snapshot) -> Int? {
        switch field {
        case .minRunners: return snapshot.minRunners
        case .warmPool: return snapshot.warmPool
        case .maxRunners: return snapshot.maxRunners
        case .runnersPerVM: return snapshot.runnersPerVM
        case .pollInterval: return snapshot.pollInterval
        case .vmCPU: return snapshot.vmCPU
        case .vmMemoryGB: return snapshot.vmMemoryGB
        case .reserveCPU: return snapshot.reserveCPU
        case .reserveMemoryGB: return snapshot.reserveMemoryGB
        case .reserveDiskGB: return snapshot.reserveDiskGB
        case .imageMinIdle: return snapshot.imageMinIdle
        case .containerMinIdle: return snapshot.container?.minIdle
        case .dockerMinIdle: return snapshot.docker?.minIdle
        case .dockerMaxSlots: return snapshot.docker?.maxSlots
        default: return nil
        }
    }

    /// Puts a staged field's value into `snapshot` (what the controls show).
    static func assign(_ field: Field, to snapshot: inout Snapshot?) {
        guard snapshot != nil else { return }
        switch field {
        case .minRunners(let n): snapshot?.minRunners = n
        case .warmPool(let n): snapshot?.warmPool = n
        case .maxRunners(let n): snapshot?.maxRunners = n
        case .runnersPerVM(let n): snapshot?.runnersPerVM = n
        case .pollInterval(let n): snapshot?.pollInterval = n
        case .vmCPU(let n): snapshot?.vmCPU = n
        case .vmMemoryGB(let n): snapshot?.vmMemoryGB = n
        case .reserveCPU(let n): snapshot?.reserveCPU = n
        case .reserveMemoryGB(let n): snapshot?.reserveMemoryGB = n
        case .reserveDiskGB(let n): snapshot?.reserveDiskGB = n
        case .imageMinIdle(let n): snapshot?.imageMinIdle = n
        case .containerMinIdle(let n): snapshot?.container?.minIdle = n
        case .dockerMinIdle(let n): snapshot?.docker?.minIdle = n
        case .dockerMaxSlots(let n): snapshot?.docker?.maxSlots = n
        case .autoResume(let on): snapshot?.autoResume = on
        case .vmEphemeral(let on): snapshot?.vmEphemeral = on
        case .image(let text): snapshot?.image = text
        default: break
        }
    }
}
