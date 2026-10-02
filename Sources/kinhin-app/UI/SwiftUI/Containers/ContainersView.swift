import KinhinKit
import SwiftUI

/// Advanced → Containers: the tool picker, then a card each for containers and
/// volumes. State and actions live in `ContainersModel`.
struct ContainersView: View {
    let model: ContainersModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
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
                if model.busy { ProgressView().controlSize(.small) }
                Button("Refresh") { model.reload() }
            }
            .controlSize(.small)
            .frame(width: FormMetrics.width)

            if !model.status.text.isEmpty {
                StatusText(text: model.status.text, style: model.status.style)
                    .frame(width: FormMetrics.width, alignment: .leading)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    FormCard(title: "Containers") {
                        if model.containers.isEmpty { HintText("No containers.") }
                        ForEach(model.containers) { containerRow($0) }
                    }
                    FormCard(title: "Volumes") {
                        if model.volumes.isEmpty { HintText("No volumes.") }
                        ForEach(model.volumes) { volumeRow($0) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
            }
        }
        .padding(.leading, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func containerRow(_ item: ManagedContainer) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                rowTitle(item.name)
                Text(detail(item))
                    .font(.system(size: 11))
                    .foregroundStyle(item.isRunning ? StatusStyle.ok.color : StatusStyle.secondary.color)
                    .lineLimit(1)
            }
            Spacer()
            ForEach(model.lifecycle(for: item), id: \.self) { action in
                Button(action.rawValue) { model.perform(action, id: item.id) }
                    .accessibilityLabel("\(action.rawValue) container \(item.name)")
            }
            Button("Delete…") { model.deleteContainer(id: item.id) }
                .accessibilityLabel("Delete container \(item.name)")
        }
        .controlSize(.small)
    }

    private func volumeRow(_ item: ManagedVolume) -> some View {
        HStack {
            rowTitle(item.name)
            Spacer()
            Button("Delete…") { model.deleteVolume(name: item.name) }
                .accessibilityLabel("Delete volume \(item.name)")
        }
        .controlSize(.small)
    }

    private func rowTitle(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func detail(_ item: ManagedContainer) -> String {
        let usage = model.usage[item.name].flatMap(FleetStatusFormatter.describe)
        return [item.image, item.status.isEmpty ? item.state : item.status, usage ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
