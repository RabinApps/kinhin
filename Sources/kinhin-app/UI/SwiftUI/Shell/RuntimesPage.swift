import KinhinKit
import SwiftUI

/// Runtimes: where jobs run, how many, and how they're routed. One scroll of cards (fleet capacity, the split between
/// runtimes, a card per runtime, the routes) with the Apply bar pinned below it. The capacity card and every Keep idle
/// floor stage until Apply; the switches, routes, pools and labels save as you make them.
struct RuntimesPage: View {
    let capacity: CapacityModel
    let mac: MacToolsModel
    @Bindable var runtimes: RuntimesModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    if runtimes.loadFailed {
                        unreadable
                    } else {
                        cards
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, Spacing.xs)
            }
            if !runtimes.loadFailed, capacity.draft != nil { CapacityApplyBar(model: capacity) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $runtimes.isYAMLEditorOpen) { EditYAMLSheet(model: runtimes) }
        .sheet(
            item: Binding(
                get: { runtimes.routeOffer },
                set: { if $0 == nil { runtimes.cancelAddRoute() } })
        ) { offer in
            AddRouteSheet(model: runtimes, runtimes: offer.runtimes)
        }
        .sheet(
            item: Binding(
                get: { runtimes.containerPoolOffer },
                set: { if $0 == nil { runtimes.cancelContainerPool() } })
        ) { offer in
            ContainerPoolSheet(model: runtimes, offer: offer)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(verbatim: MainSection.runtimes.label)
                .typeStyle(.display)
                .accessibilityAddTraits(.isHeader)
            if runtimes.loadFailed {
                Text("Config problem").typeStyle(.body).foregroundStyle(.secondary)
            } else {
                Text("Where jobs run, how many, and how they're routed.")
                    .typeStyle(.body).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Cards

    @ViewBuilder
    private var cards: some View {
        if capacity.draft != nil { FleetCapacityCard(model: capacity) }
        SplitCard(model: runtimes, hasUnappliedCapacity: capacity.hasPendingChanges)
        MacBusyStrip(model: mac)
        TartRuntimeCard(runtimes: runtimes, mac: mac, capacity: capacity)
        ContainerRuntimeCard(runtimes: runtimes, mac: mac, capacity: capacity)
        DockerRuntimeCard(runtimes: runtimes, mac: mac, capacity: capacity)
        HostRuntimeCard(runtimes: runtimes, mac: mac)
        RoutesCard(model: runtimes)
    }

    /// config.yaml does not load: say why, offer the editor, and keep the rest read-only until it loads.
    @ViewBuilder
    private var unreadable: some View {
        if runtimes.configMissing {
            Banner(verbatim: runtimes.emptyMessage, kind: .error)
        } else {
            Banner(verbatim: runtimes.emptyMessage, kind: .error)
                .action("Edit YAML…") { runtimes.editYAMLClicked() }
        }
        Card(layout: .fill) {
            Text("Capacity and routing are read-only until config.yaml loads.")
                .typeStyle(.body).foregroundStyle(.secondary)
        }
    }
}
