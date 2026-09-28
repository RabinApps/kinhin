import AppIntents
import KinhinKit

/// One runner VM as the Shortcuts parameter picker shows it: the id with
/// its phase, so a stalled VM is recognizable before it is picked.
struct VMEntity: Hashable, Sendable, AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Runner VM")
    static let defaultQuery = VMEntityQuery()

    var id: String
    /// `VMPhase` raw value ("busy", "failed", …) — context for the picker.
    var phase: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(id)", subtitle: "\(phase)")
    }
}

/// Serves the picker from the fleet's current records and revalidates saved
/// parameters. A saved id that no longer exists resolves to nothing (the
/// delete intent then reports the no-op) rather than failing the shortcut.
struct VMEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [VMEntity] {
        try await allVMs().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [VMEntity] {
        try await allVMs()
    }

    private func allVMs() async throws -> [VMEntity] {
        let status = try await FleetIntentEnvironment.bridge.status()
        return status.records.map { VMEntity(id: $0.id, phase: $0.phase.rawValue) }
    }
}
