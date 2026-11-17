import KinhinKit
import SwiftUI

/// The Routes card: which repository or workflow goes to which runtime, the pool unmatched jobs use, the label fields
/// and the Edit YAML… door. Everything here writes at once (nothing is staged).
struct RoutesCard: View {
    @Bindable var model: RuntimesModel

    var body: some View {
        Card(
            title: "Routes", subtitle: "Send a repository, or one workflow, to a runtime.", layout: .fill
        ) {
            StarvedRoutesStrip(warnings: model.starvedRoutes)
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(model.routeRows) { route in
                    routeRow(route)
                }
            }
            HStack(spacing: Spacing.sm) {
                Button("Add Route…") { model.addRouteClicked() }
                    .controlSize(.small)
                    .accessibilityIdentifier("routes-add")
                if model.routeRows.isEmpty {
                    HintText("No routes — every job uses the default pool.")
                }
            }
            defaultPoolPicker
            labelFields
            HStack(spacing: Spacing.sm) {
                Button("Edit YAML…") { model.editYAMLClicked() }
                    .controlSize(.small)
                    .accessibilityIdentifier("routes-edit-yaml")
                HintText("Every setting without a control lives in config.yaml.")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("routes-card")
    }

    // MARK: - Routes

    private func routeRow(_ route: RuntimesModel.RouteDisplay) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(verbatim: route.pattern)
                .typeStyle(.body)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)
            if route.isWorkflow {
                Text("(workflow)").typeStyle(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.sm)
            Chip(verbatim: RuntimesModel.routeChipTitle(route.runtime), tone: .neutral)
            if route.runtime == .host { Chip("unisolated", tone: .error) }
            Button("Remove") { model.removeRoute(pattern: route.pattern) }
                .controlSize(.small)
                .accessibilityLabel("Remove route \(route.pattern)")
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.lg).fill(Palette.grouped))
    }

    // MARK: - Default pool

    /// Which pool takes jobs no route claims. With several pools it also keeps the share the others leave.
    @ViewBuilder
    private var defaultPoolPicker: some View {
        if model.showsBudget {
            HStack(alignment: .bottom, spacing: Spacing.md) {
                LabeledControl("Jobs with no route run on") {
                    Picker(
                        "Jobs with no route run on",
                        selection: Binding(
                            get: { model.defaultRuntimeID },
                            set: { model.defaultRuntimeChanged(to: $0) })
                    ) {
                        ForEach(model.budgetRuntimeIDs, id: \.rawValue) { runtime in
                            Text(
                                verbatim: RuntimesModel.cardTitle(runtime)
                                    + MaturityTable.maturity(of: runtime).pickerSuffix
                            )
                            .tag(runtime)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("routes-default-pool")
                }
                HintText("The default pool also keeps whatever share the others leave.")
            }
        } else {
            StatusText(text: "Unmatched jobs → \(model.defaultRuntimeID.rawValue)", style: .secondary)
        }
    }

    // MARK: - Labels

    private var labelFields: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .top, spacing: Spacing.lg) {
                LabeledControl("Fleet base labels (every runner)") {
                    LabelsField(
                        text: $model.fleetLabelsText, id: "routes-fleet-labels",
                        label: Text("Fleet base labels"),
                        commit: { model.commitLabels(scope: .fleet, text: $0) })
                }
                if model.showsContainerLabels {
                    LabeledControl("Container extra labels") {
                        LabelsField(
                            text: $model.containerLabelsText, id: "routes-container-labels",
                            label: Text("Container extra labels"),
                            commit: { model.commitLabels(scope: .container, text: $0) })
                    }
                }
            }
            HintText("Jobs must request a subset of these via runs-on.")
        }
    }
}

/// A comma-separated label field that saves on Return or when focus leaves, and only when the text changed. A failed
/// save snaps `text` back (the model resets it), so the field never shows what was refused.
private struct LabelsField: View {
    @Binding var text: String
    let id: String
    let label: Text
    let commit: (String) -> Void
    @State private var textWhenFocused = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(text: $text) { label }
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 200, maxWidth: .infinity)
            .focused($focused)
            .onSubmit(save)
            .onChange(of: focused) { _, isFocused in
                if isFocused { textWhenFocused = text } else { save() }
            }
            .accessibilityLabel(label)
            .accessibilityIdentifier(id)
    }

    private func save() {
        guard text != textWhenFocused else { return }
        textWhenFocused = text
        commit(text)
    }
}
