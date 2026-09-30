import Foundation
import KinhinKit
import Observation

/// State and actions behind the Toolchains form: choose what gets
/// preinstalled into your runner images, and rebuild the images with it.
///
/// - Tools and stacks come from kinhin's catalog; each row says whether it
///   applies to macOS (tart), Linux (Docker / Apple container), or both.
/// - Nothing is written until **Apply**; a tool that needs Node (pnpm,
///   Playwright…) can't be applied without Node also selected, same as the
///   engine's own rule.
/// - Changes only reach an image when it is rebuilt, so each runtime has a
///   **Rebuild image…** button with a confirmation dialog.
@MainActor
@Observable
final class ToolchainsModel {
    /// How the grid is seeded when the form loads.
    enum Seed {
        /// From the saved config (every catalog entry ON when it has no
        /// `toolchains:` section) — the Advanced → Toolchains page.
        case fromConfig
        /// Every tool and stack OFF, nothing read from disk — the setup
        /// wizard's step, where the user explicitly picks what to preinstall.
        case allOff
    }

    typealias Line = StatusLine

    /// A runtime that is set up, with the platform its image targets.
    struct ImageRuntime {
        let runtime: RuntimeID
        let platform: ToolchainPlatform
    }

    @ObservationIgnored let seed: Seed
    var configURL: URL = Paths.config
    @ObservationIgnored var onEdited: (() -> Void)?

    /// Confirms a rebuild. Injectable so tests never open a modal.
    @ObservationIgnored var confirmRebuild: (_ runtime: RuntimeID, _ plan: ToolchainsConfigEditor.Plan) -> Bool = {
        runtime, plan in
        var text =
            "This replaces the current image with a fresh one that includes your saved tools. It can take 10–30 minutes and downloads a lot."
        text +=
            plan.installing.isEmpty
            ? "\n\nNo tools are selected: the image will have only the runner agents."
            : "\n\nInstalling: \(plan.installing.joined(separator: ", "))."
        if !plan.skipped.isEmpty {
            text += "\n\nSkipped (not available for this runtime): \(plan.skipped.joined(separator: ", "))."
        }
        return AlertKit.confirm(
            title: "Rebuild the \(ToolchainsModel.runtimeTitle(runtime))?", message: text,
            confirmTitle: "Rebuild Image", style: .informational)
    }
    /// Runs the actual image build for a runtime (real implementation below).
    @ObservationIgnored var rebuild: (_ runtime: RuntimeID, _ config: KinhinConfig) async throws -> Void = {
        runtime, cfg in
        try await ImageBuildService.rebuild(runtime, config: cfg)
    }

    // MARK: Selection

    private(set) var baseline = ToolchainsSelection()
    /// The selection being edited; only **Apply** writes it.
    var working = ToolchainsSelection()

    /// What each version field shows. Never blank: the default spec (or "—")
    /// fills in until the user types; what is stored goes through
    /// `normalizedVersion`, so neither a "node@" prefix nor the dash ever
    /// reaches config.yaml.
    var toolText: [String: String] = [:]
    var stackText: [String: String] = [:]
    var brewText = ""
    var specsText = ""

    // MARK: Display state

    private(set) var status = Line(text: "")
    private(set) var busy = false
    private(set) var imageRuntimes: [ImageRuntime] = []
    private var baseImageValues: [RuntimeID: String] = [:]

    init(seed: Seed = .fromConfig) {
        self.seed = seed
        resetFieldTexts()
    }

    // MARK: Derived

    var hasPendingChanges: Bool { working != baseline }
    var problems: [String] { ToolchainsConfigEditor.requirementProblems(working) }
    var applyEnabled: Bool { hasPendingChanges && problems.isEmpty && !busy }
    var revertEnabled: Bool { hasPendingChanges && !busy }
    var rebuildEnabled: Bool { !hasPendingChanges && !busy }

    func isToolOn(_ id: String) -> Bool { working.tools[id] != nil }
    func isStackOn(_ id: String) -> Bool { working.stacks[id] != nil }

    /// Whether a tool's version can be pinned (mise and npm installs).
    static func isVersionable(_ entry: ToolchainEntry) -> Bool {
        switch entry.installer {
        case .mise, .npm: return true
        default: return false
        }
    }

    func toolFieldEnabled(_ entry: ToolchainEntry) -> Bool { Self.isVersionable(entry) && isToolOn(entry.id) }

    func toolPlaceholder(_ entry: ToolchainEntry) -> String {
        Self.isVersionable(entry)
            ? (entry.defaultSpec.split(separator: "@").dropFirst().first.map(String.init) ?? "latest") : "—"
    }

