import AppKit

/// Small view builders shared by the Setup tab, the onboarding wizard, and
/// the Advanced tab so every form looks and reads the same.
@MainActor
enum FormKit {
    static let formWidth: CGFloat = 520

    /// A rounded card with a bold title and a vertical content column.
    static func card(title: String, subtitle: String? = nil) -> (card: NSView, column: NSStackView) {
        let card = LayerStyleView(frame: .zero)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.styleLayer = { layer in
            layer.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer.cornerRadius = 10
            layer.borderWidth = 1
            layer.borderColor = NSColor.separatorColor.cgColor
        }
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 13, weight: .semibold)

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        if let subtitle {
            column.addArrangedSubview(hint(subtitle))
        }

        header.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(header)
        card.addSubview(column)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            column.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            column.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            card.widthAnchor.constraint(equalToConstant: formWidth),
        ])
        return (card, column)
    }

    static func label(_ text: String, weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: weight)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    /// Small secondary text that wraps within the card.
    static func hint(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = formWidth - 28
        return label
    }

    static func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    /// A vertical, scrolling stack of cards pinned to the clip view (the
    /// document view has no intrinsic size of its own).
    static func scrollingColumn(spacing: CGFloat = 12) -> (scroll: NSScrollView, stack: NSStackView) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Flipped document so content starts at the top, not the bottom.
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8),
        ])
        return (scroll, stack)
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
