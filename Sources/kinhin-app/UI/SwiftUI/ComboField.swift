import AppKit
import SwiftUI

/// An editable combo box (type a value, or pick one from the list). SwiftUI
/// has no equivalent, so this wraps `NSComboBox`, keeping type-ahead
/// completion and the commit-on-pick / commit-on-return behavior the repo
/// pickers rely on.
struct ComboField: NSViewRepresentable {
    @Binding var text: String
    var items: [String]
    var placeholder: String
    var isEnabled: Bool = true
    var identifier: String
    var accessibilityLabel: String
    /// Fired when the user picks an item, presses Return, or leaves the field.
    var onCommit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSComboBox {
        let combo = NSComboBox(frame: .zero)
        combo.completes = true
        combo.numberOfVisibleItems = 12
        combo.identifier = NSUserInterfaceItemIdentifier(identifier)
        combo.setAccessibilityLabel(accessibilityLabel)
        combo.delegate = context.coordinator
        combo.target = context.coordinator
        combo.action = #selector(Coordinator.committed)
        return combo
    }

    func updateNSView(_ combo: NSComboBox, context: Context) {
        context.coordinator.parent = self
        combo.isEnabled = isEnabled
        combo.placeholderString = placeholder
        if context.coordinator.items != items {
            context.coordinator.items = items
            combo.removeAllItems()
            combo.addItems(withObjectValues: items)
        }
        if combo.stringValue != text { combo.stringValue = text }
    }

    @MainActor
    final class Coordinator: NSObject, NSComboBoxDelegate, NSTextFieldDelegate {
        var parent: ComboField
        var items: [String] = []

        init(_ parent: ComboField) { self.parent = parent }

        @objc func committed(_ sender: NSComboBox) {
            parent.text = sender.stringValue
            parent.onCommit()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let combo = notification.object as? NSComboBox else { return }
            parent.text = combo.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let combo = notification.object as? NSComboBox else { return }
            parent.text = combo.stringValue
            parent.onCommit()
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let combo = notification.object as? NSComboBox else { return }
            // The selection is applied to stringValue after this callback.
            Task { @MainActor [weak self, weak combo] in
                guard let self, let combo else { return }
                self.parent.text = combo.stringValue
                self.parent.onCommit()
            }
        }
    }
}
