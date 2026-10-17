import Foundation

/// Picks the healing advisor and cadences a production engine runs with.
enum HealingAdvisors {
    /// Debug builds only: `stub:<kind>` / `stub:invalid` / `stub:doubtful:<kind>`
    /// swaps in `StubHealingAdvisor` (the e2e suite). Release builds never read it.
    static let advisorVariable = "KINHIN_HEALING_ADVISOR"
    /// Debug builds only: `fast` runs the agent on second-scale cadences (the e2e suite).
    static let timingsVariable = "KINHIN_HEALING_TIMINGS"

    /// The advisor `healing.ai` picks: Ollama (a System 1 decision model, then
    /// the LLM), the on-device model when the Mac runs macOS 26 or later
    /// (`auto`), or none (`off`, or `auto` on an older Mac: rules only).
    static func production(
        config: KinhinConfig.HealingConfig = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> any HealingAdvisor {
        #if DEBUG
            if let spec = environment[advisorVariable], let stub = StubHealingAdvisor(spec: spec) {
                return stub
            }
        #endif
        switch config.ai {
        case .off:
            return NoHealingAdvisor()
        case .ollama:
            // The loader rejects `ai: ollama` without its block; a caller that
            // builds one by hand gets rules only, logged rather than silent.
            guard let ollama = config.ollama else {
                Log.warn("healing", "healing.ai is ollama but no healing.ollama block was given; rules only")
                return NoHealingAdvisor()
            }
            return ollamaAdvisor(ollama)
        case .auto:
            #if canImport(FoundationModels)
                if #available(macOS 26, *) { return FoundationModelsHealingAdvisor() }
            #endif
            return NoHealingAdvisor()
        }
    }

    /// The LLM alone, or the cascade when a System 1 model is configured.
    static func ollamaAdvisor(_ config: KinhinConfig.HealingConfig.OllamaConfig) -> any HealingAdvisor {
        let llm = OllamaHealingAdvisor(host: config.host, model: config.model, keepAlive: config.keepAlive)
        guard let fastModel = config.fastModel else { return llm }
        let fast = OllamaDecisionAdvisor(host: config.host, model: fastModel, keepAlive: config.keepAlive)
        return CascadingHealingAdvisor(fast: fast, llm: llm)
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
