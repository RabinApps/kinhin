import KinhinKit
import SwiftUI

/// The "This Mac" form: a macOS (tart) card and a Linux runtimes card.
struct MacToolsView: View {
    let model: MacToolsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            macCard
            linuxCard
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        _ title: String, on: Bool, toggleID: String, setOn: @escaping (Bool) -> Void,
        line: StatusLine, installVisible: Bool, installTitle: String, installID: String,
        install: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Toggle(title, isOn: Binding(get: { on }, set: setOn))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .accessibilityIdentifier(toggleID)
            StatusText(text: line.text, style: line.style)
            Spacer(minLength: 0)
            if installVisible { smallButton(installTitle, id: installID, action: install) }
        }
    }

    private func baseImageRow(value: String?, runtime: RuntimeID) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("Base image").font(.system(size: 12))
            Spacer(minLength: 0)
            BaseImagePickerField(value: value) { model.saveBaseImage($0, for: runtime) }
                .fixedSize()
        }
    }

    private func smallButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .controlSize(.small)
            .disabled(model.busy)
            .accessibilityIdentifier(id)
    }
}

/// Bridges the AppKit `BaseImagePicker` (still shared with the Toolchains
/// page and its tests) into SwiftUI.
struct BaseImagePickerField: NSViewRepresentable {
    let value: String?
    let onChange: (String?) -> Void

    func makeNSView(context: Context) -> BaseImagePicker {
        let picker = BaseImagePicker(value: value)
        picker.onChange = { onChange($0) }
        return picker
    }

    func updateNSView(_ picker: BaseImagePicker, context: Context) {
        picker.onChange = { onChange($0) }
        // Only re-sync when the saved value moved (or a rejected edit needs
        // reverting); resetting on every pass would clear a half-typed entry.
        if picker.value != value { picker.setValue(value) }
    }
}
