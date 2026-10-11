#if DEBUG
import Foundation
import KinhinKit

/// A scripted, looping fleet for screen recordings: jobs arrive, instances
/// clone → boot → register → run → get deleted, one job fails and its retry
/// succeeds. Pure and deterministic: a frame is a function of the elapsed
/// seconds, so two recordings of the same script look the same.
struct DemoTimeline: Sendable, Codable, Equatable {
    struct Job: Sendable, Codable, Equatable {
        let repo: String
        /// Account and forge name (they are the same string in the demo config).
        let account: String
        let runtime: RuntimeID
        let workflow: String
        /// When the job shows up in the queue, and when a free slot claims it.
        let arrive: Double
        let start: Double
        let run: Double
        var fails = false
    }

    /// Seconds before the script starts over.
    let period: Double
    let capacity: Int
    let jobs: [Job]

    static let launch = DemoTimeline(
        period: 48, capacity: 4,
        jobs: [
            Job(repo: "acme/api", account: "github", runtime: .tart, workflow: "CI", arrive: 1, start: 2, run: 14),
            Job(
                repo: "acme/web", account: "github", runtime: .appleContainer, workflow: "Lint & test", arrive: 2,
                start: 3, run: 8),
            Job(
                repo: "acme/ios", account: "github", runtime: .tart,
                workflow: "Build app", arrive: 3, start: 4, run: 16),
            Job(
                repo: "lab/infra", account: "gitea", runtime: .docker,
                workflow: "Validate", arrive: 5, start: 6, run: 7),
            Job(
                repo: "lab/site", account: "forgejo", runtime: .appleContainer, workflow: "Build docs", arrive: 7,
                start: 15.5, run: 6),
            Job(
                repo: "acme/api", account: "gitlab", runtime: .docker, workflow: "test", arrive: 9, start: 17, run: 5,
                fails: true),
            Job(
                repo: "acme/web", account: "github", runtime: .appleContainer, workflow: "Lint & test", arrive: 24,
                start: 24, run: 6),
            Job(
                repo: "lab/infra", account: "gitea", runtime: .docker,
                workflow: "Validate", arrive: 28, start: 28, run: 6),
            Job(repo: "acme/api", account: "gitlab", runtime: .docker, workflow: "test", arrive: 29, start: 29, run: 5),
        ])

    /// Why a script cannot be played; thrown by `validated()` so a typo in a hand-written script says what is wrong.
    struct Invalid: Error, CustomStringConvertible {
        let description: String
    }

    /// The scripts that ship in the app, by the name `KINHIN_DEMO` takes.
    static let builtIn: [String: DemoTimeline] = ["launch": .launch]

    /// A script by built-in name, or by path to a JSON file (anything ending in `.json`).
    static func load(_ nameOrPath: String) throws -> DemoTimeline {
        if nameOrPath.hasSuffix(".json") {
            let data = try Data(contentsOf: URL(fileURLWithPath: (nameOrPath as NSString).expandingTildeInPath))
            return try JSONDecoder().decode(DemoTimeline.self, from: data).validated()
        }
        guard let timeline = builtIn[nameOrPath] else {
            let known = builtIn.keys.sorted().joined(separator: ", ")
            throw Invalid(description: "unknown demo \"\(nameOrPath)\" (built in: \(known); or pass a .json path)")
        }
        return timeline
    }

