#if DEBUG
    import Foundation
    import KinhinKit
    import Synchronization

    /// A `FleetServing` that replays a `DemoTimeline` instead of running anything:
    /// no engine, daemon, forge, VM or Keychain. Debug builds only, switched on
    /// with `KINHIN_DEMO=<built-in name or .json path>` (see `AppDelegate.bootstrapEngine`).
    final class DemoFleetServing: FleetServing {
        private struct State {
            var running = true
            var paused = false
            var origin: Date
        }

        private let timeline: DemoTimeline
        private let clock: @Sendable () -> Date
        private let state: Mutex<State>

        init(timeline: DemoTimeline = .launch, clock: @escaping @Sendable () -> Date = { Date() }) {
            self.timeline = timeline
            self.clock = clock
            state = Mutex(State(origin: clock()))
        }

        var logName: String { "demo" }

        /// The demo named by `KINHIN_DEMO`: a built-in script name (`launch`) or a path to a `.json` script.
        /// Nil when the variable is unset or the script is unusable (the reason is logged).
        static func fromEnvironment(
            _ environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> DemoFleetServing? {
            guard let name = environment["KINHIN_DEMO"], !name.isEmpty else { return nil }
            do {
                return DemoFleetServing(timeline: try DemoTimeline.load(name))
            } catch {
                Log.error("app", "KINHIN_DEMO=\(name): \(error)")
                return nil
            }
        }

        private func snapshot() -> (elapsed: Double, now: Date, running: Bool, paused: Bool) {
            let now = clock()
            return state.withLock { ($0.origin.distance(to: now), now, $0.running, $0.paused) }
        }

        func status() async throws -> FleetStatus {
            let s = snapshot()
            return timeline.status(elapsed: s.elapsed, now: s.now, running: s.running, paused: s.paused)
        }

        func start() async throws {
            state.withLock {
                $0.running = true
                $0.origin = clock()
            }
        }

        func stop() async throws { state.withLock { $0.running = false } }

        func setPaused(_ paused: Bool) async throws { state.withLock { $0.paused = paused } }

        func deleteVM(id: String) async throws {}

        func pipelineDetail(vmID: String) async throws -> PipelineDetail? {
            let s = snapshot()
            return timeline.pipeline(vmID: vmID, elapsed: s.elapsed, now: s.now)
        }

        func pipelineLog(vmID: String, jobID: String, stepIndex: Int?) async throws -> PipelineLog? {
            PipelineLog(
                text: DemoTimeline.log(forStep: stepIndex), scope: stepIndex == nil ? .job : .step, fetchedAt: clock())
        }

        func rotate(_ target: CredentialRotation.Target, token: String) async throws {}
        func requeueQueuedJobs(for forge: ForgeID) async throws {}
        func skipQueuedJobs(for forge: ForgeID) async throws {}
    }
#endif
