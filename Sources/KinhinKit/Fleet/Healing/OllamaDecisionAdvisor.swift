import Foundation

/// The System 1 tier: an Ollama decision model (`clef-flash`, `nimble`,
/// `nimble-v3`) on `/v1/systemone`. It does not write an answer: it gives each
/// option a probability in one pass. The one `choice` question offers the
/// candidates and `none`; the advice is confident when the top option is a
/// candidate with at least `confidentProbability`.
struct OllamaDecisionAdvisor: HealingAdvisor {
    let tier: OllamaTier
    /// Seconds for the whole answer, a deadline rather than an idle timeout. A
    /// cold load of a 9B decision model took 12.7 s on the reference Mac, so
    /// the bound leaves room for a reload after Ollama unloads it.
    var timeout: TimeInterval = 60

    /// The probability a candidate needs to be confident. A guess until it is
    /// measured on real problems (see the plan's open items).
    static let confidentProbability = 0.8
    /// The endpoint takes 2 to 26 options per question.
    static let maxOptions = 26

    init(host: URL, model: String, session: URLSession = OllamaClient.defaultSession) {
        self.tier = OllamaTier(
            host: host, model: model, minimumVersion: Self.minimumVersion(for: model), session: session)
    }

    var name: String { tier.name }

    func isAvailable() async -> Bool {
        await tier.isAvailable()
    }

    /// `/v1/systemone` needs Ollama 0.35.1 (0.40.4 for `nimble-v3`).
    static func minimumVersion(for model: String) -> String {
        model.hasPrefix("nimble-v3") ? "0.40.4" : "0.35.1"
    }

    func advise(_ request: HealingAdviceRequest) async throws -> HealingAdvice? {
        guard !request.candidates.isEmpty else { return nil }
        guard request.candidates.count + 1 <= Self.maxOptions else {
            throw EngineError.healingFailed(
                "\(tier.model) takes at most \(Self.maxOptions) options; this problem has more")
        }
        let question: [String: Any] = [
            "type": "choice",
            "instructions": DecisionPrompt.question,
            "criteria": DecisionPrompt.criteria(for: request.candidates),
        ]
        let budget = HealingPrompt.budget(contextTokens: HealingPrompt.ollamaContextTokens)
        let body: [String: Any] = [
            "model": tier.model,
            "state": DecisionPrompt.state(for: request, budget: budget),
            "questions": ["fix": question],
            "keep_alive": OllamaClient.keepAlive,
        ]
        let data = try OllamaClient.encode(body)
        let client = tier.client
        let limit = timeout
        let reply = try await HealingDeadline.run(seconds: limit) {
            try await client.post("v1/systemone", body: data, timeout: limit)
        }
        let decoded = try JSONDecoder().decode(Reply.self, from: reply)
        guard let fix = decoded.answers["fix"], let choice = fix.choice else {
            throw EngineError.healingFailed("\(tier.model) gave no choice")
        }
        let probability = fix.probabilities?[choice] ?? 0
        let percent = Int((probability * 100).rounded())
        if choice == HealingPrompt.none {
            return HealingAdvice(
                remediation: nil, confident: false,
                explanation: "System 1 (\(tier.model)) found no listed fix addresses the problem (\(percent)%)",
                model: tier.model)
        }
        guard request.candidates.contains(where: { $0.kind.rawValue == choice }) else {
            throw EngineError.healingFailed("\(tier.model) chose '\(choice)', which is not one of the options")
        }
        return HealingAdvice(
            remediation: choice,
            confident: probability >= Self.confidentProbability,
            explanation: "System 1 (\(tier.model)) chose \(choice) with \(percent)% probability",
            model: tier.model)
    }

    private struct Reply: Decodable {
        let answers: [String: Answer]

        struct Answer: Decodable {
            let choice: String?
            let probabilities: [String: Double]?
        }
    }
}
