import AppKit
import KinhinKit

// Loading the view model and rendering pool, capacity, and route rows.
@MainActor
extension RuntimesWindowController {
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

    var hasLoadedForTesting: Bool { viewModel != nil }

    func reloadWithHealth() async {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            renderEmpty(message: "No config file yet — finish the Setup tab first.")
            return
        }
        let yaml: String
        let parsed: KinhinConfig
        do {
            yaml = try ConfigStore.text(at: configURL)
            parsed = try ConfigLoader.parse(yaml)
        } catch {
            renderEmpty(message: "config.yaml has a problem — \(error.localizedDescription). Fix it with Edit YAML…")
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

    func clearRows() {
        for view in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    func renderEmpty(message: String) {
        clearRows()
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        rowsStack.addArrangedSubview(label)
        headlineLabel.stringValue = ""
    }

    func render(viewModel vm: RuntimesPaneViewModel, repo: String, probing: Bool = false) {
        clearRows()
        headlineLabel.stringValue = "Fleet scope: \(repo) — \(vm.routingConfigured ? "routed" : "single-pool") fleet"

        // ---- On this Mac (installed / not installed, configured or not) ---
        if !vm.availability.isEmpty {
            rowsStack.addArrangedSubview(FormKit.sectionHeader("On this Mac"))
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
        rowsStack.addArrangedSubview(FormKit.sectionHeader("Pools & capacity"))
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
            rowsStack.addArrangedSubview(FormKit.sectionHeader("Budget"))
            rowsStack.addArrangedSubview(makeBudgetCard(rc: rc, pools: vm.pools))
        }

        // ---- Routes ------------------------------------------------------
        rowsStack.addArrangedSubview(FormKit.sectionHeader("Routes"))
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
        rowsStack.addArrangedSubview(FormKit.sectionHeader("Labels"))
        rowsStack.addArrangedSubview(makeLabelsCard())

        let defaults = NSTextField(labelWithString: "Unmatched jobs → \(vm.defaultRuntime.rawValue)")
        defaults.font = .systemFont(ofSize: 12)
        defaults.textColor = .secondaryLabelColor
        rowsStack.addArrangedSubview(defaults)
    }
}
