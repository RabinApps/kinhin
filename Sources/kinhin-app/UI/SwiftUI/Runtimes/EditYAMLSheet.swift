import KinhinKit
import SwiftUI

/// The Edit YAML sheet: the file's exact bytes in a monospaced editor, with
/// Save writing through `ConfigEditor` so the engine's validation gates the
/// result. A rejected save renders in the sheet with the text intact.
struct EditYAMLSheet: View {
    @Bindable var model: RuntimesModel

    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Edit config.yaml")
                .font(.system(size: 13, weight: .semibold))
            if !model.sheetProblem.isEmpty {
                // The editor's message is the config error's own description
                // (same words the alert used to show after closing).
                StatusText(text: model.sheetProblem, style: .error)
            }
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .frame(minHeight: 320)
                .accessibilityLabel("config.yaml editor")
            HintText("Saved only if the whole file still passes the engine's config validation.")
            HStack {
                Spacer()
                Button("Cancel", action: model.cancelYAML)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { model.saveYAML(text) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 560, height: 480)
        .onAppear { text = model.yamlAtOpen }
    }
}
