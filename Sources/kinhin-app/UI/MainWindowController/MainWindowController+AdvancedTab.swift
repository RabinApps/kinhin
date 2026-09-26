import AppKit
import KinhinKit

// The Advanced tab and its sections.
@MainActor
extension MainTabsWindowController {
    // MARK: Advanced tab

    func buildAdvancedTab() -> NSView {
        let tab = NSView()
        tab.translatesAutoresizingMaskIntoConstraints = false

        advancedSegments.target = self
        advancedSegments.action = #selector(advancedSegmentChanged(_:))
        advancedSegments.controlSize = .small
        advancedSegments.translatesAutoresizingMaskIntoConstraints = false
        advancedSegments.setAccessibilityLabel("Advanced sections")
        advancedContainer.translatesAutoresizingMaskIntoConstraints = false

        tab.addSubview(advancedSegments)
        tab.addSubview(advancedContainer)
        NSLayoutConstraint.activate([
            advancedSegments.topAnchor.constraint(equalTo: tab.topAnchor),
            advancedSegments.leadingAnchor.constraint(equalTo: tab.leadingAnchor, constant: 20),
            advancedSegments.widthAnchor.constraint(equalToConstant: 560),

            advancedContainer.topAnchor.constraint(equalTo: advancedSegments.bottomAnchor, constant: 12),
            advancedContainer.leadingAnchor.constraint(equalTo: tab.leadingAnchor, constant: 16),
            advancedContainer.trailingAnchor.constraint(equalTo: tab.trailingAnchor, constant: -16),
            advancedContainer.bottomAnchor.constraint(equalTo: tab.bottomAnchor, constant: -12),
        ])
        selectAdvancedSection(selectedAdvancedSection)
        return tab
    }

    func selectAdvancedSection(_ section: AdvancedSection) {
        selectedAdvancedSection = section
        advancedSegments.selectedSegment = AdvancedSection.allCases.firstIndex(of: section) ?? 0
        advancedContainer.subviews.forEach { $0.removeFromSuperview() }
        let view =
            advancedViews[section]
            ?? {
                let built: NSView
                switch section {
                case .accounts: built = buildAccountsSection()
                case .capacity: built = buildCapacitySection()
                case .routing: built = buildRoutingSection()
                case .containers: built = buildContainersSection()
                case .toolchains: built = buildToolchainsSection()
                case .app: built = buildAppSection()
                }
                advancedViews[section] = built
                return built
            }()
        pin(view, in: advancedContainer)
        // Data-backed sections load when shown (Capacity is skipped: reloading
        // it would discard unapplied edits).
        switch section {
        case .routing: runtimesController?.reload()
        case .containers: containersController?.reload()
        case .toolchains: break
        case .accounts:
            connectModel?.reload()
            macToolsModel?.reload()
        case .capacity, .app: break
        }
    }

    @objc func advancedSegmentChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard AdvancedSection.allCases.indices.contains(index) else { return }
        selectAdvancedSection(AdvancedSection.allCases[index])
    }

    /// Opens Advanced on a given section (used by the menu).
    func showAdvanced(_ section: AdvancedSection) {
        selectTab(.advanced)
        selectAdvancedSection(section)
    }

    func buildCapacitySection() -> NSView {
        let controller = ConfigTabViewController()
        controller.onEdited = { [weak self] in self?.runtimesEdited?() }
        configController = controller
        return controller.view
    }

    func buildToolchainsSection() -> NSView {
        let controller = ToolchainsViewController()
        controller.onEdited = { [weak self] in self?.runtimesEdited?() }
        toolchainsController = controller
        return controller.view
    }

    func buildContainersSection() -> NSView {
        let controller = ContainersViewController()
        containersController = controller
        return controller.view
    }

    func buildRoutingSection() -> NSView {
        let tab = NSView()
        let controller = RuntimesWindowController(embeddedIn: tab)
        controller.onEdited = { [weak self] in self?.runtimesEdited?() }
        runtimesController = controller
        return tab
    }
}
