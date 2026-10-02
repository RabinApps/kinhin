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
                    "\(tool.title) isn't installed on this Mac. Install Docker Desktop, OrbStack or colima, or Apple's container CLI.",
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
    func refreshUsage() async {
        guard !busy, tool.isInstalled, containers.contains(where: \.isRunning) else { return }
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
                "Stop container “\(item.name)”?",
                "This looks like a kinhin CI runner — stopping it cancels any job it is running.", "Stop")
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
                "Restart container “\(item.name)”?",
                "This looks like a kinhin CI runner — restarting it cancels any job it is running.", "Restart")
        {
            return nil
        }
        return run { try await $0.restartContainer(id: item.id) }
    }

    @discardableResult
    func deleteContainer(id: String) -> Task<Void, Never>? {
        guard let item = containers.first(where: { $0.id == id }) else { return nil }
        var message = "“\(item.name)” will be permanently removed."
        if item.isRunning { message += " It is running and will be stopped first." }
        if item.isKinhinRunner {
            message += " This looks like a kinhin CI runner — deleting it cancels any job it is running."
        }
        message += " This can’t be undone."
        guard confirm("Delete container “\(item.name)”?", message, "Delete") else { return nil }
        return run(done: "Deleted container “\(item.name)”.") {
            try await $0.deleteContainer(id: item.id, force: item.isRunning)
        }
    }

    @discardableResult
    func deleteVolume(name: String) -> Task<Void, Never>? {
        guard
            confirm(
                "Delete volume “\(name)”?",
                "The volume and all data stored in it will be permanently deleted. This can’t be undone.",
                "Delete")
        else { return nil }
        return run(done: "Deleted volume “\(name)”.") { try await $0.deleteVolume(name: name) }
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
