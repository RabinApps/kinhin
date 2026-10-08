import KinhinKit
import SwiftUI

/// Advanced → Capacity's Budget card: a stacked bar of the whole split and
/// one slider row per pool (the default's share is the live remainder, shown
/// like everyone else's). The picker for jobs with no route lives in
/// Routing. State and
/// actions live in `RuntimesModel`; every drag goes through
/// `budgetSliderChanged`, which keeps the shares totaling 100%.
struct BudgetCard: View {
    @Bindable var model: RuntimesModel

    /// Column widths, shared by the header row and the share rows so the
    /// labels line up over the numbers they name.
    private enum Column {
        static let name: CGFloat = 135  // color dot + pool name + "default" chip
        static let lock: CGFloat = 16
        static let slider: CGFloat = 150
        static let percent: CGFloat = 52  // typed field + "%"
        static let cap: CGFloat = 54
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StarvedRoutesStrip(warnings: model.starvedRoutes)
            BudgetAllocationBar(rows: model.budgetRows)
            columnHeader
            ForEach(model.budgetRows) { row in
                shareRow(row)
            }
            if !model.budgetNotice.isEmpty {
                StatusText(text: model.budgetNotice, style: .warn)
            }
            HintText(
                "Shares always total 100%. Drag or type a number; lock a pool to keep its share fixed while the others rebalance. Changes apply on release."
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: FormMetrics.width, alignment: .leading)
        .formSurface(cornerRadius: 8)
    }

    // MARK: - Sections

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text("POOL")
                .frame(width: Column.name, alignment: .leading)
            Spacer(minLength: 4)
            Text("SHARE")
                .frame(width: Column.lock + Column.slider + Column.percent + 16, alignment: .center)
            Text("INSTANCES")
                .frame(width: Column.cap, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }

    private func shareRow(_ row: RuntimesModel.BudgetRow) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(RuntimeTint.color(for: row.id))
                .frame(width: 7, height: 7)
            Text(row.id.rawValue)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            if row.isDefault {
                defaultChip
            }
            Spacer(minLength: 4)
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
                .font(.system(size: 11, weight: .medium))
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
            Image(systemName: locked ? "lock.fill" : "lock.open")
                .font(.system(size: 10))
                .foregroundStyle(locked ? Color.accentColor : Color.secondary)
                .frame(width: Column.lock)
        }
        .buttonStyle(.plain)
        .help(locked ? "Unlock \(row.id.rawValue)" : "Lock \(row.id.rawValue)'s share so other sliders leave it alone")
        .accessibilityLabel(locked ? "Unlock \(row.id.rawValue) share" : "Lock \(row.id.rawValue) share")
    }

    /// The default chip marks which pool absorbs unmatched jobs — the
    /// picker below changes it.
    private var defaultChip: some View {
        Text("default")
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(.secondary)
            .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor)))
    }

    // MARK: - Cell text

    private func capText(_ row: RuntimesModel.BudgetRow) -> String {
        row.cap.map { "\($0) inst" } ?? "n/a"
    }

    private func capAccessibilityText(_ row: RuntimesModel.BudgetRow) -> String {
        guard let cap = row.cap else { return "instance cap not partitioned" }
        return cap == 0 ? "instance cap 0 — no runner can start" : "\(cap) instances"
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
        HStack(spacing: 1) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .font(.system(size: 12, weight: .medium))
                .frame(width: 34)
                .focused($focused)
                .disabled(!isEnabled)
                .onSubmit(commit)
                .accessibilityLabel("\(runtime.rawValue) budget percent")
            Text("%").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .quaternaryLabelColor).opacity(focused ? 0.6 : 0.25))
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
/// Budget card and by Routing (above the routes it is about).
struct StarvedRoutesStrip: View {
    let warnings: [String]

    var body: some View {
        if !warnings.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .accessibilityLabel("Warning")
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(warnings, id: \.self) { warning in
                        Text(warning)
                            .font(.system(size: 11, weight: .medium))
                    }
                }
            }
            .foregroundStyle(StatusStyle.error.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .systemRed).opacity(0.12)))
        }
    }
}
