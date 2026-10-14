import Foundation

/// The Toolchains suite: for every catalog tool and stack, the cold install
/// through the `image prepare` path, its verify command, and a tiny offline
/// workload, each timed inside a bench instance of the right platform.
///
/// Quick runs time verify + workload only (an entry the image lacks reads
/// `skipped`). Thorough runs also time the cold install, on a fresh Tart VM
/// per `ToolchainCategory` or a fresh container per tool, with requirements
/// installed first and untimed.
enum ToolchainBenchmark {
    static func run(
        _ ctx: BenchmarkContext, runtime: RuntimeID, ids: [String]?
    ) async throws -> BenchmarkSuiteResult {
        let thorough = ctx.options.intensity == .thorough
        ctx.sink.set(suite: "toolchains", runtime: runtime.rawValue, step: "boot \(runtime.rawValue)")
        var instance: BenchmarkInstance
        do {
            instance = try await ctx.acquire(runtime)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return BenchmarkSuiteResult(
                name: "toolchains", runtime: runtime.rawValue, status: .failed, error: message)
        }
        let plans = grouped(ToolchainBenchPlan.plans(platform: instance.platform, ids: ids), byCategory: thorough)
        guard !plans.isEmpty else {
            await ctx.tracker.release(name: instance.name)
            return BenchmarkSuiteResult(
                name: "toolchains", runtime: runtime.rawValue, platform: instance.platformLabel, status: .skipped,
                skipReason: "no selected toolchain applies to a \(instance.platformLabel) guest")
        }

        var rows: [ToolchainBenchRow] = []
        var installed = Set<String>()
        var lastCategory: ToolchainCategory?
        var first = true
        for plan in plans {
            try Task.checkCancellation()
            // A thorough run installs into a clean guest: per category on Tart, per tool on containers.
            let needsFresh =
                thorough && !first && (runtime == .tart ? plan.category != lastCategory : true)
            if needsFresh {
                await ctx.tracker.release(name: instance.name)
                installed = []
                do {
                    instance = try await ctx.acquire(runtime)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    rows.append(
                        failedRow(plan, instance, "could not boot a fresh guest: \(error.localizedDescription)"))
                    continue
                }
            }
            first = false
            lastCategory = plan.category
            rows.append(try await row(ctx, plan, on: instance, thorough: thorough, installed: &installed))
        }
        await ctx.tracker.release(name: instance.name)
        return BenchmarkSuiteResult(
            name: "toolchains", runtime: runtime.rawValue, platform: instance.platformLabel, status: .ran,
            toolchains: rows)
    }

    /// Keeps a category's plans together (a thorough Tart run boots one VM per category), requirements first.
    static func grouped(_ plans: [ToolchainBenchPlan], byCategory: Bool) -> [ToolchainBenchPlan] {
        guard byCategory else { return plans }
        let order = ToolchainCategory.allCases
        return plans.enumerated().sorted { lhs, rhs in
            let keys = [lhs, rhs].map { entry in
                (
                    order.firstIndex(of: entry.element.category) ?? 0, entry.element.requires.isEmpty ? 0 : 1,
                    entry.offset
                )
            }
            return keys[0] < keys[1]
        }.map(\.element)
    }

    // MARK: - One entry