    /// Rejects scripts that would play wrongly: no loop, no slots, a job claimed before it is queued, or never running.
    func validated() throws -> DemoTimeline {
        guard period > 0 else { throw Invalid(description: "period must be > 0") }
        guard capacity > 0 else { throw Invalid(description: "capacity must be > 0") }
        guard !jobs.isEmpty else { throw Invalid(description: "a demo needs at least one job") }
        for (index, job) in jobs.enumerated() {
            guard job.arrive >= 0, job.start >= job.arrive else {
                throw Invalid(description: "job \(index) (\(job.repo)): start must be >= arrive >= 0")
            }
            guard job.run > 0 else { throw Invalid(description: "job \(index) (\(job.repo)): run must be > 0") }
            guard ForgeID(rawValue: job.account) != nil else {
                let forges = ForgeID.allCases.map(\.rawValue).joined(separator: ", ")
                throw Invalid(description: "job \(index): account \"\(job.account)\" is not a forge (\(forges))")
            }
            let boot = Self.bootTimes(job.runtime)
            let hold = job.fails ? Self.failedHold : 0
            let end = job.start + boot.clone + boot.boot + boot.register + job.run + hold + Self.deleteDuration
            guard end <= period else {
                throw Invalid(description: "job \(index) (\(job.repo)) ends at \(end)s, after the \(period)s loop")
            }
        }
        return self
    }

    static let failedHold = 3.0
    static let deleteDuration = 2.0
    static let stepNames = ["Set up job", "Checkout", "Install toolchain", "Build", "Test", "Post checkout"]

    /// Seconds each phase of a fresh instance takes on a runtime.
    static func bootTimes(_ runtime: RuntimeID) -> (clone: Double, boot: Double, register: Double) {
        switch runtime {
        case .tart: return (1, 3, 1.5)
        case .appleContainer: return (0.5, 1, 1)
        case .docker, .host: return (0.3, 0.7, 1)
        }
    }

    /// One job's place in the script at a moment.
    struct Placement: Sendable {
        enum Stage: Equatable, Sendable {
            case queued
            case instance(VMPhase)
        }
        let index: Int
        let job: Job
        let stage: Stage
        /// Seconds since the instance was created (0 while queued).
        let age: Double
        /// 0…1 through the run; nil outside the busy phase.
        let progress: Double?

        var vmID: String { String(format: "kinhin-17600000%02d-a1b2c3d%d", index, index % 10) }
    }

    func placements(at elapsed: Double) -> [Placement] {
        let t = elapsed.truncatingRemainder(dividingBy: period)
        return jobs.enumerated().compactMap { index, job in
            guard t >= job.arrive else { return nil }
            guard t >= job.start else {
                return Placement(index: index, job: job, stage: .queued, age: 0, progress: nil)
            }
            let age = t - job.start
            let boot = Self.bootTimes(job.runtime)
            let cloneEnd = boot.clone
            let bootEnd = cloneEnd + boot.boot
            let registerEnd = bootEnd + boot.register
            let runEnd = registerEnd + job.run
            let holdEnd = runEnd + (job.fails ? Self.failedHold : 0)
            let deleteEnd = holdEnd + Self.deleteDuration
            func make(_ phase: VMPhase, progress: Double? = nil) -> Placement {
                Placement(index: index, job: job, stage: .instance(phase), age: age, progress: progress)
            }
            switch age {
            case ..<cloneEnd: return make(.cloning)
            case ..<bootEnd: return make(.booting)
            case ..<registerEnd: return make(.registering)
            case ..<runEnd: return make(.busy, progress: (age - registerEnd) / job.run)
            case ..<holdEnd: return make(.failed)
            case ..<deleteEnd: return make(.deleting)
            default: return nil
            }
        }
    }

