import AppKit
import KinhinKit

/// "Select your toolchains": the setup wizard's dedicated step for choosing
/// what gets preinstalled into the runner images.
///
/// Unlike the Advanced → Toolchains page (which seeds everything ON from the
/// saved config, or falls back to every catalog entry ON when there is no
/// config yet), this form starts every tool and stack OFF so the user can
/// explicitly pick what they need. Nothing is written until **Apply**.
@MainActor
class ToolchainsFormViewController: ToolchainsViewController {
    /// Seed every catalog tool and stack OFF so the selection starts empty.
    private func catalogSelection() -> ToolchainsSelection {
        var out = ToolchainsSelection()
        for entry in ToolchainCatalog.tools {
            out.tools[entry.id] = nil
        }
        for stack in ToolchainCatalog.stacks {
            out.stacks[stack.id] = nil
        }
        return out
    }

    /// Load the view, then seed the grid with every catalog tool/stack OFF
    /// (the user must explicitly enable each one). This is used by the setup
    /// wizard where there is no saved config yet.
    /// Load the view, seed every tool/stack OFF, then render. Mirrors the
    /// parent's `loadView()` scaffold (scroll/column/footer/container) so the
    /// form is never blank, but starts the selection empty so the user
    /// explicitly enables each toolchain.
    override func loadView() {
        let (scroll, column) = FormKit.scrollingColumn()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(stack)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
        statusLabel.preferredMaxLayoutWidth = 300
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        applyButton.target = self
        applyButton.action = #selector(applyClicked)
        applyButton.identifier = NSUserInterfaceItemIdentifier("toolchains-apply")
        revertButton.bezelStyle = .rounded
        revertButton.target = self
        revertButton.action = #selector(revertClicked)
        let footer = FormKit.row([progress, statusLabel, FormKit.spacer(), revertButton, applyButton])
        footer.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(scroll)
        container.addSubview(footer)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            footer.widthAnchor.constraint(equalToConstant: FormKit.formWidth),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        // Seed all OFF (the user must explicitly enable each toolchain).
        working = catalogSelection()
        refreshState()
        render()
    }
}
