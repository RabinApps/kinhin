import AppKit
import KinhinKit
import SwiftUI

/// The Docker card: the tool, the base image and its build, the architecture, how many run at once and the idle floor.
/// The architecture and image write at once; the two numbers stage with the fleet capacity.
struct DockerRuntimeCard: View {
    @Bindable var runtimes: RuntimesModel
    let mac: MacToolsModel
    let capacity: CapacityModel

    var body: some View {
        RuntimeCard(
            runtime: .docker, runtimes: runtimes, mac: mac,
            cannotEnableReason: mac.dockerInstalled ? nil : Text("Docker isn't installed — optional."),
            openApp: Self.dockerAppURL == nil ? nil : { openDockerApp() }
        ) { state in
            if state == .on {
                statusRow
                baseImageRow
                limitsRow
                platformNotice
            } else if !mac.dockerInstalled {
                HintText("Docker isn't installed — optional.")
                statusRow
            }
        }
    }

    // MARK: - Rows

    private var statusRow: some View {
        ToolStatusRow(
            title: Text(verbatim: "docker"), status: mac.dockerLine,
            actionTitle: mac.dockerInstallVisible ? Text("Install…") : nil, actionID: "mac-install-docker",
            action: { mac.installDocker() }, disabled: mac.busy)
    }

    private var baseImageRow: some View {
        LabeledControl("Base image") {
            HStack(spacing: Spacing.sm) {
                BaseImagePicker(
                    value: mac.dockerBaseImage, onChange: { mac.saveBaseImage($0, for: .docker) },
                    catalog: .linuxContainer)
                SmallActionButton(title: Text("Build image…"), id: "mac-build-image-docker", disabled: mac.busy) {
                    mac.buildLinuxImage(.docker)
                }
            }
        }
    }

    private var limitsRow: some View {
        HStack(alignment: .top, spacing: Spacing.xxl) {
            LabeledControl("Architecture") {
                Picker(
                    "Architecture",
                    selection: Binding(get: { mac.dockerPlatform }, set: { mac.saveDockerPlatform($0) })
                ) {
                    Text("arm64 (native)").tag(LinuxPlatform.arm64)
                    Text("amd64 (emulated)").tag(LinuxPlatform.amd64)
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("mac-docker-platform")
            }
            StepperRow(
                "Most at once",
                value: Binding(
                    get: { capacity.draft?.docker?.maxSlots ?? 1 },
                    set: { capacity.set("docker-max-slots", to: $0, in: 1...64) { .dockerMaxSlots($0) } }),
                in: 1...64, hint: Text(verbatim: "docker.max_slots"), fieldID: "docker-max-slots")
            StepperRow(
                "Keep idle",
                value: Binding(
                    get: { capacity.draft?.docker?.minIdle ?? 0 },
                    set: {
                        capacity.set("docker-min-idle", to: $0, in: CapacityModel.keepIdleRange) { .dockerMinIdle($0) }
                    }
                ), in: CapacityModel.keepIdleRange,
                hint: Text("Applies without restart"),
                error: capacity.issue(for: .dockerMinIdle).map { Text(verbatim: $0) }, fieldID: "docker-min-idle")
        }
    }

    @ViewBuilder
    private var platformNotice: some View {
        if mac.dockerPlatform.isEmulated {
            HintText(verbatim: LinuxPlatform.emulationNotice)
                .accessibilityIdentifier("mac-docker-platform-notice")
        }
        HintText("Rebuild the Docker image after changing architecture.")
    }

    // MARK: - Docker Desktop

    private static var dockerAppURL: URL? {
        let url = URL(fileURLWithPath: "/Applications/Docker.app")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func openDockerApp() {
        if let url = Self.dockerAppURL { NSWorkspace.shared.open(url) }
    }
}
