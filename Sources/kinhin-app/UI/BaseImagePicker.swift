import AppKit
import KinhinKit

/// Chooses the base image a Linux runner image is baked on: a dropdown of the
/// curated images plus "Other…" for any Debian/Ubuntu-based reference.
/// `value` is nil for the default (Ubuntu 24.04), which is stored as no
/// `base_image:` key at all.
@MainActor
final class BaseImagePicker: NSStackView, NSTextFieldDelegate {
    /// Called with the new value (nil = default) once a valid choice is made.
    var onChange: ((String?) -> Void)?
    private(set) var value: String?

    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    let field = NSTextField()
    let problemLabel = FormKit.hint("")

    private static let otherTitle = "Other…"
    private var otherIndex: Int { LinuxBaseImage.curated.count }

    init(value: String?) {
        self.value = value
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 4

        for entry in LinuxBaseImage.curated {
            let isDefault = entry.reference == LinuxBaseImage.defaultReference
            popup.addItem(withTitle: isDefault ? "\(entry.title) (default)" : entry.title)
        }
        popup.addItem(withTitle: Self.otherTitle)
        popup.target = self
        popup.action = #selector(popupChanged)
        popup.setAccessibilityLabel("Base image")
        popup.identifier = NSUserInterfaceItemIdentifier("base-image-popup")

        field.placeholderString = "e.g. debian:12 or ghcr.io/org/image:tag"
        field.delegate = self
        field.identifier = NSUserInterfaceItemIdentifier("base-image-field")
        field.setAccessibilityLabel("Custom base image")
        field.widthAnchor.constraint(equalToConstant: 220).isActive = true

        problemLabel.textColor = .systemRed
        problemLabel.isHidden = true

        addArrangedSubview(FormKit.row([popup, field]))
        addArrangedSubview(problemLabel)
        setValue(value)
    }

    required init?(coder: NSCoder) { fatalError("created in code") }

    /// Shows `value` without reporting a change (used when loading from config).
    func setValue(_ newValue: String?) {
        value = newValue
        problemLabel.isHidden = true
        let reference = newValue ?? LinuxBaseImage.defaultReference
        if let index = LinuxBaseImage.curated.firstIndex(where: { $0.reference == reference }) {
            popup.selectItem(at: index)
            field.isHidden = true
            field.stringValue = ""
        } else {
            popup.selectItem(at: otherIndex)
            field.isHidden = false
            field.stringValue = reference
        }
    }

    @objc private func popupChanged() {
        problemLabel.isHidden = true
        let index = popup.indexOfSelectedItem
        if index == otherIndex {
            field.isHidden = false
            window?.makeFirstResponder(field)
            return
        }
        field.isHidden = true
        commit(LinuxBaseImage.curated[index].reference)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        commitCustom(field.stringValue)
    }

    /// Validates and applies a typed reference; a bad one is explained under
    /// the control and the previous value stays.
    func commitCustom(_ text: String) {
        let reference = text.trimmingCharacters(in: .whitespaces)
        if let problem = LinuxBaseImage.problem(with: reference) {
            problemLabel.stringValue = "Base image \(problem)."
            problemLabel.isHidden = false
            return
        }
        problemLabel.isHidden = true
        commit(reference)
    }

    private func commit(_ reference: String) {
        let newValue = reference == LinuxBaseImage.defaultReference ? nil : reference
        guard newValue != value else { return }
        value = newValue
        onChange?(newValue)
    }
}
