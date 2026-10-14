import KinhinKit
import SwiftUI

/// Advanced → Capacity: the This Mac form (its macOS and Linux cards) at the
/// top, then reserve, the split between runtimes (Budget) and the VM capacity
/// steppers in cards, with Revert and Apply pinned
/// below — they apply to the capacity fields only; the This Mac form saves as
/// you edit, exactly as it did on Accounts. State and actions live in
/// `CapacityModel` (VM capacity) and `MacToolsModel` (this Mac).
struct CapacityView: View {
    typealias Field = GeneralConfigEditor.Field

    let model: CapacityModel
    let mac: MacToolsModel
    /// Drives the Budget card; its instance counts read the saved config.
    let runtimes: RuntimesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader("This Mac")
                    MacToolsView(model: mac)
                    // The capacity cards need a config that parses; the This Mac
                    // card always renders (it carries its own config error line).
                    if model.draft != nil {
                        SectionHeader("Capacity")
                        reserveCard
                        if runtimes.showsBudget {
                            SectionHeader("Split between runtimes")
                            BudgetCard(model: runtimes)
                            if model.hasPendingChanges {
                                HintText("Instance counts update once you Apply the changes below.")
                            }
                        }
                        capacityCards
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                StatusText(verbatim: model.status.text, style: model.status.style)
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

    @ViewBuilder
    private var capacityCards: some View {
        FormCard(title: "How much runs at once") {
            row(
                "Fewest VMs kept ready", "min-runners", \.minRunners, 0...16, Field.minRunners,
                help: "0 means VMs only start when a job is waiting.")
            row(
                "Warm VMs kept ready (base image)", "warm-pool", \.warmPool, 0...16, Field.warmPool,
                help: "Booted VMs that wait for a job, so it skips the clone and boot. 0 is off.")
            row(
                "Most VMs at once", "max-runners", \.maxRunners, 1...32, Field.maxRunners,
                help: "The hard ceiling on VMs running together.")
            row(
                "Jobs per VM", "runners-per-vm", \.runnersPerVM, 1...8, Field.runnersPerVM,
                help: "Runners sharing one VM. 1 is safest; more share its CPU and RAM.")
            row(
                "Look for new jobs every (seconds)", "poll", \.pollInterval, 5...300, Field.pollInterval
            )
            Toggle(
                "Resume on its own once the queue is empty",
                isOn: Binding(
                    get: { model.draft?.autoResume ?? false }, set: { model.setAutoResume($0) })
            )
            .accessibilityIdentifier("auto-resume-toggle")
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
            HStack(spacing: 3) {
                Text("Base image")
                Spacer()
                TextField(
                    "Base image",
                    text: Binding(get: { model.draft?.image ?? "" }, set: { model.setImage($0) })
                )
                .labelsHidden()
                .frame(width: 220)
                .accessibilityIdentifier("image-field")
            }
        }
    }

    @ViewBuilder
    private var reserveCard: some View {
        FormCard(
            title: "Keep free for your Mac",
            subtitle: "Resources kinhin will not hand to VMs, so your Mac stays responsive."
        ) {
            row("CPU cores", "reserve-cpu", \.reserveCPU, 0...12, Field.reserveCPU)
            row("Memory (GB)", "reserve-mem", \.reserveMemoryGB, 0...32, Field.reserveMemoryGB)
        }
    }

    /// A label, a number field and a stepper that stay in sync.
    private func row(
        _ title: LocalizedStringKey, _ id: String, _ path: WritableKeyPath<GeneralConfigEditor.Snapshot, Int>,
        _ range: ClosedRange<Int>, _ make: @escaping (Int) -> Field, help: LocalizedStringKey? = nil
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