    func stackFieldEnabled(_ stack: ToolchainStack) -> Bool { stack.versionKind != nil && isStackOn(stack.id) }

    func stackPlaceholder(_ stack: ToolchainStack) -> String {
        let selected = working.stacks[stack.id]
        return stack.versionKind == nil
            ? "—" : (selected?.isEmpty ?? true ? (stack.defaultVersion.isEmpty ? "latest" : stack.defaultVersion) : "—")
    }

    func baseImage(for runtime: RuntimeID) -> String? { baseImageValues[runtime] }

    // MARK: Loading

    /// Says why the config could not be loaded, instead of a blank grid.
    func showLoadError(_ error: Error) {
        status = Line(
            text:
                "config.yaml has a problem — \(error.localizedDescription). Use Advanced → App → Open config file.",
            style: .error)
    }

    /// A "everything on by default" selection mirroring the catalog, used to
    /// keep the grid populated before the user has written any config.
    func catalogSelection() -> ToolchainsSelection {
        var out = ToolchainsSelection()
        for entry in ToolchainCatalog.tools { out.tools[entry.id] = "" }
        for stack in ToolchainCatalog.stacks { out.stacks[stack.id] = "" }
        return out
    }

    /// Reloads the saved selection as the baseline and reseeds the grid per
    /// `seed`: every catalog entry ON when the config has no `toolchains:`
    /// section (so the page is never blank), or all OFF in the wizard, where
    /// the user must explicitly pick each toolchain.
    func reload() {
        let loaded: ToolchainsSelection
        do {
            loaded = try ToolchainsConfigEditor.selection(from: ConfigStore.text(at: configURL))
        } catch {
            showLoadError(error)
            return
        }
        baseline = loaded
        switch seed {
        case .allOff: working = ToolchainsSelection()
        case .fromConfig: working = loaded.isEmpty ? catalogSelection() : loaded
        }
        resetFieldTexts()
        refreshImages()
        refreshState()
    }

    /// Re-derives every field's text from `working`.
    func resetFieldTexts() {
        toolText = Dictionary(
            uniqueKeysWithValues: ToolchainCatalog.tools.map { entry in
                let selected = working.tools[entry.id]
                return (
                    entry.id,
                    selected.flatMap { !$0.isEmpty ? $0 : nil } ?? (entry.defaultSpec.isEmpty ? "—" : entry.defaultSpec)
                )
            })
        stackText = Dictionary(
            uniqueKeysWithValues: ToolchainCatalog.stacks.map { stack in
                let selected = working.stacks[stack.id]
                return (
                    stack.id,
                    selected.flatMap { !$0.isEmpty ? $0 : nil }
                        ?? (stack.defaultVersion.isEmpty ? "—" : stack.defaultVersion)
                )
            })
        brewText = working.extraBrew.joined(separator: ", ")
        specsText = working.extraSpecs.joined(separator: ", ")
    }

    /// One image row per runtime that is actually set up.
    private func refreshImages() {
        let snapshot = ConfigStore.snapshotOrLog(at: configURL)
        var runtimes: [ImageRuntime] = []
        if TartController.isInstalled() { runtimes.append(ImageRuntime(runtime: .tart, platform: .macOS)) }
        if snapshot?.container != nil { runtimes.append(ImageRuntime(runtime: .appleContainer, platform: .linux)) }
        if snapshot?.docker != nil { runtimes.append(ImageRuntime(runtime: .docker, platform: .linux)) }
        imageRuntimes = runtimes
        baseImageValues = [:]
        for item in runtimes where item.runtime != .tart {
            if let value = snapshot?.baseImage(for: item.runtime) { baseImageValues[item.runtime] = value }
        }
    }

    // MARK: Editing (working copy only; Apply writes)

    func setTool(_ id: String, on: Bool) {
        working.tools[id] = on ? ToolchainsConfigEditor.normalizedVersion(toolText[id] ?? "", for: id) : nil
        refreshState()
    }

    func setStack(_ id: String, on: Bool) {
        working.stacks[id] = on ? ToolchainsConfigEditor.normalizedVersion(stackText[id] ?? "", for: id) : nil
        refreshState()
    }

    func setToolText(_ id: String, _ text: String) {
        toolText[id] = text
        if working.tools[id] != nil {
            working.tools[id] = ToolchainsConfigEditor.normalizedVersion(
                text.trimmingCharacters(in: .whitespaces), for: id)
        }
        refreshState()
    }

