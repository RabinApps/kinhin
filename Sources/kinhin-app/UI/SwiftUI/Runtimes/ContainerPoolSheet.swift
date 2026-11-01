import KinhinKit
import SwiftUI

/// The Add / Edit container pool sheet: one field per `container.pools:` key. A blank field inherits the
/// `container:` section's value, which its placeholder shows. Problems (from the fields or the config loader)
/// render inside the sheet with the values intact, as in Add Route.
struct ContainerPoolSheet: View {
    @Bindable var model: RuntimesModel
    let offer: RuntimesModel.ContainerPoolOffer

    @State private var draft: ContainerPoolDraft

    init(model: RuntimesModel, offer: RuntimesModel.ContainerPoolOffer) {
        self.model = model
        self.offer = offer
        _draft = State(initialValue: offer.original.map { ContainerPoolDraft(pool: $0) } ?? ContainerPoolDraft())
    }

    /// Width of the label column, so every field starts at the same x.
    private static let labelWidth: CGFloat = 110

    var body: some View {
        let defaults = offer.defaults
        VStack(alignment: .leading, spacing: 8) {
            Text(offer.original == nil ? "Add Container Pool" : "Edit Container Pool")
                .font(.system(size: 13, weight: .semibold))
            if offer.isFirstPool {
                HintText(
                    "Named pools replace the single container pool: the keys under container: become each pool's defaults, and a job no pool's labels claim goes to the pool with the fewest labels."
                )
            }

            row("Name") {
                TextField("e.g. big", text: $draft.name)
                    .accessibilityLabel("Pool name")
            }
            row("Labels") {
                TextField(Self.labelsPlaceholder(defaults.labels), text: $draft.labels)
                    .accessibilityLabel("Pool labels")
            }
            row("CPUs") {
                TextField(Self.inherited(String(defaults.cpus)), text: $draft.cpus)
                    .accessibilityLabel("CPUs per runner")
            }
            row("Memory (GB)") {
                TextField(Self.inherited(String(defaults.memoryGB)), text: $draft.memoryGB)
                    .accessibilityLabel("Memory per runner in GB")
            }
            row("Max runners") {
                TextField(Self.noLimit, text: $draft.max)
                    .accessibilityLabel("Max runners at once")
            }
            row("Idle runners") {
                TextField(Self.inherited(String(defaults.minIdle)), text: $draft.minIdle)
                    .accessibilityLabel("Idle runners kept")
            }
            row("Docker") {
                Picker("Docker", selection: $draft.docker) {
                    Text(verbatim: Self.dockerDefault(defaults.docker)).tag(ContainerPoolDraft.DockerChoice.inherit)
                    Text("On").tag(ContainerPoolDraft.DockerChoice.on)
                    Text("Off").tag(ContainerPoolDraft.DockerChoice.off)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            row("Image") {
                TextField(Self.imagePlaceholder(defaults.image), text: $draft.image)
                    .accessibilityLabel("Pool image")
            }
            row("Base image") {
                TextField(Self.inherited(defaults.baseImage ?? LinuxBaseImage.defaultReference), text: $draft.baseImage)
                    .accessibilityLabel("Pool base image")
            }
            row("Run flags") {
                TextEditor(text: $draft.flags)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    .frame(height: 44)
                    .accessibilityLabel("Extra container run arguments, one per line")
            }
            HintText(
                "Leave a field blank to use the container: section's value. Run flags take one argument per line. The pool's runners also carry the label kinhin-container-<name>; build its image with kinhin image prepare --container --pool <name>."
            )

            if !model.sheetProblem.isEmpty {
                StatusText(verbatim: model.sheetProblem, style: .error)
            }

            HStack {
                Spacer()
                Button("Cancel", action: model.cancelContainerPool)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { model.confirmContainerPool(draft) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Save container pool")
            }
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .padding(16)
        .frame(width: 440, alignment: .leading)
    }

    /// One labelled field: the label in a fixed column, the control filling the rest.
    private func row<Control: View>(_ label: LocalizedStringKey, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .frame(width: Self.labelWidth, alignment: .leading)
            control()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Placeholders (pinned by tests without presenting the sheet)

    /// A blank field's placeholder: the `container:` value it inherits.
    static func inherited(_ value: String) -> String {
        String(
            localized: "inherits \(value)", bundle: .l10n,
            comment: "Placeholder of a blank container pool field; %@ is the value it inherits from container:")
    }

    static var noLimit: String {
        String(
            localized: "no limit", bundle: .l10n,
            comment: "Placeholder of the container pool Max runners field: blank sets no max")
    }

    static func labelsPlaceholder(_ inherited: [String]?) -> String {
        guard let inherited, !inherited.isEmpty else {
            return String(
                localized: "e.g. linux, big", bundle: .l10n,
                comment: "Placeholder of the container pool Labels field; keep the example labels")
        }
        return Self.inherited(inherited.joined(separator: ", "))
    }

    static func imagePlaceholder(_ inherited: String) -> String {
        guard !inherited.isEmpty else {
            return String(
                localized: "required (container: names no image)", bundle: .l10n,
                comment: "Placeholder of the container pool Image field when the section has no image; keep container:")
        }
        return Self.inherited(inherited)
    }

    /// The Docker picker's first segment: the section's setting.
    static func dockerDefault(_ on: Bool) -> String {
        on
            ? String(
                localized: "Default (on)", bundle: .l10n,
                comment: "Container pool Docker picker: inherit the section's docker: true")
            : String(
                localized: "Default (off)", bundle: .l10n,
                comment: "Container pool Docker picker: inherit the section's docker: false")
    }
}
