import KinhinKit
import SwiftUI

/// The Diagnostics Health pane's healing card: the policy, the advisor, the fixes waiting for approval, the problems
/// only the user can fix, the fixes running now and the recent history.
struct HealingSectionView: View {
    let healing: HealingPresentation
    let busyIDs: Set<String>
    let approve: (String) -> Void
    let dismiss: (String) -> Void

    var body: some View {
        Card(
            title: Text("Healing"), subtitle: healing.enabled ? Text(verbatim: healing.policy) : nil, layout: .fill
        ) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                if !healing.enabled {
                    StatusText(verbatim: healing.policy, style: .warn)
                }
                if let advisor = healing.advisor { HintText(verbatim: advisor) }

                if !healing.pending.isEmpty {
                    group(title: Text("Waiting for your approval")) {
                        ForEach(healing.pending) { item in
                            HealingItemRow(item: item) {
                                Button("Approve") { approve(item.id) }
                                    .buttonStyle(.borderedProminent)
                                    .accessibilityLabel("Approve this fix")
                                Button("Dismiss") { dismiss(item.id) }
                                    .accessibilityLabel("Dismiss this fix")
                            }
                            .disabled(busyIDs.contains(item.id))
                        }
                    }
                }
                if !healing.surfaced.isEmpty {
                    group(title: Text("Needs you")) {
                        ForEach(healing.surfaced) { item in
                            HealingItemRow(item: item) {
                                Button("Dismiss") { dismiss(item.id) }
                                    .accessibilityLabel("Dismiss this problem")
                            }
                            .disabled(busyIDs.contains(item.id))
                        }
                    }
                }
                if !healing.running.isEmpty {
                    group(title: Text("Fixing now")) {
                        ForEach(healing.running) { item in
                            HealingItemRow(item: item) { EmptyView() }
                        }
                    }
                }
                if !healing.history.isEmpty {
                    group(title: Text("Recent")) {
                        ForEach(healing.history) { item in
                            HealingItemRow(item: item) { EmptyView() }
                        }
                    }
                } else if healing.enabled, healing.isQuiet {
                    HintText(
                        verbatim: String(
                            localized: "Nothing to fix so far.", bundle: .l10n,
                            comment: "Diagnostics healing card when the journal is empty"))
                }
            }
        }
    }

    private func group(title: Text, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            title.typeStyle(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            content()
        }
    }
}

/// One journal entry: outcome chip and age, what happened, the advisor's reason, and its buttons.
private struct HealingItemRow<Actions: View>: View {
    let item: HealingPresentation.Item
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                Chip(verbatim: item.outcomeLabel, tone: tone)
                Text(verbatim: AppFormat.relative(item.updatedAt))
                    .typeStyle(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                actions.controlSize(.small)
            }
            // Selectable so commands in the instructions can be copied.
            Text(verbatim: item.detail)
                .typeStyle(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let explanation = item.explanation {
                HintText(
                    verbatim: String(
                        localized: "Advisor's reasoning: \(explanation)", bundle: .l10n,
                        comment: "Diagnostics healing entry; %@ is the on-device model's one-sentence reason")
                )
                .textSelection(.enabled)
            }
        }
        .padding(Spacing.sm + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.md).fill(Palette.grouped))
    }

    private var tone: Chip.Tone { item.chipTone }
}

extension HealingPresentation.Item {
    /// The outcome chip's tone: amber while it waits on approval, red when only the user can act or it failed, blue
    /// while running, green when fixed, grey when closed without a fix.
    var chipTone: Chip.Tone {
        switch outcome {
        case .succeeded, .resolved: return .ok
        case .failed, .surfaced: return .error
        case .pending: return .warn
        case .running: return .accent
        case .dismissed, .expired: return .neutral
        }
    }
}
