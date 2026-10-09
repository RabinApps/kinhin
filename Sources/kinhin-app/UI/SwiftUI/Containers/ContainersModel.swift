import Foundation
import KinhinKit
import Observation

/// State and actions behind Advanced → Containers: list, start/stop/restart
/// and delete containers, and list and delete volumes, for Docker or Apple
/// container. Every delete asks for confirmation first, and running containers
/// (and kinhin's own CI runner containers) get a stronger warning. Nothing here
/// creates containers or volumes: kinhin's engine creates its own runner
/// containers, and never uses named volumes.
@MainActor
@Observable
final class ContainersModel {
    enum Lifecycle: String {
        case start = "Start"
        case stop = "Stop"
        case restart = "Restart"

        /// The button title (the raw value stays the stable English identifier).
        var label: String {
            switch self {
            case .start: return String(localized: "Start", bundle: .l10n, comment: "Container row button")
            case .stop: return String(localized: "Stop", bundle: .l10n, comment: "Container row button")
            case .restart: return String(localized: "Restart", bundle: .l10n, comment: "Container row button")
            }
        }

        /// What VoiceOver says for the row button; %@ is the container name.
        func accessibilityLabel(container name: String) -> String {
            switch self {
            case .start:
                return String(
                    localized: "Start container \(name)", bundle: .l10n,
                    comment: "VoiceOver label of a container row button; %@ is the container name")
            case .stop:
                return String(
                    localized: "Stop container \(name)", bundle: .l10n,
                    comment: "VoiceOver label of a container row button; %@ is the container name")
            case .restart:
                return String(
                    localized: "Restart container \(name)", bundle: .l10n,
                    comment: "VoiceOver label of a container row button; %@ is the container name")
            }
        }
    }

    /// Confirms a destructive action. Real UI shows an alert; tests inject a
    /// closure so no modal ever blocks them.
    @ObservationIgnored var confirm: (_ title: String, _ message: String, _ button: String) -> Bool = {
        title, message, button in
        AlertKit.confirm(title: title, message: message, confirmTitle: button, destructive: true)
    }
    /// Builds the manager for a tool (tests inject a fake shell).
    @ObservationIgnored var makeManager: (ContainerTool) -> ContainerManager = { ContainerManager(tool: $0) }

    private(set) var tool: ContainerTool = .docker
    private(set) var containers: [ManagedContainer] = []
    private(set) var volumes: [ManagedVolume] = []
    /// Live CPU/RAM of running containers, keyed by container name.
    private(set) var usage: [String: ResourceUsage] = [:]
    private(set) var status = StatusLine(text: "")
    private(set) var busy = false
    private var installed: [ContainerTool] = []
    @ObservationIgnored private var refreshingUsage = false

    /// The tools the picker offers: the installed ones, or all of them when
    /// none is (so the "isn't installed" message still has a tool to name).
    var selectableTools: [ContainerTool] { installed.isEmpty ? ContainerTool.allCases : installed }

    // MARK: - Loading

    /// Drops tools that aren't installed and picks a usable default.
    private func applyToolAvailability() {
        installed = ContainerTool.allCases.filter(\.isInstalled)
        if !tool.isInstalled, let first = installed.first { tool = first }
    }

    func select(_ candidate: ContainerTool) {
        tool = candidate
        reload()
    }

    func reload() {
        applyToolAvailability()
        guard tool.isInstalled else {
            containers = []
            volumes = []
            usage = [:]
            status = StatusLine(
                text:
                    String(
                        localized:
                            "\(tool.title) isn't installed on this Mac. Install Docker Desktop, OrbStack or colima, or Apple's container CLI.",
                        bundle: .l10n, comment: "Containers tab status; %@ is the container tool name"),
                style: .error)
            return
        }
        busy = true
        Task { [weak self] in
            await self?.reloadAndWait()
            self?.busy = false
        }
    }

    /// Awaitable reload for tests.
    func reloadAndWait() async {
        applyToolAvailability()
        let manager = makeManager(tool)
        do {
            containers = try await manager.containers()
            volumes = try await manager.volumes()
            status = StatusLine(text: "")
            // Best effort: a stats failure must not hide the container list.
            usage = (try? await manager.stats()) ?? [:]
        } catch {
            containers = []
            volumes = []
            usage = [:]
            status = StatusLine(text: error.localizedDescription, style: .error)
        }
    }

    /// Re-reads only the live CPU/RAM numbers (the Containers tab calls this
    /// every few seconds while visible). Best effort; skipped while a reload
    /// or action is in flight and when nothing is running.
    /// A tick is skipped while the previous one is still running (a slow
    /// `docker stats` must not pile up overlapping calls).
    func refreshUsage() async {
        guard !busy, !refreshingUsage, tool.isInstalled, containers.contains(where: \.isRunning) else { return }
        refreshingUsage = true
        defer { refreshingUsage = false }
        usage = (try? await makeManager(tool).stats()) ?? usage
    }

    // MARK: - Actions

    func lifecycle(for item: ManagedContainer) -> [Lifecycle] {
        item.isRunning ? [.stop, .restart] : [.start]
    }

