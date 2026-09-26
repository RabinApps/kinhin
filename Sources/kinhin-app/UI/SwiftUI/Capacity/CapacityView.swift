import KinhinKit
import SwiftUI

/// Advanced → Capacity: stepper rows in cards, with Revert and Apply pinned
/// below. State and actions live in `CapacityModel`.
struct CapacityView: View {
    typealias Field = GeneralConfigEditor.Field

    let model: CapacityModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                if model.draft != nil {
                    VStack(alignment: .leading, spacing: 12) {
                        FormCard(title: "How much runs at once") {
                            row(
                                "Fewest VMs kept ready", "min-runners", \.minRunners, 0...16, Field.minRunners,
                                help: "0 means VMs only start when a job is waiting.")
                            row(
                                "Most VMs at once", "max-runners", \.maxRunners, 1...32, Field.maxRunners,
                                help: "The hard ceiling on VMs running together.")
                            row(
                                "Jobs per VM", "runners-per-vm", \.runnersPerVM, 1...8, Field.runnersPerVM,
                                help: "Runners sharing one VM. 1 is safest; more share its CPU and RAM.")
                            row(
                                "Look for new jobs every (seconds)", "poll", \.pollInterval, 5...300, Field.pollInterval
                            )
                        }
                        FormCard(title: "Each VM") {
                            row("CPU cores", "vm-cpu", \.vmCPU, 1...16, Field.vmCPU)
                            row("Memory (GB)", "vm-mem", \.vmMemoryGB, 2...64, Field.vmMemoryGB)
                            Toggle(
                                "Fresh VM for every job (recommended)",
                                isOn: Binding(
                                    get: { model.draft?.vmEphemeral ?? false }, set: { model.setEphemeral($0) })
                            )
                            .accessibilityIdentifier("ephemeral-toggle")
                            HStack {
                                Text("Base image")
                                TextField(
                                    "Base image",
                                    text: Binding(get: { model.draft?.image ?? "" }, set: { model.setImage($0) })
                                )
                                .labelsHidden()
                                .frame(width: 220)
                                .accessibilityIdentifier("image-field")
                            }
                        }
                        FormCard(
                            title: "Keep free for your Mac",
                            subtitle: "Resources kinhin will not hand to VMs, so your Mac stays responsive."
                        ) {
                            row("CPU cores", "reserve-cpu", \.reserveCPU, 0...12, Field.reserveCPU)
                            row("Memory (GB)", "reserve-mem", \.reserveMemoryGB, 0...32, Field.reserveMemoryGB)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                StatusText(text: model.status.text, style: model.status.style)
                Spacer()
                Button("Revert") { model.revert() }
                    .disabled(!model.hasPendingChanges)
                    .accessibilityIdentifier("capacity-revert")
                Button("Apply") { model.applyPending() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.hasPendingChanges)
                    .accessibilityIdentifier("capacity-apply")
            }
            .frame(width: FormMetrics.width)
        }
        .padding(.leading, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A label, a number field and a stepper that stay in sync.
    private func row(
        _ title: String, _ id: String, _ path: WritableKeyPath<GeneralConfigEditor.Snapshot, Int>,
        _ range: ClosedRange<Int>, _ make: @escaping (Int) -> Field, help: String? = nil
    ) -> some View {
        let value = Binding(
            get: { model.draft?[keyPath: path] ?? range.lowerBound },
            set: { model.set(id, path, to: $0, in: range, make: make) })
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text(title)
                Spacer()
                TextField(title, value: value, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 46)
                    .accessibilityIdentifier(id)
                Stepper(title, value: value, in: range).labelsHidden()
            }
            if let help { HintText(help) }
        }
    }
}
