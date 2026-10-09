import KinhinKit
import SwiftUI

/// The Add Route sheet: pattern field, runtime picker, and the host-consent
/// checkbox. Its verdicts (empty pattern, duplicate, missing consent) render
/// inside the sheet with the entered values intact — replacing the alert
/// loop that re-ran the form for every correction.
struct AddRouteSheet: View {
    @Bindable var model: RuntimesModel
    let runtimes: [RuntimeID]

    @State private var pattern = ""
    @State private var runtime: RuntimeID
    @State private var consent = false

    init(model: RuntimesModel, runtimes: [RuntimeID]) {
        self.model = model
        self.runtimes = runtimes
        _runtime = State(initialValue: runtimes.first ?? .tart)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "Send a repository, or one workflow, to a runtime. Use owner/repo for a whole repo, or owner/repo@Workflow Name for one workflow."
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            TextField(Self.patternPlaceholder, text: $pattern)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .accessibilityLabel("Repo or workflow pattern")

            Picker("Runtime to use", selection: $runtime) {
                ForEach(runtimes, id: \.rawValue) { id in
                    Text(RuntimesModel.runtimeTitle(id) + MaturityTable.maturity(of: id).pickerSuffix).tag(id)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel("Runtime to use")

            if Self.consentNeeded(for: runtime) {
                Toggle(RuntimesModel.hostConsentTitle, isOn: $consent)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Host route consent")
            }

            if !model.sheetProblem.isEmpty {
                StatusText(verbatim: model.sheetProblem, style: .error)
            }

            HStack {
                Spacer()
                Button("Cancel", action: model.cancelAddRoute)
                    .keyboardShortcut(.cancelAction)
                Button("Add") { model.confirmAddRoute(rawPattern: pattern, runtime: runtime, consent: consent) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Add route")
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
    }

    // MARK: - Form contract (pinned by tests without presenting the sheet)

    static var patternPlaceholder: String {
        String(
            localized: "acme/api  or  acme/api@Workflow Name", bundle: .l10n,
            comment: "Placeholder of the Add Route pattern field; keep the pattern syntax")
    }

    var runtimeOptions: [String] { runtimes.map(RuntimesModel.runtimeTitle) }

    /// The consent checkbox is offered only while a host runtime is selected.
    var consentOffered: Bool { Self.consentNeeded(for: runtime) }
    static func consentNeeded(for runtime: RuntimeID) -> Bool { runtime == .host }
    /// Consent is never pre-ticked.
    var consentIsOn: Bool { consent }
}
