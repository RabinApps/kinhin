import Foundation

/// Text rendering of a pipeline, shared by the CLI and the app (labels,
/// glyphs, durations) so both surfaces describe states the same way.
public enum PipelineFormatter {
    public static func label(for state: PipelineStepState) -> String {
        switch state {
        case .pending: return "Queued"
        case .running: return "Running"
        case .succeeded: return "Succeeded"
        case .failed: return "Failed"
        case .skipped: return "Skipped"
        case .cancelled: return "Cancelled"
        }
    }

    public static func symbol(for state: PipelineStepState) -> String {
        switch state {
        case .pending: return "○"
        case .running: return "◐"
        case .succeeded: return "✓"
        case .failed: return "✕"
        case .skipped: return "–"
        case .cancelled: return "⊘"
        }
    }

    /// "1m 12s", "45s", "1h 02m"; nil without a start time.
    public static func duration(from start: Date?, to end: Date?, now: Date = Date()) -> String? {
        guard let start else { return nil }
        let seconds = max(0, Int((end ?? now).timeIntervalSince(start)))
        if seconds >= 3600 { return String(format: "%dh %02dm", seconds / 3600, (seconds % 3600) / 60) }
        if seconds >= 60 { return "\(seconds / 60)m \(String(format: "%02d", seconds % 60))s" }
        return "\(seconds)s"
    }

    /// "3s ago", "2m ago", "1h ago", "2d ago" (never negative: clock skew reads "just now").
    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<3: return "just now"
        case ..<60: return "\(seconds)s ago"
        case ..<3600: return "\(seconds / 60)m ago"
        case ..<86_400: return "\(seconds / 3600)h ago"
        default: return "\(seconds / 86_400)d ago"
        }
    }

    /// One line of live timing for a job or step: how long it has run and when
    /// it started (running) or finished (done). Nil while it is still queued.
    public static func timing(
        state: PipelineStepState, startedAt: Date?, finishedAt: Date?, now: Date = Date()
    ) -> String? {
        guard state != .pending, let startedAt else { return nil }
        let took = duration(from: startedAt, to: state.isFinished ? finishedAt : nil, now: now)
        if state.isFinished {
            guard let finishedAt else { return took }
            return [took, "finished \(ago(finishedAt, now: now))"].compactMap { $0 }.joined(separator: " · ")
        }
        return [took, "started \(ago(startedAt, now: now))"].compactMap { $0 }.joined(separator: " · ")
    }

    /// Why a job shows no steps (nil when it has some).
    public static func stepsHint(for job: PipelineJob, forge: ForgeID) -> String? {
        job.steps.isEmpty ? "\(forge.displayName) exposes no steps for this job." : nil
    }

    /// A job whose name or id matches `query` (exact id, else case-insensitive
    /// name; a unique substring also matches).
    public static func job(matching query: String, in detail: PipelineDetail) -> PipelineJob? {
        if let exact = detail.jobs.first(where: { $0.id == query }) { return exact }
        let lowered = query.lowercased()
        if let named = detail.jobs.first(where: { $0.name.lowercased() == lowered }) { return named }
        let partial = detail.jobs.filter { $0.name.lowercased().contains(lowered) }
        return partial.count == 1 ? partial[0] : nil
    }

    /// The pipeline as terminal text: header, then every job with its steps,
    /// or only `job` (with its steps) when given.
    public static func report(
        _ detail: PipelineDetail, vm: String? = nil, job only: PipelineJob? = nil, now: Date = Date()
    ) -> String {
        var lines: [String] = []
        lines.append("\(detail.forge.displayName) · \(detail.title)" + (vm.map { "  (\($0))" } ?? ""))
        let meta = [detail.repository, detail.ref, detail.sha.map { String($0.prefix(7)) }].compactMap { $0 }
        if !meta.isEmpty { lines.append(meta.joined(separator: " · ")) }
        if let url = only?.url ?? detail.url { lines.append(url) }
        lines.append("state: \(label(for: detail.state).lowercased())")
        if detail.granularity == .job {
            lines.append("note: \(detail.forge.displayName) reports jobs, not individual steps.")
        }
        lines.append("")
        let jobs = only.map { [$0] } ?? detail.jobs
        for job in jobs {
            let facts = [
                label(for: job.state),
                timing(state: job.state, startedAt: job.startedAt, finishedAt: job.finishedAt, now: now),
                job.isCurrent ? "this VM" : nil,
            ].compactMap { $0 }.joined(separator: " · ")
            lines.append("\(symbol(for: job.state)) \(job.name)  [\(facts)]")
            // Steps are shown for a single job, or for the VM's own job in the overview.
            guard only != nil || job.isCurrent else { continue }
            for step in job.steps {
                let timed = timing(state: step.state, startedAt: step.startedAt, finishedAt: step.finishedAt, now: now)
                lines.append("    \(symbol(for: step.state)) \(step.name)" + (timed.map { "  \($0)" } ?? ""))
            }
            if only != nil, let hint = stepsHint(for: job, forge: detail.forge) { lines.append("    \(hint)") }
        }
        return lines.joined(separator: "\n")
    }
}