    func perform(_ action: Lifecycle, id: String) {
        switch action {
        case .start: startContainer(id: id)
        case .stop: stopContainer(id: id)
        case .restart: restartContainer(id: id)
        }
    }

    @discardableResult
    func startContainer(id: String) -> Task<Void, Never>? {
        guard containers.contains(where: { $0.id == id }) else { return nil }
        return run { try await $0.startContainer(id: id) }
    }

    /// Stopping interrupts whatever the container is doing, so kinhin's own CI
    /// runners ask first; other containers stop immediately.
    @discardableResult
    func stopContainer(id: String) -> Task<Void, Never>? {
        guard let item = containers.first(where: { $0.id == id }) else { return nil }
        if item.isKinhinRunner,
            !confirm(
                String(
                    localized: "Stop container “\(item.name)”?", bundle: .l10n,
                    comment: "Confirmation title; %@ is the container name"),
                String(
                    localized: "This looks like a kinhin CI runner — stopping it cancels any job it is running.",
                    bundle: .l10n, comment: "Confirmation body for stopping a kinhin runner container"),
                String(localized: "Stop", bundle: .l10n, comment: "Confirm button that stops a container"))
        {
            return nil
        }
        return run { try await $0.stopContainer(id: item.id) }
    }

    @discardableResult
    func restartContainer(id: String) -> Task<Void, Never>? {
        guard let item = containers.first(where: { $0.id == id }) else { return nil }
        if item.isKinhinRunner,
            !confirm(
                String(
                    localized: "Restart container “\(item.name)”?", bundle: .l10n,
                    comment: "Confirmation title; %@ is the container name"),
                String(
                    localized: "This looks like a kinhin CI runner — restarting it cancels any job it is running.",
                    bundle: .l10n, comment: "Confirmation body for restarting a kinhin runner container"),
                String(localized: "Restart", bundle: .l10n, comment: "Confirm button that restarts a container"))
        {
            return nil
        }
        return run { try await $0.restartContainer(id: item.id) }
    }

    @discardableResult
    func deleteContainer(id: String) -> Task<Void, Never>? {
        guard let item = containers.first(where: { $0.id == id }) else { return nil }
        // One whole sentence set per case, so a translation can reword each combination.
        let message: String
        switch (item.isRunning, item.isKinhinRunner) {
        case (false, false):
            message = String(
                localized: "“\(item.name)” will be permanently removed. This can’t be undone.", bundle: .l10n,
                comment: "Delete-container confirmation body; %@ is the container name")
        case (true, false):
            message = String(
                localized:
                    "“\(item.name)” will be permanently removed. It is running and will be stopped first. This can’t be undone.",
                bundle: .l10n,
                comment: "Delete-container confirmation body for a running container; %@ is the container name")
        case (false, true):
            message = String(
                localized:
                    "“\(item.name)” will be permanently removed. This looks like a kinhin CI runner — deleting it cancels any job it is running. This can’t be undone.",
                bundle: .l10n,
                comment: "Delete-container confirmation body for a kinhin runner; %@ is the container name")
        case (true, true):
            message = String(
                localized:
                    "“\(item.name)” will be permanently removed. It is running and will be stopped first. This looks like a kinhin CI runner — deleting it cancels any job it is running. This can’t be undone.",
                bundle: .l10n,
                comment: "Delete-container confirmation body for a running kinhin runner; %@ is the container name")
        }
        guard
            confirm(
                String(
                    localized: "Delete container “\(item.name)”?", bundle: .l10n,
                    comment: "Confirmation title; %@ is the container name"), message,
                String(localized: "Delete", bundle: .l10n, comment: "Destructive confirm button"))
        else { return nil }
        return run(
            done: String(
                localized: "Deleted container “\(item.name)”.", bundle: .l10n,
                comment: "Containers tab status; %@ is the container name")
        ) {
            try await $0.deleteContainer(id: item.id, force: item.isRunning)
        }
    }

    @discardableResult
    func deleteVolume(name: String) -> Task<Void, Never>? {
        guard
            confirm(
                String(
                    localized: "Delete volume “\(name)”?", bundle: .l10n,
                    comment: "Confirmation title; %@ is the volume name"),
                String(
                    localized:
                        "The volume and all data stored in it will be permanently deleted. This can’t be undone.",
                    bundle: .l10n, comment: "Delete-volume confirmation body"),
                String(localized: "Delete", bundle: .l10n, comment: "Destructive confirm button"))
        else { return nil }
        return run(
            done: String(
                localized: "Deleted volume “\(name)”.", bundle: .l10n,
                comment: "Containers tab status; %@ is the volume name")
        ) { try await $0.deleteVolume(name: name) }
    }

    /// Runs an operation, then reloads; failures show inline.
    private func run(done message: String? = nil, _ operation: @escaping (ContainerManager) async throws -> Void)
        -> Task<Void, Never>
    {
        let manager = makeManager(tool)
        busy = true
        return Task { [weak self] in
            do {
                try await operation(manager)
                await self?.reloadAndWait()
                if let message { self?.status = StatusLine(text: message) }
            } catch {
                self?.status = StatusLine(text: error.localizedDescription, style: .error)
            }
            self?.busy = false
        }
    }
}
