import AppKit
import KinhinKit

// Capacity budget editing (sliders and steppers).
@MainActor
extension RuntimesWindowController {
    // MARK: Budget editing

    /// The budget card: one slider per non-default pool (share of the whole
    /// host budget), the default pool shown as the remainder, and a
    /// default-runtime popup. Every change writes through
    /// RuntimesConfigEditor — engine validation gates the file.
    func makeBudgetCard(rc: KinhinConfig.RuntimeConfig, pools: [RuntimesPaneViewModel.PoolRow]) -> NSView {
        let card = LayerStyleView(frame: .zero)
        card.styleLayer = { layer in
            layer.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer.cornerRadius = 8
            layer.borderWidth = 1
            layer.borderColor = NSColor.separatorColor.cgColor
        }

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(column)

        let defaultRuntime = RuntimeID(rawValue: rc.defaultRuntime) ?? .tart
        let shares = BudgetEditor.displayShares(current: rc.budget, defaultRuntime: defaultRuntime)

        // Starved-route warning strip: visible only when a configured route
        // targets a runtime whose cap is 0 at the current split. Updated
        // live by updateCapPreviews on every slider tick.
        let warning = LayerStyleLabel(wrappingLabelWithString: "") { layer in
            layer.backgroundColor = NSColor.systemRed.withAlphaComponent(0.12).cgColor
            layer.cornerRadius = 6
        }
        warning.font = .systemFont(ofSize: 11, weight: .medium)
        warning.textColor = .systemRed
        warning.identifier = NSUserInterfaceItemIdentifier("budget-warning")
        warning.isHidden = true
        warning.widthAnchor.constraint(equalToConstant: 460).isActive = true
        column.addArrangedSubview(warning)

        // Default-runtime picker row.
        let defaultLabel = NSTextField(labelWithString: "Default (gets the remainder):")
        defaultLabel.font = .systemFont(ofSize: 12)
        let popup = NSPopUpButton()
        popup.controlSize = .small
        for pool in pools {
            popup.addItem(withTitle: pool.runtime.rawValue)
            popup.item(at: popup.numberOfItems - 1)?.representedObject = pool.runtime.rawValue
            if pool.runtime == defaultRuntime {
                popup.select(popup.item(at: popup.numberOfItems - 1))
            }
        }
        popup.target = self
        popup.action = #selector(defaultRuntimeChanged(_:))
        let defaultRow = NSStackView(views: [defaultLabel, popup])
        defaultRow.orientation = .horizontal
        defaultRow.spacing = 8
        column.addArrangedSubview(defaultRow)

        // One slider row per non-default pool. Each row ends in a live
        // "N inst" cap preview: while dragging, it shows what the engine
        // would provision at that split — before anything is saved.
        for pool in pools where pool.runtime != defaultRuntime {
            let share = rc.budget[pool.runtime.rawValue] ?? 0
            let label = NSTextField(labelWithString: pool.runtime.rawValue)
            label.font = .systemFont(ofSize: 12)
            label.widthAnchor.constraint(equalToConstant: 110).isActive = true

            let slider = NSSlider(
                value: share, minValue: 0, maxValue: 1, target: self, action: #selector(budgetSliderChanged(_:)))
            slider.controlSize = .small
            slider.isContinuous = true  // fire during the drag for live previews
            slider.identifier = NSUserInterfaceItemIdentifier(pool.runtime.rawValue)
            slider.widthAnchor.constraint(equalToConstant: 220).isActive = true

            let percent = NSTextField(
                labelWithString: "\(Int((shares[pool.runtime.rawValue] ?? share).rounded() * 100))%")
            percent.font = .systemFont(ofSize: 12, weight: .medium)
            percent.identifier = NSUserInterfaceItemIdentifier("pct-\(pool.runtime.rawValue)")
            percent.widthAnchor.constraint(equalToConstant: 44).isActive = true

            let capPreview = NSTextField(labelWithString: "")
            capPreview.font = .systemFont(ofSize: 11, weight: .medium)
            capPreview.textColor = .secondaryLabelColor
            capPreview.identifier = NSUserInterfaceItemIdentifier("cap-\(pool.runtime.rawValue)")
            capPreview.widthAnchor.constraint(equalToConstant: 52).isActive = true

            let row = NSStackView(views: [label, slider, percent, capPreview])
            row.orientation = .horizontal
            row.spacing = 8
            column.addArrangedSubview(row)
        }

        // The default pool's effective share and cap (read-only remainder).
        let remainder = NSTextField(
            labelWithString: String(
                format: "%@ keeps the remaining %.0f%%", defaultRuntime.rawValue,
                (shares[defaultRuntime.rawValue] ?? 0).rounded() * 100))
        remainder.font = .systemFont(ofSize: 11)
        remainder.textColor = .secondaryLabelColor
        remainder.identifier = NSUserInterfaceItemIdentifier("remainder-note")
        column.addArrangedSubview(remainder)

        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            column.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            column.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
        ])
        card.widthAnchor.constraint(equalToConstant: 505).isActive = true
        return card
    }

    /// Slider moved: update the live cap previews on every drag tick, and
    /// debounce the actual config write until the drag settles (~400ms).
    @objc func budgetSliderChanged(_ sender: NSSlider) {
        guard let runtimeName = sender.identifier?.rawValue,
            let runtime = RuntimeID(rawValue: runtimeName),
            let rc = currentRuntimeConfig
        else { return }
        let defaultRuntime = RuntimeID(rawValue: rc.defaultRuntime) ?? .tart
        let budget = BudgetEditor.setShare(
            of: runtime,
            to: sender.doubleValue,
            current: rc.budget,
            defaultRuntime: defaultRuntime
        )
        updateCapPreviews(budget: budget, defaultRuntime: rc.defaultRuntime)

        previewCommitTask?.cancel()
        previewCommitTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            // refreshPane: false — the on-screen values already match what
            // we're writing; a full rebuild mid-gesture would yank the
            // slider out from under the user's hand.
            self?.commit(budget: budget, defaultRuntime: rc.defaultRuntime, refreshPane: false)
        }
    }

    /// Recompute "N inst" previews for all rows (and the remainder note)
    /// from a candidate budget — the same partition math the engine uses.
    /// Labels are found by identifier inside the budget card's row stacks.
    func updateCapPreviews(budget: [String: Double], defaultRuntime: String) {
        guard let parsed = parsedConfigForPreview else { return }
        let def = RuntimeID(rawValue: defaultRuntime) ?? .tart
        let caps = BudgetEditor.previewCaps(
            host: ResourceProbe().snapshot(),
            reserve: parsed.reserve,
            vmShape: (parsed.vm.cpuCount, parsed.vm.memoryGB),
            containerShape: parsed.container.map { ($0.cpus, $0.memoryGB) },
            weights: budget,
            defaultRuntime: def,
            dockerShape: parsed.docker.map { ($0.cpus, $0.memoryGB) }
        )
        // Walk every view in the pane; slider rows and the remainder note
        // are tagged with "cap-<runtime>" / "pct-<runtime>" / "remainder-note".
        func walk(_ view: NSView, into out: inout [String: NSTextField]) {
            if let id = view.identifier?.rawValue, let label = view as? NSTextField {
                out[id] = label
            }
            for sub in view.subviews { walk(sub, into: &out) }
        }
        var labels: [String: NSTextField] = [:]
        for row in rowsStack.arrangedSubviews { walk(row, into: &labels) }

        for (runtime, cap) in caps {
            labels["cap-\(runtime.rawValue)"]?.stringValue = "\(cap) inst"
        }
        // Starved-route strip: recomputed on every tick so a drag that would
        // strand a route shows the warning before the user lets go.
        if let warning = labels["budget-warning"] {
            let routes = currentRuntimeConfig?.routes ?? []
            let configured = Set(viewModel?.pools.map(\.runtime) ?? [])
            let starved = BudgetEditor.starvedRoutes(routes: routes, caps: caps, configuredRuntimes: configured)
            warning.stringValue = starved.map { "⚠︎ \($0)" }.joined(separator: "\n")
            warning.isHidden = starved.isEmpty
        }
        // Percent labels update live too (they were rendered for the old split).
        let total = budget.values.reduce(0, +)
        for (runtime, weight) in budget {
            let effective = runtime == def.rawValue ? max(0, 1 - (total - weight)) : weight
            labels["pct-\(runtime)"]?.stringValue = "\(Int((effective * 100).rounded()))%"
        }
        if let remainder = labels["remainder-note"] {
            let pct = Int(((budget[def.rawValue] ?? 0) * 100).rounded())
            remainder.stringValue = String(
                format: "%@ keeps the remaining %d%% — %d inst", def.rawValue, pct, caps[def] ?? 0)
        }
    }

    /// Default switched: rewrite the section with the new default (weights
    /// stay; the remainder rule re-homes).
    @objc func defaultRuntimeChanged(_ sender: NSPopUpButton) {
        guard let rc = currentRuntimeConfig,
            let chosen = sender.selectedItem?.representedObject as? String
        else { return }
        commit(budget: rc.budget, defaultRuntime: chosen)
    }

    func commit(budget: [String: Double], defaultRuntime: String, refreshPane: Bool = true) {
        guard var rc = currentRuntimeConfig else { return }
        if let problem = BudgetEditor.validate(budget) {
            presentError(NSError(domain: "kinhin", code: 2, userInfo: [NSLocalizedDescriptionKey: problem]))
            reload()  // snap sliders back to the on-disk truth
            return
        }
        rc.budget = budget
        rc.defaultRuntime = defaultRuntime
        do {
            try RuntimesConfigEditor.apply(rc, to: configURL)
            currentRuntimeConfig = rc  // next drag starts from the new baseline
            if refreshPane { reload() }
            onEdited?()
        } catch {
            presentError(error)
            reload()
        }
    }

    /// A rounded card row: title, optional secondary line, optional remove
    /// button, optional accessory view (the health chip) on the right.
    func makeCard(
        title: String, detail: String?, removeAction: Selector?, cardIdentifier: String = "", accessory: NSView? = nil
    ) -> NSView {
        let card = LayerStyleView(frame: .zero)
        card.styleLayer = { layer in
            layer.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer.cornerRadius = 8
            layer.borderWidth = 1
            layer.borderColor = NSColor.separatorColor.cgColor
        }

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail

        var stackViews: [NSView] = [titleLabel]
        if let detail {
            let detailLabel = NSTextField(labelWithString: detail)
            detailLabel.font = .systemFont(ofSize: 11)
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.lineBreakMode = .byTruncatingTail
            stackViews.append(detailLabel)
        }

        let titleStack = NSStackView(views: stackViews)
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(titleStack)

        NSLayoutConstraint.activate([
            titleStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            titleStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            titleStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
        ])
        card.widthAnchor.constraint(equalToConstant: 505).isActive = true

        if let removeAction {
            let remove = NSButton(title: "Remove", target: self, action: removeAction)
            remove.bezelStyle = .rounded
            remove.controlSize = .small
            remove.translatesAutoresizingMaskIntoConstraints = false
            remove.identifier = NSUserInterfaceItemIdentifier(cardIdentifier)
            card.addSubview(remove)
            NSLayoutConstraint.activate([
                remove.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
                remove.centerYAnchor.constraint(equalTo: card.centerYAnchor),
                titleStack.trailingAnchor.constraint(lessThanOrEqualTo: remove.leadingAnchor, constant: -8),
            ])
        } else if let accessory {
            accessory.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(accessory)
            NSLayoutConstraint.activate([
                accessory.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
                accessory.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
                titleStack.trailingAnchor.constraint(lessThanOrEqualTo: accessory.leadingAnchor, constant: -8),
            ])
        } else {
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -12).isActive = true
        }
        return card
    }
}
