import KinhinKit
import SwiftUI

/// The split between runtimes: a stacked bar of the whole split and one slider row per pool (the default's share is
/// the live remainder, shown like everyone else's). The picker for jobs with no route lives with the routes. State and
/// actions live in `RuntimesModel`; every drag goes through `budgetSliderChanged`, which keeps the shares totaling 100%.
///
/// `BudgetCard` is the form-width card the setup wizard embeds; the Runtimes page uses `SplitCard`, the same rows in a
/// full-width titled card.
struct BudgetCard: View {
    @Bindable var model: RuntimesModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            BudgetRowsView(model: model)
            HintText(
                "Shares always total 100%. Drag or type a number; lock a pool to keep its share fixed while the others rebalance. Changes apply on release."
            )
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.md - 2)
        .frame(width: FormMetrics.width, alignment: .leading)
        .formSurface(cornerRadius: Radius.lg)
    }
}

/// The Runtimes page's "Split between runtimes" card. With one pool there is nothing to split and it says so.
struct SplitCard: View {
    @Bindable var model: RuntimesModel
    /// Capacity edits are waiting for Apply, so the instance counts are about to change.
    let hasUnappliedCapacity: Bool

    var body: some View {
        Card(
            title: "Split between runtimes",
            subtitle: model.showsBudget
                ? "Shares always total 100%. Drag or type a number; lock a pool to keep its share." : nil,
            layout: .fill,
            trailing: {
                if model.showsBudget, hasUnappliedCapacity {
                    HintText("Instance counts update once you Apply")
                }
            }
        ) {
            if model.showsBudget {
                BudgetRowsView(model: model)
            } else {
                Text(
                    "Only one runtime is enabled, so there's nothing to split. Enable another to share capacity."
                )
                .typeStyle(.body)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("split-single-runtime")
            }
        }
    }
}

/// The bar, the column headings, the share rows, the capped notice and the starved-route banner.
struct BudgetRowsView: View {
    @Bindable var model: RuntimesModel

