import KinhinKit
import SwiftUI

/// The "This Mac" form: a macOS (tart) card and a Linux runtimes card. The
/// install dialogs are sheets owned by `MacToolsModel` (presented from its
/// `installOffer` / `missingBrewOffer`).
@MainActor
struct MacToolsView: View {
    @Bindable var model: MacToolsModel
    @State private var newImageName = ""
    @State private var newImageBase: String? = "ghcr.io/cirruslabs/macos-tahoe-xcode:latest"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            macCard
            linuxCard
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $model.installOffer) { offer in
            InstallConfirmationSheet(
                offer: offer,
                onConfirm: { model.installs.confirmInstall($0) },
                onCopy: { model.installs.copyInstallCommand($0) },
                onCancel: { model.installs.cancelInstall() }
            )
        }
        .sheet(item: $model.linuxSetupOffer) { offer in
            LinuxRuntimeSetupSheet(offer: offer, model: model)
        }
        .sheet(item: $model.missingBrewOffer) { offer in
            MissingBrewSheet(
                offer: offer,
                onGetBrew: { model.installs.openBrewSite() },
                onDownload: { model.installs.downloadManually() },
                onCancel: { model.installs.cancelMissingBrew() }
            )
        }
    }

    private var macCard: some View {
        FormCard(
            title: "macOS jobs (optional)",
            subtitle:
                "Run macOS workflows in disposable virtual machines powered by tart. Skip this if you only need Linux jobs."
        ) {
            statusRow(
                "tart", line: model.tartLine, visible: model.tartInstallVisible, button: Text("Install…"),
                id: "mac-install-tart"
            ) {
                model.installTart()
            }
            statusRow(
                "Base image", line: model.imageLine, visible: model.imageButtonVisible,
                button: Text(verbatim: model.imageButtonTitle),
                id: "mac-prepare-image"
            ) {
                model.prepareImage()
            }
            if !model.imagePresent && !model.tartLinuxOn {
                HintText(verbatim: ImagePrepCost.notice)
                    .accessibilityIdentifier("mac-image-prep-cost")
            }
            if model.tartLinuxOn {
                HintText(
                    "tart is serving Linux jobs — its base image is chosen under Linux jobs below. Add a macOS image under More images so macOS jobs still have somewhere to run."
                )
            } else {
                baseImageRow(value: model.tartBaseImage, runtime: .tart)
            }
            if model.offersNamedImages { moreImagesSection }
            if model.busy || !model.busyLine.text.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    if model.busy { ProgressView().controlSize(.small).accessibilityLabel("Working") }
                    StatusText(verbatim: model.busyLine.text, style: model.busyLine.style)
                        .textSelection(.enabled)
                    if model.busy {
                        Spacer(minLength: 0)
                        Button("Cancel") { model.cancelRunning() }
                            .controlSize(.small)
                            .accessibilityIdentifier("mac-busy-cancel")
                    }
                }
            }
        }
    }

    /// Extra named images (for example one baked on an Xcode base, or a Linux
    /// base for Linux jobs). Each is prepared on its own; picking which image
    /// a job runs on comes later. A Linux-named image strips the fleet's
    /// `macos` label automatically, so macOS and Linux Tart VMs can share one
    /// fleet.
    private var moreImagesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("More images").font(.system(size: 12, weight: .semibold))
            HintText(
                "Extra prepared images, such as one on an Xcode base or a Linux base. Each has its own base and is rebuilt separately. A Linux-named image strips the fleet's `macos` label automatically."
            )
            ForEach(model.namedImages.rows) { row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(row.name).font(.system(size: 12, design: .monospaced))
                        StatusText(
                            text: row.present ? "ready ✓" : "not prepared yet",
                            style: row.present ? .secondary : .warn)
                        Spacer(minLength: 0)
                        smallButton(
                            row.present ? Text("Rebuild…") : Text("Prepare"), id: "mac-image-prepare-\(row.name)"
                        ) {
                            model.namedImages.prepare(row.name)
                        }
                        smallButton(Text("Remove"), id: "mac-image-remove-\(row.name)") {
                            model.namedImages.remove(row.name)
                        }
                    }
                    HStack(spacing: 8) {
                        Text("Run jobs with labels").font(.system(size: 11)).foregroundStyle(
                            StatusStyle.secondary.color)
                        Spacer(minLength: 0)
                        ImageLabelsField(
                            labels: row.labels, id: row.name, commit: { model.namedImages.setLabels($0, for: row.name) }
                        )
                    }
                    HStack(spacing: 8) {
                        Text("Base image").font(.system(size: 11)).foregroundStyle(StatusStyle.secondary.color)
                        Spacer(minLength: 0)
                        BaseImagePicker(
                            value: row.baseImage,
                            onChange: { model.namedImages.setBase($0, for: row.name) },
                            catalog: .tartVM,
                            pinDigest: { reference in await BaseImageChoice.pin(reference, in: .tartVM) }
                        )
                        .fixedSize()
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("New image name", text: $newImageName)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 150)
                    .accessibilityIdentifier("mac-image-new-name")
                BaseImagePicker(
                    value: newImageBase, onChange: { newImageBase = $0 }, catalog: .tartVM,
                    pinDigest: { reference in await BaseImageChoice.pin(reference, in: .tartVM) }
                )
                .fixedSize()
                Spacer(minLength: 0)
                smallButton(Text("Add image"), id: "mac-image-add") {
                    model.namedImages.add(name: newImageName, baseImage: newImageBase)
                    newImageName = ""
                }
                .disabled(model.busy || newImageName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var linuxCard: some View {
        FormCard(
            title: "Linux jobs (optional)",
            subtitle: "Turn one on to run Linux workflows. Without tart, this is all you need."
        ) {
            if model.activeLinuxRuntimes.isEmpty {
                linuxSetupRow
            }
            tartLinuxRow()
            if model.tartLinuxOn {
                baseImageRow(value: model.tartBaseImage, runtime: .tart, catalog: .tartLinux)
                if let warning = model.tartLinuxLabelWarning {
                    HintText(verbatim: warning)
                        .foregroundStyle(StatusStyle.warn.color)
                        .accessibilityIdentifier("mac-tart-linux-label-warning")
                }
            }
            runtimeRow(
                "Apple container", on: model.containerOn, toggleID: "mac-container-toggle",
                setOn: { model.setContainer($0) }, line: model.containerLine,
                installVisible: model.containerInstallVisible,
                installTitle: Text(verbatim: model.containerInstallTitle),
                installID: "mac-install-container", maturity: MaturityTable.maturity(of: .appleContainer),
                install: { model.installContainer() })
            if model.containerOn {
                baseImageRow(value: model.containerBaseImage, runtime: .appleContainer)
                buildImageRow(.appleContainer)
            }
            runtimeRow(
                "Docker", on: model.dockerOn, toggleID: "mac-docker-toggle",
                setOn: { model.setDocker($0) }, line: model.dockerLine,
                installVisible: model.dockerInstallVisible, installTitle: Text("Install…"),
                installID: "mac-install-docker", maturity: MaturityTable.maturity(of: .docker),
                install: { model.installDocker() })
            if model.dockerOn {
                baseImageRow(value: model.dockerBaseImage, runtime: .docker)
                buildImageRow(.docker)
                platformRow()
            }
        }
    }

    /// A repo has Linux jobs but nothing is turned on yet: offer the
    /// three-way choice as one row that opens the comparison sheet.
    private var linuxSetupRow: some View {
        Button {
            model.chooseLinuxRuntime()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("Set up Linux jobs…")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Text("Apple container · Docker · Tart (Linux VM)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("mac-linux-setup-btn")
    }

    private func statusRow(
        _ title: LocalizedStringKey, line: StatusLine, visible: Bool, button: Text, id: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold))
            StatusText(verbatim: line.text, style: line.style)
            Spacer(minLength: 0)
            if visible { smallButton(button, id: id, action: action) }
        }
    }

    private func runtimeRow(
        _ title: LocalizedStringKey, on: Bool, toggleID: String, setOn: @escaping @MainActor (Bool) -> Void,
        line: StatusLine, installVisible: Bool, installTitle: Text, installID: String,
        maturity: Maturity = .liveTested, install: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            // Binding's setter is @Sendable; the toggle only ever fires on the
            // main actor, so hop back synchronously (same pattern as AppMain).
            Toggle(
                title,
                isOn: Binding(
                    get: { on },
                    set: { newValue in MainActor.assumeIsolated { setOn(newValue) } }
                )
            )
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .accessibilityIdentifier(toggleID)
            MaturityBadge(maturity)
            StatusText(verbatim: line.text, style: line.style)
            Spacer(minLength: 0)
            if installVisible { smallButton(installTitle, id: installID, action: install) }
        }
    }

    /// Tart first: a full Linux VM per job. Needs tart installed, so the
    /// checkbox stays off until it is (the Install… button is right here).
    private func tartLinuxRow() -> some View {
        HStack(spacing: 8) {
            Toggle(
                "Tart (Linux VM)",
                isOn: Binding(
                    get: { model.tartLinuxOn },
                    set: { newValue in MainActor.assumeIsolated { model.setTartLinux(newValue) } }
                )
            )
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .disabled(!model.tartInstalled)
            .accessibilityIdentifier("mac-tart-linux-toggle")
            MaturityBadge(MaturityTable.tartLinux)
            StatusText(verbatim: model.tartLine.text, style: model.tartLine.style)
            Spacer(minLength: 0)
            if model.tartInstallVisible {
                smallButton(Text("Install…"), id: "mac-install-tart-linux") { model.installTart() }
            }
        }
    }

    private func baseImageRow(value: String?, runtime: RuntimeID, catalog: BaseImageChoice.Catalog? = nil)
        -> some View
    {
        HStack(alignment: .top, spacing: 8) {
            Text("Base image").font(.system(size: 12))
            Spacer(minLength: 0)
            BaseImagePicker(
                value: value,
                onChange: { model.saveBaseImage($0, for: runtime) },
                catalog: catalog ?? (runtime == .tart ? .tartVM : .linuxContainer),
                pinDigest: runtime == .tart
                    ? { reference in await BaseImageChoice.pin(reference, in: catalog ?? .tartVM) }
                    : nil
            )
            .fixedSize()
        }
    }

    private func buildImageRow(_ runtime: RuntimeID) -> some View {
        HStack(spacing: 8) {
            Text("Image").font(.system(size: 12))
            Spacer(minLength: 0)
            smallButton(Text("Build image…"), id: "mac-build-image-\(runtime.rawValue)") {
                model.buildLinuxImage(runtime)
            }
        }
    }

    private func platformRow() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Text("Architecture").font(.system(size: 12))
                Spacer(minLength: 0)
                Picker(
                    "Architecture",
                    selection: Binding(get: { model.dockerPlatform }, set: { model.saveDockerPlatform($0) })
                ) {
                    Text("arm64 (native)").tag(LinuxPlatform.arm64)
                    Text("amd64 (emulated)").tag(LinuxPlatform.amd64)
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("mac-docker-platform")
            }
            if model.dockerPlatform.isEmulated {
                HintText(
                    verbatim: LinuxPlatform.emulationNotice + " "
                        + String(
                            localized: "Rebuild the Docker image after changing this.", bundle: .l10n,
                            comment: "Appended to the amd64 emulation notice")
                )
                .accessibilityIdentifier("mac-docker-platform-notice")
            }
        }
    }

    private func smallButton(_ title: Text, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { title }
            .controlSize(.small)
            .disabled(model.busy)
            .accessibilityIdentifier(id)
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
            .controlSize(.small)
            .frame(width: 180)
            .focused($focused)
            .onAppear { text = labels.joined(separator: ", ") }
            .onSubmit { commit(text) }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit(text) } }
            .accessibilityIdentifier("mac-image-labels-\(id)")
    }
}
