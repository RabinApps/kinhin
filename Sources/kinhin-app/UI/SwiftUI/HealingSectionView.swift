import KinhinKit
import SwiftUI

/// The Diagnostics sheet's healing card: the policy, the fixes waiting for
/// approval, the problems only the user can fix, and the recent history.
struct HealingSectionView: View {
    let healing: HealingPresentation
    let busyIDs: Set<String>
    let approve: (String) -> Void
    let dismiss: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("●")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(dotStyle.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Healing").font(.system(size: 13, weight: .semibold))
                    secondary(healing.policy)
                    if let advisor = healing.advisor { secondary(advisor) }
                }
            }

            if !healing.pending.isEmpty {
                group(title: Text("Waiting for your approval")) {
                    ForEach(healing.pending) { item in
                        HealingItemRow(item: item) {
                            Button("Approve") { approve(item.id) }
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
                secondary(
                    String(
                        localized: "Nothing to fix so far.", bundle: .l10n,
                        comment: "Diagnostics healing card when the journal is empty"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 500, alignment: .leading)
        .formSurface(cornerRadius: 8)
    }

    /// Amber while something waits on the user, green otherwise, grey when off.
    private var dotStyle: StatusStyle {
        guard healing.enabled else { return .secondary }
        return healing.pending.isEmpty && healing.surfaced.isEmpty ? .ok : .warn
    }

    private func secondary(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func group(title: Text, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            title.font(.system(size: 11, weight: .semibold))
            content()
        }
        .padding(.leading, 24)
    }
}

/// One journal entry: outcome and age, what happened, the advisor's reason,
/// and its buttons.
private struct HealingItemRow<Actions: View>: View {
    let item: HealingPresentation.Item
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: item.outcomeLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(outcomeStyle.color)
                    Text(verbatim: AppFormat.relative(item.updatedAt))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                // Selectable so commands in the instructions can be copied.
                Text(verbatim: item.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let explanation = item.explanation {
                    Text(
                        verbatim: String(
                            localized: "Advisor's reasoning: \(explanation)", bundle: .l10n,
                            comment: "Diagnostics healing entry; %@ is the on-device model's one-sentence reason")
                    )
                    .font(.system(size: 11))
                    .italic()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            actions.controlSize(.small)
        }
    }

    private var outcomeStyle: StatusStyle {
        switch item.outcome {
        case .succeeded, .resolved: return .ok
        case .failed: return .error
        case .pending, .surfaced, .running: return .warn
        case .dismissed, .expired: return .secondary
        }
    }
}
