import Foundation

/// The question every model-backed advisor is asked, and the text it gets:
/// the problem, the fixes kinhin allows, and the recent log lines. The
/// on-device model and the Ollama advisors share it, so they answer the same
/// question and only the transport differs.
enum HealingPrompt {
    /// The answer for "none of the listed fixes".
    static let none = "none"

    static let instructions = """
        You choose a fix for a problem in a self-hosted CI runner fleet on a Mac. Pick only from the fixes \
        listed, or none when no listed fix addresses the problem. Use only facts stated in the problem and \
        the log lines; do not guess a cause they do not name.
        """

    /// Characters of prompt that fit a window of `contextTokens`: about four
    /// characters a token, half the window for the prompt (the instructions,
    /// the schema and the answer need the rest).
    static func budget(contextTokens: Int) -> Int {
        contextTokens * 4 / 2
    }

    /// The window the Ollama advisors ask for (`num_ctx`).
    static let ollamaContextTokens = 4096

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
}
