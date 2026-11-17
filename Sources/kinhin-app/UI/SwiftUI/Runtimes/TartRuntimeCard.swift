import KinhinKit
import SwiftUI

/// The macOS (Tart) card: the tart tool, the base image and its rebuild, the idle floor and warm VMs, the extra named
/// images, and tart serving Linux. Image and tool edits write at once (`MacToolsModel`); the idle floors and warm VMs
/// stage with the fleet capacity (`CapacityModel`).
struct TartRuntimeCard: View {
    @Bindable var runtimes: RuntimesModel
    let mac: MacToolsModel
    let capacity: CapacityModel

    var body: some View {
        RuntimeCard(runtime: .tart, runtimes: runtimes, mac: mac) { state in
            if state == .on { cardBody }
        }
    }

    // MARK: - Body

    @ViewBuilder
    private var cardBody: some View {
        ToolStatusRow(
            title: Text(verbatim: "tart"), status: mac.tartLine,
            actionTitle: mac.tartInstallVisible ? Text("Install…") : nil, actionID: "mac-install-tart",
            action: { mac.installTart() }, disabled: mac.busy)
        baseImageBlock
        keepIdleRow
        if mac.offersNamedImages { MoreImagesSection(mac: mac, capacity: capacity) }
        if let issue = capacity.issue(for: .macOS) {
            StatusText(verbatim: issue, style: .error)
                .accessibilityIdentifier("tart-macos-limit-error")
        }
        tartLinuxBlock
    }

    private var baseImageBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if mac.tartLinuxOn {
                HintText(
                    "tart is serving Linux jobs — its base image is chosen below. Add a macOS image under More images so macOS jobs still have somewhere to run."
                )
            } else {
                LabeledControl("Base image") {
                    HStack(spacing: Spacing.sm) {
                        BaseImagePicker(
                            value: mac.tartBaseImage, onChange: { mac.saveBaseImage($0, for: .tart) },
                            catalog: .tartVM,
                            pinDigest: { reference in await BaseImageChoice.pin(reference, in: .tartVM) })
                        if mac.imageButtonVisible {
                            SmallActionButton(
                                title: Text(verbatim: mac.imageButtonTitle), id: "mac-prepare-image",
                                disabled: mac.busy
                            ) { mac.prepareImage() }
                        }
                        StatusText(verbatim: mac.imageLine.text, style: mac.imagePresent ? .ok : mac.imageLine.style)
                    }
                }
                if !mac.imagePresent {
                    HintText(verbatim: ImagePrepCost.notice).accessibilityIdentifier("mac-image-prep-cost")
                }
            }
        }
    }

    private var keepIdleRow: some View {
        let cap = MinIdleValidation.macOSVMsPerMac
        return HStack(alignment: .top, spacing: Spacing.xxl) {
            StepperRow(
                "Keep idle",
                value: Binding(
                    get: { capacity.draft?.imageMinIdle ?? 0 },
                    set: {
                        capacity.set("image-min-idle", to: $0, in: CapacityModel.keepIdleRange) { .imageMinIdle($0) }
                    }
                ), in: CapacityModel.keepIdleRange,
                hint: Text("macOS allows \(cap) VMs per Mac across all images"),
                error: capacity.issue(for: .imageMinIdle).map { Text(verbatim: $0) }, fieldID: "image-min-idle"
            )
            .help("Applies without restart")
            StepperRow(
                "Warm VMs",
                value: Binding(
                    get: { capacity.draft?.warmPool ?? 0 },
                    set: { capacity.set("warm-pool", to: $0, in: 0...16) { .warmPool($0) } }), in: 0...16,
                hint: Text("Booted but unregistered; ≤ most VMs at once"), fieldID: "warm-pool")
        }
    }

    private var tartLinuxBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Toggle(
                "Also serve Linux jobs with tart (Linux VM)",
                isOn: Binding(
                    get: { mac.tartLinuxOn },
                    set: { newValue in MainActor.assumeIsolated { mac.setTartLinux(newValue) } })
            )
            .toggleStyle(.checkbox)
            .disabled(!mac.tartInstalled)
            .accessibilityIdentifier("mac-tart-linux-toggle")
            if let warning = mac.tartLinuxLabelWarning {
                HintText(verbatim: warning)
                    .foregroundStyle(StatusStyle.warn.color)
                    .accessibilityIdentifier("mac-tart-linux-label-warning")
            } else {
                HintText("Tart Linux serves jobs with the macos label removed.")
            }
            if mac.tartLinuxOn {
                LabeledControl("Linux base image") {
                    BaseImagePicker(
                        value: mac.tartBaseImage, onChange: { mac.saveBaseImage($0, for: .tart) },
                        catalog: .tartLinux,
                        pinDigest: { reference in await BaseImageChoice.pin(reference, in: .tartLinux) })
                }
            }
        }
    }
}