    private static func row(
        _ ctx: BenchmarkContext, _ plan: ToolchainBenchPlan, on instance: BenchmarkInstance, thorough: Bool,
        installed: inout Set<String>
    ) async throws -> ToolchainBenchRow {
        ctx.sink.set(step: plan.id)
        var row = ToolchainBenchRow(
            tool: plan.id, platform: instance.platformLabel, runtime: instance.runtimeID.rawValue,
            installer: plan.installer, status: .ran,
            workload: plan.workload.skipReason == nil ? workloadName(plan) : nil)
        do {
            try await ensureGuestPackages(ctx, plan, on: instance)
            if thorough { try await ensureGuestMiseTools(ctx, plan, on: instance) }
            if thorough {
                try await ensureRequirements(ctx, plan, on: instance, installed: &installed)
                let existing = try await timedVerify(ctx, plan, on: instance)
                if existing.succeeded {
                    row.verifyMs = existing.ms
                    row.note = "preinstalled"
                } else {
                    ctx.sink.set(step: "\(plan.id) › install")
                    let install = try await BenchmarkContext.measure {
                        try await ctx.run(instance, plan.installScript(runsAsRoot: runsAsRoot(instance)), timeout: 3600)
                    }
                    guard install.value.succeeded else {
                        let detail = BenchmarkContext.detail(of: install.value)
                        // A guest that ran out of disk says nothing about the tool.
                        if let reason = try await diskFullReason(ctx, on: instance, output: detail) {
                            return finish(row, .skipped, reason: reason)
                        }
                        return finish(row, .failed, note: "install failed: \(detail)")
                    }
                    row.installMs = install.ms
                    let verified = try await timedVerify(ctx, plan, on: instance)
                    row.verifyMs = verified.ms
                    guard verified.succeeded else {
                        return finish(row, .failed, note: "verify failed after install: \(verified.detail)")
                    }
                }
                installed.insert(plan.id)
            } else {
                let verified = try await timedVerify(ctx, plan, on: instance)
                row.verifyMs = verified.ms
                guard verified.succeeded else {
                    row.verifyMs = nil
                    return finish(
                        row, .skipped,
                        reason: "not installed in this image (a thorough run times the install)")
                }
            }
            switch plan.workload {
            case .skip(let reason):
                row.skipReason = reason
                row.note = [row.note, "verify only"].compactMap { $0 }.joined(separator: "; ")
            case .script(_, let body):
                ctx.sink.set(step: "\(plan.id) › workload")
                let timed = try await BenchmarkContext.measure { try await ctx.run(instance, body, timeout: 900) }
                if timed.value.exitCode == BenchmarkScripts.skipExitCode {
                    row.skipReason = BenchmarkContext.lastLine(timed.value.stdout) ?? "workload skipped"
                    row.workload = nil
                } else if timed.value.succeeded {
                    row.workloadMs = timed.ms
                } else {
                    return finish(row, .failed, note: "workload failed: \(BenchmarkContext.detail(of: timed.value))")
                }
            }
            return row
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return finish(row, .failed, note: error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private static func workloadName(_ plan: ToolchainBenchPlan) -> String? {
        if case .script(let name, _) = plan.workload { return name }
        return nil
    }

    private static func finish(
        _ row: ToolchainBenchRow, _ status: BenchmarkOutcome, reason: String? = nil, note: String? = nil
    ) -> ToolchainBenchRow {
        var row = row
        row.status = status
        if let reason { row.skipReason = reason }
        if let note { row.note = note }
        return row
    }

    private static func failedRow(_ plan: ToolchainBenchPlan, _ instance: BenchmarkInstance, _ note: String)
        -> ToolchainBenchRow
    {
        ToolchainBenchRow(
            tool: plan.id, platform: instance.platformLabel, runtime: instance.runtimeID.rawValue,
            installer: plan.installer, status: .failed, note: note)
    }

    /// Container guests bake as root; a Tart guest runs the `admin` user and goes through sudo.
    private static func runsAsRoot(_ instance: BenchmarkInstance) -> Bool { instance.runtimeID != .tart }

    private static func timedVerify(_ ctx: BenchmarkContext, _ plan: ToolchainBenchPlan, on instance: BenchmarkInstance)
        async throws -> (succeeded: Bool, ms: Double, detail: String)
    {
        let timed = try await BenchmarkContext.measure {
            try await ctx.run(instance, "{ \(plan.verify); } >/dev/null", timeout: 300)
        }
        return (timed.value.succeeded, timed.ms, BenchmarkContext.detail(of: timed.value))
    }

    /// apt packages the entry needs on a Linux guest (a compiler, headers). Untimed; a no-op once present.
    private static func ensureGuestPackages(
        _ ctx: BenchmarkContext, _ plan: ToolchainBenchPlan, on instance: BenchmarkInstance
    ) async throws {
        guard instance.platform == .linux, let first = plan.guestPackages.first else { return }
        let sudo = runsAsRoot(instance) ? "" : "sudo "
        // `a|b` (a catalog library named differently per base image) installs the first name this apt knows.
        let packages = plan.guestPackages.map { package in
            package.contains("|")
                ? "\"$(pick \(package.split(separator: "|").map { BenchmarkScripts.quote(String($0)) }.joined(separator: " ")))\""
                : BenchmarkScripts.quote(package)
        }.joined(separator: " ")
        ctx.sink.set(step: "\(plan.id) › guest packages")
        let result = try await ctx.run(
            instance,
            """
            export DEBIAN_FRONTEND=noninteractive
            pick() { for n in "$@"; do if apt-cache show "$n" >/dev/null 2>&1; then echo "$n"; return; fi; done; echo "$1"; }
            if ! dpkg-query -W -f='${Status}' \(BenchmarkScripts.quote(first)) 2>/dev/null | grep -q 'install ok installed'; then
              \(sudo)apt-get update -qq
              \(sudo)apt-get install -y --no-install-recommends \(packages)
            fi
            """, timeout: 1800)
        guard result.succeeded else {
            throw BenchmarkError.stepFailed(step: "guest packages", detail: BenchmarkContext.detail(of: result))
        }
    }

    /// A modern Ruby from mise for gem installs on macOS (the system Ruby 2.6 cannot build native extensions).
    private static func ensureGuestMiseTools(
        _ ctx: BenchmarkContext, _ plan: ToolchainBenchPlan, on instance: BenchmarkInstance
    ) async throws {
        guard instance.platform == .macOS else { return }
        for tool in plan.guestMiseTools {
            ctx.sink.set(step: "\(plan.id) › \(tool) from mise")
            let quoted = BenchmarkScripts.quote(tool)
            let result = try await ctx.run(
                instance, "mise which \(quoted) >/dev/null 2>&1 || mise use --global \(quoted)@latest", timeout: 3600)
            guard result.succeeded else {
                throw BenchmarkError.stepFailed(step: "\(tool) from mise", detail: BenchmarkContext.detail(of: result))
            }
        }
    }

    /// A reason to skip rather than fail when an install died because the guest had no room: out-of-space
    /// output, or a failed extraction on a nearly full disk.
    private static func diskFullReason(
        _ ctx: BenchmarkContext, on instance: BenchmarkInstance, output: String
    ) async throws -> String? {
        let lowered = output.lowercased()
        let suspicious = lowered.contains("space") || lowered.contains("extract") || lowered.contains("write error")
        guard suspicious else { return nil }
        let free = try await ctx.run(instance, #"df -k "$HOME" | awk 'NR==2 {print $4}'"#, timeout: 60)
        guard let kilobytes = Int(free.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let gigabytes = Double(kilobytes) / 1_048_576
        guard gigabytes < 4 else { return nil }
        return String(format: "the guest has only %.1f GB free; free disk space and re-run", gigabytes)
    }

    /// Installs what `plan` requires (node for npm tools, java for the JVM ones) when the guest lacks it. Untimed.
    private static func ensureRequirements(
        _ ctx: BenchmarkContext, _ plan: ToolchainBenchPlan, on instance: BenchmarkInstance,
        installed: inout Set<String>
    ) async throws {
        for requirement in plan.requires where !installed.contains(requirement) {
            guard let tool = ToolchainCatalog.tool(id: requirement) else { continue }
            let dependency = ToolchainBenchPlan.plan(for: tool, platform: plan.platform)
            let present = try await timedVerify(ctx, dependency, on: instance)
            if !present.succeeded {
                ctx.sink.set(step: "\(plan.id) › prerequisite \(requirement)")
                let result = try await ctx.run(
                    instance, dependency.installScript(runsAsRoot: runsAsRoot(instance)), timeout: 3600)
                guard result.succeeded else {
                    throw BenchmarkError.stepFailed(
                        step: "prerequisite \(requirement)", detail: BenchmarkContext.detail(of: result))
                }
            }
            installed.insert(requirement)
        }
    }
}
