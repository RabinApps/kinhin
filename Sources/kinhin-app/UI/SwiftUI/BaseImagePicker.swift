import KinhinKit
import SwiftUI

/// The choices behind `BaseImagePicker`: a curated list plus "Other…" for any
/// Debian/Ubuntu-based reference. A value of nil is the default (Ubuntu
/// 24.04), which is stored as no `base_image:` key at all.
enum BaseImageChoice {
    static let curated = LinuxBaseImage.curated
    /// The index of "Other…" in the picker.
    static var otherIndex: Int { curated.count }

    static func title(at index: Int) -> String {
        guard curated.indices.contains(index) else { return "Other…" }
        let entry = curated[index]
        return entry.reference == LinuxBaseImage.defaultReference ? "\(entry.title) (default)" : entry.title
    }

    /// The curated entry for a stored value, or "Other…" when it isn't one.
    static func index(of value: String?) -> Int {
        let reference = value ?? LinuxBaseImage.defaultReference
        return curated.firstIndex { $0.reference == reference } ?? otherIndex
    }

    /// The value to store for a reference: nil for the default.
    static func stored(_ reference: String) -> String? {
        reference == LinuxBaseImage.defaultReference ? nil : reference
    }

    /// A typed reference: the value to store, or why it can't be used.
    static func validate(_ text: String) -> Result<String?, ProblemText> {
        let reference = text.trimmingCharacters(in: .whitespaces)
        if let problem = LinuxBaseImage.problem(with: reference) {
            return .failure(ProblemText(text: "Base image \(problem)."))
        }
        return .success(stored(reference))
    }

    struct ProblemText: Error, Equatable { let text: String }
}

/// Chooses the base image a Linux runner image is baked on. The saved `value`
/// is the source of truth (a rejected save leaves the picker on it); only an
/// in-progress "Other…" entry is local state.
struct BaseImagePicker: View {
    let value: String?
    /// Called with the new value (nil = default) once a valid choice is made.
    let onChange: (String?) -> Void

    @State private var pickingOther = false
    @State private var custom = ""
    @State private var problem: String?
    @FocusState private var customFocused: Bool

    private var selection: Int { pickingOther ? BaseImageChoice.otherIndex : BaseImageChoice.index(of: value) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Picker("Base image", selection: Binding(get: { selection }, set: select)) {
                    ForEach(0...BaseImageChoice.otherIndex, id: \.self) { Text(BaseImageChoice.title(at: $0)) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("base-image-popup")
                if selection == BaseImageChoice.otherIndex {
                    TextField("e.g. debian:12 or ghcr.io/org/image:tag", text: $custom)
                        .frame(width: 220)
                        .focused($customFocused)
                        .onSubmit { commitCustom() }
                        .accessibilityLabel("Custom base image")
                        .accessibilityIdentifier("base-image-field")
                }
            }
            if let problem { HintText(problem).foregroundStyle(StatusStyle.error.color) }
        }
        .onAppear { syncCustom() }
        .onChange(of: value) { _, _ in
            problem = nil
            pickingOther = false
            syncCustom()
        }
        .onChange(of: customFocused) { _, focused in if !focused && pickingOther { commitCustom() } }
    }

    private func syncCustom() {
        custom = BaseImageChoice.index(of: value) == BaseImageChoice.otherIndex ? (value ?? "") : ""
    }

    private func select(_ index: Int) {
        problem = nil
        if index == BaseImageChoice.otherIndex {
            pickingOther = true
            customFocused = true
            return
        }
        pickingOther = false
        commit(BaseImageChoice.stored(BaseImageChoice.curated[index].reference))
    }

    private func commitCustom() {
        switch BaseImageChoice.validate(custom) {
        case .failure(let issue): problem = issue.text
        case .success(let newValue):
            problem = nil
            commit(newValue)
        }
    }

    private func commit(_ newValue: String?) {
        guard newValue != value else { return }
        onChange(newValue)
    }
}
