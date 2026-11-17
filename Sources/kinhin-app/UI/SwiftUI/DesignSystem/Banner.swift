import SwiftUI

/// A full-width notice at the top of a page: a warning ("Disk is almost full") or an error ("Fleet not responding"),
/// tinted with the system color, an icon and the message in primary text, and an optional action (Dismiss). The icon
/// and the words carry the severity, the tint only reinforces it.
struct Banner: View {
    /// The banner's severity. `warn` and `error` are what the design draws; `info` is the neutral variant.
    enum Kind: Equatable {
        case info, warn, error

        var style: StatusStyle {
            switch self {
            case .info: return .secondary
            case .warn: return .warn
            case .error: return .error
            }
        }

        var symbol: String {
            switch self {
            case .info: return "info.circle.fill"
            case .warn, .error: return "exclamationmark.triangle.fill"
            }
        }
    }

    let kind: Kind
    let message: Text
    var trailingAction: (title: Text, label: Text?, run: () -> Void)?

    init(_ key: LocalizedStringKey, kind: Kind) {
        self.kind = kind
        message = Text(key)
    }

    /// Already-localized text a model built.
    init(verbatim text: String, kind: Kind) {
        self.kind = kind
        message = Text(verbatim: text)
    }

    /// Adds a trailing action, e.g. `Banner(verbatim: notice, kind: .warn).action("Dismiss") { … }`.
    /// `label` is the spoken name when "Dismiss" alone is ambiguous ("Dismiss the disk pressure warning").
    func action(_ title: LocalizedStringKey, label: LocalizedStringKey? = nil, _ run: @escaping () -> Void) -> Banner {
        var copy = self
        copy.trailingAction = (Text(title), label.map { Text($0) }, run)
        return copy
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.md - 2) {
            Image(systemName: kind.symbol)
                .foregroundStyle(kind.style.color)
                .accessibilityHidden(true)
            message
                .typeStyle(.body)
                .fontWeight(.medium)
                .foregroundStyle(Palette.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let trailingAction {
                Button(action: trailingAction.run) { trailingAction.title }
                    .controlSize(.small)
                    .accessibilityLabel(trailingAction.label ?? trailingAction.title)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(RoundedRectangle(cornerRadius: Radius.lg).fill(kind.style.fill.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(kind.style.fill.opacity(0.6), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

#Preview("Banners") {
    VStack(spacing: Spacing.sm) {
        Banner(verbatim: "Disk is almost full — new VMs are held.", kind: .warn).action("Dismiss") {}
        Banner(verbatim: "Fleet not responding.", kind: .error)
        Banner(verbatim: "Auto-resume is on.", kind: .info)
    }
    .padding(Spacing.lg)
    .frame(width: 520)
}
