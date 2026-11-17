import SwiftUI

/// The inset row of the design's grouped cards: a grouped-background rounded rectangle (radius 6, 10 by 8 padding)
/// holding a title, optional detail and a trailing accessory. Used by every Diagnostics pane and the Settings cards.
struct InsetRow<Leading: View, Content: View, Trailing: View>: View {
    var alignment: VerticalAlignment = .center
    @ViewBuilder var leading: Leading
    @ViewBuilder var content: Content
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: alignment, spacing: Spacing.sm + 2) {
            leading
            content.frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, Spacing.sm + 2)
        .padding(.vertical, Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.md).fill(Palette.grouped))
    }
}

extension InsetRow where Leading == EmptyView {
    init(
        alignment: VerticalAlignment = .center, @ViewBuilder content: () -> Content,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(alignment: alignment, leading: { EmptyView() }, content: content, trailing: trailing)
    }
}

extension InsetRow where Trailing == EmptyView {
    init(
        alignment: VerticalAlignment = .center, @ViewBuilder leading: () -> Leading,
        @ViewBuilder content: () -> Content
    ) {
        self.init(alignment: alignment, leading: leading, content: content, trailing: { EmptyView() })
    }
}

extension InsetRow where Leading == EmptyView, Trailing == EmptyView {
    init(alignment: VerticalAlignment = .center, @ViewBuilder content: () -> Content) {
        self.init(alignment: alignment, leading: { EmptyView() }, content: content, trailing: { EmptyView() })
    }
}

/// A row with a title and an optional second line: the "label / hint" shape of the Settings and Diagnostics rows.
struct RowLabel: View {
    let title: Text
    var detail: Text?

    init(_ title: LocalizedStringKey, detail: LocalizedStringKey? = nil) {
        self.title = Text(title)
        self.detail = detail.map { Text($0) }
    }

    init(verbatim title: String, detail: String? = nil) {
        self.title = Text(verbatim: title)
        self.detail = detail.map { Text(verbatim: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            title.typeStyle(.body).fontWeight(.medium)
            if let detail { HintText(detail) }
        }
    }
}

/// The dot that leads a health row: green when fine, red when not (a filled circle, with a symbol for VoiceOver).
struct StatusDot: View {
    let style: StatusStyle
    var size: CGFloat = 10

    var body: some View {
        Circle().fill(style.fill).frame(width: size, height: size).accessibilityHidden(true)
    }
}

#Preview("Inset rows") {
    VStack(spacing: Spacing.sm) {
        InsetRow(leading: { StatusDot(style: .ok) }, content: { RowLabel(verbatim: "Host", detail: "10 cores") })
        InsetRow(content: { RowLabel(verbatim: "Show at launch") }, trailing: { Text(verbatim: "Yes") })
    }
    .padding(Spacing.lg).frame(width: 480)
}
