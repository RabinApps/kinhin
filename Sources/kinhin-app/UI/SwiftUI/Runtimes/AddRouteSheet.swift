import KinhinKit
import SwiftUI

/// The Add Route sheet: pattern field, runtime picker, and the host-consent
/// checkbox (never pre-ticked). Its verdicts (empty pattern, duplicate, missing consent) show as you type, inside the
/// sheet with the entered values intact, and keep Add off until the route is acceptable.
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
        SheetScaffold(title: "Add Route", width: 480) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HintText(
                    "Send a repository, or one workflow, to a runtime. Use owner/repo or owner/repo@Workflow Name.")
                LabeledControl("Repository or workflow pattern") {
                    TextField(Self.patternPlaceholder, text: $pattern)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Repo or workflow pattern")
                        .accessibilityIdentifier("add-route-pattern")
                }
                LabeledControl("Runtime") {
                    Picker("Runtime to use", selection: $runtime) {
                        ForEach(runtimes, id: \.rawValue) { id in
                            Text(verbatim: RuntimesModel.runtimeTitle(id) + MaturityTable.maturity(of: id).pickerSuffix)
                                .tag(id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Runtime to use")
                }
                if Self.consentNeeded(for: runtime) {
                    Toggle(isOn: $consent) {
                        Text(verbatim: RuntimesModel.hostConsentTitle).fixedSize(horizontal: false, vertical: true)
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityLabel("Host route consent")
                }
                if let problem = shownProblem {
                    StatusText(verbatim: problem, style: .error)
                        .accessibilityIdentifier("add-route-problem")
                }
            }
        } footer: {
            SheetConfirmFooter(
                "Add", canConfirm: liveProblem == nil,
                confirm: { model.confirmAddRoute(rawPattern: pattern, runtime: runtime, consent: consent) },
                cancel: model.cancelAddRoute)
        }
    }

    /// What is wrong with the values as they stand. Nothing before the user has typed or ticked anything: the empty
    /// form is just waiting, though Add stays off.
    private var liveProblem: String? {
        RuntimesModel.patternProblem(
            pattern, existing: model.currentRuntimeConfig?.routes ?? [], runtime: runtime, consent: consent)
    }

    private var shownProblem: String? {
        if !model.sheetProblem.isEmpty { return model.sheetProblem }
        let untouched = pattern.trimmingCharacters(in: .whitespaces).isEmpty && !consent
        return untouched ? nil : liveProblem
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
