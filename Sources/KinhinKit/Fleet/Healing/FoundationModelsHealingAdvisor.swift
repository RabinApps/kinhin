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
            let prompt = HealingPrompt.prompt(for: request, budget: Self.promptBudget())
            return try await Self.withDeadline(timeout) {
                let session = LanguageModelSession(model: .default, instructions: HealingPrompt.instructions)
                let response = try await session.respond(
                    to: prompt, schema: schema,
                    options: GenerationOptions(temperature: 0, maximumResponseTokens: 200))
                let content = response.content
                let pick = try content.value(String.self, forProperty: "remediation")
                let explanation = try content.value(String.self, forProperty: "explanation")
                return HealingAdvice(
                    remediation: pick == HealingPrompt.none ? nil : pick,
                    confident: try content.value(Bool.self, forProperty: "confident"),
                    explanation: LogRedactor.redact(explanation.trimmingCharacters(in: .whitespacesAndNewlines)),
                    selfReported: true)
            }
        }

        // MARK: - Schema and prompt

        /// The answer's shape: one candidate (or none), whether the model is
        /// sure, and one sentence for the user, generated in that order.
        @available(macOS 26, *)
        static func schema(for candidates: [Remediation]) throws -> GenerationSchema {
            let ids = candidates.map(\.kind.rawValue) + [HealingPrompt.none]
            let list = candidates.map { "\($0.kind.rawValue) (\($0.summary))" }.joined(separator: "; ")
            let root = DynamicGenerationSchema(
                name: "HealingAdvice", description: "The fix to apply for one fleet problem.",
                properties: [
                    DynamicGenerationSchema.Property(
                        name: "remediation",
                        description:
                            "The one fix that addresses the cause, from: \(list); or \(HealingPrompt.none) when none does",
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

        /// Characters of prompt the model's window leaves room for (see
        /// `HealingPrompt.budget`). 4,096 tokens on macOS 26 when the size is unknown.
        static func promptBudget() -> Int {
            guard #available(macOS 26, *), case .available = SystemLanguageModel.default.availability else {
                return HealingPrompt.budget(contextTokens: 4096)
            }
            let size = SystemLanguageModel.default.contextSize
            return HealingPrompt.budget(contextTokens: size > 0 ? size : 4096)
        }

        /// `operation`'s result, or `EngineError.healingFailed` after `seconds`.
        static func withDeadline<T: Sendable>(
            _ seconds: Double, _ operation: @escaping @Sendable () async throws -> T
        ) async throws -> T {
            try await HealingDeadline.run(seconds: seconds, operation)
        }
    }
#endif
