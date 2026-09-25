import AppKit
import KinhinKit

/// The Runtimes pane: read-only view of the fleet's runtime pools, capacity
/// partition, and per-repo/per-workflow routes — with light editing (add and
/// remove routes, via the validated config editor). Heavier editing opens
/// the YAML; every write goes through RuntimesConfigEditor so the rest of
/// the config file is preserved and engine validation gates the result.
@MainActor
final class RuntimesWindowController: NSWindowController {
    var onEdited: (() -> Void)?
    /// The config file this pane reads and edits (tests point it at a scratch file).
    var configURL: URL = Paths.config

    private let rowsStack = NSStackView()
    private let headlineLabel = NSTextField(labelWithString: "")
    private var viewModel: RuntimesPaneViewModel?
    private var previewCommitTask: Task<Void, Never>?
    private var parsedConfigForPreview: KinhinConfig?
    private var currentRuntimeConfig: KinhinConfig.RuntimeConfig?

    convenience init() {
        self.init(embeddedIn: nil)
    }

    /// Embedded in the main window's Runtimes tab: `container` receives the
    /// full pane. Nil container → the standalone-window form, unchanged.
    convenience init(embeddedIn container: NSView?) {
        let size = NSSize(width: 560, height: 520)
        let standalone = container == nil
        let contentContainer = container ?? NSView(frame: NSRect(origin: .zero, size: size))
        if standalone {
            let window = NSWindow(
                contentRect: contentContainer.frame,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "kinhin Runtimes"
            window.titlebarAppearsTransparent = true
            window.appearance = nil  // follow the system (light & dark)
            window.backgroundColor = .windowBackgroundColor
            window.contentView = contentContainer
            window.center()
            self.init(window: window)
        } else {
            self.init(window: nil)
        }
        buildUI(in: contentContainer, size: size)
    }

    // MARK: UI construction

    private func buildUI(in container: NSView, size: NSSize) {
        container.wantsLayer = true

        // ---- Header -----------------------------------------------------
        let title = NSTextField(labelWithString: "⚖️  Runtimes")
        title.font = .systemFont(ofSize: 22, weight: .bold)
        headlineLabel.font = .systemFont(ofSize: 13)
        headlineLabel.textColor = .secondaryLabelColor
        headlineLabel.maximumNumberOfLines = 2

        let headerStack = NSStackView(views: [title, headlineLabel])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 6
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerStack)

        // ---- Scrollable content ------------------------------------------
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 8
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        // Flipped document so the page opens at the TOP (an unflipped one
        // starts scrolled to the bottom and clips the first cards).
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rowsStack)
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: document.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rowsStack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        // ---- Footer -------------------------------------------------------
        let addRouteButton = NSButton(title: "Add Route…", target: self, action: #selector(addRouteClicked))
        addRouteButton.bezelStyle = .rounded
        let editButton = NSButton(title: "Edit YAML…", target: self, action: #selector(editConfigInUI))
        editButton.bezelStyle = .rounded
        let hint = NSTextField(labelWithString: "Slider changes apply on release; validation gates every write.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        let footer = NSStackView(views: [addRouteButton, editButton, hint])
        footer.orientation = .horizontal
        footer.spacing = 12
        footer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(footer)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            headerStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            headerStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            scroll.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -14),

            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])
    }

    // MARK: Config editing (in-UI YAML editor)

    /// Opens the validated in-UI editor sheet. The textarea starts from the
    /// exact on-disk bytes; Save writes through ConfigEditor, so the engine's
    /// full validation gates the result — a bad edit shows the error instead
    /// of landing on disk.
    @objc func editConfigInUI() {
        // No window guard here: the embedded Runtimes tab has no own window
        // (only the standalone pane does), and runModal works either way.
        let original = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""

        let editor = NSTextView()
        editor.string = original
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isEditable = true
        editor.setAccessibilityLabel("config.yaml editor")
        // Track the clip view's width (same as the Logs viewer): an
        // autoresizing text view is sized once and never grows/shrinks when
        // the alert is resized or laid out late.
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 420))
        scroll.hasVerticalScroller = true
        scroll.documentView = editor
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(
            labelWithString: "Saved only if the whole file still passes the engine's config validation.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let column = NSStackView(views: [hint, scroll])
        column.orientation = .vertical
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        column.widthAnchor.constraint(equalToConstant: 560).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 420).isActive = true

        let alert = NSAlert()
        alert.messageText = "Edit config.yaml"
        alert.alertStyle = .informational
        alert.accessoryView = column
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = editor

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let updated = editor.string
        guard updated != original else { return }
        do {
            try ConfigEditor.save(updated, to: configURL)
            Log.info("runtimes-pane", "config edited in UI; validation passed")
            onEdited?()
        } catch {
            presentError(error)
        }
        reload()
    }

    // MARK: Loading & rendering

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        reload()
    }

    /// Two-pass load: cards render immediately (health marked "checking…"),
    /// then live probe results flip the chips in place — the pane never
    /// blocks on a subprocess.
    func reload() {
        reloadCount += 1
        Task { await reloadWithHealth() }
    }

    /// Test hooks.
    private(set) var reloadCount = 0
    var hasLoadedForTesting: Bool { viewModel != nil }

    private func reloadWithHealth() async {
        guard let yaml = try? String(contentsOf: configURL, encoding: .utf8) else {
            renderEmpty(message: "No config file yet — finish the Setup tab first.")
            return
        }
        guard let parsed = try? ConfigLoader.parse(yaml) else {
            renderEmpty(message: "config.yaml doesn't parse — fix it with Edit YAML…")
            return
        }
        let host = ResourceProbe().snapshot()

        // Fast pass: no probes.
        let fast = await RuntimesPaneViewModel.load(configYAML: yaml, host: host, reserve: parsed.reserve)
        viewModel = fast
        parsedConfigForPreview = parsed
        currentRuntimeConfig =
            (try? RuntimesConfigEditor.parsed(from: yaml))
            ?? KinhinConfig.RuntimeConfig(defaultRuntime: fast.defaultRuntime.rawValue)
        render(viewModel: fast, repo: parsed.repo, probing: true)
        // Fill the initial cap previews from the on-disk budget.
        if let rc = currentRuntimeConfig {
            updateCapPreviews(budget: rc.budget, defaultRuntime: rc.defaultRuntime)
        }

        // Health pass: probe each enabled pool's runtime concurrently.
        let withHealth = await RuntimesPaneViewModel.load(
            configYAML: yaml, host: host, reserve: parsed.reserve, loadHealth: true)
        guard withHealth != fast else { return }  // nothing changed; no flicker
        viewModel = withHealth
        render(viewModel: withHealth, repo: parsed.repo, probing: false)
        // The re-render recreated the slider rows: refill their previews.
        if let rc = currentRuntimeConfig {
            updateCapPreviews(budget: rc.budget, defaultRuntime: rc.defaultRuntime)
        }
    }

    private func clearRows() {
        for view in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func renderEmpty(message: String) {
        clearRows()
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        rowsStack.addArrangedSubview(label)
        headlineLabel.stringValue = ""
    }

    private func render(viewModel vm: RuntimesPaneViewModel, repo: String, probing: Bool = false) {
        clearRows()
        headlineLabel.stringValue = "Fleet scope: \(repo) — \(vm.routingConfigured ? "routed" : "single-pool") fleet"

        // ---- On this Mac (installed / not installed, configured or not) ---
        if !vm.availability.isEmpty {
            rowsStack.addArrangedSubview(sectionHeader("On this Mac"))
            for id in [RuntimeID.tart, .appleContainer, .docker] {
                guard let health = vm.availability[id] else { continue }
                let inUse = vm.pools.contains { $0.runtime == id }
                let title = Self.availabilityTitle(id, health: health, inUse: inUse)
                let detail: String?
                switch health {
                case .ready:
                    detail = nil
                case .missing(_, let fix):
                    detail = "To install: \(fix)"
                case .broken(let why):
                    detail = why
                }
                rowsStack.addArrangedSubview(makeCard(title: title, detail: detail, removeAction: nil))
            }
        }

        // ---- Pools -------------------------------------------------------
        rowsStack.addArrangedSubview(sectionHeader("Pools & capacity"))
        for pool in vm.pools {
            let name = pool.runtime == .tart ? "🍎 Tart VMs (macOS)" : "🐧 Apple containers (Linux)"
            var headline = name + " — "
            if let cap = pool.cap {
                headline += "cap \(cap) instance\(cap == 1 ? "" : "s")"
            } else {
                headline += "cap n/a"
            }
            if let pct = pool.budgetPercent {
                headline += String(format: " · %.0f%% of host budget", pct)
            }
            if pool.runtime == vm.defaultRuntime {
                headline += " · default"
            }
            // Health chip: live probe result (or "checking…" during the
            // fast pass). The fix hint rides along when unhealthy.
            var details: [String] = ["labels: " + pool.labels.joined(separator: ", ")]
            if let note = RuntimesPaneViewModel.healthNote(for: pool.health) {
                details.append("⚠︎ " + note)
            }
            let chip = Self.healthChip(pool.health, probing: probing)
            let card = makeCard(
                title: headline,
                detail: details.joined(separator: "\n"),
                removeAction: nil,
                accessory: chip
            )
            rowsStack.addArrangedSubview(card)
        }

        // ---- Budget -------------------------------------------------------
        if vm.pools.count > 1, let rc = currentRuntimeConfig {
            rowsStack.addArrangedSubview(sectionHeader("Budget"))
            rowsStack.addArrangedSubview(makeBudgetCard(rc: rc, pools: vm.pools))
        }

        // ---- Routes ------------------------------------------------------
        rowsStack.addArrangedSubview(sectionHeader("Routes"))
        if vm.routes.isEmpty {
            let empty = NSTextField(labelWithString: "  No routes — every job uses the default pool.")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            rowsStack.addArrangedSubview(empty)
        } else {
            for route in vm.routes {
                let title =
                    route.isWorkflow
                    ? "\(route.pattern)  →  \(route.runtime.rawValue)  (workflow)"
                    : "\(route.pattern)  →  \(route.runtime.rawValue)"
                let card = makeCard(
                    title: title, detail: nil, removeAction: #selector(removeRouteClicked(_:)),
                    cardIdentifier: route.pattern)
                rowsStack.addArrangedSubview(card)
            }
        }

        // ---- Labels -------------------------------------------------------
        rowsStack.addArrangedSubview(sectionHeader("Labels"))
        rowsStack.addArrangedSubview(makeLabelsCard())

        let defaults = NSTextField(labelWithString: "Unmatched jobs → \(vm.defaultRuntime.rawValue)")
        defaults.font = .systemFont(ofSize: 12)
        defaults.textColor = .secondaryLabelColor
        rowsStack.addArrangedSubview(defaults)
    }

    // MARK: Labels editing

    /// The labels card: the fleet's base label set and, when the container
    /// runtime is configured, container.labels. Both edit through the
    /// validated LabelsConfigEditor; the container marker is protected.
    private func makeLabelsCard() -> NSView {
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
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(column)

        let yaml = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""

        // Fleet base labels.
        column.addArrangedSubview(NSTextField(labelWithString: "Fleet base labels (every runner):"))
        let fleetLabels = LabelsConfigEditor.labels(in: yaml, scope: .fleet)
        let fleetField = NSTextField(string: fleetLabels.joined(separator: ", "))
        fleetField.font = .systemFont(ofSize: 12)
        fleetField.identifier = NSUserInterfaceItemIdentifier("fleet-labels-field")
        fleetField.widthAnchor.constraint(equalToConstant: 440).isActive = true
        fleetField.delegate = self
        column.addArrangedSubview(fleetField)

        let fleetHint = NSTextField(
            labelWithString: "Comma-separated. Jobs must request a subset of these via runs-on:.")
        fleetHint.font = .systemFont(ofSize: 11)
        fleetHint.textColor = .tertiaryLabelColor
        column.addArrangedSubview(fleetHint)

        // Container extra labels (only when the runtime is configured).
        if viewModel?.containerConfigured == true {
            column.addArrangedSubview(NSView())
            column.addArrangedSubview(NSTextField(labelWithString: "Container extra labels (appleContainer pool):"))
            let containerLabels = LabelsConfigEditor.labels(in: yaml, scope: .container)
            let containerField = NSTextField(string: containerLabels.joined(separator: ", "))
            containerField.font = .systemFont(ofSize: 12)
            containerField.identifier = NSUserInterfaceItemIdentifier("container-labels-field")
            containerField.widthAnchor.constraint(equalToConstant: 440).isActive = true
            containerField.delegate = self
            column.addArrangedSubview(containerField)

            let containerHint = NSTextField(
                labelWithString: "Merged with the kinhin-container marker (always present) at pool build.")
            containerHint.font = .systemFont(ofSize: 11)
            containerHint.textColor = .tertiaryLabelColor
            column.addArrangedSubview(containerHint)
        }

        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            column.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            column.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
        ])
        card.widthAnchor.constraint(equalToConstant: 505).isActive = true
        return card
    }

    /// Parse a comma-separated label list.
    private static func parseLabelList(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Commit a label field edit (called on Enter or focus loss).
    private func commitLabels(field: NSTextField, scope: LabelsConfigEditor.Scope) {
        let labels = Self.parseLabelList(field.stringValue)
        do {
            try LabelsConfigEditor.apply(labels, scope: scope, to: configURL)
            Log.info("runtimes-pane", "\(scope == .fleet ? "fleet" : "container") labels updated")
            onEdited?()
        } catch {
            presentError(error)
            // Snap the field back to the on-disk truth.
            let yaml = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
            field.stringValue = LabelsConfigEditor.labels(in: yaml, scope: scope).joined(separator: ", ")
        }
    }

    /// "On this Mac" row title: what's installed vs not, and whether the
    /// config actually uses it.
    static func availabilityTitle(_ id: RuntimeID, health: RuntimeHealth, inUse: Bool) -> String {
        let name: String
        switch id {
        case .tart: name = "🍎 Tart (macOS VMs)"
        case .appleContainer: name = "🐧 Apple container (Linux)"
        case .docker: name = "🐳 Docker (Linux)"
        case .host: name = "Host"
        }
        let state: String
        switch health {
        case .ready: state = "installed ✓"
        case .missing: state = "not installed"
        case .broken: state = "installed — needs attention"
        }
        return "\(name) — \(state)\(inUse ? " · used by your fleet" : " · not used by your config")"
    }

    /// A small colored health chip: green ready / red not ready /
    /// grey "checking…" while the probe pass is in flight.
    static func healthChip(_ health: RuntimeHealth?, probing: Bool) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        switch health {
        case .ready:
            label.stringValue = "● ready"
            label.textColor = .systemGreen
        case .missing(let tool, _):
            label.stringValue = "● \(tool) missing"
            label.textColor = .systemRed
        case .broken:
            label.stringValue = "● error"
            label.textColor = .systemRed
        case nil:
            label.stringValue = probing ? "● checking…" : ""
            label.textColor = .tertiaryLabelColor
        }
        return label
    }

    // MARK: Budget editing

    /// The budget card: one slider per non-default pool (share of the whole
    /// host budget), the default pool shown as the remainder, and a
    /// default-runtime popup. Every change writes through
    /// RuntimesConfigEditor — engine validation gates the file.
    private func makeBudgetCard(rc: KinhinConfig.RuntimeConfig, pools: [RuntimesPaneViewModel.PoolRow]) -> NSView {
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
    private func updateCapPreviews(budget: [String: Double], defaultRuntime: String) {
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

    private func commit(budget: [String: Double], defaultRuntime: String, refreshPane: Bool = true) {
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

    private func sectionHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    /// A rounded card row: title, optional secondary line, optional remove
    /// button, optional accessory view (the health chip) on the right.
    private func makeCard(
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

    // MARK: Actions

    @objc func editConfigClicked() {
        NSWorkspace.shared.open(configURL)
    }

    /// Runtimes a route can target: tart always, plus whichever Linux runtimes
    /// the config has enabled (a route to an unconfigured runtime is rejected).
    static func routableRuntimes(in config: KinhinConfig?) -> [RuntimeID] {
        var ids: [RuntimeID] = [.tart]
        if config?.container != nil { ids.append(.appleContainer) }
        if config?.docker != nil { ids.append(.docker) }
        return ids
    }

    /// The Add Route form with explicit frames (an NSAlert accessory view
    /// doesn't run Auto Layout, so stack views collapse there).
    static func makeRouteForm(runtimes: [RuntimeID]) -> (view: NSView, pattern: NSTextField, popup: NSPopUpButton) {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 64))
        let pattern = NSTextField(frame: NSRect(x: 0, y: 40, width: 340, height: 24))
        pattern.placeholderString = "acme/api  or  acme/api@Workflow Name"
        pattern.setAccessibilityLabel("Repo or workflow pattern")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 6, width: 340, height: 26), pullsDown: false)
        for id in runtimes {
            switch id {
            case .tart: popup.addItem(withTitle: "tart — macOS VMs")
            case .appleContainer: popup.addItem(withTitle: "Apple container — Linux")
            case .docker: popup.addItem(withTitle: "Docker — Linux")
            case .host: popup.addItem(withTitle: "host")
            }
            popup.lastItem?.representedObject = id.rawValue
        }
        popup.setAccessibilityLabel("Runtime to use")
        view.addSubview(pattern)
        view.addSubview(popup)
        return (view, pattern, popup)
    }

    /// Overridable so tests never open a modal: returns (pattern, runtime) or nil.
    var promptForRoute: ([RuntimeID]) -> (String, RuntimeID)? = { runtimes in
        let alert = NSAlert()
        alert.messageText = "Add Route"
        alert.informativeText =
            "Send a repository, or one workflow, to a runtime. Use owner/repo for a whole repo, or owner/repo@Workflow Name for one workflow."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let form = RuntimesWindowController.makeRouteForm(runtimes: runtimes)
        alert.accessoryView = form.view
        alert.window.initialFirstResponder = form.pattern
        while true {
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let pattern = form.pattern.stringValue.trimmingCharacters(in: .whitespaces)
            if pattern.isEmpty {
                alert.informativeText = "Enter a repository (owner/repo) first."
                continue
            }
            guard let raw = form.popup.selectedItem?.representedObject as? String, let id = RuntimeID(rawValue: raw)
            else { return nil }
            return (pattern, id)
        }
    }

    /// Where routing problems and "nothing to do" explanations are shown.
    var presentNotice: (_ title: String, _ message: String) -> Void = { title, message in
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc func addRouteClicked() {
        guard viewModel != nil, let parsed = parsedConfigForPreview else {
            presentNotice(
                "Routes are still loading",
                "The runtime list hasn't loaded yet. If this keeps happening, check that config.yaml exists and is valid (Advanced → App → Open config file)."
            )
            reload()
            return
        }
        let runtimes = Self.routableRuntimes(in: parsed)
        guard runtimes.count > 1 else {
            presentNotice(
                "Nothing to route to yet",
                "Routes send a repo or workflow to a runtime, and only tart is set up. Turn on Docker or Apple container in Advanced → Accounts first."
            )
            return
        }
        guard let (patternValue, runtimeID) = promptForRoute(runtimes) else { return }
        let runtimeValue = runtimeID.rawValue

        var rc = currentRuntimeConfig ?? KinhinConfig.RuntimeConfig()
        guard !rc.routes.contains(where: { $0.pattern == patternValue }) else {
            presentError(
                NSError(
                    domain: "kinhin", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "A route for '\(patternValue)' already exists."]))
            return
        }
        rc.routes.append(KinhinConfig.RuntimeConfig.Route(pattern: patternValue, runtime: runtimeValue))

        do {
            try RuntimesConfigEditor.apply(rc, to: configURL)
            reload()
            onEdited?()
        } catch {
            presentError(error)
        }
    }

    @objc func removeRouteClicked(_ sender: NSButton) {
        guard let pattern = sender.identifier?.rawValue,
            let rc = currentRuntimeConfig
        else { return }
        var updated = rc
        updated.routes.removeAll { $0.pattern == pattern }
        do {
            try RuntimesConfigEditor.apply(updated, to: configURL)
            reload()
            onEdited?()
        } catch {
            presentError(error)
        }
    }
}

extension RuntimesWindowController: NSTextFieldDelegate {
    /// Label fields commit on Enter or on focus loss. The delegate fires for
    /// every field; scope comes from the field's identifier.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        switch field.identifier?.rawValue {
        case "fleet-labels-field":
            commitLabels(field: field, scope: .fleet)
        case "container-labels-field":
            commitLabels(field: field, scope: .container)
        default:
            break
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Enter in a label field commits and dismisses the keyboard focus.
        guard control is NSTextField, (control.identifier?.rawValue.hasSuffix("labels-field") ?? false) else {
            return false
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            NSApp.keyWindow?.makeFirstResponder(nil)
            return true
        }
        return false
    }
}
