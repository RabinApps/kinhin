import AppKit
import KinhinKit

/// Advanced → Capacity: how many VMs the fleet runs and how big they are.
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
final class ConfigTabViewController: NSViewController {
    /// The config file this form edits (tests point it at a scratch file).
    var configURL: URL = Paths.config
    /// Fired once after an Apply wrote at least one change.
    var onEdited: (() -> Void)?

    private let stack = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let revertButton = NSButton(title: "Revert", target: nil, action: nil)
    private var snapshot: GeneralConfigEditor.Snapshot?

    /// Pending edits keyed by control id (last edit wins).
    private var pending: [String: GeneralConfigEditor.Field] = [:]
    private var pendingOrder: [String] = []
    private var steppers: [StepperRow] = []

    init() { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("ConfigTabViewController is created in code") }

    override func loadView() {
        let (scroll, column) = FormKit.scrollingColumn()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(stack)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        applyButton.target = self
        applyButton.action = #selector(applyClicked)
        applyButton.identifier = NSUserInterfaceItemIdentifier("capacity-apply")
        revertButton.bezelStyle = .rounded
        revertButton.target = self
        revertButton.action = #selector(revertClicked)
        revertButton.identifier = NSUserInterfaceItemIdentifier("capacity-revert")
        let footer = FormKit.row([statusLabel, FormKit.spacer(), revertButton, applyButton])
        footer.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(scroll)
        container.addSubview(footer)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            footer.widthAnchor.constraint(equalToConstant: FormKit.formWidth),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        reload()
    }

    // MARK: Loading & rendering

    func reload() {
        let yaml = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        guard let snap = try? GeneralConfigEditor.snapshot(from: yaml) else {
            statusLabel.stringValue = "config.yaml doesn't parse — use Advanced → App → Open config file."
            statusLabel.textColor = .systemRed
            return
        }
        snapshot = snap
        clearPending()
        render()
    }

    /// Test seam: render an explicit snapshot.
    func renderForTesting(_ snap: GeneralConfigEditor.Snapshot) {
        snapshot = snap
        clearPending()
        render()
    }

