import Foundation

/// Picks the healing advisor and cadences a production engine runs with.
enum HealingAdvisors {
    /// Debug builds only: `stub:<kind>` / `stub:invalid` / `stub:doubtful:<kind>`
    /// swaps in `StubHealingAdvisor` (the e2e suite). Release builds never read it.
    static let advisorVariable = "KINHIN_HEALING_ADVISOR"
    /// Debug builds only: `fast` runs the agent on second-scale cadences (the e2e suite).
    static let timingsVariable = "KINHIN_HEALING_TIMINGS"

    /// The on-device model (Foundation Models) when the Mac runs
    /// macOS 26 or later; otherwise none (rules only).
    static func production(environment: [String: String] = ProcessInfo.processInfo.environment) -> any HealingAdvisor {
        #if DEBUG
            if let spec = environment[advisorVariable], let stub = StubHealingAdvisor(spec: spec) {
                return stub
            }
        #endif
        #if canImport(FoundationModels)
            if #available(macOS 26, *) { return FoundationModelsHealingAdvisor() }
        #endif
        return NoHealingAdvisor()
    }

    static func productionTimings(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> HealingAgent.Timings {
        #if DEBUG
            if environment[timingsVariable] == "fast" { return .fast }
        #endif
        return HealingAgent.Timings()
    }
}
