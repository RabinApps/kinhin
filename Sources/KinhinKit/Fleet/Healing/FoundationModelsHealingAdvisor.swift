#if canImport(FoundationModels)
    import Foundation
    import FoundationModels

    /// The healing advisor on Apple Intelligence (Foundation Models): entirely
    /// on this Mac, no account, nothing sent anywhere. Builds against the macOS
    /// 26 SDK and answers only on macOS 26 or later; on older systems it is
    /// never available and the agent runs its rules alone.
    ///
    /// One structured generation answers everything: `remediation` is a string
    /// limited to the request's candidate ids (plus `none`), so the model's
    /// output is schema-constrained to the allowlist before the agent checks it
    /// again; `confident` and a one-sentence `explanation` come from the same
    /// generation, so the reasoning shown is the reasoning behind the pick. The
    /// call has a deadline: a model that is slow or unavailable is "no advice",
    /// never a stall.
    struct FoundationModelsHealingAdvisor: HealingAdvisor {
        /// Seconds for the whole answer.
        var timeout: Double = 20

        var name: String { "apple-intelligence" }

        func isAvailable() async -> Bool {
            guard #available(macOS 26, *) else { return false }
            if case .available = SystemLanguageModel.default.availability { return true }
            return false
        }

        func advise(_ request: HealingAdviceRequest) async throws -> HealingAdvice? {
            guard #available(macOS 26, *), !request.candidates.isEmpty else { return nil }
            let schema = try Self.schema(for: request.candidates)
            let prompt = Self.prompt(for: request, budget: Self.promptBudget())
            return try await Self.withDeadline(timeout) {
                let session = LanguageModelSession(model: .default, instructions: Self.instructions)
                let response = try await session.respond(
                    to: prompt, schema: schema,
                    options: GenerationOptions(temperature: 0, maximumResponseTokens: 200))
                let content = response.content
                let pick = try content.value(String.self, forProperty: "remediation")
                let explanation = try content.value(String.self, forProperty: "explanation")
                return HealingAdvice(
                    remediation: pick == Self.none ? nil : pick,
                    confident: try content.value(Bool.self, forProperty: "confident"),
                    explanation: LogRedactor.redact(explanation.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }

        // MARK: - Schema and prompt

        static let none = "none"

        static let instructions = """
            You choose a fix for a problem in a self-hosted CI runner fleet on a Mac. Pick only from the fixes \
            listed, or none when no listed fix addresses the problem. Use only facts stated in the problem and \
            the log lines; do not guess a cause they do not name.
            """

        /// The answer's shape: one candidate (or none), whether the model is
        /// sure, and one sentence for the user, generated in that order.
        @available(macOS 26, *)
        static func schema(for candidates: [Remediation]) throws -> GenerationSchema {
            let ids = candidates.map(\.kind.rawValue) + [none]
            let list = candidates.map { "\($0.kind.rawValue) (\($0.summary))" }.joined(separator: "; ")
            let root = DynamicGenerationSchema(
                name: "HealingAdvice", description: "The fix to apply for one fleet problem.",
                properties: [
                    DynamicGenerationSchema.Property(
                        name: "remediation",
                        description: "The one fix that addresses the cause, from: \(list); or \(none) when none does",
                        schema: DynamicGenerationSchema(name: "Remediation", anyOf: ids)),
                    DynamicGenerationSchema.Property(
                        name: "confident",
                        description: "true only when the problem and the logs clearly point at that fix",
                        schema: DynamicGenerationSchema(type: Bool.self)),
                    DynamicGenerationSchema.Property(
                        name: "explanation",
                        description: "One short sentence for a developer: why this fix (or none)",
                        schema: DynamicGenerationSchema(type: String.self)),
                ])
            return try GenerationSchema(root: root, dependencies: [])
        }

        /// The problem, its candidates and the recent log lines, trimmed to
        /// `budget` characters (the context is cut first, from the oldest end).
        static func prompt(for request: HealingAdviceRequest, budget: Int) -> String {
            let subject = request.signal.subject.map { ", \($0)" } ?? ""
            let head = """
                Problem (\(request.signal.kind.rawValue)\(subject)): \(request.signal.detail)
                Fixes kinhin may apply: \(request.candidates.map(\.summary).joined(separator: "; ")).
                Recent log lines:

                """
            let room = max(0, budget - head.count)
            return LogRedactor.redact(head + String(request.context.suffix(room)))
        }

        /// Characters of prompt the model's window leaves room for: about four
        /// characters a token, half the window for the prompt (the instructions,
        /// the schema and the answer need the rest). 4,096 tokens on macOS 26.
        static func promptBudget() -> Int {
            guard #available(macOS 26, *), case .available = SystemLanguageModel.default.availability else {
                return 4096 * 4 / 2
            }
            let size = SystemLanguageModel.default.contextSize
            return (size > 0 ? size : 4096) * 4 / 2
        }

        /// `operation`'s result, or `EngineError.healingFailed` after `seconds`.
        static func withDeadline<T: Sendable>(
            _ seconds: Double, _ operation: @escaping @Sendable () async throws -> T
        ) async throws -> T {
            try await HealingDeadline.run(seconds: seconds, operation)
        }
    }
#endif
