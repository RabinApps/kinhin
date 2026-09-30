import KinhinKit
import SwiftUI

/// SwiftUI counterparts of the `FormKit` builders, so hosted forms look the
/// same as the AppKit ones still around them.
enum FormMetrics {
    /// Width of a form card (matches `FormKit.formWidth`).
    static let width: CGFloat = 520
}

/// Semantic colors for one-line status text.
enum StatusStyle {
    case secondary, ok, warn, error

    var color: Color {
        switch self {
        case .secondary: return Color(nsColor: .secondaryLabelColor)
        case .ok: return Color(nsColor: .systemGreen)
        case .warn: return Color(nsColor: .systemOrange)
        case .error: return Color(nsColor: .systemRed)
        }
    }
}

/// A status message with its color, as kept by form models.
struct StatusLine: Equatable {
    var text: String
    var style: StatusStyle = .secondary

    /// A config write the editor rejected (nothing was written).
    static func notSaved(_ error: Error) -> StatusLine {
        StatusLine(text: "Not saved — \(error.localizedDescription)", style: .error)
    }

    /// config.yaml doesn't parse: said on the form instead of rendering
    /// defaults as if nothing were configured.
    static func unreadableConfig(_ error: Error) -> StatusLine {
        StatusLine(
            text: "config.yaml can't be read — \(error.localizedDescription). Fix it in Advanced → Edit YAML.",
            style: .error)
    }
}

/// A settings form backed by config.yaml: where it reads and writes, and who
/// to tell after a successful write (the app pushes the edit to the fleet).
@MainActor
protocol ConfigFormModel: AnyObject {
    var configURL: URL { get set }
    var onChanged: (() -> Void)? { get set }
}

/// One line of status feedback ("Connected ✓", "Not saved — …").
struct StatusText: View {
    let text: String
    var style: StatusStyle = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(style.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Small secondary text that wraps within its card.
struct HintText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A small uppercase label that titles a group of cards.
struct SectionHeader: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
    }
}

/// The rounded, bordered container every form section sits in.
struct FormCard<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
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
    let title: String
    var subtitle: String?
    var badge: String?
    @ViewBuilder var content: Content
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 10)
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    if let badge { Text(badge).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(expanded ? "expanded" : "collapsed")

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

/// A collapsible "Token permissions" list: exactly what a forge token needs,
/// with a link to where it is created. Expands itself when `expandOnError`.
struct TokenRequirementsView: View {
    let requirements: TokenRequirements
    var expandOnError = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 10)
                    Text("Token permissions needed").font(.system(size: 11, weight: .semibold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Token permissions needed")
            .accessibilityValue(expanded ? "expanded" : "collapsed")

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(requirements.options, id: \.kind) { option in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(option.kind).font(.system(size: 11, weight: .semibold))
                                if let url = URL(string: option.url), option.url.hasPrefix("http") {
                                    Link("Create…", destination: url).font(.system(size: 11))
                                }
                            }
                            ForEach(option.permissions, id: \.self) { line in
                                HintText("• " + line).textSelection(.enabled)
                            }
                        }
                    }
                    if let note = requirements.note { HintText(note) }
                }
                .padding(.leading, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: expandOnError) { _, isError in if isError { expanded = true } }
    }
}
