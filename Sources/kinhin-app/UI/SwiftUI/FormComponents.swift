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
