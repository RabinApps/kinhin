import AppKit
import KinhinKit
import SwiftUI

/// The shared shell of a runtime's card on the Runtimes page: the header (dot, name, labels, health, "default" and
/// maturity chips, the enable switch), the health note, then the runtime's own body. A runtime that is not serving
/// jobs shows only what turning it on needs (`content` decides, from the state it is handed).
struct RuntimeCard<Content: View>: View {
    let runtime: RuntimeID
    @Bindable var runtimes: RuntimesModel
    let mac: MacToolsModel
    /// A one-line description under the name, for a runtime with no labels to list (Host).
    var detail: Text?
    /// The switch is disabled with this reason when the runtime cannot be turned on yet (its tool is missing).
    var cannotEnableReason: Text?
    /// Opens the runtime's own app (Docker Desktop) from a button on the health note's banner.
    var openApp: (() -> Void)?
    @ViewBuilder var content: (RuntimesModel.PoolState) -> Content

    var body: some View {
        let state = runtimes.poolState(runtime)
        VStack(alignment: .leading, spacing: Spacing.lg - 2) {
            header(state)
            if state == .on, let note = runtimes.healthNote(for: runtime) {
                noteBanner(note)
            }
            content(state)
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .formSurface(cornerRadius: Radius.xl)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("runtime-card-\(runtime.rawValue)")
    }

    private func noteBanner(_ note: String) -> Banner {
        let banner = Banner(verbatim: note, kind: .warn)
        guard let openApp else { return banner }
        return banner.action("Open Docker", openApp)
    }

    // MARK: - Header

    private func header(_ state: RuntimesModel.PoolState) -> some View {
        HStack(alignment: .center, spacing: Spacing.md - 2) {
            RuntimeDot(runtime: runtime, size: Spacing.md)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(verbatim: RuntimesModel.cardTitle(runtime)).typeStyle(.heading)
                if state == .on, let detail {
                    detail.typeStyle(.caption).foregroundStyle(.secondary)
                } else if state == .on, let labels = runtimes.labelsLine(for: runtime) {
                    Text(verbatim: labels).typeStyle(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Spacing.sm)
            chips(state)
            if runtime != .host { enableSwitch(state) }
        }
        .opacity(state == .on ? 1 : 0.7)
    }

    @ViewBuilder
    private func chips(_ state: RuntimesModel.PoolState) -> some View {
        if state == .on {
            if let chip = runtimes.healthChip(for: runtime) {
                Chip(verbatim: chip.text, style: chip.style)
            }
            if runtimes.isDefaultPool(runtime) { Chip("default", tone: .accent) }
        }
        if runtime == .host {
            Chip("unisolated", tone: .error)
        } else {
            MaturityChip(maturity: MaturityTable.maturity(of: runtime))
        }
    }

    private func enableSwitch(_ state: RuntimesModel.PoolState) -> some View {
        let blocked = state != .on && cannotEnableReason != nil
        let locked = state == .on && !runtimes.canSwitchOff(runtime)
        return Toggle(
            "",
            isOn: Binding(
                get: { state == .on },
                set: { runtimes.setRuntimeOn(runtime, $0, mac: mac) })
        )
        .labelsHidden()
        .toggleStyle(.switch)
        .disabled(locked || blocked)
        .help(
            locked
                ? Text("The default pool, or a pool a route uses, stays on.")
                : (blocked ? (cannotEnableReason ?? Text(verbatim: "")) : Text(verbatim: ""))
        )
        .accessibilityLabel("Enable \(runtime.rawValue) pool")
        .accessibilityIdentifier("pool-enabled-\(runtime.rawValue)")
    }
}

/// "Untested" / "Experimental" in the header of a runtime that is not live-tested; nothing for one that is.
struct MaturityChip: View {
    let maturity: Maturity

    var body: some View {
        switch maturity {
        case .liveTested: EmptyView()
        case .untested: Chip("Untested", tone: .warn)
        case .experimental: Chip("Experimental", tone: .warn)
        }
    }
}

/// A tool's status line inside a card ("tart  ·  installed ✓"), with its Install… button when the tool is missing.
struct ToolStatusRow: View {
    let title: Text
    let status: StatusLine
    var actionTitle: Text?
    var actionID = ""
    var action: () -> Void = {}
    var disabled = false

    var body: some View {
        HStack(spacing: Spacing.sm) {
            title.typeStyle(.emphasis)
            Spacer(minLength: Spacing.sm)
            StatusText(verbatim: status.text, style: status.style)
            if let actionTitle {
                Button(action: action) { actionTitle }
                    .controlSize(.small)
                    .disabled(disabled)
                    .accessibilityIdentifier(actionID)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.lg).fill(Palette.grouped))
    }
}

/// A caption over a control: the design's labelled field.
struct LabeledControl<Control: View>: View {
    let label: Text
    @ViewBuilder var control: Control

    init(_ key: LocalizedStringKey, @ViewBuilder control: () -> Control) {
        label = Text(key)
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            label.typeStyle(.caption).fontWeight(.medium).foregroundStyle(.secondary)
            control
        }
    }
}

/// The small buttons beside a status line, disabled while one of the Mac tools' long actions runs.
struct SmallActionButton: View {
    let title: Text
    let id: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) { title }
            .controlSize(.small)
            .disabled(disabled)
            .accessibilityIdentifier(id)
    }
}
