import Foundation
import KinhinKit

// Edit YAML as a SwiftUI sheet (replacing RuntimesSheets' NSAlert). The state
// lives on `RuntimesModel`; `RuntimesView` presents `EditYAMLSheet` while
// `isYAMLEditorOpen` is true.

extension RuntimesModel {
    // MARK: Actions

    /// Edit YAML… pressed: load the file's exact bytes into the sheet. A file
    /// that cannot be read is presented instead of opening an empty editor.
    func editYAMLClicked() {
        do {
            yamlAtOpen = try ConfigStore.text(at: configURL)
            sheetProblem = ""
            isYAMLEditorOpen = true
        } catch {
            AlertKit.present(error: error, title: "Can't open config.yaml")
        }
    }

    /// Save pressed in the sheet: unchanged text just closes (matching the
    /// alert it replaces); changed text goes through ConfigEditor, so the
    /// engine's full validation gates the result — a bad edit shows the
    /// error instead of landing on disk. Failures keep the sheet open with
    /// the text preserved for fixing.
    func saveYAML(_ text: String) {
        guard text != yamlAtOpen else {
            isYAMLEditorOpen = false
            return
        }
        do {
            try ConfigEditor.save(text, to: configURL)
            Log.info("runtimes-pane", "config edited in UI; validation passed")
            isYAMLEditorOpen = false
            reload()
            onEdited?()
        } catch {
            sheetProblem = error.localizedDescription
        }
    }

    /// Cancel pressed (or the sheet was dismissed).
    func cancelYAML() {
        isYAMLEditorOpen = false
        sheetProblem = ""
    }
}
