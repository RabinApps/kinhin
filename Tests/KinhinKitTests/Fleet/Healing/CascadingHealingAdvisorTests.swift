import Synchronization
import XCTest

@testable import KinhinKit

/// The cascade: System 1 first, the LLM when System 1 is not confident or picks nothing.
final class CascadingHealingAdvisorTests: XCTestCase {
    /// Counts the calls a scripted tier receives.
    private final class CallCounter: Sendable {
        private let value = Mutex<Int>(0)

        var count: Int { value.withLock { $0 } }

        func increment() { value.withLock { $0 += 1 } }
    }

    /// A tier with a fixed answer or failure, that counts how often it was asked.
    private struct ScriptedAdvisor: HealingAdvisor {
        enum Outcome: Sendable {
            case answer(HealingAdvice?)
            case failure
        }

        let name: String
        let available: Bool
        let outcome: Outcome
        let asked = CallCounter()

        var askedCount: Int { asked.count }

        func isAvailable() async -> Bool { available }

        func advise(_ request: HealingAdviceRequest) async throws -> HealingAdvice? {
            asked.increment()
            switch outcome {
            case .answer(let advice): return advice
            case .failure: throw EngineError.healingFailed("scripted failure")
            }
        }
    }

    private func confident(_ fix: String) -> HealingAdvice {
        HealingAdvice(remediation: fix, confident: true, explanation: "fast", model: "clef-flash")
    }

    private func doubtful(_ fix: String) -> HealingAdvice {
        HealingAdvice(remediation: fix, confident: false, explanation: "fast, doubtful", model: "clef-flash")
    }

    private func none() -> HealingAdvice {
        HealingAdvice(remediation: nil, confident: false, explanation: "fast, none", model: "clef-flash")
    }

    private let llmAnswer = HealingAdvice(
        remediation: "retry_forge_attach", confident: true, explanation: "llm", model: "my-llm")

    func testAConfidentSystemOnePickIsFinal() async throws {
        let fast = ScriptedAdvisor(name: "fast", available: true, outcome: .answer(confident("retry_forge_attach")))
        let llm = ScriptedAdvisor(name: "llm", available: true, outcome: .answer(llmAnswer))
        let advice = try await CascadingHealingAdvisor(fast: fast, llm: llm).advise(OllamaTestSupport.request)
        XCTAssertEqual(advice?.model, "clef-flash")
        XCTAssertEqual(llm.askedCount, 0, "the LLM is not asked about an easy case")
    }

    func testADoubtfulSystemOnePickGoesToTheLLM() async throws {
        let fast = ScriptedAdvisor(name: "fast", available: true, outcome: .answer(doubtful("retry_forge_attach")))
        let llm = ScriptedAdvisor(name: "llm", available: true, outcome: .answer(llmAnswer))
        let advice = try await CascadingHealingAdvisor(fast: fast, llm: llm).advise(OllamaTestSupport.request)
        XCTAssertEqual(advice?.model, "my-llm")
        XCTAssertEqual(llm.askedCount, 1)
    }

    func testSystemOneSayingNoneGoesToTheLLM() async throws {
        let fast = ScriptedAdvisor(name: "fast", available: true, outcome: .answer(none()))
        let llm = ScriptedAdvisor(name: "llm", available: true, outcome: .answer(llmAnswer))
        let advice = try await CascadingHealingAdvisor(fast: fast, llm: llm).advise(OllamaTestSupport.request)
        XCTAssertEqual(advice?.model, "my-llm")
        XCTAssertEqual(llm.askedCount, 1)
    }

    func testWhenTheLLMFailsSystemOnesAnswerStands() async throws {
        let fast = ScriptedAdvisor(name: "fast", available: true, outcome: .answer(doubtful("retry_forge_attach")))
        let llm = ScriptedAdvisor(name: "llm", available: true, outcome: .failure)
        let advice = try await CascadingHealingAdvisor(fast: fast, llm: llm).advise(OllamaTestSupport.request)
        XCTAssertEqual(advice?.model, "clef-flash")
        XCTAssertEqual(advice?.confident, false)
    }

