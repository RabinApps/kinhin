import AppKit
import KinhinKit

/// Advanced → Containers: list, create and delete containers and volumes for
/// Docker or Apple container. Every delete asks for confirmation first, and
/// running containers (and kinhin's own CI runner containers) get a stronger
/// warning. Create opens a small form dialog.
@MainActor
final class ContainersViewController: NSViewController {
    /// Confirms a destructive action. Real UI shows an alert; tests inject a
    /// closure so no modal ever blocks them.
    var confirm: (_ title: String, _ message: String, _ button: String) -> Bool = { title, message, button in
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }
    /// Collects values for a create form; nil = cancelled. Injectable for tests.
    var promptForm: (_ title: String, _ fields: [(label: String, placeholder: String, value: String)]) -> [String]? = { title, fields in
        ContainersViewController.presentForm(title: title, fields: fields)
    }
    /// Builds the manager for a tool (tests inject a fake shell).
    var makeManager: (ContainerTool) -> ContainerManager = { ContainerManager(tool: $0) }

    private(set) var tool: ContainerTool = .docker
    private var containers: [ManagedContainer] = []
    private var volumes: [ManagedVolume] = []

    private let toolControl = NSSegmentedControl(
        labels: ContainerTool.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let listStack = NSStackView()
    private let progress = NSProgressIndicator()

    init() { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("created in code") }

    override func loadView() {
        toolControl.target = self
        toolControl.action = #selector(toolChanged)
        toolControl.controlSize = .small
        toolControl.selectedSegment = 0
        toolControl.setAccessibilityLabel("Container tool")

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 0
        statusLabel.preferredMaxLayoutWidth = FormKit.formWidth - 20
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false

        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshClicked))
        refresh.bezelStyle = .rounded
        refresh.controlSize = .small
        let top = FormKit.row([toolControl, FormKit.spacer(), progress, refresh])
        top.translatesAutoresizingMaskIntoConstraints = false

        let (scroll, column) = FormKit.scrollingColumn()
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 12
        column.addArrangedSubview(listStack)

