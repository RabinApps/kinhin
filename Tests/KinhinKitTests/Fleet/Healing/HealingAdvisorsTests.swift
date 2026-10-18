import XCTest

@testable import KinhinKit

/// Which advisor `healing.ai` builds. The environment is empty so the debug stub never applies.
final class HealingAdvisorsTests: XCTestCase {
    private func production(_ config: KinhinConfig.HealingConfig) -> any HealingAdvisor {
        HealingAdvisors.production(config: config, environment: [:])
    }

    func testOffHasNoAdvisor() {
        let advisor = production(KinhinConfig.HealingConfig(ai: .off))
        XCTAssertEqual(advisor.name, "none")
    }

    func testOllamaWithoutASystemOneModelIsTheLLMAlone() {
        let config = KinhinConfig.HealingConfig(
            ai: .ollama, ollama: KinhinConfig.HealingConfig.OllamaConfig(model: "my-llm"))
        let advisor = production(config)
        XCTAssertFalse(advisor is CascadingHealingAdvisor)
        XCTAssertEqual(advisor.name, "ollama:my-llm")
    }

    func testOllamaWithASystemOneModelCascades() {
        let config = KinhinConfig.HealingConfig(
            ai: .ollama,
            ollama: KinhinConfig.HealingConfig.OllamaConfig(model: "my-llm", fastModel: "clef-flash"))
        let advisor = production(config)
        XCTAssertTrue(advisor is CascadingHealingAdvisor)
        XCTAssertEqual(advisor.name, "ollama:my-llm")
    }

    func testOllamaModeWithoutItsBlockHasNoAdvisor() {
        // The loader rejects this; the factory still never invents a model.
        let advisor = production(KinhinConfig.HealingConfig(ai: .ollama))
        XCTAssertEqual(advisor.name, "none")
    }

    func testTheEngineDependenciesCarryTheConfiguredAdvisor() {
        // The engine's wiring: `healing` from the config must reach the advisor the engine uses.
        let healing = KinhinConfig.HealingConfig(
            ai: .ollama, ollama: KinhinConfig.HealingConfig.OllamaConfig(model: "my-llm"))
        let dependencies = FleetEngine.Dependencies.live(healing: healing)
        XCTAssertEqual(dependencies.healingAdvisor?.name, "ollama:my-llm")
    }
}
