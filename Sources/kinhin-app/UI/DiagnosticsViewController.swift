import AppKit
import KinhinKit

/// The Diagnostics sheet (Fleet tab → Diagnostics…): the full `kinhin
/// doctor` report — host, CLT, tart, containers, capacity, toolchain cache —
/// rendered with green/red chips, live probe results, and copyable fix
/// commands. Read-only; repairs stay in the setup checklist.
@MainActor
final class DiagnosticsViewController: NSViewController {
    private let stack = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "Probing this Mac…")

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("DiagnosticsViewController is created in code")
    }

    override func loadView() {
        let size = NSSize(width: 560, height: 520)
        let container = NSView(frame: NSRect(origin: .zero, size: size))

        let title = NSTextField(labelWithString: "🩺  Diagnostics")
        title.font = .systemFont(ofSize: 18, weight: .bold)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        let header = NSStackView(views: [title, statusLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4
        header.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = stack
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // The document stack has no frame of its own (auto layout): pin its
        // width and top to the clip view or it collapses to 0x0 and the
        // report renders invisible. No bottom pin — the stack grows past the
        // viewport and the clip view scrolls (a bottom equality would fight
        // the taller-than-viewport content).
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])

        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\r"
        closeButton.setAccessibilityLabel("Close diagnostics")
        let footer = NSStackView(views: [NSView(), closeButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.arrangedSubviews[0].setContentHuggingPriority(.defaultLow, for: .horizontal)

        container.addSubview(header)
        container.addSubview(scroll)
        container.addSubview(footer)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),

            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
        ])

        view = container
        Task { await load() }
    }

    /// Runs the doctor probe set (the same builder `kinhin doctor --json`
    /// uses) and renders the result.
    func load() async {
        statusLabel.stringValue = "Probing this Mac…"
        let report = await DoctorReportBuilder().build()
        render(report)
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        statusLabel.stringValue = "Checked \(stamp)"
    }

    /// Refresh only when the sheet is visible (called from the poll loop).
    func refreshIfVisible() async {
        guard isViewLoaded, view.window != nil else { return }
        await load()
    }

    // MARK: Rendering

    /// Internal (not private) so MainWindowTests can pin the report layout
    /// with a decoded fixture — DoctorReport's section inits are internal
    /// to KinhinKit, but the type is Codable with stable field names.
    func render(_ report: DoctorReport) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Host
        stack.addArrangedSubview(row("Host", detail: "\(report.host.logicalCores) cores · \(report.host.memoryGB) GB RAM · \(report.host.freeDiskGB) GB free · \(report.host.arm64 ? "Apple silicon" : "Intel")", ok: true))

        // Command Line Tools
        let cltOK = report.clt.ok
        stack.addArrangedSubview(row("Command Line Tools", detail: report.clt.version ?? report.clt.state, ok: cltOK, fix: cltOK ? nil : report.clt.fixCommand))

        // Tart
        let tartOK = report.tart.ok
        var tartDetail = report.tart.reason ?? "healthy"
        if !report.tart.repairCommands.isEmpty {
            tartDetail += "\nFix: \(report.tart.repairCommands[0])"
        }
        stack.addArrangedSubview(row("Tart (macOS VMs)", detail: tartDetail, ok: tartOK))

        // Containers (only when configured)
        if let container = report.container {
            var detail = container.fix ?? "ready — image \(container.image)"
            if !container.imageFound { detail += "\nimage \(container.image) not built yet (kinhin image prepare --container)" }
            stack.addArrangedSubview(row("Apple container (Linux)", detail: detail, ok: container.ok))
        }
        if let docker = report.docker {
            var detail = docker.fix ?? "ready — image \(docker.image)"
            if !docker.imageFound { detail += "\nimage \(docker.image) not built yet (kinhin image prepare --docker)" }
            stack.addArrangedSubview(row("Docker (Linux)", detail: detail, ok: docker.ok))
        }

        // Capacity (nil when the config can't parse — nothing to plan against)
        if let capacity = report.capacity {
            stack.addArrangedSubview(row(
                "Capacity",
                detail: "\(capacity.maxConcurrent) VMs · \(capacity.jobSlots) job slots — \(capacity.bindingConstraint)",
                ok: capacity.fits
            ))
        }

        // Toolchain cache
        let cache = report.toolchainCache
        var cacheDetail = "\(ByteCountFormatter.string(fromByteCount: cache.totalBytes, countStyle: .file)) cached"
        if cache.warning { cacheDetail += " — shared with runners but empty (run image prepare)" }
        stack.addArrangedSubview(row("Toolchain cache", detail: cacheDetail, ok: cache.usable))
    }

    private func row(_ title: String, detail: String, ok: Bool, fix: String? = nil) -> NSView {
        // Layer-backed card: LayerStyleView re-resolves the background/border
        // colors on every display update, so light/dark switches stay correct.
        let card = LayerStyleView(frame: .zero)
        card.styleLayer = { layer in
            layer.cornerRadius = 8
            layer.borderWidth = 1
            layer.borderColor = NSColor.separatorColor.cgColor
            layer.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }

        let chip = NSTextField(labelWithString: ok ? "●" : "●")
        chip.font = .systemFont(ofSize: 14, weight: .bold)
        chip.textColor = ok ? .systemGreen : .systemRed

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        let detailLabel = NSTextField(wrappingLabelWithString: detail + (fix.map { "\n\($0)" } ?? ""))
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor

        let column = NSStackView(views: [titleLabel, detailLabel])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(chip)
        card.addSubview(column)
        NSLayoutConstraint.activate([
            chip.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            chip.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),

            column.leadingAnchor.constraint(equalTo: chip.trailingAnchor, constant: 10),
            column.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            column.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            column.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -12),

            card.widthAnchor.constraint(equalToConstant: 500),
        ])
        return card
    }

    /// Sheets attached with `beginSheet` are only ended by the parent
    /// window — `dismiss(_:)` walks the presentation chain, which is empty
    /// here, so the Close button did nothing and the sheet stayed attached.
    /// (If the click lands before the sheet finished attaching, orderOut
    /// cancels the pending attach — the parent never keeps it alive.)
    @objc private func closeClicked() {
        guard let sheet = view.window else { return }
        if let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        } else {
            sheet.orderOut(nil)
        }
    }
}