    private func render() {
        guard let snap = snapshot else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        steppers.removeAll()

        // How much work at once
        let work = FormKit.card(title: "How much runs at once")
        work.column.addArrangedSubview(
            stepperRow(
                "Fewest VMs kept ready", help: "0 means VMs only start when a job is waiting.",
                value: snap.minRunners, range: 0...16, id: "min-runners", make: { .minRunners($0) }))
        work.column.addArrangedSubview(
            stepperRow(
                "Most VMs at once", help: "The hard ceiling on VMs running together.",
                value: snap.maxRunners, range: 1...32, id: "max-runners", make: { .maxRunners($0) }))
        work.column.addArrangedSubview(
            stepperRow(
                "Jobs per VM", help: "Runners sharing one VM. 1 is safest; more share its CPU and RAM.",
                value: snap.runnersPerVM, range: 1...8, id: "runners-per-vm", make: { .runnersPerVM($0) }))
        work.column.addArrangedSubview(
            stepperRow(
                "Look for new jobs every (seconds)", help: nil,
                value: snap.pollInterval, range: 5...300, id: "poll", make: { .pollInterval($0) }))
        stack.addArrangedSubview(work.card)

        // Each VM
        let vm = FormKit.card(title: "Each VM")
        vm.column.addArrangedSubview(
            stepperRow(
                "CPU cores", help: nil, value: snap.vmCPU, range: 1...16, id: "vm-cpu", make: { .vmCPU($0) }))
        vm.column.addArrangedSubview(
            stepperRow(
                "Memory (GB)", help: nil, value: snap.vmMemoryGB, range: 2...64, id: "vm-mem", make: { .vmMemoryGB($0) }
            ))
        let ephemeral = NSButton(
            checkboxWithTitle: "Fresh VM for every job (recommended)", target: self,
            action: #selector(ephemeralToggled(_:)))
        ephemeral.state = snap.vmEphemeral ? .on : .off
        ephemeral.identifier = NSUserInterfaceItemIdentifier("ephemeral-toggle")
        vm.column.addArrangedSubview(ephemeral)
        let imageField = NSTextField(string: snap.image)
        imageField.identifier = NSUserInterfaceItemIdentifier("image-field")
        imageField.delegate = self
        imageField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        vm.column.addArrangedSubview(FormKit.row([FormKit.label("Base image"), imageField]))
        stack.addArrangedSubview(vm.card)

        // Headroom
        let reserve = FormKit.card(
            title: "Keep free for your Mac",
            subtitle: "Resources kinhin will not hand to VMs, so your Mac stays responsive.")
        reserve.column.addArrangedSubview(
            stepperRow(
                "CPU cores", help: nil, value: snap.reserveCPU, range: 0...12, id: "reserve-cpu",
                make: { .reserveCPU($0) }))
        reserve.column.addArrangedSubview(
            stepperRow(
                "Memory (GB)", help: nil, value: snap.reserveMemoryGB, range: 0...32, id: "reserve-mem",
                make: { .reserveMemoryGB($0) }))
        stack.addArrangedSubview(reserve.card)

        refreshApplyState()
    }

    // MARK: Pending edits

    private func stage(_ id: String, _ field: GeneralConfigEditor.Field) {
        if pending[id] == nil { pendingOrder.append(id) }
        pending[id] = field
        refreshApplyState()
    }

    private func clearPending() {
        pending.removeAll()
        pendingOrder.removeAll()
    }

    private func refreshApplyState() {
        let count = pending.count
        applyButton.isEnabled = count > 0
        revertButton.isEnabled = count > 0
        if count > 0 {
            statusLabel.stringValue =
                "\(count) unapplied change\(count == 1 ? "" : "s") — Apply restarts the fleet if needed."
            statusLabel.textColor = .systemOrange
        } else if !statusLabel.stringValue.hasPrefix("Applied") && !statusLabel.stringValue.hasPrefix("Not applied") {
            statusLabel.stringValue = ""
        }
    }

    var hasPendingChanges: Bool { !pending.isEmpty }

    @objc private func revertClicked() {
        statusLabel.stringValue = ""
        reload()
    }

    @objc private func applyClicked() { applyPending() }

    /// Writes every pending edit. Fields validate against each other (Max ≥
    /// Min), so a rejected write is retried after the others land.
    func applyPending() {
        var remaining = pendingOrder.compactMap { id in pending[id].map { (id, $0) } }
        var lastError: Error?
        var wroteAny = false
        for _ in 0..<max(1, remaining.count) {
            var failed: [(String, GeneralConfigEditor.Field)] = []
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
            statusLabel.stringValue = "Not applied — \(lastError.localizedDescription)"
            statusLabel.textColor = .systemRed
        } else {
            clearPending()
            statusLabel.stringValue = "Applied ✓"
            statusLabel.textColor = .systemGreen
        }
        if let yaml = try? String(contentsOf: configURL, encoding: .utf8),
            let snap = try? GeneralConfigEditor.snapshot(from: yaml)
        {
            snapshot = snap
        }
        if wroteAny { onEdited?() }
        applyButton.isEnabled = !pending.isEmpty
        revertButton.isEnabled = !pending.isEmpty
    }

    // MARK: Controls

    @objc private func ephemeralToggled(_ sender: NSButton) {
        stage("ephemeral", .vmEphemeral(sender.state == .on))
    }

    private func stepperRow(
        _ title: String, help: String?, value: Int, range: ClosedRange<Int>, id: String,
        make: @escaping (Int) -> GeneralConfigEditor.Field
    ) -> NSView {
        let row = StepperRow(value: value, range: range, id: id) { [weak self] newValue in
            self?.stage(id, make(newValue))
        }
        steppers.append(row)
        let line = FormKit.row([FormKit.label(title), FormKit.spacer(), row.view])
        line.widthAnchor.constraint(equalToConstant: FormKit.formWidth - 28).isActive = true
        guard let help else { return line }
        let column = NSStackView(views: [line, FormKit.hint(help)])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        return column
    }

    // MARK: Test hooks

    func stageForTesting(_ field: GeneralConfigEditor.Field, id: String) { stage(id, field) }
}

/// A number field and stepper that stay in sync and report the new value.
@MainActor
private final class StepperRow: NSObject, NSTextFieldDelegate {
    let field: NSTextField
    let stepper = NSStepper()
    let view: NSStackView
    private let range: ClosedRange<Int>
    private let onChange: (Int) -> Void

    init(value: Int, range: ClosedRange<Int>, id: String, onChange: @escaping (Int) -> Void) {
        self.range = range
        self.onChange = onChange
        field = NSTextField(string: String(value))
        field.identifier = NSUserInterfaceItemIdentifier(id)
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.widthAnchor.constraint(equalToConstant: 46).isActive = true
        stepper.minValue = Double(range.lowerBound)
        stepper.maxValue = Double(range.upperBound)
        stepper.increment = 1
        stepper.intValue = Int32(value)
        stepper.identifier = NSUserInterfaceItemIdentifier(id)
        view = NSStackView(views: [field, stepper])
        view.orientation = .horizontal
        view.spacing = 3
        super.init()
        stepper.target = self
        stepper.action = #selector(stepperChanged)
        field.delegate = self
    }

    @objc private func stepperChanged() {
        field.intValue = stepper.intValue
        onChange(Int(stepper.intValue))
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        let typed = min(max(Int(field.stringValue) ?? Int(stepper.intValue), range.lowerBound), range.upperBound)
        field.intValue = Int32(typed)
        guard typed != Int(stepper.intValue) else { return }
        stepper.intValue = Int32(typed)
        onChange(typed)
    }
}

extension ConfigTabViewController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
            field.identifier?.rawValue == "image-field"
        else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value != snapshot?.image else { return }
        stage("image", .image(value))
    }
}