    func testASystemOneFailureGoesToTheLLM() async throws {
        let fast = ScriptedAdvisor(name: "fast", available: true, outcome: .failure)
        let llm = ScriptedAdvisor(name: "llm", available: true, outcome: .answer(llmAnswer))
        let advice = try await CascadingHealingAdvisor(fast: fast, llm: llm).advise(OllamaTestSupport.request)
        XCTAssertEqual(advice?.model, "my-llm")
        XCTAssertEqual(fast.askedCount, 1)
    }

    func testAnUnavailableSystemOneIsNotAsked() async throws {
        let fast = ScriptedAdvisor(name: "fast", available: false, outcome: .answer(confident("prune_images")))
        let llm = ScriptedAdvisor(name: "llm", available: true, outcome: .answer(llmAnswer))
        let advice = try await CascadingHealingAdvisor(fast: fast, llm: llm).advise(OllamaTestSupport.request)
        XCTAssertEqual(advice?.model, "my-llm")
        XCTAssertEqual(fast.askedCount, 0)
    }

    func testAnUnavailableLLMIsNotAsked() async throws {
        let fast = ScriptedAdvisor(name: "fast", available: true, outcome: .answer(doubtful("retry_forge_attach")))
        let llm = ScriptedAdvisor(name: "llm", available: false, outcome: .answer(llmAnswer))
        let advice = try await CascadingHealingAdvisor(fast: fast, llm: llm).advise(OllamaTestSupport.request)
        XCTAssertEqual(advice?.model, "clef-flash")
        XCTAssertEqual(llm.askedCount, 0)
    }

    func testAnLLMSelfReportedPickKeepsItsFlagThroughTheCascade() async throws {
        // The agent queues a self-reported pick for approval; the flag must survive the cascade.
        let fast = ScriptedAdvisor(name: "fast", available: true, outcome: .answer(none()))
        let selfReported = HealingAdvice(
            remediation: "retry_forge_attach", confident: true, explanation: "llm", model: "my-llm",
            selfReported: true)
        let llm = ScriptedAdvisor(name: "llm", available: true, outcome: .answer(selfReported))
        let advice = try await CascadingHealingAdvisor(fast: fast, llm: llm).advise(OllamaTestSupport.request)
        XCTAssertEqual(advice?.model, "my-llm")
        XCTAssertEqual(advice?.selfReported, true)
    }

    func testTheCascadeIsAvailableWhenEitherTierIs() async {
        let fastOnly = CascadingHealingAdvisor(
            fast: ScriptedAdvisor(name: "fast", available: true, outcome: .answer(nil)),
            llm: ScriptedAdvisor(name: "llm", available: false, outcome: .answer(nil)))
        let llmOnly = CascadingHealingAdvisor(
            fast: ScriptedAdvisor(name: "fast", available: false, outcome: .answer(nil)),
            llm: ScriptedAdvisor(name: "llm", available: true, outcome: .answer(nil)))
        let neither = CascadingHealingAdvisor(
            fast: ScriptedAdvisor(name: "fast", available: false, outcome: .answer(nil)),
            llm: ScriptedAdvisor(name: "llm", available: false, outcome: .answer(nil)))
        let fastAvailable = await fastOnly.isAvailable()
        let llmAvailable = await llmOnly.isAvailable()
        let noneAvailable = await neither.isAvailable()
        XCTAssertTrue(fastAvailable)
        XCTAssertTrue(llmAvailable)
        XCTAssertFalse(noneAvailable)
    }

    func testTheCascadeIsNamedForTheLLM() {
        let cascade = CascadingHealingAdvisor(
            fast: ScriptedAdvisor(name: "fast", available: true, outcome: .answer(nil)),
            llm: ScriptedAdvisor(name: "ollama:my-llm", available: true, outcome: .answer(nil)))
        XCTAssertEqual(cascade.name, "ollama:my-llm")
    }
}