    /// Column widths, shared by the header row and the share rows so the
    /// labels line up over the numbers they name.
    private enum Column {
        static let slider: CGFloat = 150
        static let percent: CGFloat = 62  // typed field + "%"
        static let cap: CGFloat = 84  // wide enough for the "INSTANCES" header
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            BudgetAllocationBar(rows: model.budgetRows)
            VStack(alignment: .leading, spacing: Spacing.sm) {
                columnHeader
                ForEach(model.budgetRows) { row in
                    shareRow(row)
                }
            }
            if !model.budgetNotice.isEmpty {
                StatusText(verbatim: model.budgetNotice, style: .warn)
            }
            StarvedRoutesStrip(warnings: model.starvedRoutes)
        }
    }

    // MARK: - Sections

    private var columnHeader: some View {
        HStack(spacing: Spacing.sm) {
            Text("POOL")
            Spacer(minLength: Spacing.xs)
            Text("SHARE")
                .frame(width: Column.slider + Column.percent + 52, alignment: .center)
            Text("INSTANCES")
                .lineLimit(1)
                .frame(width: Column.cap, alignment: .trailing)
        }
        .typeStyle(.caption)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    private func shareRow(_ row: RuntimesModel.BudgetRow) -> some View {
        HStack(spacing: Spacing.sm) {
            RuntimeDot(runtime: row.id)
            Text(verbatim: RuntimesModel.cardTitle(row.id))
                .typeStyle(.body)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)
            if row.isDefault {
                Chip("default", tone: .accent)
            }
            Spacer(minLength: Spacing.xs)
            lockButton(row)
            Slider(
                value: Binding(
                    get: { model.percentShares[row.id.rawValue] ?? model.budgetShare(for: row.id) },
                    set: { model.budgetSliderChanged(runtime: row.id, fraction: $0) }
                ),
                in: 0...1,
                onEditingChanged: { model.budgetDragEditingChanged($0) }
            )
            .controlSize(.small)
            .frame(width: Column.slider)
            .disabled(!model.canMoveBudget(row.id))
            .accessibilityLabel("\(row.id.rawValue) budget share")
            PercentField(
                runtime: row.id, share: row.share, isEnabled: model.canMoveBudget(row.id), model: model
            )
            .frame(width: Column.percent, alignment: .trailing)
            Text(capText(row))
                .typeStyle(.caption)
                .foregroundStyle(row.cap == 0 ? StatusStyle.error.color : Color.secondary)
                .frame(width: Column.cap, alignment: .trailing)
                .accessibilityLabel(capAccessibilityText(row))
        }
        .accessibilityElement(children: .contain)
    }

    private func lockButton(_ row: RuntimesModel.BudgetRow) -> some View {
        let locked = model.isLocked(row.id)
        return Button {
            model.toggleLock(row.id)
        } label: {
            if locked { Text("Unlock") } else { Text("Lock") }
        }
        .controlSize(.small)
        .help(locked ? "Unlock \(row.id.rawValue)" : "Lock \(row.id.rawValue)'s share so other sliders leave it alone")
        .accessibilityLabel(locked ? "Unlock \(row.id.rawValue) share" : "Lock \(row.id.rawValue) share")
    }

    // MARK: - Cell text

    private func capText(_ row: RuntimesModel.BudgetRow) -> String {
        row.cap.map { cap in
            String(
                localized: "cap \(cap)", bundle: .l10n,
                comment: "Capacity table cell: the pool's instance cap")
        }
            ?? String(
                localized: "n/a", bundle: .l10n,
                comment: "Capacity table cell when there is no instance cap (not applicable)")
    }

    private func capAccessibilityText(_ row: RuntimesModel.BudgetRow) -> String {
        guard let cap = row.cap else {
            return String(
                localized: "instance cap not partitioned", bundle: .l10n,
                comment: "VoiceOver text of a capacity table cell")
        }
        return cap == 0
            ? String(
                localized: "instance cap 0 — no runner can start", bundle: .l10n,
                comment: "VoiceOver text of a capacity table cell")
            : String(
                localized: "\(cap) instances", bundle: .l10n,
                comment: "VoiceOver text of a capacity table cell; plural by the cap")
    }
}

/// The typed share: shows the live percent, commits on Return or when focus
/// leaves, and falls back to the model's value for junk. Local text only
/// while it has focus, so drags elsewhere keep it in sync.
private struct PercentField: View {
    let runtime: RuntimeID
    let share: Double
    let isEnabled: Bool
    let model: RuntimesModel

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .typeStyle(.body)
                .frame(width: 34)
                .focused($focused)
                .disabled(!isEnabled)
                .onSubmit(commit)
                .accessibilityLabel("\(runtime.rawValue) budget percent")
            Text(verbatim: "%").typeStyle(.body).foregroundStyle(.secondary)
        }
        .padding(.horizontal, Spacing.xs + 2)
        .padding(.vertical, Spacing.xs)
        .background(RoundedRectangle(cornerRadius: Radius.md).fill(Palette.surface))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(focused ? Palette.accent : Palette.separator, lineWidth: 1)
        )
        .onAppear { text = Self.display(share) }
        .onChange(of: share) { _, new in if !focused { text = Self.display(new) } }
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    }

    private func commit() {
        guard text != Self.display(share) else { return }  // untouched: nothing to write
        model.budgetPercentTyped(runtime: runtime, text: text)
        text = Self.display(model.percentShares[runtime.rawValue] ?? share)
    }

    private static func display(_ share: Double) -> String { "\(Int((share * 100).rounded()))" }
}

/// Inline banner for splits that would strand a routed pool — shown while
/// the drag is still in progress, not after a failed save. Used by the
/// split card and by the routes card (above the routes it is about).
struct StarvedRoutesStrip: View {
    let warnings: [String]

    var body: some View {
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(warnings, id: \.self) { warning in
                    Banner(verbatim: warning, kind: .error)
                }
            }
        }
    }
}
