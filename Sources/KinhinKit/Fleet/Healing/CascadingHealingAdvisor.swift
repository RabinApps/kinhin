import Foundation
import Synchronization

/// The Ollama cascade: System 1 (a fast decision model) answers first, and the
/// LLM answers when System 1 is not confident or picks nothing. A confident
/// System 1 pick is final, so the bigger model is only asked the hard cases.
struct CascadingHealingAdvisor: HealingAdvisor {
    let fast: any HealingAdvisor
    let llm: any HealingAdvisor
    let fastReady = TierReadiness()
    let llmReady = TierReadiness()

    /// The LLM's name: the snapshot shows the model the user chose as the advisor.
    var name: String { llm.name }

    func isAvailable() async -> Bool {
        if await fast.isAvailable() { return true }
        return await llm.isAvailable()
    }

    /// Each tier is asked only when its readiness (cached in `TierReadiness`) says
    /// it can answer, so an unpulled model is not asked on every escalation.
    func advise(_ request: HealingAdviceRequest) async throws -> HealingAdvice? {
        var first: HealingAdvice?
        if await fastReady.isReady(now: Date(), probe: { await fast.isAvailable() }) {
            first = try await answer(from: fast, request)
        }
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

/// One tier's last readiness answer. A ready answer is reused for `recheck`
/// seconds; a not-ready answer only for `notReadyRecheck`, so a model pulled
/// after a failed check is picked up soon. A cancelled probe is not cached
/// (it says nothing about the model).
final class TierReadiness: Sendable {
    static let recheck: TimeInterval = 600
    static let notReadyRecheck: TimeInterval = 60
    private let last = Mutex<(answer: Bool, at: Date)?>(nil)

    func isReady(now: Date, probe: () async -> Bool) async -> Bool {
        if let cached = last.withLock({ $0 }) {
            let ttl = cached.answer ? Self.recheck : Self.notReadyRecheck
            if abs(now.timeIntervalSince(cached.at)) < ttl { return cached.answer }
        }
        let answer = await probe()
        guard !Task.isCancelled else { return answer }
        last.withLock { $0 = (answer, now) }
        return answer
    }
}