    func setStackText(_ id: String, _ text: String) {
        stackText[id] = text
        if working.stacks[id] != nil {
            working.stacks[id] = ToolchainsConfigEditor.normalizedVersion(
                text.trimmingCharacters(in: .whitespaces), for: id)
        }
        refreshState()
    }

    func setBrewText(_ text: String) {
        brewText = text
        working.extraBrew = Self.splitList(text.trimmingCharacters(in: .whitespaces))
        refreshState()
    }

    func setSpecsText(_ text: String) {
        specsText = text
        working.extraSpecs = Self.splitList(text.trimmingCharacters(in: .whitespaces))
        refreshState()
    }

    func setShareCache(_ on: Bool) {
        working.shareCache = on
        refreshState()
    }

    static func splitList(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: State

    func refreshState() {
        let pending = hasPendingChanges
        let problems = self.problems
        if !problems.isEmpty {
            status = Line(text: problems.joined(separator: " "), style: .warn)
        } else if pending {
            status = Line(text: "Unapplied changes. Apply, then rebuild an image.", style: .warn)
        } else if !busy, !status.text.hasPrefix("Applied"), !status.text.hasPrefix("Rebuilt"),
            !status.text.hasPrefix("Not")
        {
            status = Line(text: "")
        }
    }

    func revert() {
        status = Line(text: "")
        reload()
    }

    func apply() {
        do {
            try ToolchainsConfigEditor.apply(working, to: configURL)
            baseline = working
            status = Line(text: "Applied ✓ — rebuild an image below to use it.", style: .ok)
            refreshState()
            onEdited?()
        } catch {
            status = Line(text: "Not applied — \(error.localizedDescription)", style: .error)
        }
    }

    /// Writes the chosen base image; on failure says why and shows what is
    /// actually saved.
    func saveBaseImage(_ value: String?, for runtime: RuntimeID) {
        do {
            try GeneralConfigEditor.setBaseImage(value, for: runtime, at: configURL)
            baseImageValues[runtime] = value
            status = Line(text: "Base image saved — rebuild the image to use it.")
            onEdited?()
        } catch {
            AlertKit.present(error: error, title: "Couldn't save the base image")
            baseImageValues[runtime] = ConfigStore.snapshotOrLog(at: configURL)?.baseImage(for: runtime)
        }
    }

    // MARK: Rebuild

    @discardableResult
    func startRebuild(_ runtime: RuntimeID) -> Task<Void, Never>? {
        guard !hasPendingChanges else { return nil }
        let platform: ToolchainPlatform = runtime == .tart ? .macOS : .linux
        guard confirmRebuild(runtime, ToolchainsConfigEditor.plan(baseline, for: platform)) else { return nil }
        let cfg: KinhinConfig
        do {
            cfg = try ConfigLoader.load(from: configURL)
        } catch {
            status = Line(text: "Not started — \(error.localizedDescription)", style: .error)
            return nil
        }
        busy = true
        status = Line(text: "Rebuilding the \(Self.runtimeTitle(runtime))… this can take a while.")
        refreshState()
        let rebuild = self.rebuild
        return Task { [weak self] in
            do {
                try await rebuild(runtime, cfg)
                self?.status = Line(text: "Rebuilt the \(Self.runtimeTitle(runtime)) ✓", style: .ok)
                self?.reload()
            } catch {
                self?.status = Line(text: "Not rebuilt — \(error.localizedDescription)", style: .error)
            }
            self?.busy = false
            self?.refreshState()
        }
    }

    static func runtimeTitle(_ runtime: RuntimeID) -> String {
        switch runtime {
        case .tart: return "macOS image (tart)"
        case .appleContainer: return "Linux image (Apple container)"
        case .docker: return "Linux image (Docker)"
        case .host: return "host"
        }
    }

    // MARK: Test hooks

    func toggleToolForTesting(_ id: String, version: String = "", on: Bool = true) {
        working.tools[id] = on ? version : nil
        refreshState()
    }
    func toggleStackForTesting(_ id: String, on: Bool = true) {
        working.stacks[id] = on ? "" : nil
        refreshState()
    }
    func setShareCacheForTesting(_ on: Bool) { setShareCache(on) }
    var statusTextForTesting: String { status.text }
    var applyEnabledForTesting: Bool { applyEnabled }
    var rebuildEnabledForTesting: [RuntimeID: Bool] {
        Dictionary(uniqueKeysWithValues: imageRuntimes.map { ($0.runtime, rebuildEnabled) })
    }
}