// MARK: - More images

/// The extra named tart images (`images:`): one block each with its labels, base, warm VMs and idle floor, then the
/// add row. Each is prepared on its own; a Linux-named image strips the fleet's `macos` label automatically.
private struct MoreImagesSection: View {
    let mac: MacToolsModel
    let capacity: CapacityModel
    @State private var newImageName = ""
    @State private var newImageBase: String? = "ghcr.io/cirruslabs/macos-tahoe-xcode:latest"

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("More images").typeStyle(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            ForEach(mac.namedImages.rows) { row in
                imageBlock(row)
            }
            HStack(spacing: Spacing.sm) {
                TextField("New image name", text: $newImageName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .accessibilityIdentifier("mac-image-new-name")
                BaseImagePicker(
                    value: newImageBase, onChange: { newImageBase = $0 }, catalog: .tartVM,
                    pinDigest: { reference in await BaseImageChoice.pin(reference, in: .tartVM) })
                SmallActionButton(
                    title: Text("Add image"), id: "mac-image-add",
                    disabled: mac.busy || newImageName.trimmingCharacters(in: .whitespaces).isEmpty
                ) {
                    mac.namedImages.add(name: newImageName, baseImage: newImageBase)
                    newImageName = ""
                }
            }
        }
    }

    private func imageBlock(_ row: NamedImagesModel.Row) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Text(verbatim: row.name).typeStyle(.emphasis).monospaced()
                StatusText(
                    text: row.present ? "ready ✓" : "not prepared yet", style: row.present ? .ok : .warn)
                Spacer(minLength: Spacing.sm)
                SmallActionButton(
                    title: row.present ? Text("Rebuild…") : Text("Prepare"), id: "mac-image-prepare-\(row.name)",
                    disabled: mac.busy
                ) { mac.namedImages.prepare(row.name) }
                SmallActionButton(title: Text("Remove"), id: "mac-image-remove-\(row.name)", disabled: mac.busy) {
                    mac.namedImages.remove(row.name)
                }
            }
            HStack(alignment: .top, spacing: Spacing.lg) {
                LabeledControl("Run jobs with labels") {
                    ImageLabelsField(
                        labels: row.labels, id: row.name, commit: { mac.namedImages.setLabels($0, for: row.name) })
                }
                LabeledControl("Base image") {
                    BaseImagePicker(
                        value: row.baseImage, onChange: { mac.namedImages.setBase($0, for: row.name) },
                        catalog: .tartVM,
                        pinDigest: { reference in await BaseImageChoice.pin(reference, in: .tartVM) })
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                WarmPoolStepper(
                    count: row.warmPool, id: row.name, commit: { mac.namedImages.setWarmPool($0, for: row.name) })
                StepperRow(
                    "Keep idle",
                    value: Binding(
                        get: { capacity.imageMinIdle(row.name) },
                        set: { capacity.setImageMinIdle(row.name, to: $0) }), in: CapacityModel.keepIdleRange,
                    error: capacity.issue(for: .image(row.name)).map { Text(verbatim: $0) },
                    fieldID: "mac-image-min-idle-\(row.name)"
                )
                .help("Applies without restart")
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.lg).fill(Palette.grouped))
    }
}

/// How many VMs of one extra image stay warm. Each step saves the config (and restarts the engine) once the clicks settle.
private struct WarmPoolStepper: View {
    let count: Int
    let id: String
    let commit: (Int) -> Void
    /// The value while the user is still clicking. Nil shows `count`, the saved value.
    @State private var pending: Int?

    var body: some View {
        StepperRow(
            "VMs kept ready", value: Binding(get: { pending ?? count }, set: { pending = $0 }), in: 0...8,
            fieldID: "mac-image-warm-\(id)"
        )
        // Each change restarts this task, so the config is written once the clicks settle, not per click.
        .task(id: pending) {
            guard let target = pending, target != count else { return }
            // try?: cancelled means another click restarted the debounce; the isCancelled check below stops this one.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            commit(target)
            pending = nil
        }
    }
}

/// Comma-separated labels for one extra image, saved on Return or when focus leaves.
private struct ImageLabelsField: View {
    let labels: [String]
    let id: String
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("e.g. xcode", text: $text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 160)
            .focused($focused)
            .onAppear { text = labels.joined(separator: ", ") }
            .onSubmit { commit(text) }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit(text) } }
            .accessibilityIdentifier("mac-image-labels-\(id)")
    }
}
