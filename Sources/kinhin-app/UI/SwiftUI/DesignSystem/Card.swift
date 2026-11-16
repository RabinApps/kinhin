import KinhinKit
import SwiftUI

/// The rounded, bordered container every form section sits in.
///
/// Literal titles and subtitles are looked up in the String Catalog; model-built (already
/// localized) text is passed as `Text(verbatim:)`.
struct FormCard<Content: View>: View {
    let title: Text
    var subtitle: Text?
    /// A forge whose brand mark leads the title (forge cards).
    var forge: ForgeID?
    @ViewBuilder var content: Content

    init(
        title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, forge: ForgeID? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = Text(title)
        self.subtitle = subtitle.map { Text($0) }
        self.forge = forge
        self.content = content()
    }

    init(title: Text, subtitle: Text? = nil, forge: ForgeID? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.forge = forge
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let forge { ForgeIconView(forge: forge, size: 14) }
                title.font(.system(size: 13, weight: .semibold))
            }
            if let subtitle { HintText(subtitle) }
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: FormMetrics.width, alignment: .leading)
        .formSurface(cornerRadius: 10)
    }
}

/// A `FormCard` whose body folds away behind its title row. Starts collapsed;
/// `badge` stays visible in the header (e.g. "2 selected").
struct CollapsibleFormCard<Content: View>: View {
    let title: Text
    var subtitle: Text?
    /// Already-localized text (e.g. a count), so it is shown verbatim.
    var badge: String?
    @ViewBuilder var content: Content
    @State private var expanded = false

    init(
        title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, badge: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = Text(title)
        self.subtitle = subtitle.map { Text($0) }
        self.badge = badge
        self.content = content()
    }

    init(title: Text, subtitle: Text? = nil, badge: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.badge = badge
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
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: FormMetrics.width, alignment: .leading)
        .formSurface(cornerRadius: 10)
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
