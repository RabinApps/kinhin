import KinhinKit
import SwiftUI

/// The "This Mac" form: a macOS (tart) card and a Linux runtimes card. The
/// install dialogs are sheets owned by `MacToolsModel` (presented from its
/// `installOffer` / `missingBrewOffer`).
@MainActor
struct MacToolsView: View {
    @Bindable var model: MacToolsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            macCard
            linuxCard
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $model.installOffer) { offer in
            InstallConfirmationSheet(
                offer: offer,
                onConfirm: { model.confirmInstall($0) },
                onCopy: { model.copyInstallCommand($0) },
                onCancel: { model.cancelInstall() }
            )
        }
        .sheet(item: $model.missingBrewOffer) { offer in
            MissingBrewSheet(
                offer: offer,
                onGetBrew: { model.openBrewSite() },
                onDownload: { model.downloadManually() },
                onCancel: { model.cancelMissingBrew() }
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
                "tart", line: model.tartLine, visible: model.tartInstallVisible, button: "Install…",
                id: "mac-install-tart"
            ) {
                model.installTart()
            }
            statusRow(
                "Base image", line: model.imageLine, visible: model.imageButtonVisible, button: "Prepare image",
                id: "mac-prepare-image"
            ) {
                model.prepareImage()
            }
            if model.tartLinuxOn {
                HintText("tart is serving Linux jobs — its base image is chosen under Linux jobs below.")
            } else {
                baseImageRow(value: model.tartBaseImage, runtime: .tart)
            }
            if model.busy || !model.busyLine.text.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    if model.busy { ProgressView().controlSize(.small) }
                    StatusText(text: model.busyLine.text, style: model.busyLine.style)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var linuxCard: some View {
        FormCard(
            title: "Linux jobs (optional)",
            subtitle: "Turn one on to run Linux workflows. Without tart, this is all you need."
        ) {
            tartLinuxRow
            if model.tartLinuxOn {
                baseImageRow(value: model.tartBaseImage, runtime: .tart, catalog: .tartLinux)
                if let warning = model.tartLinuxLabelWarning {
                    HintText(warning)
                        .foregroundStyle(StatusStyle.warn.color)
                        .accessibilityIdentifier("mac-tart-linux-label-warning")
                }
            }
            runtimeRow(
                "Apple container", on: model.containerOn, toggleID: "mac-container-toggle",
                setOn: { model.setContainer($0) }, line: model.containerLine,
                installVisible: model.containerInstallVisible, installTitle: model.containerInstallTitle,
                installID: "mac-install-container", install: { model.installContainer() })
            if model.containerOn {
                baseImageRow(value: model.containerBaseImage, runtime: .appleContainer)
            }
            runtimeRow(
                "Docker", on: model.dockerOn, toggleID: "mac-docker-toggle",
                setOn: { model.setDocker($0) }, line: model.dockerLine,
                installVisible: model.dockerInstallVisible, installTitle: "Install…",
                installID: "mac-install-docker", install: { model.installDocker() })
            if model.dockerOn {
                baseImageRow(value: model.dockerBaseImage, runtime: .docker)
                platformRow
            }
        }
    }

    private func statusRow(
        _ title: String, line: StatusLine, visible: Bool, button: String, id: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold))
            StatusText(text: line.text, style: line.style)
            Spacer(minLength: 0)
            if visible { smallButton(button, id: id, action: action) }
        }
    }

    private func runtimeRow(
        _ title: String, on: Bool, toggleID: String, setOn: @escaping @MainActor (Bool) -> Void,
        line: StatusLine, installVisible: Bool, installTitle: String, installID: String,
        install: @escaping () -> Void
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
            StatusText(text: line.text, style: line.style)
            Spacer(minLength: 0)
            if installVisible { smallButton(installTitle, id: installID, action: install) }
        }
    }

    /// Tart first: a full Linux VM per job. Needs tart installed, so the
    /// checkbox stays off until it is (the Install… button is right here).
    private var tartLinuxRow: some View {
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
            StatusText(text: model.tartLine.text, style: model.tartLine.style)
            Spacer(minLength: 0)
            if model.tartInstallVisible {
                smallButton("Install…", id: "mac-install-tart-linux") { model.installTart() }
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

    /// Native arm64 by default; amd64 is an explicit opt-in that runs under
    /// emulation, so the trade-off is stated right under the picker.
    private var platformRow: some View {
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
                HintText(LinuxPlatform.emulationNotice + " Rebuild the Docker image after changing this.")
                    .accessibilityIdentifier("mac-docker-platform-notice")
            }
        }
    }

    private func smallButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .controlSize(.small)
            .disabled(model.busy)
            .accessibilityIdentifier(id)
    }
}
