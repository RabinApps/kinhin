import Foundation

/// The LLM tier: an Ollama chat model (any model the user pulled or built with
/// `ollama create`), asked through `/api/chat`. The JSON schema in `format`
/// limits the reply to a candidate's id or `none`, a confidence and a
/// sentence, the same answer shape the on-device model gives.
struct OllamaHealingAdvisor: HealingAdvisor {
    let tier: OllamaTier
    /// Seconds for the whole answer, a deadline rather than an idle timeout; a
    /// local model may cold-start.
    var timeout: TimeInterval = 60

    /// Structured `format` needs Ollama 0.5 or later.
    static let minimumVersion = "0.5.0"

    init(
        host: URL, model: String, keepAlive: String = OllamaClient.keepAlive,
        session: URLSession = OllamaClient.defaultSession
    ) {
        self.tier = OllamaTier(
            host: host, model: model, minimumVersion: Self.minimumVersion, keepAlive: keepAlive, session: session)
    }

    var name: String { tier.name }

    func isAvailable() async -> Bool {
        await tier.isAvailable()
    }

    func advise(_ request: HealingAdviceRequest) async throws -> HealingAdvice? {
        guard !request.candidates.isEmpty else { return nil }
        let budget = HealingPrompt.budget(contextTokens: HealingPrompt.ollamaContextTokens)
        let messages: [[String: String]] = [
            ["role": "system", "content": HealingPrompt.instructions],
            ["role": "user", "content": HealingPrompt.prompt(for: request, budget: budget)],
        ]
        let options: [String: Any] = [
            "temperature": 0, "num_predict": 2048, "num_ctx": HealingPrompt.ollamaContextTokens,
        ]
        // Thinking models (gemma4, for one) reason before they answer. Their reasoning
        // comes back in `message.thinking` and the answer in `message.content`, but
        // the reasoning counts against `num_predict`, so the budget leaves room for it.
        let body: [String: Any] = [
            "model": tier.model,
            "stream": false,
            "keep_alive": tier.keepAlive,
            "messages": messages,
            "format": Self.schema(kinds: request.candidates.map(\.kind.rawValue)),
            "options": options,
        ]
        let data = try OllamaClient.encode(body)
        let client = tier.client
        let limit = timeout
        let reply = try await HealingDeadline.run(seconds: limit) {
            try await client.post("api/chat", body: data, timeout: limit)
        }
        let chat = try JSONDecoder().decode(ChatReply.self, from: reply)
        let answer = try JSONDecoder().decode(Answer.self, from: Data(chat.message.content.utf8))
        return HealingAdvice(
            remediation: answer.remediation == HealingPrompt.none ? nil : answer.remediation,
            confident: answer.confident,
            explanation: LogRedactor.redact(answer.explanation.trimmingCharacters(in: .whitespacesAndNewlines)),
            model: tier.model, selfReported: true)
    }

    /// The answer's shape: one candidate id (or `none`), whether the model is
    /// sure, and one sentence, as JSON Schema for Ollama's `format`.
    static func schema(kinds: [String]) -> [String: Any] {
        let remediation: [String: Any] = [
            "type": "string",
            "enum": kinds + [HealingPrompt.none],
            "description": "The one fix that addresses the cause, or none",
        ]
        let confident: [String: Any] = [
            "type": "boolean",
            "description": "true only when the problem and the logs clearly point at that fix",
        ]
        let explanation: [String: Any] = [
            "type": "string",
            "description": "One short sentence for a developer: why this fix (or none)",
        ]
        return [
            "type": "object",
            "properties": ["remediation": remediation, "confident": confident, "explanation": explanation],
            "required": ["remediation", "confident", "explanation"],
        ]
    }

    private struct ChatReply: Decodable {
        let message: Message

        struct Message: Decodable {
            let content: String
        }
    }

    private struct Answer: Decodable {
        let remediation: String
        let confident: Bool
        let explanation: String
    }
}
