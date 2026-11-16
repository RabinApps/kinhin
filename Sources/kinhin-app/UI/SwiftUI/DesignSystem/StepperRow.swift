import SwiftUI

/// A labeled number stepper: the label above, a number field with the system stepper, then a hint (or, in red, the
/// validation error that replaces it). Disabled dims the whole row. The error is words, never only a red outline.
struct StepperRow: View {
    let label: Text
    @Binding var value: Int
    let range: ClosedRange<Int>
    var hint: Text?
    var error: Text?
    var isDisabled = false
    /// The identifier the number field carries, for UI tests.
    var fieldID: String?

    init(
        _ label: LocalizedStringKey, value: Binding<Int>, in range: ClosedRange<Int>, hint: Text? = nil,
        error: Text? = nil, isDisabled: Bool = false, fieldID: String? = nil
    ) {
        self.label = Text(label)
        _value = value
        self.range = range
        self.hint = hint
        self.error = error
        self.isDisabled = isDisabled
        self.fieldID = fieldID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            label
                .typeStyle(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            HStack(spacing: Spacing.sm) {
                TextField(value: $value, format: .number) { label }
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 56)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.md)
                            .strokeBorder(error == nil ? Color.clear : Palette.red, lineWidth: 1)
                    )
                    .accessibilityIdentifier(fieldID ?? "")
                Stepper(value: $value, in: range) { label }.labelsHidden()
            }
            if let error {
                error.typeStyle(.caption).foregroundStyle(StatusStyle.error.color)
            } else if let hint {
                hint.typeStyle(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
        .accessibilityElement(children: .contain)
    }
}

#Preview("Stepper rows") {
    @Previewable @State var normal = 2
    @Previewable @State var hinted = 1
    @Previewable @State var invalid = 5
    @Previewable @State var off = 0
    HStack(alignment: .top, spacing: Spacing.xl) {
        StepperRow("CPU cores", value: $normal, in: 0...16)
        StepperRow("Memory (GB)", value: $hinted, in: 0...16, hint: Text(verbatim: "Applies on Apply"))
        StepperRow("Most VMs at once", value: $invalid, in: 0...16, error: Text(verbatim: "Exceeds most at once (3)"))
        StepperRow("Jobs per VM", value: $off, in: 0...16, isDisabled: true)
    }
    .padding(Spacing.lg)
}
