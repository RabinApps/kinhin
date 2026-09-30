import Foundation
import KinhinKit

// Add Route as a SwiftUI sheet (replacing RuntimesSheets' NSAlert). The state
// lives on `RuntimesModel`; `RuntimesView` presents `AddRouteSheet` while
// `routeOffer` is non-nil.

extension RuntimesModel {
    // MARK: - Sheet state

    /// The open Add Route sheet's inputs: which runtimes a new route may
    /// target (tart always, configured Linux runtimes, and host, which needs
    /// the explicit consent checkbox).
    struct RouteOffer: Identifiable {
        let runtimes: [RuntimeID]
        var id: [RuntimeID] { runtimes }
    }

    // MARK: - Pure helpers (shared with tests)

    /// The Add Route sheet's checkbox text (replaces RuntimesSheets.hostConsentTitle).
    static let hostConsentTitle = "Host only: run this repo's code directly on my Mac, unisolated"

    /// Popup title for one runtime choice.
    static func runtimeTitle(_ id: RuntimeID) -> String {
        switch id {
        case .tart: return "tart — macOS VMs"
        case .appleContainer: return "Apple container — Linux"
        case .docker: return "Docker — Linux"
        case .host: return "Host — this Mac, no isolation"
        }
    }

    /// What an entered pattern needs before it can be written. The order is
    /// the sheet's verdict order: empty → duplicate → host consent.
    /// Returns the trimmed pattern when acceptable.
    static func patternProblem(
        _ raw: String, existing: [KinhinConfig.RuntimeConfig.Route], runtime: RuntimeID, consent: Bool
    ) -> String? {
        let pattern = raw.trimmingCharacters(in: .whitespaces)
        if pattern.isEmpty {
            return "Enter a repository (owner/repo) first."
        }
        if existing.contains(where: { $0.pattern == pattern }) {
            return "A route for '\(pattern)' already exists."
        }
        if runtime == .host && !consent {
            return
                "Host routes run this repo's code directly on your Mac with your privileges. Tick the box to confirm, or pick another runtime."
        }
        return nil
    }

    /// Runtimes a route can target: tart always, plus whichever Linux runtimes
    /// the config has enabled (a route to an unconfigured runtime is rejected).
    static func routableRuntimes(in config: KinhinConfig?) -> [RuntimeID] {
        var ids: [RuntimeID] = [.tart]
        if config?.container != nil { ids.append(.appleContainer) }
        if config?.docker != nil { ids.append(.docker) }
        // Host needs no config section (only the runner agent, which the
        // setup checklist installs); the route itself carries the consent.
        ids.append(.host)
        return ids
    }

    // MARK: - Actions

    /// Add Route… pressed: build the offer for the sheet, or explain why
    /// there is nothing to offer yet. Never a silent no-op.
    func addRouteClicked() {
        guard viewModel != nil, let parsed = parsedConfig else {
            presentNotice(
                "Routes are still loading",
                "The runtime list hasn't loaded yet. If this keeps happening, check that config.yaml exists and is valid (Advanced → App → Open config file)."
            )
            reload()
            return
        }
        routeOffer = RouteOffer(runtimes: Self.routableRuntimes(in: parsed))
        sheetProblem = ""
    }

    /// Add pressed in the sheet: validate the pending values, write through
    /// the engine's config editor, close the sheet. With a problem, the
    /// verdict stays inside the sheet (values preserved) for the user to fix.
    func confirmAddRoute(rawPattern: String, runtime: RuntimeID, consent: Bool) {
        guard routeOffer != nil else { return }
        let pattern = rawPattern.trimmingCharacters(in: .whitespaces)
        if let problem = Self.patternProblem(
            pattern, existing: currentRuntimeConfig?.routes ?? [], runtime: runtime, consent: consent)
        {
            sheetProblem = problem
            return
        }
        var rc = currentRuntimeConfig ?? KinhinConfig.RuntimeConfig()
        rc.routes.append(
            KinhinConfig.RuntimeConfig.Route(
                pattern: pattern, runtime: runtime.rawValue, consent: runtime == .host && consent ? true : nil))
        do {
            try RuntimesConfigEditor.apply(rc, to: configURL)
            routeOffer = nil
            reload()
            onChanged?()
        } catch {
            // The sheet closes (matching the alert it replaces) and the
            // editor's rejection is presented.
            routeOffer = nil
            presentError(error)
        }
    }

    /// Cancel pressed (or the sheet was dismissed).
    func cancelAddRoute() {
        routeOffer = nil
        sheetProblem = ""
    }

    func removeRoute(pattern: String) {
        guard let rc = currentRuntimeConfig else { return }
        var updated = rc
        updated.routes.removeAll { $0.pattern == pattern }
        do {
            try RuntimesConfigEditor.apply(updated, to: configURL)
            reload()
            onChanged?()
        } catch {
            presentError(error)
        }
    }
}
