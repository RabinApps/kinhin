import SwiftUI

/// A pill label: a state ("Running"), a count, a maturity ("Untested"). The tint is a translucent system color behind
/// text in its AA-safe variant; `solid` fills it and sets the text white (the wizard's current step). Always carries
/// text, so the state never reads by color alone.
struct Chip: View {
    enum Tone: Equatable {
        case neutral, accent, ok, warn, error

        var fill: Color {
            switch self {
            case .neutral: return Palette.secondaryText
            case .accent: return Palette.accent
            case .ok: return Palette.green
            case .warn: return Palette.orange
            case .error: return Palette.red
            }
        }

        var text: Color {
            switch self {
            case .neutral: return Palette.secondaryText
            case .accent: return Palette.accentText
            case .ok: return Palette.greenText
            case .warn: return Palette.orangeText
            case .error: return Palette.redText
            }
        }

        init(_ style: StatusStyle) {
            switch style {
            case .secondary: self = .neutral
            case .ok: self = .ok
            case .warn: self = .warn
            case .error: self = .error
            }
        }
    }

    let label: Text
    var tone: Tone = .neutral
    var solid = false
    /// An SF Symbol that leads the label (phase chips: "bolt.fill" busy, "flame" warm).
    var symbol: String?

    init(_ key: LocalizedStringKey, tone: Tone = .neutral, solid: Bool = false, symbol: String? = nil) {
        label = Text(key)
        self.tone = tone
        self.solid = solid
        self.symbol = symbol
    }

    init(verbatim text: String, tone: Tone = .neutral, solid: Bool = false, symbol: String? = nil) {
        label = Text(verbatim: text)
        self.tone = tone
        self.solid = solid
        self.symbol = symbol
    }

    init(verbatim text: String, style: StatusStyle, solid: Bool = false, symbol: String? = nil) {
        self.init(verbatim: text, tone: Tone(style), solid: solid, symbol: symbol)
    }

    var body: some View {
        HStack(spacing: Spacing.xs) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            label
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(solid ? Color.white : tone.text)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xxs + 1)
        .background(Capsule().fill(solid ? tone.text : tone.fill.opacity(0.15)))
        .fixedSize()
    }
}

#Preview("Chips") {
    VStack(alignment: .leading, spacing: Spacing.sm) {
        HStack {
            Chip(verbatim: "Healthy", tone: .ok)
            Chip(verbatim: "Needs attention", tone: .warn)
            Chip(verbatim: "Error", tone: .error)
            Chip(verbatim: "default", tone: .accent)
            Chip(verbatim: "Untested", tone: .warn)
        }
        HStack {
            Chip(verbatim: "busy", tone: .ok, symbol: "bolt.fill")
            Chip(verbatim: "warm", tone: .warn, symbol: "flame")
            Chip(verbatim: "failed", tone: .error, symbol: "exclamationmark.triangle.fill")
            Chip(verbatim: "2", tone: .accent, solid: true)
            Chip(verbatim: "deleting", tone: .neutral, symbol: "xmark.circle")
        }
    }
    .padding(Spacing.lg)
}
