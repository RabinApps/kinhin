import KinhinKit
import SwiftUI

/// The Runtimes page's "Fleet capacity" card: what applies to every runtime. Edits stage in `CapacityModel` and
/// are written together when the page's Apply is pressed.
struct FleetCapacityCard: View {
    typealias Field = GeneralConfigEditor.Field

    let model: CapacityModel

    var body: some View {
        Card(
            title: "Fleet capacity", subtitle: "Applies to every runtime. Changes stage until you press Apply.",
            layout: .fill
        ) {
            HStack(alignment: .top, spacing: Spacing.xxl) {
                // Idle floors add up against this ceiling, so its error lands here.
                capacityStepper(
                    "Most VMs at once", "max-runners", \.maxRunners, 1...32, Field.maxRunners,
                    error: model.issue(for: .total))
                capacityStepper("Fewest kept ready", "min-runners", \.minRunners, 0...16, Field.minRunners)
                capacityStepper("Jobs per VM", "runners-per-vm", \.runnersPerVM, 1...8, Field.runnersPerVM)
                capacityStepper("Look for jobs every (s)", "poll", \.pollInterval, 5...300, Field.pollInterval)
            }
            HStack(alignment: .top, spacing: Spacing.xxl) {
                Toggle(
                    "Resume on its own once the queue is empty",
                    isOn: Binding(get: { model.draft?.autoResume ?? false }, set: { model.setAutoResume($0) })
                )
                .accessibilityIdentifier("auto-resume-toggle")
                Toggle(
                    "Fresh VM for every job (recommended)",
                    isOn: Binding(get: { model.draft?.vmEphemeral ?? false }, set: { model.setEphemeral($0) })
                )
                .accessibilityIdentifier("ephemeral-toggle")
            }
            .toggleStyle(.checkbox)

            capacityGroup("Each VM") {
                capacityStepper("CPU cores", "vm-cpu", \.vmCPU, 1...16, Field.vmCPU)
                capacityStepper("Memory (GB)", "vm-mem", \.vmMemoryGB, 2...64, Field.vmMemoryGB)
            }
            capacityGroup("Keep free for your Mac") {
                capacityStepper("CPU", "reserve-cpu", \.reserveCPU, 0...12, Field.reserveCPU)
                capacityStepper("Memory (GB)", "reserve-mem", \.reserveMemoryGB, 0...32, Field.reserveMemoryGB)
                capacityStepper("Disk (GB)", "reserve-disk", \.reserveDiskGB, 0...500, Field.reserveDiskGB)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fleet-capacity-card")
    }

    private func capacityGroup<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content)
        -> some View
    {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title).typeStyle(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: Spacing.xl) { content() }
        }
    }

    /// A number control that stages its edit; the id is also the number field's accessibility identifier.
    private func capacityStepper(
        _ title: LocalizedStringKey, _ id: String, _ path: KeyPath<GeneralConfigEditor.Snapshot, Int>,
        _ range: ClosedRange<Int>, _ make: @escaping (Int) -> Field, error: String? = nil
    ) -> some View {
        StepperRow(
            title,
            value: Binding(
                get: { model.draft?[keyPath: path] ?? range.lowerBound },
                set: { model.set(id, to: $0, in: range, make: make) }),
            in: range, error: error.map { Text(verbatim: $0) }, fieldID: id)
    }
}

#Preview("Fleet capacity") {
    let model = CapacityModel()
    FleetCapacityCard(model: model)
        .padding(Spacing.lg)
        .frame(width: 700)
}
