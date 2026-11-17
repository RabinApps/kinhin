import KinhinKit
import SwiftUI

/// How wide a `Card` is: the fixed form width of the existing screens, or as wide as its column.
enum CardLayout {
    /// `FormMetrics.width` (680). The existing forms are laid out for it.
    case form
    /// Fills the column it sits in (the design's "fill + max width" cards).
    case fill
}

/// The grouped card of the design (radius 12, padding 16, 12 between its parts): an optional title row with an optional
/// subtitle and trailing accessory (a chip, a dot, a button), then the content.
///
/// Literal titles and subtitles are looked up in the String Catalog; model-built (already
/// localized) text is passed as `Text(verbatim:)`. `FormCard` is the same type with no trailing accessory.
struct Card<Content: View, Trailing: View>: View {
    let title: Text?
    var subtitle: Text?
    /// A forge whose brand mark leads the title (forge cards).
    var forge: ForgeID?
    var layout: CardLayout = .form
    let trailing: Trailing
    @ViewBuilder var content: Content

    init(
        title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, forge: ForgeID? = nil,
        layout: CardLayout = .form, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content
    ) {
        self.title = Text(title)
        self.subtitle = subtitle.map { Text($0) }
        self.forge = forge
        self.layout = layout
        self.trailing = trailing()
        self.content = content()
    }

    init(
        title: Text, subtitle: Text? = nil, forge: ForgeID? = nil, layout: CardLayout = .form,
        @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.forge = forge
        self.layout = layout
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            if title != nil || Trailing.self != EmptyView.self {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        HStack(spacing: Spacing.xs) {
                            if let forge { ForgeIconView(forge: forge, size: 14) }
                            title?.typeStyle(.emphasis)
                        }
                        if let subtitle { HintText(subtitle) }
                    }
                    Spacer(minLength: Spacing.sm)
                    trailing
                }
            }
            content
        }
        .padding(Spacing.lg)
        .frame(width: layout == .form ? FormMetrics.width : nil, alignment: .leading)
        .frame(maxWidth: layout == .fill ? .infinity : nil, alignment: .leading)
        .formSurface(cornerRadius: Radius.xl)
    }
}

extension Card where Trailing == EmptyView {
    init(
        title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, forge: ForgeID? = nil,
        layout: CardLayout = .form, @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title, subtitle: subtitle, forge: forge, layout: layout, trailing: { EmptyView() }, content: content)
    }

    init(
        title: Text, subtitle: Text? = nil, forge: ForgeID? = nil, layout: CardLayout = .form,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title, subtitle: subtitle, forge: forge, layout: layout, trailing: { EmptyView() }, content: content)
    }

    /// An untitled card: just the grouped surface around its content (the Fleet screen's status card).
    init(layout: CardLayout = .form, @ViewBuilder content: () -> Content) {
        self.title = nil
        self.subtitle = nil
        self.forge = nil
        self.layout = layout
        self.trailing = EmptyView()
        self.content = content()
    }
}

/// The card with no trailing accessory: what the existing screens call.
typealias FormCard<Content: View> = Card<Content, EmptyView>

/// A `FormCard` whose body folds away behind its title row. Starts collapsed;
/// `badge` stays visible in the header (e.g. "2 selected").
struct CollapsibleFormCard<Content: View>: View {
    let title: Text
    var subtitle: Text?
    /// Already-localized text (e.g. a count), so it is shown verbatim.
    var badge: String?
    var layout: CardLayout = .form
    @ViewBuilder var content: Content
    @State private var expanded = false

    init(
        title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, badge: String? = nil,
        layout: CardLayout = .form, @ViewBuilder content: () -> Content
    ) {
        self.title = Text(title)
        self.subtitle = subtitle.map { Text($0) }
        self.badge = badge
        self.layout = layout
        self.content = content()
    }

    init(
        title: Text, subtitle: Text? = nil, badge: String? = nil, layout: CardLayout = .form,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.badge = badge
        self.layout = layout
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.forward")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 10)
                    title.font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    if let badge { Text(verbatim: badge).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(expanded ? Text("expanded") : Text("collapsed"))

            if expanded {
                if let subtitle { HintText(subtitle) }
                content
            }
        }
        .padding(Spacing.lg)
        .frame(width: layout == .form ? FormMetrics.width : nil, alignment: .leading)
        .frame(maxWidth: layout == .fill ? .infinity : nil, alignment: .leading)
        .formSurface(cornerRadius: Radius.xl)
    }
}

extension View {
    /// Card background and hairline border, following light/dark appearance.
    func formSurface(cornerRadius: CGFloat) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}
