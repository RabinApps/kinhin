import AppKit
import KinhinKit

// Fleet and container label editing.
@MainActor
extension RuntimesWindowController {
    // MARK: Labels editing

    /// The labels card: the fleet's base label set and, when the container
    /// runtime is configured, container.labels. Both edit through the
    /// validated LabelsConfigEditor; the container marker is protected.
    func makeLabelsCard() -> NSView {
        let card = LayerStyleView(frame: .zero)
        card.styleLayer = { layer in
            layer.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer.cornerRadius = 8
            layer.borderWidth = 1
            layer.borderColor = NSColor.separatorColor.cgColor
        }

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(column)

        let yaml = ConfigStore.textOrLog(at: configURL)

        // Fleet base labels.
        column.addArrangedSubview(NSTextField(labelWithString: "Fleet base labels (every runner):"))
        let fleetLabels = LabelsConfigEditor.labels(in: yaml, scope: .fleet)
        let fleetField = NSTextField(string: fleetLabels.joined(separator: ", "))
        fleetField.font = .systemFont(ofSize: 12)
        fleetField.identifier = NSUserInterfaceItemIdentifier("fleet-labels-field")
        fleetField.widthAnchor.constraint(equalToConstant: 440).isActive = true
        fleetField.delegate = self
        column.addArrangedSubview(fleetField)

        let fleetHint = NSTextField(
            labelWithString: "Comma-separated. Jobs must request a subset of these via runs-on:.")
        fleetHint.font = .systemFont(ofSize: 11)
        fleetHint.textColor = .tertiaryLabelColor
        column.addArrangedSubview(fleetHint)

        // Container extra labels (only when the runtime is configured).
        if viewModel?.containerConfigured == true {
            column.addArrangedSubview(NSView())
            column.addArrangedSubview(NSTextField(labelWithString: "Container extra labels (appleContainer pool):"))
            let containerLabels = LabelsConfigEditor.labels(in: yaml, scope: .container)
            let containerField = NSTextField(string: containerLabels.joined(separator: ", "))
            containerField.font = .systemFont(ofSize: 12)
            containerField.identifier = NSUserInterfaceItemIdentifier("container-labels-field")
            containerField.widthAnchor.constraint(equalToConstant: 440).isActive = true
            containerField.delegate = self
            column.addArrangedSubview(containerField)

            let containerHint = NSTextField(
                labelWithString: "Merged with the kinhin-container marker (always present) at pool build.")
            containerHint.font = .systemFont(ofSize: 11)
            containerHint.textColor = .tertiaryLabelColor
            column.addArrangedSubview(containerHint)
        }

        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            column.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            column.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
        ])
        card.widthAnchor.constraint(equalToConstant: 505).isActive = true
        return card
    }

    /// Parse a comma-separated label list.
    static func parseLabelList(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Commit a label field edit (called on Enter or focus loss).
    func commitLabels(field: NSTextField, scope: LabelsConfigEditor.Scope) {
        let labels = Self.parseLabelList(field.stringValue)
        do {
            try LabelsConfigEditor.apply(labels, scope: scope, to: configURL)
            Log.info("runtimes-pane", "\(scope == .fleet ? "fleet" : "container") labels updated")
            onEdited?()
        } catch {
            presentError(error)
            // Snap the field back to the on-disk truth.
            let yaml = ConfigStore.textOrLog(at: configURL)
            field.stringValue = LabelsConfigEditor.labels(in: yaml, scope: scope).joined(separator: ", ")
        }
    }

    /// "On this Mac" row title: what's installed vs not, and whether the
    /// config actually uses it.
    static func availabilityTitle(_ id: RuntimeID, health: RuntimeHealth, inUse: Bool) -> String {
        let name: String
        switch id {
        case .tart: name = "🍎 Tart (macOS VMs)"
        case .appleContainer: name = "🐧 Apple container (Linux)"
        case .docker: name = "🐳 Docker (Linux)"
        case .host: name = "Host"
        }
        let state: String
        switch health {
        case .ready: state = "installed ✓"
        case .missing: state = "not installed"
        case .broken: state = "installed — needs attention"
        }
        return "\(name) — \(state)\(inUse ? " · used by your fleet" : " · not used by your config")"
    }

    /// A small colored health chip: green ready / red not ready /
    /// grey "checking…" while the probe pass is in flight.
    static func healthChip(_ health: RuntimeHealth?, probing: Bool) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        switch health {
        case .ready:
            label.stringValue = "● ready"
            label.textColor = .systemGreen
        case .missing(let tool, _):
            label.stringValue = "● \(tool) missing"
            label.textColor = .systemRed
        case .broken:
            label.stringValue = "● error"
            label.textColor = .systemRed
        case nil:
            label.stringValue = probing ? "● checking…" : ""
            label.textColor = .tertiaryLabelColor
        }
        return label
    }
}
