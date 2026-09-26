import AppKit
import KinhinKit

/// A small modal progress window for the setup repairs: a title and a
/// spinner for the whole run, closed when the task finishes. A failure shows
/// the error through `AlertKit` — never a silent no-op.
@MainActor
enum RepairProgress {
    static func run(title: String, _ body: @escaping () async throws -> Void) {
        let progress = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 0, height: 16))
        progress.isIndeterminate = true
        progress.startAnimation(nil)

        // Explicit container + constraints (never a bare stack as contentView —
        // same fragility that blanked the setup window).
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 90))
        let window = NSWindow(
            contentRect: container.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(NSTextField(labelWithString: title))
        stack.addArrangedSubview(progress)
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -14),
        ])
        window.contentView = container
        window.center()
        window.makeKeyAndOrderFront(nil)

        Task { @MainActor in
            do {
                try await body()
                window.close()
            } catch {
                window.close()
                AlertKit.present(error: error, title: Self.alertTitle(from: title))
            }
        }
    }

    /// "Installing tart via Homebrew…" titles the progress window; the same
    /// words (ellipsis dropped) title the failure alert.
    private static func alertTitle(from progressTitle: String) -> String {
        var title = progressTitle
        if title.hasSuffix("…") { title.removeLast() }
        return title
    }
}
