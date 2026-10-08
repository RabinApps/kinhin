import SwiftUI

/// The Fleet tab's top card: a visual diagram of where the fleet runs, which
/// also carries the old VM list. One lane per execution runtime (its identity
/// mark + name), every live instance one icon-led row — a phase-colored icon
/// followed by its detail text and the Pipeline…/Delete actions — and an
/// explicit "idle" for a runtime with nothing running. State comes from
/// `FleetDiagramModel`, derived from the same status snapshot as the status
/// card below it.
struct FleetDiagramView: View {
    let model: FleetDiagramModel
    /// Headline shown instead of the lanes before the first status arrives
    /// ("Checking the fleet…", "Needs setup — …", "Fleet not responding — …").
    var placeholder: String?
    /// Opens the live pipeline sheet for the tapped row.
    var onOpenPipeline: (String) -> Void
    /// Confirms, then deletes the instance (the old VM list's Delete button).
    var onDelete: (String) -> Void

    var body: some View {
        FormCard(title: "Runtimes", subtitle: subtitle) {
            if let placeholder {
                StatusText(text: placeholder, style: .secondary)
                    .accessibilityIdentifier("fleet-diagram-placeholder")
            } else if model.lanes.isEmpty {
                StatusText(text: "No runtimes — the fleet is idle.")
                    .accessibilityIdentifier("fleet-diagram-empty")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(model.lanes.indices), id: \.self) { index in
                        if index > 0 { Divider() }
                        laneRow(model.lanes[index])
                    }
                }
                .accessibilityIdentifier("fleet-diagram")
            }
        }
        .accessibilityIdentifier("fleet-diagram-card")
    }

    /// How many instances are up and how many hold a job — the card's only
    /// summary, so it appears only once something is running.
    private var subtitle: String? {
        guard placeholder == nil, model.instanceCount > 0 else { return nil }
        return "\(model.instanceCount) instance\(model.instanceCount == 1 ? "" : "s") · \(model.busyCount) busy"
    }

    // MARK: - Lanes

    private func laneRow(_ lane: FleetDiagramModel.Lane) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(lane.mark)
                    .font(.system(size: 12))
                Text(lane.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if lane.isIdle {
                    StatusText(text: "idle")
                        .accessibilityIdentifier("fleet-diagram-idle-\(lane.id.rawValue)")
                } else if let count = lane.countText {
                    Text(count)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel(count)
                }
            }
            if !lane.isIdle {
                // One list per lane: an icon-led row for every instance.
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(lane.instances) { instanceRow($0) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(lane.title) — \(lane.isIdle ? "idle" : (lane.countText ?? "running"))")
    }

    /// One instance as a single row — the phase icon leads, then the old VM
    /// list's title, detail line, and Pipeline…/Delete actions. Tapping the
    /// icon or the text opens the pipeline when the instance can hold a job.
    private func instanceRow(_ instance: FleetDiagramModel.Instance) -> some View {
        HStack(spacing: 8) {
            rowLead(instance)
            Spacer(minLength: 12)
            if instance.opensPipeline {
                Button("Pipeline…") { onOpenPipeline(instance.id) }
                    .controlSize(.small)
                    .accessibilityLabel("Show pipeline of \(instance.id)")
            }
            Button("Delete") { onDelete(instance.id) }
                .controlSize(.small)
                .accessibilityLabel("Delete \(instance.id)")
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 30)
        .accessibilityIdentifier("fleet-diagram-row-\(instance.id)")
    }

    /// The tappable head of a row: the phase icon plus the title and detail
    /// text, announced as one element (tooltip text) and — when there is a
    /// pipeline to show — activatable like a button.
    @ViewBuilder
    private func rowLead(_ instance: FleetDiagramModel.Instance) -> some View {
        let lead = HStack(spacing: 8) {
            rowIcon(instance)
            VStack(alignment: .leading, spacing: 1) {
                Text(instance.title)
                    .font(.system(size: 11, design: .monospaced))
                Text(instance.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(instance.hasError ? StatusStyle.error.color : StatusStyle.secondary.color)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if instance.opensPipeline { onOpenPipeline(instance.id) } }
        .help(instance.tooltip)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(instance.accessibilityText)
        if instance.opensPipeline {
            lead
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { onOpenPipeline(instance.id) }
        } else {
            lead
        }
    }

    /// The row's leading icon: a rounded square tinted by state — the phase
    /// at a glance, carrying the tooltip's facts for VoiceOver.
    private func rowIcon(_ instance: FleetDiagramModel.Instance) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        return Image(systemName: instance.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(instance.style.color)
            .frame(width: 26, height: 26)
            .background(shape.fill(instance.style.color.opacity(0.12)))
            .overlay(shape.strokeBorder(instance.style.color.opacity(0.4), lineWidth: 1))
            .accessibilityHidden(true)
    }
}
