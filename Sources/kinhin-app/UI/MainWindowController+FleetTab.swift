import AppKit
import KinhinKit

// The Fleet tab: controls, live status, VM rows, and the actions they trigger.
@MainActor
extension MainTabsWindowController {
    // MARK: Fleet tab

    func buildFleetTab() -> NSView {
        let tab = NSView()
        tab.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "○  kinhin")
        title.font = .systemFont(ofSize: 22, weight: .bold)
        statusLineLabel.font = .systemFont(ofSize: 12)
        statusLineLabel.textColor = .secondaryLabelColor
        statusLineLabel.maximumNumberOfLines = 3

        let headerStack = NSStackView(views: [title, statusLineLabel])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 6
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        tab.addSubview(headerStack)

        let startButton = NSButton(title: "Start", target: self, action: #selector(startClicked))
        startButton.bezelStyle = .rounded
        startButton.setAccessibilityLabel("Start the fleet")
        let stopButton = NSButton(title: "Stop", target: self, action: #selector(stopClicked))
        stopButton.bezelStyle = .rounded
        stopButton.setAccessibilityLabel("Stop the fleet")
        let pause = NSButton(title: "Pause", target: self, action: #selector(pauseClicked))
        pause.bezelStyle = .rounded
        pause.setAccessibilityLabel("Pause or resume the fleet")
        pauseButton = pause

        let controlRow = NSStackView(views: [startButton, stopButton, pause])
        controlRow.orientation = .horizontal
        controlRow.spacing = 8
        controlRow.translatesAutoresizingMaskIntoConstraints = false
        tab.addSubview(controlRow)

        // VMs
        let vmHeader = FormKit.sectionHeader("VMs")
        let vmList = NSStackView()
        vmList.orientation = .vertical
        vmList.alignment = .leading
        vmList.spacing = 4
        vmList.translatesAutoresizingMaskIntoConstraints = false
        vmStack = vmList
        let vmScroll = NSScrollView()
        vmScroll.hasVerticalScroller = true
        vmScroll.drawsBackground = false
        // Flipped document so rows start at the TOP of the scroll area (an
        // unflipped one floats short lists to the bottom).
        let vmDocument = FlippedView()
        vmDocument.translatesAutoresizingMaskIntoConstraints = false
        vmDocument.addSubview(vmList)
        vmScroll.documentView = vmDocument
        vmScroll.translatesAutoresizingMaskIntoConstraints = false
        tab.addSubview(vmHeader)
        tab.addSubview(vmScroll)

        // Current jobs (which workflows are running right now, on which VM)
        let jobsHeader = FormKit.sectionHeader("Current jobs")
        let jobs = NSStackView()
        jobs.orientation = .vertical
        jobs.alignment = .leading
        jobs.spacing = 3
        jobs.translatesAutoresizingMaskIntoConstraints = false
        jobsStack = jobs
        tab.addSubview(jobsHeader)
        tab.addSubview(jobs)

        let diagnosticsButton = NSButton(title: "Diagnostics…", target: self, action: #selector(diagnosticsClicked))
        diagnosticsButton.bezelStyle = .rounded
        let updateButton = NSButton(title: "Check for Updates…", target: self, action: #selector(updateClicked))
        updateButton.bezelStyle = .rounded
        let logsButton = NSButton(title: "Logs…", target: self, action: #selector(showLogsClicked))
        logsButton.bezelStyle = .rounded
        let footer = NSStackView(views: [logsButton, diagnosticsButton, updateButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false
        tab.addSubview(footer)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: tab.topAnchor, constant: 8),
            headerStack.leadingAnchor.constraint(equalTo: tab.leadingAnchor, constant: 20),
            headerStack.trailingAnchor.constraint(lessThanOrEqualTo: tab.trailingAnchor, constant: -20),

            controlRow.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 12),
            controlRow.leadingAnchor.constraint(equalTo: tab.leadingAnchor, constant: 20),

            vmHeader.topAnchor.constraint(equalTo: controlRow.bottomAnchor, constant: 12),
            vmHeader.leadingAnchor.constraint(equalTo: tab.leadingAnchor, constant: 20),

            vmScroll.topAnchor.constraint(equalTo: vmHeader.bottomAnchor, constant: 6),
            vmScroll.leadingAnchor.constraint(equalTo: tab.leadingAnchor, constant: 20),
            vmScroll.trailingAnchor.constraint(equalTo: tab.trailingAnchor, constant: -20),
            vmScroll.heightAnchor.constraint(equalTo: tab.heightAnchor, multiplier: 0.30),
            vmDocument.topAnchor.constraint(equalTo: vmScroll.contentView.topAnchor),
            vmDocument.leadingAnchor.constraint(equalTo: vmScroll.contentView.leadingAnchor),
            vmDocument.trailingAnchor.constraint(equalTo: vmScroll.contentView.trailingAnchor),
            vmList.topAnchor.constraint(equalTo: vmDocument.topAnchor),
            vmList.leadingAnchor.constraint(equalTo: vmDocument.leadingAnchor),
            vmList.trailingAnchor.constraint(equalTo: vmDocument.trailingAnchor),
            vmList.bottomAnchor.constraint(equalTo: vmDocument.bottomAnchor),

            jobsHeader.topAnchor.constraint(equalTo: vmScroll.bottomAnchor, constant: 10),
            jobsHeader.leadingAnchor.constraint(equalTo: tab.leadingAnchor, constant: 20),

            jobs.topAnchor.constraint(equalTo: jobsHeader.bottomAnchor, constant: 6),
            jobs.leadingAnchor.constraint(equalTo: tab.leadingAnchor, constant: 24),
            jobs.trailingAnchor.constraint(lessThanOrEqualTo: tab.trailingAnchor, constant: -20),

            footer.leadingAnchor.constraint(equalTo: tab.leadingAnchor, constant: 20),
            footer.bottomAnchor.constraint(equalTo: tab.bottomAnchor, constant: -14),
        ])
        return tab
    }

    // MARK: Rendering

    /// Re-renders the Fleet tab's status line, controls, VM list, and
    /// current-jobs section. Safe to call before the first refresh.
    func render(status: FleetStatus?) {
        lastStatus = status
        statusLineLabel.stringValue = AppDelegate.statusLineText(for: status)
        isPaused = status?.paused ?? false
        pauseButton?.title = isPaused ? "Resume" : "Pause"

        if let vmStack {
            vmStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            let records = status?.records ?? []
            if records.isEmpty {
                vmStack.addArrangedSubview(FormKit.secondaryLabel("No VMs — the fleet is idle."))
            } else {
                for record in records {
                    vmStack.addArrangedSubview(makeVMRow(for: record))
                }
            }
        }

        if let jobsStack {
            jobsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            let working = (status?.records ?? []).filter { $0.job != nil }
            guard !working.isEmpty else {
                jobsStack.addArrangedSubview(FormKit.secondaryLabel("No jobs running."))
                return
            }
            for record in working {
                let repoText = (record.repos?.joined(separator: ", ") ?? "")
                let text = "▸ \(record.job ?? "") — \(repoText)  (\(record.id), \(record.phase.rawValue))"
                jobsStack.addArrangedSubview(FormKit.secondaryLabel(text, mono: true))
            }
        }
    }

    func makeVMRow(for record: VMRecord) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "• \(record.id) — \(record.phase.rawValue)")
        title.font = .monospacedSystemFont(ofSize: 11, weight: .regular)

        var parts: [String] = []
        if let repos = record.repos, !repos.isEmpty {
            parts.append(repos.count == 1 ? repos[0] : "\(repos.count) repos")
        }
        if let job = record.job { parts.append(job) }
        if let err = record.error { parts.append("⚠︎ \(err)") }
        let detail = NSTextField(labelWithString: parts.joined(separator: " · "))
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = record.error != nil ? .systemRed : .secondaryLabelColor

        let column = NSStackView(views: [title, detail])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 1
        column.translatesAutoresizingMaskIntoConstraints = false

        let delete = NSButton(title: "Delete", target: self, action: #selector(deleteVMClicked(_:)))
        delete.bezelStyle = .rounded
        delete.controlSize = .small
        delete.translatesAutoresizingMaskIntoConstraints = false
        delete.setAccessibilityLabel("Delete \(record.id)")
        delete.identifier = NSUserInterfaceItemIdentifier("deleteVM:\(record.id)")

        row.addSubview(column)
        row.addSubview(delete)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
            column.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 4),
            column.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            delete.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -4),
            delete.leadingAnchor.constraint(greaterThanOrEqualTo: column.trailingAnchor, constant: 12),
            delete.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    @objc func startClicked() { delegate?.startFleet() }
    @objc func stopClicked() { delegate?.stopFleet() }
    @objc func pauseClicked() {
        if isPaused { delegate?.resumeFleet() } else { delegate?.pauseFleet() }
    }

    @objc func deleteVMClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, id.hasPrefix("deleteVM:") else { return }
        delegate?.deleteVM(id: String(id.dropFirst("deleteVM:".count)))
    }

    @objc func logsClicked() { delegate?.openLogsFolder() }
    @objc func updateClicked() { delegate?.checkForUpdatesNow() }
}
