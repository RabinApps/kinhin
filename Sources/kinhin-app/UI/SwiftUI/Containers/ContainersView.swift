import KinhinKit
import SwiftUI

/// Diagnostics → Containers: the tool picker card, then a card each for containers and volumes. State and actions live
/// in `ContainersModel`.
struct ContainersView: View {
    let model: ContainersModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                Card(title: "Tool", layout: .fill) {
                    HStack(spacing: Spacing.sm) {
                        Picker(
                            "Container tool",
                            selection: Binding(get: { model.tool }, set: { model.select($0) })
                        ) {
                            ForEach(model.selectableTools, id: \.self) { Text($0.title) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        Spacer()
                        if model.busy { ProgressView().controlSize(.small).accessibilityLabel("Working") }
                        Button("Refresh") { model.reload() }
                    }
                    .controlSize(.small)
                    if !model.status.text.isEmpty {
                        StatusText(verbatim: model.status.text, style: model.status.style)
                    }
                }
                Card(title: "Containers", layout: .fill) {
                    VStack(spacing: Spacing.sm) {
                        ForEach(model.containers) { containerRow($0) }
                    }
                    if model.containers.isEmpty { HintText("No containers.") }
                }
                Card(title: "Volumes", layout: .fill) {
                    VStack(spacing: Spacing.sm) {
                        ForEach(model.volumes) { volumeRow($0) }
                    }
                    if model.volumes.isEmpty { HintText("No volumes.") }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, Spacing.md)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Live CPU/RAM: SwiftUI cancels this task when the tab goes away.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))  // cancellation ends the loop via isCancelled
                await model.refreshUsage()
            }
        }
    }

    private func containerRow(_ item: ManagedContainer) -> some View {
        InsetRow(
            content: {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    rowTitle(item.name)
                    Text(detail(item))
                        .typeStyle(.caption)
                        .foregroundStyle(item.isRunning ? StatusStyle.ok.color : StatusStyle.secondary.color)
                        .lineLimit(1)
                }
            },
            trailing: {
                HStack(spacing: Spacing.sm) {
                    ForEach(model.lifecycle(for: item), id: \.self) { action in
                        Button(action.label) { model.perform(action, id: item.id) }
                            .accessibilityLabel(action.accessibilityLabel(container: item.name))
                    }
                    Button("Delete…") { model.deleteContainer(id: item.id) }
                        .accessibilityLabel(
                            String(
                                localized: "Delete container \(item.name)", bundle: .l10n,
                                comment: "VoiceOver label of a container row button; %@ is the container name"))
                }
                .controlSize(.small)
            })
    }

    private func volumeRow(_ item: ManagedVolume) -> some View {
        InsetRow(
            content: { rowTitle(item.name) },
            trailing: {
                Button("Delete…") { model.deleteVolume(name: item.name) }
                    .controlSize(.small)
                    .accessibilityLabel(
                        String(
                            localized: "Delete volume \(item.name)", bundle: .l10n,
                            comment: "VoiceOver label of a volume row button; %@ is the volume name"))
            })
    }

    private func rowTitle(_ name: String) -> some View {
        Text(verbatim: name)
            .typeStyle(.body)
            .fontWeight(.semibold)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func detail(_ item: ManagedContainer) -> String {
        let usage = model.usage[item.name].flatMap(FleetStatusFormatter.describe)
        let pool = model.pool(of: item).map {
            String(
                localized: "pool \($0)", bundle: .l10n,
                comment: "Instance detail: the named container pool it runs in; %@ is the pool name")
        }
        return [item.image, pool ?? "", item.status.isEmpty ? item.state : item.status, usage ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
