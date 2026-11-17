import KinhinKit
import SwiftUI

/// The Edit YAML sheet: the file's exact bytes in a monospaced editor, with
/// Save writing through `ConfigEditor` so the engine's validation gates the
/// result. A rejected save renders in the sheet with the text intact.
struct EditYAMLSheet: View {
    @Bindable var model: RuntimesModel

    @State private var text = ""

    var body: some View {
        SheetScaffold(title: "Edit config.yaml", width: 560) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                TextEditor(text: $text)
                    .font(.system(.callout, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(Spacing.sm)
                    .background(RoundedRectangle(cornerRadius: Radius.md).fill(Palette.grouped))
                    .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Palette.separator, lineWidth: 1))
                    .frame(minHeight: 320)
                    .accessibilityLabel("config.yaml editor")
                HintText("Saved only if the whole file still passes the engine's config validation.")
                if !model.sheetProblem.isEmpty {
                    // The editor's message is the config error's own description.
                    StatusText(verbatim: model.sheetProblem, style: .error)
                }
            }
        } footer: {
            SheetConfirmFooter("Save", confirm: { model.saveYAML(text) }, cancel: model.cancelYAML)
        }
        .onAppear { text = model.yamlAtOpen }
    }
}
