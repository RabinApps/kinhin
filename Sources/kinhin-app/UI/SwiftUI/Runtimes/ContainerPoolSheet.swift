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

    var body: some View {
        let defaults = offer.defaults
        SheetScaffold(
            verbatimTitle: offer.original == nil
                ? String(localized: "Add Container Pool", bundle: .l10n, comment: "Sheet title")
                : String(localized: "Edit Container Pool", bundle: .l10n, comment: "Sheet title"),
            width: 480
        ) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                if offer.isFirstPool {
                    HintText(
                        "Named pools replace the single container pool: the keys under container: become each pool's defaults, and a job no pool's labels claim goes to the pool with the fewest labels among those of the architecture it asks for (x64 or arm64)."
                    )
                }
                HStack(alignment: .top, spacing: Spacing.md) {
                    poolField("Name", prompt: Text("e.g. big"), text: $draft.name, label: Text("Pool name"), width: 180)
                    poolField(
                        "Labels", prompt: Text(verbatim: Self.labelsPlaceholder(defaults.labels)), text: $draft.labels,
                        label: Text("Pool labels"))
                }
                HStack(alignment: .top, spacing: Spacing.md) {
                    poolField(
                        "CPUs", prompt: Text(verbatim: Self.inherited(String(defaults.cpus))), text: $draft.cpus,
                        label: Text("CPUs per runner"), width: 80)
                    poolField(
                        "Memory (GB)", prompt: Text(verbatim: Self.inherited(String(defaults.memoryGB))),
                        text: $draft.memoryGB,
                        label: Text("Memory per runner in GB"), width: 100)
                    poolField(
                        "Max runners", prompt: Text(verbatim: Self.noLimit), text: $draft.max,
                        label: Text("Max runners at once"),
                        width: 100)
                    poolField(
                        "Idle runners", prompt: Text(verbatim: Self.inherited(String(defaults.minIdle))),
                        text: $draft.minIdle,
                        label: Text("Idle runners kept"), width: 100)
                }
                LabeledControl("Docker") {
                    Picker("Docker", selection: $draft.docker) {
                        Text(verbatim: Self.dockerDefault(defaults.docker)).tag(ContainerPoolDraft.DockerChoice.inherit)
                        Text("On").tag(ContainerPoolDraft.DockerChoice.on)
                        Text("Off").tag(ContainerPoolDraft.DockerChoice.off)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                poolField(
                    "Image", prompt: Text(verbatim: Self.imagePlaceholder(defaults.image)), text: $draft.image,
                    label: Text("Pool image"))
                poolField(
                    "Base image",
                    prompt: Text(verbatim: Self.inherited(defaults.baseImage ?? LinuxBaseImage.defaultReference)),
                    text: $draft.baseImage, label: Text("Pool base image"))
                LabeledControl("Run flags (one per line)") {
                    TextEditor(text: $draft.flags)
                        .font(.system(.callout, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(Spacing.xs)
                        .background(RoundedRectangle(cornerRadius: Radius.md).fill(Palette.grouped))
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Palette.separator, lineWidth: 1)
                        )
                        .frame(height: 56)
                        .accessibilityLabel("Extra container run arguments, one per line")
                }
                HintText(
                    "Leave a field blank to use the container: section's value. Run flags take one argument per line. The pool's runners also carry the label kinhin-container-<name>; build its image with kinhin image prepare --container --pool <name>."
                )
                if !model.sheetProblem.isEmpty {
                    StatusText(verbatim: model.sheetProblem, style: .error)
                }
            }
        } footer: {
            SheetConfirmFooter(
                "Save", confirm: { model.confirmContainerPool(draft) }, cancel: model.cancelContainerPool)
        }
    }

    /// One captioned text field; `width` nil lets it take the rest of the row.
    private func poolField(
        _ title: LocalizedStringKey, prompt: Text, text: Binding<String>, label: Text,
        width: CGFloat? = nil
    ) -> some View {
        LabeledControl(title) {
            TextField(text: text, prompt: prompt) { label }
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(label)
        }
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
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
