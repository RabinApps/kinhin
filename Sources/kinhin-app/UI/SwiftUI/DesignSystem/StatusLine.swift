import KinhinKit
import SwiftUI

/// The four status styles of the design. Never color alone: every use pairs the color with its text (or an icon).
enum StatusStyle {
    case secondary, ok, warn, error

    /// The color of status *text*: the AA-safe variants of the design.
    var color: Color {
        switch self {
        case .secondary: return Palette.secondaryText
        case .ok: return Palette.greenText
        case .warn: return Palette.orangeText
        case .error: return Palette.redText
        }
    }

    /// The system color for a dot, bar or tinted background that accompanies the text.
    var fill: Color {
        switch self {
        case .secondary: return Palette.secondaryText
        case .ok: return Palette.green
        case .warn: return Palette.orange
        case .error: return Palette.red
        }
    }
}

/// A status message with its color, as kept by form models.
struct StatusLine: Equatable {
    var text: String
    var style: StatusStyle = .secondary

    /// A config write the editor rejected (nothing was written).
    static func notSaved(_ error: Error) -> StatusLine {
        StatusLine(
            text: String(
                localized: "Not saved — \(error.localizedDescription)", bundle: .l10n,
                comment: "Form status line; %@ is the error's description"), style: .error)
    }

    /// config.yaml doesn't parse: said on the form instead of rendering
    /// defaults as if nothing were configured.
    static func unreadableConfig(_ error: Error) -> StatusLine {
        StatusLine(
            text: String(
                localized: "config.yaml can't be read — \(error.localizedDescription). Fix it in Runtimes → Edit YAML.",
                bundle: .l10n, comment: "Form status line; %@ is the YAML parse error"),
            style: .error)
    }
}

/// One line of status feedback ("Connected ✓", "Not saved — …").
///
/// A literal (`StatusText(text: "idle")`) is looked up in the String Catalog; text a model already
/// built (and localized) goes through `verbatim:`.
struct StatusText: View {
    let text: Text
    var style: StatusStyle = .secondary

    init(text: LocalizedStringKey, style: StatusStyle = .secondary) {
        self.text = Text(text)
        self.style = style
    }

    init(verbatim text: String, style: StatusStyle = .secondary) {
        self.text = Text(verbatim: text)
        self.style = style
    }

    var body: some View {
        text
            .typeStyle(.caption)
            .foregroundStyle(style.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Small secondary text that wraps within its card. A literal is looked up in the String Catalog;
/// text a model already built (and localized) goes through `verbatim:`.
struct HintText: View {
    let text: Text

    init(_ key: LocalizedStringKey) { self.text = Text(key) }

    init(_ text: Text) { self.text = text }

    init(verbatim text: String) { self.text = Text(verbatim: text) }

    var body: some View {
        text
            .typeStyle(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A small uppercase label that titles a group of cards.
struct SectionHeader: View {
    let key: LocalizedStringKey

    init(_ key: LocalizedStringKey) { self.key = key }

    var body: some View {
        Text(key)
            .textCase(.uppercase)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.tertiary)
    }
}
