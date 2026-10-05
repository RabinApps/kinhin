import Foundation

// MARK: - Routing-safe `runs-on:` editing for a workflow file.

/// Why "editor" and not "rewriter": kinhin routes per *label*, so only jobs
/// whose `runs-on:` is a plain label list (or a single scalar label) can be
/// routed by editing it. A `${{ }}` expression or a `{group:, labels:}`
/// mapping is resolved by the forge at queue time, so we refuse those jobs
/// and route through a config route instead — the same shape the user would
/// have to write manually. A job with no `runs-on:` at all (a reusable-
/// workflow `uses:` job) is refused too: writing one would invalidate it.
public enum WorkflowRouteEditor {
    /// A job whose `runs-on:` cannot be edited by kinhin (no plain label list).
    public enum EditError: LocalizedError {
        case cannotEdit(String, runsOn: String)
        case jobNotFound(String)

        public var errorDescription: String? {
            switch self {
            case .cannotEdit(let job, let runsOn):
                return "cannot edit job '\(job)': its runs-on: is '\(runsOn)'; "
                    + "route it with `kinhin runtimes route add` or edit the workflow by hand"
            case .jobNotFound(let job):
                return "could not locate job '\(job)' in the workflow file"
            }
        }
    }
}

// MARK: - Inspection (no write)

extension WorkflowRouteEditor {
    /// Does the job's `runs-on:` look like something kinhin can edit? A plain
    /// label list, or one scalar label. The forge forms — a `${{ }}`
    /// expression, a group mapping, or no key at all — are refused: they
    /// cannot be edited without changing what the workflow means.
    public static func canEdit(_ job: WorkflowJob) -> Bool {
        switch job.runsOn {
        case .labels, .scalar: return true
        case .absent, .expression, .groupMap: return false
        }
    }

    /// The job's existing labels (a scalar is its one label), or the error
    /// when the job is not editable.
    public static func labels(_ job: WorkflowJob) throws -> [String] {
        switch job.runsOn {
        case .labels(let labels): return labels
        case .scalar(let label): return [label]
        case .absent, .expression, .groupMap:
            throw EditError.cannotEdit(job.id, runsOn: job.runsOn.description)
        }
    }

    /// Whether the marker is already present for a job (a scalar label counts).
    public static func hasMarker(_ job: WorkflowJob, marker: String) -> Bool {
        ((try? labels(job)) ?? []).contains { $0.caseInsensitiveCompare(marker) == .orderedSame }
    }

    /// The marker for a runtime, or nil when the runtime has no marker (tart
    /// is route-only: its runners serve the fleet's default labels).
    public static func marker(for runtime: RuntimeID) -> String? {
        switch runtime {
        case .appleContainer: return "kinhin-container"
        case .docker: return "kinhin-docker"
        case .host: return "kinhin-host"
        case .tart: return nil
        }
    }
}

// MARK: - Editing (comment-preserving text surgery)

extension WorkflowRouteEditor {
    /// The new label list for a job routed to `runtime`. `poolLabels` are the
    /// target pool's registered labels — exactly what `kinhin runtimes`
    /// reports for it. The rules:
    ///
    /// - Labels the pool's runners don't advertise are dropped. The forge
    ///   AND-matches every label, so a leftover GitHub-hosted name
    ///   (`ubuntu-latest`) would strand the job forever; keeping only labels
    ///   the target registers with guarantees the runner match.
    /// - The target's marker is appended when missing, so kinhin's routing
    ///   picks the pool by label opt-in. For a markerless runtime (tart),
    ///   every stale `kinhin-*` marker is stripped instead — a marker-only
    ///   job would otherwise land in the wrong pool once a tart route applies.
    /// - When nothing matchable survives (a GitHub-hosted scalar, an
    ///   all-stale list), the pool's exact label list is written instead.
    public static func editJobLabels(current: [String], runtime: RuntimeID, poolLabels: [String]) -> [String] {
        let matchable = Set(poolLabels.map { $0.lowercased() })
        var out = current.filter { matchable.contains($0.lowercased()) }
        // Nothing matchable survived (a GitHub-hosted scalar, an all-stale
        // list): the pool's exact labels are the safe rewrite — marker and
        // runner match included.
        if out.isEmpty { return poolLabels }
        if let marker = marker(for: runtime) {
            if !out.contains(where: { $0.caseInsensitiveCompare(marker) == .orderedSame }) {
                out.append(marker)
            }
        } else {
            out = out.filter { !$0.hasPrefix("kinhin-") }
        }
        return out
    }

