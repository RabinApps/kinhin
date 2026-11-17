import KinhinKit
import SwiftUI

/// The Linux (Apple container) card: the container service, the base image and its build, the idle floor, and the
/// named pools. Pools write at once through their sheet; the idle floor stages with the fleet capacity.
struct ContainerRuntimeCard: View {
    @Bindable var runtimes: RuntimesModel
    let mac: MacToolsModel
    let capacity: CapacityModel

    var body: some View {
        RuntimeCard(
            runtime: .appleContainer, runtimes: runtimes, mac: mac,
            cannotEnableReason: mac.containerInstalled ? nil : Text("Install Apple container to turn this on.")
        ) { state in
            if state == .on {
                serviceRow
                baseImageRow
                keepIdleRow
                poolsSection
            } else if !mac.containerInstalled {
                serviceRow
            }
        }
    }

    // MARK: - Rows

    private var serviceRow: some View {
        ToolStatusRow(
            title: Text("Container service"), status: mac.containerLine,
            actionTitle: mac.containerInstallVisible ? Text(verbatim: mac.containerInstallTitle) : nil,
            actionID: "mac-install-container", action: { mac.installContainer() }, disabled: mac.busy)
    }

    private var baseImageRow: some View {
        LabeledControl("Base image") {
            HStack(spacing: Spacing.sm) {
                BaseImagePicker(
                    value: mac.containerBaseImage, onChange: { mac.saveBaseImage($0, for: .appleContainer) },
                    catalog: .linuxContainer)
                SmallActionButton(
                    title: Text("Build image…"), id: "mac-build-image-appleContainer", disabled: mac.busy
                ) { mac.buildLinuxImage(.appleContainer) }
            }
        }
    }

    private var keepIdleRow: some View {
        StepperRow(
            "Keep idle",
            value: Binding(
                get: { capacity.draft?.container?.minIdle ?? 0 },
                set: {
                    capacity.set("container-min-idle", to: $0, in: CapacityModel.keepIdleRange) {
                        .containerMinIdle($0)
                    }
                }
            ), in: CapacityModel.keepIdleRange, hint: Text("Used by the default pool"),
            error: capacity.issue(for: .containerMinIdle).map { Text(verbatim: $0) }, fieldID: "container-min-idle"
        )
        .help("Applies without restart")
    }

    // MARK: - Pools

    private var poolsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Pools").typeStyle(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            let rows = runtimes.containerPoolRows
            if rows.isEmpty {
                HintText("No named pools — every container job runs in the one pool container: describes.")
            }
            ForEach(rows) { row in
                poolRow(row)
            }
            Button("Add Container Pool…") { runtimes.addContainerPoolClicked() }
                .controlSize(.small)
        }
    }

    private func poolRow(_ row: RuntimesModel.ContainerPoolRow) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                Text(verbatim: row.id).typeStyle(.emphasis).monospaced()
                if let chip = RuntimesModel.builtChip(row.built) {
                    Chip(verbatim: chip.text, style: chip.style)
                }
                Spacer(minLength: Spacing.sm)
                Button("Edit…") { runtimes.editContainerPoolClicked(name: row.id) }
                    .controlSize(.small)
                    .accessibilityLabel("Edit container pool \(row.id)")
                Button("Remove") { runtimes.removeContainerPool(name: row.id) }
                    .controlSize(.small)
                    .accessibilityLabel("Remove container pool \(row.id)")
            }
            HintText(verbatim: row.detail)
            if let issue = capacity.issue(for: .pool(row.id)) {
                StatusText(verbatim: issue, style: .error)
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.lg).fill(Palette.grouped))
    }
}
