import KinhinKit
import SwiftUI

/// Advanced → Routing: the fleet's runtime pools, routes, default pool and
/// labels (the capacity split lives in Advanced → Capacity). State and actions live in `RuntimesModel`, which owns the
/// Add Route and Edit YAML sheets too (presented from `routeOffer` and
/// `isYAMLEditorOpen`).
struct RuntimesView: View {
    @Bindable var model: RuntimesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if model.loadFailed {
                StatusText(text: model.emptyMessage, style: .warn)
                    .frame(width: FormMetrics.width, alignment: .leading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader("Pools")
                        ForEach(model.poolRows) { pool in
                            poolCard(pool)
                        }

                        SectionHeader("Routes")
                        StarvedRoutesStrip(warnings: model.starvedRoutes)
                        if model.routeRows.isEmpty {
                            StatusText(text: "  No routes — every job uses the default pool.")
                        } else {
                            ForEach(model.routeRows, id: \.pattern) { route in
                                routeCard(route)
                            }
                        }

                        defaultRuntimeCard

                        SectionHeader("Labels")
                        labelsCard
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                }
            }
            footer
        }
        .padding(.leading, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $model.isYAMLEditorOpen) {
            EditYAMLSheet(model: model)
        }
        .sheet(
            item: Binding(
                get: { model.routeOffer },
                set: { if $0 == nil { model.cancelAddRoute() } }
            )
        ) { offer in
            AddRouteSheet(model: model, runtimes: offer.runtimes)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            StatusText(text: model.headline, style: .secondary)
        }
        .frame(width: FormMetrics.width, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Add Route…") { model.addRouteClicked() }
            Button("Edit YAML…") { model.editYAMLClicked() }
            Spacer()
        }
        .controlSize(.small)
        .padding(.top, 6)
        .frame(width: FormMetrics.width, alignment: .leading)
    }

    private func card(title: String, detail: String?, chip: (text: String, style: StatusStyle)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let chip, !chip.text.isEmpty {
                    Text(chip.text)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(chip.style.color)
                }
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: FormMetrics.width, alignment: .leading)
        .formSurface(cornerRadius: 8)
    }

    private func poolCard(_ pool: RuntimesModel.PoolDisplay) -> some View {
        let chip = RuntimesModel.healthChip(pool.health, probing: false)
        return card(title: pool.title, detail: pool.detail, chip: chip)
    }

    private func routeCard(_ route: (pattern: String, title: String)) -> some View {
        HStack {
            Text(route.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button("Remove") { model.removeRoute(pattern: route.pattern) }
                .controlSize(.small)
                .accessibilityLabel("Remove route \(route.pattern)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: FormMetrics.width, alignment: .leading)
        .formSurface(cornerRadius: 8)
    }

    // MARK: - Default runtime

    /// Which pool takes jobs no route claims. With several pools it is also
    /// the one that holds the budget's remainder (see Capacity).
    @ViewBuilder
    private var defaultRuntimeCard: some View {
        if model.showsBudget {
            VStack(alignment: .leading, spacing: 4) {
                Picker(
                    "Jobs with no route run on:",
                    selection: Binding(
                        get: { model.defaultRuntimeID.rawValue },
                        set: { model.defaultRuntimeChanged(to: $0) }
                    )
                ) {
                    ForEach(model.budgetRuntimeIDs, id: \.rawValue) { runtime in
                        Text(runtime.rawValue + MaturityTable.maturity(of: runtime).pickerSuffix).tag(runtime.rawValue)
                    }
                }
                .controlSize(.small)
                HintText("The default pool also keeps whatever share the others leave (Advanced → Capacity).")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(width: FormMetrics.width, alignment: .leading)
            .formSurface(cornerRadius: 8)
        } else {
            StatusText(text: "Unmatched jobs → \(model.defaultRuntimeID.rawValue)", style: .secondary)
        }
    }

    // MARK: - Labels

    private var labelsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Fleet base labels (every runner):")
                .font(.system(size: 12))
            TextField(
                "",
                text: Binding(
                    get: { model.fleetLabelsText },
                    set: { model.fleetLabelsText = $0 }
                ),
                onCommit: { model.commitLabels(scope: .fleet, text: model.fleetLabelsText) }
            )
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .accessibilityLabel("Fleet base labels")
            HintText("Comma-separated. Jobs must request a subset of these via runs-on:.")

            if model.showsContainerLabels {
                Text("Container extra labels (appleContainer pool):")
                    .font(.system(size: 12))
                    .padding(.top, 4)
                TextField(
                    "",
                    text: Binding(
                        get: { model.containerLabelsText },
                        set: { model.containerLabelsText = $0 }
                    ),
                    onCommit: { model.commitLabels(scope: .container, text: model.containerLabelsText) }
                )
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .accessibilityLabel("Container extra labels")
                HintText("Merged with the kinhin-container marker (always present) at pool build.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: FormMetrics.width, alignment: .leading)
        .formSurface(cornerRadius: 8)
    }
}
