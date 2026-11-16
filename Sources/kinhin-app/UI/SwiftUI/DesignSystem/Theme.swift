import AppKit
import SwiftUI

// The design tokens of `design/kinhin-app.fig` (page "Components"): the spacing and radius scales, the type styles
// and the semantic colors. Views take every metric, font and color from here, so a change to the design is a change
// to one file. See "Design first" in CONTRIBUTING.md.

// MARK: - Spacing and radius

/// The spacing scale: 2 / 4 / 8 / 12 / 16 / 20 / 24 points.
enum Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24

    /// Padding around a page's content, and between its cards.
    static let page = xxl
}

/// The corner-radius scale: 2 / 4 / 6 / 8 / 12 points. Cards use `xl`, banners `lg`, controls and rows `md`.
enum Radius {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let md: CGFloat = 6
    static let lg: CGFloat = 8
    static let xl: CGFloat = 12
}

// MARK: - Type styles

/// The type scale. macOS system text styles where one matches (body 13, title3 15, title2 17, title 22; `callout`
/// is the 12-point caption), so the fonts follow the system rather than a hard-coded family.
enum TypeStyle {
    /// 12 / regular: hints, secondary lines, chips.
    case caption
    /// 13 / regular.
    case body
    /// 13 / semibold: row titles, card titles.
    case emphasis
    /// 15 / semibold: a section's sub-heading.
    case heading
    /// 17 / bold: sheet titles, the sidebar's product name.
    case title
    /// 22 / bold: a page's heading.
    case display

    var font: Font {
        switch self {
        case .caption: return .callout
        case .body: return .body
        case .emphasis: return .body.weight(.semibold)
        case .heading: return .title3.weight(.semibold)
        case .title: return .title2.weight(.bold)
        case .display: return .title.weight(.bold)
        }
    }
}

extension View {
    /// Applies one of the design's type styles.
    func typeStyle(_ style: TypeStyle) -> some View { font(style.font) }
}

// MARK: - Colors

/// Semantic colors. Fills (dots, bars, selection, chip backgrounds) use the system colors; colored *text* and filled
/// buttons use the `…Text` variants, slightly deeper in light mode so the label clears WCAG AA (4.5:1) on the card and
/// window backgrounds, and the plain system color in dark mode.
enum Palette {
    // Fills.
    static let accent = Color.accentColor
    static let green = Color(nsColor: .systemGreen)
    static let orange = Color(nsColor: .systemOrange)
    static let red = Color(nsColor: .systemRed)
    static let teal = Color(nsColor: .systemTeal)
    static let purple = Color(nsColor: .systemPurple)

    // Surfaces.
    /// The page behind the cards (grouped background).
    static let grouped = Color(nsColor: .windowBackgroundColor)
    /// A card, field or row surface.
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
    /// The star beside "Support kinhin".
    static let star = Color(nsColor: .kinhinStar)

    // Text.
    static let primaryText = Color(nsColor: .labelColor)
    static let secondaryText = Color(nsColor: .secondaryLabelColor)
    static let accentText = Color(nsColor: .kinhinAccentText)
    static let greenText = Color(nsColor: .kinhinGreenText)
    static let orangeText = Color(nsColor: .kinhinOrangeText)
    static let redText = Color(nsColor: .kinhinRedText)
}

extension NSColor {
    /// A color with a fixed light-mode value (the design's AA-safe variant) and a dark-mode value from the system.
    fileprivate static func adaptive(light: (CGFloat, CGFloat, CGFloat), dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua { return dark }
            return NSColor(srgbRed: light.0 / 255, green: light.1 / 255, blue: light.2 / 255, alpha: 1)
        }
    }

    /// Blue text: #0062E0 in light mode.
    static let kinhinAccentText = adaptive(light: (0, 98, 224), dark: .systemBlue)
    /// Green text: #1F7A35 in light mode.
    static let kinhinGreenText = adaptive(light: (31, 122, 53), dark: .systemGreen)
    /// Orange text: #B34700 in light mode.
    static let kinhinOrangeText = adaptive(light: (179, 71, 0), dark: .systemOrange)
    /// The Support star: #7A5A00 in light mode (a yellow that holds against the sidebar), system yellow in dark.
    static let kinhinStar = adaptive(light: (122, 90, 0), dark: .systemYellow)
    /// Red text: #C70014 in light mode.
    static let kinhinRedText = adaptive(light: (199, 0, 20), dark: .systemRed)
}
