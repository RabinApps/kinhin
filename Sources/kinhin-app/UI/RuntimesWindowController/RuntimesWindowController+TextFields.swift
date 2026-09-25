import AppKit
import KinhinKit

extension RuntimesWindowController: NSTextFieldDelegate {
    /// Label fields commit on Enter or on focus loss. The delegate fires for
    /// every field; scope comes from the field's identifier.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        switch field.identifier?.rawValue {
        case "fleet-labels-field":
            commitLabels(field: field, scope: .fleet)
        case "container-labels-field":
            commitLabels(field: field, scope: .container)
        default:
            break
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Enter in a label field commits and dismisses the keyboard focus.
        guard control is NSTextField, (control.identifier?.rawValue.hasSuffix("labels-field") ?? false) else {
            return false
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            NSApp.keyWindow?.makeFirstResponder(nil)
            return true
        }
        return false
    }
}
