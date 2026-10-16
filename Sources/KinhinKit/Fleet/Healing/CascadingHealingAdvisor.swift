import Foundation
import Synchronization

/// The Ollama cascade: System 1 (a fast decision model) answers first, and the
/// LLM answers when System 1 is not confident or picks nothing. A confident
/// System 1 pick is final, so the bigger model is only asked the hard cases.
struct CascadingHealingAdvisor: HealingAdvisor {
    let fast: any HealingAdvisor
    let llm: any HealingAdvisor
    let llmReady = LLMReadiness()

    /// The LLM's name: the snapshot shows the model the user chose as the advisor.
    var name: String { llm.name }

    func isAvailable() async -> Bool {
        if await fast.isAvailable() { return true }
        return await llm.isAvailable()
    }

    /// System 1 is asked directly: a tier that is down fails its request, which
    /// is logged and treated as no answer. The LLM is asked only when its
    /// readiness (cached for `LLMReadiness.recheck`) says it can answer, so an
    /// unpulled model is not asked on every escalation.
    func advise(_ request: HealingAdviceRequest) async throws -> HealingAdvice? {
        let first = try await answer(from: fast, request)
        if let first, first.confident, first.remediation != nil { return first }
        // The LLM gives the final answer; if it has none, System 1's stands
        // (a doubtful pick is still only surfaced by the agent).
        guard await llmReady.isReady(now: Date(), probe: { await llm.isAvailable() }) else { return first }
        return try await answer(from: llm, request) ?? first
    }

    /// One tier's answer. A failure is logged and treated as no answer, so
    /// the other tier can still answer; cancellation always propagates.
    private func answer(from advisor: any HealingAdvisor, _ request: HealingAdviceRequest) async throws
        -> HealingAdvice?
    {
        do {
            return try await advisor.advise(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.warn("healing", "\(advisor.name) gave no advice: \(error.localizedDescription)")
            return nil
        }
    }
}

/// The LLM tier's last readiness answer, reused for `recheck` seconds. A cancelled
/// probe is not cached (it says nothing about the model).
final class LLMReadiness: Sendable {
    static let recheck: TimeInterval = 600
    private let last = Mutex<(answer: Bool, at: Date)?>(nil)

    func isReady(now: Date, probe: () async -> Bool) async -> Bool {
        if let cached = last.withLock({ $0 }), abs(now.timeIntervalSince(cached.at)) < Self.recheck {
            return cached.answer
        }
        let answer = await probe()
        guard !Task.isCancelled else { return answer }
        last.withLock { $0 = (answer, now) }
        return answer
    }
}