    /// Replace (or insert) the job's `runs-on:` line in `text` with `labels`,
    /// preserving every other byte of the file — comments, formatting and the
    /// rest of the workflow. A trailing comment on the `runs-on:` line itself
    /// survives; comments *inside* a replaced block-style list go with the
    /// labels they described.
    ///
    /// Block style (`runs-on:` followed by `- item` lines) is collapsed back
    /// to one flow line, consuming the old sequence so nothing is orphaned.
    public static func applyLabelEdit(jobID: String, labels: [String], in text: String) throws -> String {
        guard let jobIdx = findJobLine(jobID: jobID, in: text) else {
            throw EditError.jobNotFound(jobID)
        }
        var lines = text.components(separatedBy: "\n")
        let jobIndent = lineIndent(in: lines[jobIdx])
        if let runsOnIdx = indexOfRunsOnLine(after: jobIdx, in: lines, jobIndent: jobIndent) {
            let oldLine = lines[runsOnIdx]
            let keyIndent = lineIndent(in: oldLine)
            var newLine =
                String(repeating: " ", count: keyIndent)
                + "runs-on: [" + labels.map(flowLabel).joined(separator: ", ") + "]"
            // Keep a trailing ` # comment` on the replaced line.
            if let hash = oldLine.range(of: " #") {
                newLine += String(oldLine[hash.lowerBound...])
            }
            // Consume a block-style value (deeper-indented lines) so no
            // sequence items are left orphaned after the flow line.
            var end = runsOnIdx + 1
            while end < lines.count {
                let trimmed = lines[end].trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || lineIndent(in: lines[end]) > keyIndent {
                    end += 1
                } else {
                    break
                }
            }
            while end > runsOnIdx + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                end -= 1  // blank lines after the block belong to the next key
            }
            if end > runsOnIdx + 1 { lines.removeSubrange((runsOnIdx + 1)..<end) }
            lines[runsOnIdx] = newLine
        } else {
            // No `runs-on:` key in the job block: insert one just inside it.
            let indent = jobIndent + 2
            let line =
                String(repeating: " ", count: indent)
                + "runs-on: [" + labels.map(flowLabel).joined(separator: ", ") + "]"
            lines.insert(line, at: jobIdx + 1)
        }
        return lines.joined(separator: "\n")
    }

    /// The job key line (`  build:`) inside the top-level `jobs:` mapping.
    /// Scanning stops at the first column-0 key after `jobs:` begins, so a
    /// later top-level mapping can't supply a false match.
    private static func findJobLine(jobID: String, in text: String) -> Int? {
        let lines = text.components(separatedBy: "\n")
        var inJobs = false
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = lineIndent(in: line)
            if indent == 0, !trimmed.isEmpty, !trimmed.hasPrefix("#") {
                if trimmed == "jobs:" {
                    inJobs = true
                    continue
                }
                if inJobs { break }  // left the jobs block
                continue
            }
            guard inJobs, indent == 2, trimmed.hasSuffix(":") else { continue }
            var candidate = String(trimmed.dropLast())  // the trailing colon
            if candidate.count >= 2, candidate.hasPrefix("\""), candidate.hasSuffix("\"") {
                candidate = String(candidate.dropFirst().dropLast())
            }
            if candidate.caseInsensitiveCompare(jobID) == .orderedSame { return index }
        }
        return nil
    }

    /// The `runs-on:` key line inside a job block (any indent wider than the
    /// job's). Blank lines within the block don't end the search; the first
    /// real line back at (or above) the job's own indent does.
    private static func indexOfRunsOnLine(after jobIdx: Int, in lines: [String], jobIndent: Int) -> Int? {
        for i in (jobIdx + 1)..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if lineIndent(in: lines[i]) <= jobIndent { return nil }
            if trimmed.hasPrefix("runs-on:") { return i }
        }
        return nil
    }

    private static func lineIndent(in line: String) -> Int {
        line.count - line.drop(while: { $0 == " " }).count
    }

    /// One label in a flow sequence: plain when that is unambiguous, quoted
    /// when it contains YAML flow metacharacters (space, comma, brackets…).
    private static func flowLabel(_ label: String) -> String {
        let unsafe = CharacterSet(charactersIn: ",[]#:'\"{}&*!|>%@` \t")
        if label.isEmpty || label.unicodeScalars.contains(where: { unsafe.contains($0) }) {
            return YAMLText.quoted(label)
        }
        return label
    }
}
