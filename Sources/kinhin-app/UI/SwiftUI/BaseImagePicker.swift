import KinhinKit
import SwiftUI

/// The choices behind `BaseImagePicker`: a curated list plus "Other…" for any
/// free-form reference. Two catalogs share this picker: the Linux container
/// bases (`LinuxBaseImage`, nil = Ubuntu 24.04) and the tart VM images
/// (`TartBaseImage`, nil = the default macOS base). A nil value is the
/// catalog default, stored as no `base_image:` key at all.
enum BaseImageChoice {
    /// Which curated list a picker instance offers.
    enum Catalog {
        case linuxContainer
        case tartVM

        var entries: [(title: String, reference: String)] {
            switch self {
            case .linuxContainer: return LinuxBaseImage.curated
            case .tartVM: return TartBaseImage.curated
            }
        }

        /// The reference nil resolves to (stored as no key at all).
        var defaultReference: String {
            switch self {
            case .linuxContainer: return LinuxBaseImage.defaultReference
            case .tartVM: return TartBaseImage.defaultReference
            }
        }

        /// Why a typed "Other…" reference is unusable, or nil when fine.
        func problem(with reference: String) -> String? {
            switch self {
            case .linuxContainer: return LinuxBaseImage.problem(with: reference)
            case .tartVM: return TartBaseImage.problem(with: reference)
            }
        }
    }

    /// The default (Linux container) catalog, for existing callers/tests.
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

    // MARK: Catalog-generic variants (the view uses these)

    static func title(at index: Int, in catalog: Catalog) -> String {
        let entries = catalog.entries
        guard entries.indices.contains(index) else { return "Other…" }
        let entry = entries[index]
        return entry.reference == catalog.defaultReference ? "\(entry.title) (default)" : entry.title
    }

    static func index(of value: String?, in catalog: Catalog) -> Int {
        let reference = value ?? catalog.defaultReference
        return catalog.entries.firstIndex { $0.reference == reference } ?? catalog.entries.count
    }

    static func stored(_ reference: String, in catalog: Catalog) -> String? {
        reference == catalog.defaultReference ? nil : reference
    }

    static func validate(_ text: String, in catalog: Catalog) -> Result<String?, ProblemText> {
        let reference = text.trimmingCharacters(in: .whitespaces)
        if let problem = catalog.problem(with: reference) {
            return .failure(ProblemText(text: "Base image \(problem)."))
        }
        return .success(stored(reference, in: catalog))
    }

    struct ProblemText: Error, Equatable { let text: String }

    /// What a pin attempt produced: the reference to store and the one-line
    /// status to show next to the picker.
    struct PinOutcome: Equatable {
        let reference: String
        let pinned: Bool
        let message: String
    }

    /// The picker's pin flow, one call: validates the typed reference (a
    /// malformed pin or argv hazard fails without touching the network),
    /// asks the resolver, and wraps the answer for the UI. Tart-only — the
    /// Linux container catalog pins through docker, not the registry API.
    static func pin(
        _ reference: String, in catalog: Catalog,
        resolver: any DigestResolving = RegistryDigestResolver()
    ) async -> Result<PinOutcome, ProblemText> {
        guard catalog == .tartVM else {
            return .failure(ProblemText(text: "Pinning applies to tart VM images only."))
        }
        guard case .success(.some(let unpinned)) = validate(reference, in: catalog) else {
            return .failure(ProblemText(text: "Base image is not a usable reference."))
        }
        do {
            let result = try await TartBaseImage.pin(
                TartBaseImage.PinRequest(reference: unpinned, resolve: true), resolver: resolver)
            return .success(PinOutcome(reference: result.reference, pinned: result.pinned, message: result.message))
        } catch let error as ImageError {
            return .failure(ProblemText(text: error.localizedDescription))
        } catch {
            return .failure(ProblemText(text: error.localizedDescription))
        }
    }
}

extension Result {
    /// Convenience for disabling the pin button until the typed reference
    /// validates.
    var isFailure: Bool { if case .failure = self { return true }; return false }
}

