import SwiftUI

/// The Fleet page's runtime cards: one `Card` per execution runtime (its identity mark and name, a dot in its color,
/// "N instances · cap C" or "idle"), every live instance one row — phase glyph, name, phase word, detail line and the
/// Pipeline / Delete buttons. State comes from `FleetDiagramModel`, derived from the same status snapshot as the
/// status block above it.
struct FleetDiagramView: View {
    let model: FleetDiagramModel
    /// Text shown instead of the lanes before the first status arrives or while the fleet can't be reached
    /// ("Checking the fleet…", "Fleet not responding — …").
    var placeholder: String?
    /// Opens the live pipeline sheet for the tapped row.
    var onOpenPipeline: (String) -> Void
    /// Confirms, then deletes the instance.
    var onDelete: (String) -> Void

    var body: some View {
        if let placeholder {
            Card(title: "Runtimes", layout: .fill) {
                StatusText(verbatim: placeholder)
                    .accessibilityIdentifier("fleet-diagram-placeholder")
            }
            .accessibilityIdentifier("fleet-diagram-card")
        } else if model.lanes.isEmpty {
            Card(title: "Runtimes", layout: .fill) {
                StatusText(text: "No runtimes — the fleet is idle.")
                    .accessibilityIdentifier("fleet-diagram-empty")
            }
            .accessibilityIdentifier("fleet-diagram-card")
        } else {
            VStack(alignment: .leading, spacing: Spacing.md) {
                ForEach(model.lanes) { laneCard($0) }
            }
            .accessibilityIdentifier("fleet-diagram")
        }
    }

    private func laneAccessibilityLabel(_ lane: FleetDiagramModel.Lane) -> String {
        let state =
            lane.isIdle
            ? String(localized: "idle", bundle: .l10n, comment: "VoiceOver state of an empty runtime lane")
            : (lane.countText
                ?? String(localized: "running", bundle: .l10n, comment: "VoiceOver state of a busy runtime lane"))
        return String(
            localized: "\(lane.title) — \(state)", bundle: .l10n,
            comment: "VoiceOver label of a runtime lane: its name, then idle/running/instance count")
    }

    // MARK: - Lanes

    private func laneCard(_ lane: FleetDiagramModel.Lane) -> some View {
        Card(
            title: Text(verbatim: lane.title), subtitle: Text(verbatim: lane.subtitle), layout: .fill,
            trailing: { RuntimeDot(runtime: lane.id) },
            content: {
                if !lane.isIdle {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        ForEach(lane.instances) { instanceRow($0) }
                    }
                }
            }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(laneAccessibilityLabel(lane))
        .accessibilityIdentifier("fleet-diagram-lane-\(lane.id.rawValue)")
    }

    /// One instance: glyph, name, phase word, detail, then Pipeline (only when it holds a job) and Delete. Tapping the
    /// text opens the pipeline when the instance can hold a job.
    private func instanceRow(_ instance: FleetDiagramModel.Instance) -> some View {
        HStack(spacing: Spacing.md - 2) {
            rowLead(instance)
            Spacer(minLength: Spacing.md)
            if instance.opensPipeline {
                Button("Pipeline") { onOpenPipeline(instance.id) }
                    .accessibilityLabel("Show pipeline of \(instance.id)")
            }
            Button("Delete") { onDelete(instance.id) }
                .accessibilityLabel("Delete \(instance.id)")
        }
        .controlSize(.small)
        .padding(.horizontal, Spacing.md - 2)
        .padding(.vertical, Spacing.sm - 1)
        .background(RoundedRectangle(cornerRadius: Radius.md).fill(Palette.grouped))
        .accessibilityIdentifier("fleet-diagram-row-\(instance.id)")
    }

    /// The head of a row, announced as one element (tooltip text) and, when there is a pipeline to show, activatable
    /// like a button.
    @ViewBuilder
    private func rowLead(_ instance: FleetDiagramModel.Instance) -> some View {
        let color = instance.tone.text
        let lead = HStack(spacing: Spacing.md - 2) {
            Image(systemName: instance.symbol)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(verbatim: instance.name).typeStyle(.body).fontWeight(.medium)
            Text(verbatim: instance.phaseWord)
                .font(.callout.weight(.semibold))
                .foregroundStyle(color)
            if !instance.detail.isEmpty {
                Text(verbatim: instance.detail)
                    .typeStyle(.caption)
                    .foregroundStyle(instance.hasError ? StatusStyle.error.color : StatusStyle.secondary.color)
                    .lineLimit(2)
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
}