        let container = NSView()
        container.addSubview(top)
        container.addSubview(statusLabel)
        container.addSubview(scroll)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: container.topAnchor),
            top.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            top.widthAnchor.constraint(equalToConstant: FormKit.formWidth),
            statusLabel.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            statusLabel.widthAnchor.constraint(equalToConstant: FormKit.formWidth),
            scroll.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        applyToolAvailability()
    }

    // MARK: Loading

    /// Disables tools that aren't installed and picks a usable default.
    private func applyToolAvailability() {
        for (index, candidate) in ContainerTool.allCases.enumerated() {
            toolControl.setEnabled(candidate.isInstalled, forSegment: index)
        }
        if !tool.isInstalled, let first = ContainerTool.allCases.first(where: \.isInstalled) {
            tool = first
        }
        toolControl.selectedSegment = ContainerTool.allCases.firstIndex(of: tool) ?? 0
    }

    func reload() {
        applyToolAvailability()
        guard tool.isInstalled else {
            containers = []
            volumes = []
            render()
            setStatus("\(tool.title) isn't installed on this Mac. Install Docker Desktop, OrbStack or colima, or Apple's container CLI.", error: true)
            return
        }
        let manager = makeManager(tool)
        progress.startAnimation(nil)
        Task { [weak self] in
            do {
                async let c = manager.containers()
                async let v = manager.volumes()
                let (loadedC, loadedV) = try await (c, v)
                self?.containers = loadedC
                self?.volumes = loadedV
                self?.setStatus("", error: false)
            } catch {
                self?.containers = []
                self?.volumes = []
                self?.setStatus(error.localizedDescription, error: true)
            }
            self?.progress.stopAnimation(nil)
            self?.render()
        }
    }

    /// Awaitable reload for tests.
    func reloadAndWait() async {
        applyToolAvailability()
        let manager = makeManager(tool)
        do {
            containers = try await manager.containers()
            volumes = try await manager.volumes()
            setStatus("", error: false)
        } catch {
            containers = []
            volumes = []
            setStatus(error.localizedDescription, error: true)
        }
        render()
    }

    private func setStatus(_ text: String, error: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = error ? .systemRed : .secondaryLabelColor
        statusLabel.isHidden = text.isEmpty
    }

    // MARK: Rendering

    private func render() {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let containerCard = FormKit.card(title: "Containers")
        if containers.isEmpty {
            containerCard.column.addArrangedSubview(FormKit.hint("No containers."))
        }
        for item in containers {
            containerCard.column.addArrangedSubview(containerRow(item))
        }
        let newContainer = NSButton(title: "New Container…", target: self, action: #selector(newContainerClicked))
        newContainer.bezelStyle = .rounded
        newContainer.identifier = NSUserInterfaceItemIdentifier("new-container")
        containerCard.column.addArrangedSubview(newContainer)
        listStack.addArrangedSubview(containerCard.card)

        let volumeCard = FormKit.card(title: "Volumes")
        if volumes.isEmpty {
            volumeCard.column.addArrangedSubview(FormKit.hint("No volumes."))
        }
        for item in volumes {
            volumeCard.column.addArrangedSubview(volumeRow(item))
        }
        let newVolume = NSButton(title: "New Volume…", target: self, action: #selector(newVolumeClicked))
        newVolume.bezelStyle = .rounded
        newVolume.identifier = NSUserInterfaceItemIdentifier("new-volume")
        volumeCard.column.addArrangedSubview(newVolume)
        listStack.addArrangedSubview(volumeCard.card)
    }

    private func containerRow(_ item: ManagedContainer) -> NSView {
        let name = NSTextField(labelWithString: item.name)
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        name.lineBreakMode = .byTruncatingMiddle
        let detail = NSTextField(labelWithString: [item.image, item.status.isEmpty ? item.state : item.status].filter { !$0.isEmpty }.joined(separator: " · "))
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = item.isRunning ? .systemGreen : .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        func small(_ title: String, _ action: Selector, _ prefix: String) -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.identifier = NSUserInterfaceItemIdentifier("\(prefix):\(item.id)")
            button.setAccessibilityLabel("\(title.replacingOccurrences(of: "…", with: "")) container \(item.name)")
            return button
        }
        let lifecycle: [NSButton] = item.isRunning
            ? [small("Stop", #selector(stopContainerClicked(_:)), "stop-container"),
               small("Restart", #selector(restartContainerClicked(_:)), "restart-container")]
            : [small("Start", #selector(startContainerClicked(_:)), "start-container")]
        let delete = small("Delete…", #selector(deleteContainerClicked(_:)), "delete-container")
        let row = FormKit.row([text, FormKit.spacer()] + lifecycle + [delete])
        row.widthAnchor.constraint(equalToConstant: FormKit.formWidth - 28).isActive = true
        return row
    }

    private func volumeRow(_ item: ManagedVolume) -> NSView {
        let name = NSTextField(labelWithString: item.name)
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        name.lineBreakMode = .byTruncatingMiddle
        let delete = NSButton(title: "Delete…", target: self, action: #selector(deleteVolumeClicked(_:)))
        delete.bezelStyle = .rounded
        delete.controlSize = .small
        delete.identifier = NSUserInterfaceItemIdentifier("delete-volume:\(item.name)")
        delete.setAccessibilityLabel("Delete volume \(item.name)")
        let row = FormKit.row([name, FormKit.spacer(), delete])
        row.widthAnchor.constraint(equalToConstant: FormKit.formWidth - 28).isActive = true
        return row
    }

    // MARK: Actions

    @objc private func toolChanged() {
        let index = toolControl.selectedSegment
        guard ContainerTool.allCases.indices.contains(index) else { return }
        tool = ContainerTool.allCases[index]
        reload()
    }

    @objc private func refreshClicked() { reload() }

    @objc private func newContainerClicked() { createContainer() }
    @objc private func newVolumeClicked() { createVolume() }

    @discardableResult
    func createContainer() -> Task<Void, Never>? {
        guard let values = promptForm("New Container", [
            ("Name", "my-container", ""),
            ("Image", "alpine:latest", ""),
        ]) else { return nil }
        return perform { try await $0.createContainer(name: values[0].trimmingCharacters(in: .whitespaces),
                                               image: values[1].trimmingCharacters(in: .whitespaces)) }
    }

    @discardableResult
    func createVolume() -> Task<Void, Never>? {
        guard let values = promptForm("New Volume", [("Name", "my-volume", "")]) else { return nil }
        return perform { try await $0.createVolume(name: values[0].trimmingCharacters(in: .whitespaces)) }
    }

    @objc private func deleteContainerClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, raw.hasPrefix("delete-container:") else { return }
        deleteContainer(id: String(raw.dropFirst("delete-container:".count)))
    }

    @objc private func startContainerClicked(_ sender: NSButton) { startContainer(id: id(from: sender, prefix: "start-container:")) }
    @objc private func stopContainerClicked(_ sender: NSButton) { stopContainer(id: id(from: sender, prefix: "stop-container:")) }
    @objc private func restartContainerClicked(_ sender: NSButton) { restartContainer(id: id(from: sender, prefix: "restart-container:")) }

    private func id(from sender: NSButton, prefix: String) -> String {
        let raw = sender.identifier?.rawValue ?? ""
        return raw.hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : ""
    }

    @discardableResult
    func startContainer(id: String) -> Task<Void, Never>? {
        guard containers.contains(where: { $0.id == id }) else { return nil }
        return perform { try await $0.startContainer(id: id) }
    }

    /// Stopping interrupts whatever the container is doing, so kinhin's own CI
    /// runners ask first; other containers stop immediately.
    @discardableResult
    func stopContainer(id: String) -> Task<Void, Never>? {
        guard let item = containers.first(where: { $0.id == id }) else { return nil }
        if item.isKinhinRunner,
           !confirm("Stop container “\(item.name)”?",
                    "This looks like a kinhin CI runner — stopping it cancels any job it is running.", "Stop") { return nil }
        return perform { try await $0.stopContainer(id: item.id) }
    }

    @discardableResult
    func restartContainer(id: String) -> Task<Void, Never>? {
        guard let item = containers.first(where: { $0.id == id }) else { return nil }
        if item.isKinhinRunner,
           !confirm("Restart container “\(item.name)”?",
                    "This looks like a kinhin CI runner — restarting it cancels any job it is running.", "Restart") { return nil }
        return perform { try await $0.restartContainer(id: item.id) }
    }

    @objc private func deleteVolumeClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, raw.hasPrefix("delete-volume:") else { return }
        deleteVolume(name: String(raw.dropFirst("delete-volume:".count)))
    }

    @discardableResult
    func deleteContainer(id: String) -> Task<Void, Never>? {
        guard let item = containers.first(where: { $0.id == id }) else { return nil }
        var message = "“\(item.name)” will be permanently removed."
        if item.isRunning { message += " It is running and will be stopped first." }
        if item.isKinhinRunner { message += " This looks like a kinhin CI runner — deleting it cancels any job it is running." }
        message += " This can’t be undone."
        guard confirm("Delete container “\(item.name)”?", message, "Delete") else { return nil }
        return perform { try await $0.deleteContainer(id: item.id, force: item.isRunning) }
    }

    @discardableResult
    func deleteVolume(name: String) -> Task<Void, Never>? {
        guard confirm("Delete volume “\(name)”?",
                      "The volume and all data stored in it will be permanently deleted. This can’t be undone.",
                      "Delete") else { return nil }
        return perform { try await $0.deleteVolume(name: name) }
    }

    /// Runs an operation, then reloads; failures show inline.
    @discardableResult
    private func perform(_ operation: @escaping (ContainerManager) async throws -> Void) -> Task<Void, Never> {
        let manager = makeManager(tool)
        progress.startAnimation(nil)
        return Task { [weak self] in
            do {
                try await operation(manager)
                await self?.reloadAndWait()
            } catch {
                self?.setStatus(error.localizedDescription, error: true)
            }
            self?.progress.stopAnimation(nil)
        }
    }

    var statusTextForTesting: String { statusLabel.stringValue }
    var containersForTesting: [ManagedContainer] { containers }
    var volumesForTesting: [ManagedVolume] { volumes }

    // MARK: Form dialog

    private static func presentForm(title: String, fields: [(label: String, placeholder: String, value: String)]) -> [String]? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let inputs = fields.map { field -> NSTextField in
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            input.placeholderString = field.placeholder
            input.stringValue = field.value
            input.setAccessibilityLabel(field.label)
            return input
        }
        let rows = zip(fields, inputs).map { field, input -> NSView in
            let label = NSTextField(labelWithString: field.label)
            label.font = .systemFont(ofSize: 12)
            label.widthAnchor.constraint(equalToConstant: 48).isActive = true
            return FormKit.row([label, input])
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 340, height: CGFloat(rows.count) * 32)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = inputs.first
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let values = inputs.map { $0.stringValue }
        return values.first(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) == nil ? values : nil
    }
}