/// Chooses the base image a runtime's prepare starts from. The saved `value`
/// is the source of truth (a rejected save leaves the picker on it); only an
/// in-progress "Other…" entry is local state.
struct BaseImagePicker: View {
    let value: String?
    /// Called with the new value (nil = default) once a valid choice is made.
    let onChange: (String?) -> Void
    /// Which curated list to offer (Linux container bases by default).
    var catalog: BaseImageChoice.Catalog = .linuxContainer
    /// Resolves the typed reference and returns the digest-pinned form to
    /// store. Tart-only (the registry flow is meaningless for the Linux
    /// container catalog, which pins via docker anyway); nil hides the
    /// pin affordance. The default asks the real registry.
    var pinDigest: ((String) async -> Result<BaseImageChoice.PinOutcome, BaseImageChoice.ProblemText>)?

    @State private var pickingOther = false
    @State private var custom = ""
    @State private var problem: String?
    @State private var resolving = false
    @State private var status: String?
    @FocusState private var customFocused: Bool

    private var otherIndex: Int { catalog.entries.count }
    private var selection: Int { pickingOther ? otherIndex : BaseImageChoice.index(of: value, in: catalog) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Picker("Base image", selection: Binding(get: { selection }, set: select)) {
                    ForEach(0...otherIndex, id: \.self) { Text(BaseImageChoice.title(at: $0, in: catalog)) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("base-image-popup")
                if selection == otherIndex {
                    TextField("e.g. debian:12 or ghcr.io/org/image:tag", text: $custom)
                        .frame(width: 220)
                        .focused($customFocused)
                        .onSubmit { commitCustom() }
                        .accessibilityLabel("Custom base image")
                        .accessibilityIdentifier("base-image-field")
                    if pinDigest != nil {
                        Button(resolving ? "Resolving…" : "Pin…") { pinFromField() }
                            .disabled(resolving || BaseImageChoice.validate(custom, in: catalog).isFailure)
                            .help(
                                "Ask the registry which digest it serves and store the pinned reference, so every bake uses identical bits"
                            )
                            .accessibilityIdentifier("base-image-pin")
                    }
                }
            }
            if let problem { HintText(problem).foregroundStyle(StatusStyle.error.color) }
            if let status { HintText(status).foregroundStyle(StatusStyle.ok.color) }
        }
        .onAppear { syncCustom() }
        .onChange(of: value) { _, _ in
            problem = nil
            status = nil
            pickingOther = false
            syncCustom()
        }
        .onChange(of: customFocused) { _, focused in if !focused && pickingOther { commitCustom() } }
    }

    private func syncCustom() {
        custom = BaseImageChoice.index(of: value, in: catalog) == otherIndex ? (value ?? "") : ""
    }

    private func select(_ index: Int) {
        problem = nil
        status = nil
        if index == otherIndex {
            pickingOther = true
            customFocused = true
            return
        }
        pickingOther = false
        commit(BaseImageChoice.stored(catalog.entries[index].reference, in: catalog))
    }

    private func commitCustom() {
        switch BaseImageChoice.validate(custom, in: catalog) {
        case .failure(let issue): problem = issue.text
        case .success(let newValue):
            problem = nil
            commit(newValue)
        }
    }

    /// Pin…: validate first, ask the injected resolver, and store the pinned
    /// form. A stored pin also lands in the field (the picker re-derives
    /// "Other…" from the new value), so the pin is visible after saving.
    private func pinFromField() {
        switch BaseImageChoice.validate(custom, in: catalog) {
        case .failure(let issue):
            problem = issue.text
        case .success(let candidate):
            guard let candidate else { return }
            problem = nil
            status = nil
            resolving = true
            Task { @MainActor in
                defer { resolving = false }
                guard let pinDigest else { return }
                switch await pinDigest(candidate) {
                case .success(let outcome):
                    status = outcome.message
                    commit(outcome.reference)
                case .failure(let issue):
                    problem = issue.text
                }
            }
        }
    }

    private func commit(_ newValue: String?) {
        guard newValue != value else { return }
        onChange(newValue)
    }
}
