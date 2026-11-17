import Foundation
import KinhinKit

// What each runtime card on the Runtimes page shows about its pool: on, switched off, or not set up at all.

extension RuntimesModel {
    /// Where a runtime stands in the config.
    enum PoolState: Equatable {
        /// Serving jobs: in `vm.pools`.
        case on
        /// Configured but switched off (`enabled: false`).
        case off
        /// No section for it (Apple container, Docker), so there is nothing to switch back on yet.
        case unconfigured
    }

    func poolState(_ runtime: RuntimeID) -> PoolState {
        guard let vm = viewModel else { return runtime == .host ? .on : .unconfigured }
        if vm.pools.contains(where: { $0.runtime == runtime }) { return .on }
        if vm.disabledPools.contains(runtime) { return .off }
        return runtime == .host ? .on : .unconfigured
    }

    private func poolRow(_ runtime: RuntimeID) -> RuntimesPaneViewModel.PoolRow? {
        viewModel?.pools.first { $0.runtime == runtime }
    }

    /// "labels: self-hosted, macos, arm64" for a running pool.
    func labelsLine(for runtime: RuntimeID) -> String? {
        guard let pool = poolRow(runtime), !pool.labels.isEmpty else { return nil }
        return String(
            localized: "labels: \(pool.labels.joined(separator: ", "))", bundle: .l10n,
            comment: "Routing tab pool detail; %@ lists runner labels")
    }

    /// The pool's health chip text and tone; nil for a pool that is not running or not probed yet.
    func healthChip(for runtime: RuntimeID) -> (text: String, style: StatusStyle)? {
        guard let pool = poolRow(runtime) else { return nil }
        let chip = Self.healthChip(pool.health, probing: isProbingHealth)
        return chip.text.isEmpty ? nil : chip
    }

    /// The probe's explanation of a pool that is not ready ("Docker Desktop isn't running"); nil when healthy.
    func healthNote(for runtime: RuntimeID) -> String? {
        RuntimesPaneViewModel.healthNote(for: poolRow(runtime)?.health)
    }

    func isDefaultPool(_ runtime: RuntimeID) -> Bool { viewModel?.defaultRuntime == runtime }

    /// The card's switch: a section that exists is switched through `enabled:`; one that does not exist yet is created
    /// by `mac` with its defaults (as the setup wizard does).
    func setRuntimeOn(_ runtime: RuntimeID, _ on: Bool, mac: MacToolsModel) {
        switch (poolState(runtime), runtime) {
        case (.unconfigured, .appleContainer):
            mac.setContainer(on)
            reload()
        case (.unconfigured, .docker):
            mac.setDocker(on)
            reload()
        default:
            setPoolEnabled(runtime, on)
        }
    }

    /// Whether the card's switch can turn the runtime off (see `canDisablePool`); a runtime that is not on has
    /// nothing to protect.
    func canSwitchOff(_ runtime: RuntimeID) -> Bool { poolState(runtime) != .on || canDisablePool(runtime) }

    /// Short names the page uses: the cards, the split table, the route chips.
    static func cardTitle(_ runtime: RuntimeID) -> String {
        switch runtime {
        case .tart: return String(localized: "macOS (Tart)", bundle: .l10n, comment: "Runtime card title and split row")
        case .appleContainer:
            return String(
                localized: "Linux (Apple container)", bundle: .l10n, comment: "Runtime card title and split row")
        case .docker: return String(localized: "Docker", bundle: .l10n, comment: "Runtime card title and split row")
        case .host:
            return String(localized: "Host (this Mac)", bundle: .l10n, comment: "Runtime card title and split row")
        }
    }

    /// The runtime chip on a route row.
    static func routeChipTitle(_ runtime: RuntimeID) -> String {
        switch runtime {
        case .tart: return String(localized: "macOS (Tart)", bundle: .l10n, comment: "Runtime card title and split row")
        case .appleContainer:
            return String(localized: "Apple container", bundle: .l10n, comment: "Runtime chip on a route row")
        case .docker: return String(localized: "Docker", bundle: .l10n, comment: "Runtime card title and split row")
        case .host: return String(localized: "Host", bundle: .l10n, comment: "Runtime chip on a route row")
        }
    }
}
