import KinhinKit
import SwiftUI

/// Advanced → Routing: the fleet's runtime pools, capacity budget, routes,
/// and labels. State and actions live in `RuntimesModel`; the two heavy
/// modals (Add Route, Edit YAML) stay AppKit in `RuntimesSheets`.
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
                        if !model.availabilityRows.isEmpty {
                            SectionHeader("On this Mac")
                            ForEach(model.availabilityRows, id: \.id) { row in
                                card(title: row.title, detail: row.detail)
                            }
                        }

                        SectionHeader("Pools & capacity")
                        ForEach(model.poolRows) { pool in
                            poolCard(pool)
                        }

                        if model.showsBudget {
                            SectionHeader("Budget")
                            budgetCard
                        }

                        SectionHeader("Routes")
                        if model.routeRows.isEmpty {
                            StatusText(text: "  No routes — every job uses the default pool.")
                        } else {
                            ForEach(model.routeRows, id: \.pattern) { route in
                                routeCard(route)
                            }
                        }

                        SectionHeader("Labels")
                        labelsCard

                        StatusText(
                            text:
                                "Unmatched jobs → \(model.defaultRuntimeID.rawValue)",
                            style: .secondary
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                }
            }
            footer
        }
        .padding(.leading, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            StatusText(text: model.headline, style: .secondary)
        }
        .frame(width: FormMetrics.width, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Add Route…") { model.addRouteClicked() }
            Button("Edit YAML…") {
                RuntimesSheets.editConfigYAML(configURL: model.configURL); model.reload()
            }
            HintText("Slider changes apply on release; validation gates every write.")
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

    // MARK: Budget

    private var budgetCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.starvedRoutes.isEmpty {
                Text(model.starvedRoutes.joined(separator: "\n"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(StatusStyle.error.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(width: FormMetrics.width - 60, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .systemRed).opacity(0.12)))
            }

            Picker(
                "Default (gets the remainder):",
                selection: Binding(
                    get: { model.defaultRuntimeID.rawValue },
                    set: { model.defaultRuntimeChanged(to: $0) }
                )
            ) {
                ForEach(model.budgetRuntimeIDs, id: \.rawValue) { runtime in
                    Text(runtime.rawValue).tag(runtime.rawValue)
                }
            }
            .controlSize(.small)
            .labelsHidden()

            ForEach(model.budgetRuntimeIDs.filter { $0 != model.defaultRuntimeID }, id: \.rawValue) { runtime in
                HStack(spacing: 8) {
                    Text(runtime.rawValue)
                        .font(.system(size: 12))
                        .frame(width: 110, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { model.budgetShare(for: runtime) },
                            set: { model.budgetSliderChanged(runtime: runtime, fraction: $0) }
                        ),
                        in: 0...1
                    )
                    .controlSize(.small)
                    .frame(width: 220)
                    .accessibilityLabel("\(runtime.rawValue) budget share")
                    Text(model.percentText(for: runtime))
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 44, alignment: .leading)
                    Text(model.capPreviews[runtime].map { "\($0) inst" } ?? "")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .leading)
                }
            }

            HintText(model.remainderNote)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: FormMetrics.width, alignment: .leading)
        .formSurface(cornerRadius: 8)
    }

    // MARK: Labels

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
