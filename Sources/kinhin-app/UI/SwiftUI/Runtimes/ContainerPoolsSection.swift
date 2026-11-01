import KinhinKit
import SwiftUI

/// Advanced → Routing's Container pools group: a card per named Apple container pool (labels, shape, floors,
/// Docker, image and whether it is built) with Edit… and Remove, then Add Container Pool…. Without `pools:`, a
/// hint says the section is one pool. State and actions live in `RuntimesModel` (`RuntimesModel+ContainerPools`).
struct ContainerPoolsSection: View {
    @Bindable var model: RuntimesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let rows = model.containerPoolRows
            if rows.isEmpty {
                StatusText(
                    text: "  No named pools — every container job runs in the one pool container: describes.",
                    style: .secondary)
            }
            ForEach(rows) { row in
                poolCard(row)
            }
            HStack {
                Button("Add Container Pool…") { model.addContainerPoolClicked() }
                    .controlSize(.small)
                Spacer()
            }
            .frame(width: FormMetrics.width, alignment: .leading)
        }
    }

    private func poolCard(_ row: RuntimesModel.ContainerPoolRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: row.id)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let chip = RuntimesModel.builtChip(row.built) {
                    Text(verbatim: chip.text)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(chip.style.color)
                }
                Spacer(minLength: 8)
                Button("Edit…") { model.editContainerPoolClicked(name: row.id) }
                    .controlSize(.small)
                    .accessibilityLabel("Edit container pool \(row.id)")
                Button("Remove") { model.removeContainerPool(name: row.id) }
                    .controlSize(.small)
                    .accessibilityLabel("Remove container pool \(row.id)")
            }
            Text(verbatim: row.detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: FormMetrics.width, alignment: .leading)
        .formSurface(cornerRadius: 8)
    }
}