    /// The fleet status at `elapsed` seconds into the script; `now` anchors the dates.
    func status(elapsed: Double, now: Date, running: Bool = true, paused: Bool = false) -> FleetStatus {
        var status = FleetStatus(
            running: running, paused: paused, pollInterval: 5, queuePolledAt: now, capacityCap: capacity,
            jobCapacity: capacity, updatedAt: now)
        status.currentPollInterval = 5
        guard running else { return status }
        let placed = placements(at: elapsed)
        var queuedByRepo: [String: Int] = [:]
        var runningByRepo: [String: Int] = [:]
        for placement in placed {
            switch placement.stage {
            case .queued:
                queuedByRepo[placement.job.repo, default: 0] += 1
            case .instance(let phase):
                var record = VMRecord(
                    id: placement.vmID, phase: phase, createdAt: now.addingTimeInterval(-placement.age))
                record.updatedAt = now
                record.runnerName = placement.vmID
                record.platform = placement.job.account
                record.runtimeID = placement.job.runtime
                record.ip = "192.168.64.\(10 + placement.index)"
                if phase == .busy || phase == .failed {
                    record.job = placement.job.workflow
                    record.repos = [placement.job.repo]
                }
                if phase == .busy {
                    runningByRepo[placement.job.repo, default: 0] += 1
                    let load = Double(placement.index % 3) * 12
                    record.usage = ResourceUsage(
                        cpuPercent: placement.job.runtime == .tart ? 55 + load : 180 + load * 4,
                        memoryUsedMB: 2200 + placement.index * 310, memoryLimitMB: 8192)
                }
                if phase == .failed {
                    record.error = "job failed: step \"Test\" exited with code 1"
                    status.setAlert(
                        "vm:\(placement.vmID)", "\(placement.job.repo): job failed on \(placement.vmID) (exit code 1)")
                }
                status.records.append(record)
            }
        }
        status.queueDepth = queuedByRepo.values.reduce(0, +)
        status.queueByRepo = queuedByRepo.isEmpty ? nil : queuedByRepo
        status.runningByRepo = runningByRepo.isEmpty ? nil : runningByRepo
        status.desired = min(capacity, status.activeCount + status.queueDepth)
        let busy = Double(runningByRepo.values.reduce(0, +))
        status.host = HostUsage(cpuPercent: 8 + busy * 9, memoryUsedGB: 14 + busy * 2.5, memoryTotalGB: 64)
        return status
    }

    /// The pipeline a busy instance is running at `elapsed`; nil for any other instance.
    func pipeline(vmID: String, elapsed: Double, now: Date) -> PipelineDetail? {
        guard let placement = placements(at: elapsed).first(where: { $0.vmID == vmID }),
            let progress = placement.progress, let forge = ForgeID(rawValue: placement.job.account)
        else { return nil }
        let names = Self.stepNames
        let done = Int(progress * Double(names.count))
        let started = now.addingTimeInterval(-progress * placement.job.run)
        let steps = names.enumerated().map { offset, name in
            PipelineStep(
                name: name, state: offset < done ? .succeeded : offset == done ? .running : .pending,
                startedAt: offset <= done ? started : nil, finishedAt: offset < done ? now : nil,
                logRef: "step-\(offset)")
        }
        let job = PipelineJob(
            id: "job-\(placement.index)", name: placement.job.workflow, state: .running, startedAt: started,
            steps: steps, isCurrent: true, logRef: "job-\(placement.index)")
        return PipelineDetail(
            forge: forge, title: placement.job.workflow, repository: placement.job.repo, ref: "main", sha: "9f3c2ab",
            state: .running, startedAt: started, jobs: [job], granularity: .step, fetchedAt: now)
    }

    static func log(forStep stepIndex: Int?) -> String {
        let name = stepIndex.flatMap { names($0) } ?? "job"
        return """
            ##[group]Run \(name)
            ▸ fresh instance, nothing left over from the last job
            ▸ resolving dependencies… done
            ▸ compiling 214 files… done in 3.2s
            ▸ all checks passed
            ##[endgroup]
            """
    }

    private static func names(_ index: Int) -> String? {
        stepNames.indices.contains(index) ? stepNames[index] : nil
    }
}
extension DemoTimeline.Job {
    /// `fails` is optional in a script (absent means the job succeeds).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repo = try container.decode(String.self, forKey: .repo)
        account = try container.decode(String.self, forKey: .account)
        runtime = try container.decode(RuntimeID.self, forKey: .runtime)
        workflow = try container.decode(String.self, forKey: .workflow)
        arrive = try container.decode(Double.self, forKey: .arrive)
        start = try container.decode(Double.self, forKey: .start)
        run = try container.decode(Double.self, forKey: .run)
        fails = try container.decodeIfPresent(Bool.self, forKey: .fails) ?? false
    }
}
#endif
