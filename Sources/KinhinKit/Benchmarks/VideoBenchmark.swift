import Foundation

/// The video suite: builds a small generated video with `kinhin video build`'s pipeline in a container runtime and
/// times the image pull, a clean build, a cached rebuild and (thorough) a full-quality build. It runs on the host's
/// container runtime through `VideoRunner`, not in a fleet VM, over a throwaway repository in the run's scratch
/// directory, so the user's own videos are never touched.
enum VideoBenchmark {
    static let suiteName = "video"
    static let projectName = "bench"

    /// The generated video: three drawn scenes with a voice-over, like the `hello` example, so it needs no recordings.
    static let projectConfig = """
        {
          "name": "Benchmark",
          "theme": "paper",
          "format": "16:9",
          "voice": { "engine": "kokoro", "name": "af_heart" },
          "scenes": [
            { "id": "hello", "type": "title",
              "props": { "title": "Benchmark", "subtitle": "timing the video pipeline" },
              "narration": "This is a short video that times the pipeline." },
            { "id": "idea", "type": "statement",
              "props": { "text": "Write the words. Pick a look.", "sub": "The pictures follow the voice." },
              "narration": "Write the words, pick a look, and the pictures follow the voice." },
            { "id": "bye", "type": "outro",
              "props": { "line": "Make yours.", "url": "example.com", "facts": ["Open source", "Runs locally"] },
              "narration": "Make yours." }
          ]
        }

        """

    /// The video runtime a benchmark runtime id stands for (nil for tart and host, which cannot build videos).
    static func videoRuntime(for id: RuntimeID) -> VideoRuntime? {
        switch id {
        case .appleContainer: return .appleContainer
        case .docker: return .docker
        case .tart, .host: return nil
        }
    }

    static func run(_ ctx: BenchmarkContext, runtime id: RuntimeID) async throws -> BenchmarkSuiteResult {
        guard let preferred = videoRuntime(for: id) else {
            return .skipped(suiteName, runtime: id, reason: "videos build in a container runtime (container or docker)")
        }
        let log = Locked<[String]>([])
        let runner = ctx.env.videoRunner { line in
            log.withLock { lines in
                lines.append(line)
                if lines.count > 12 { lines.removeFirst(lines.count - 12) }
            }
        }
        let repo = ctx.scratch.root.appendingPathComponent("video-repo", isDirectory: true)
        let plan: VideoRunPlan
        do {
            try prepareRepo(repo)
            var build = VideoBuildOptions(project: projectName)
            build.music = "off"
            build.fast = true
            plan = try await runner.plan(options: build, repo: repo, runtime: preferred, image: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as VideoError {
            // No runtime, or the service is not running: nothing was measured, which is a skip, not a failure.
            return .skipped(suiteName, runtime: id, reason: error.errorDescription ?? "\(error)")
        }
        return try await ctx.suite(suiteName, runtime: id, platform: "linux", notes: ["image \(plan.image)"]) { steps in
            if let pull = try await pullStep(ctx, runner: runner, plan: plan) { steps.append(pull) }
            steps.append(try await buildStep(ctx, runner: runner, log: log, plan: plan, name: "clean-build"))
            steps.append(try await buildStep(ctx, runner: runner, log: log, plan: plan, name: "cached-build"))
            if ctx.options.intensity == .thorough {
                // A full build is only a full build with nothing cached to lean on.
                // Best effort: a cache that cannot be removed only makes the "full" build faster than it should be.
                try? FileManager.default.removeItem(at: plan.cacheDirectory)
                var full = VideoBuildOptions(project: projectName)
                full.music = "off"
                let fullPlan = VideoRunPlan.make(
                    options: full, runtime: preferred, binary: plan.inspect[0], image: plan.image, repo: repo)
                steps.append(try await buildStep(ctx, runner: runner, log: log, plan: fullPlan, name: "full-build"))
            }
        }
    }

    /// Writes `<repo>/.kinhin/videos/bench.json`.
    private static func prepareRepo(_ repo: URL) throws {
        let directory = VideoProjects.directory(in: repo)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(projectConfig.utf8).write(to: directory.appendingPathComponent("\(projectName).json"))
    }

    /// The image pull, timed on its own so a first run's download does not pollute the build numbers. Nil when the
    /// image is already on this Mac.
    private static func pullStep(
        _ ctx: BenchmarkContext, runner: VideoRunner, plan: VideoRunPlan
    ) async throws -> BenchmarkStep? {
        // A probe that cannot run reads as "not present": the pull below then reports the real problem.
        if let present = try? await ctx.env.shell.run(plan.inspect, cwd: nil, timeout: 30), present.succeeded {
            return nil
        }
        ctx.sink.set(step: "image-pull")
        let timed = try await BenchmarkContext.measure {
            try await runner.ensureImage(image: plan.image, inspect: plan.inspect, pull: plan.pull)
        }
        return BenchmarkStep(name: "image-pull", durationMs: timed.ms)
    }

    private static func buildStep(
        _ ctx: BenchmarkContext, runner: VideoRunner, log: Locked<[String]>, plan: VideoRunPlan, name: String
    ) async throws -> BenchmarkStep {
        ctx.sink.set(step: name)
        let timed = try await BenchmarkContext.measure { try await runner.build(plan: plan) }
        guard timed.value == 0 else {
            let tail = log.withLock { $0.suffix(6).joined(separator: "\n") }
            let detail = "the video build exited \(timed.value)"
            throw BenchmarkError.stepFailed(step: name, detail: tail.isEmpty ? detail : "\(detail):\n\(tail)")
        }
        let size = outputBytes(plan.outputDirectory)
        let note = size.map { "\($0 / 1024) KB written" }
        return BenchmarkStep(name: name, durationMs: timed.ms, note: note)
    }

    /// The total size of what the build wrote, including subfolders, nil when it wrote nothing.
    private static func outputBytes(_ directory: URL) -> Int? {
        let keys: [URLResourceKey] = [.fileSizeKey]
        // The size is only a note on the step: an unreadable folder leaves the note out.
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else {
            return nil
        }
        let files = walker.compactMap { $0 as? URL }
        // An unreadable file counts as zero bytes: the size is only a note.
        let sizes = files.map { (try? $0.resourceValues(forKeys: Set(keys)).fileSize) ?? 0 }
        let total = sizes.reduce(0, +)
        return total > 0 ? total : nil
    }
}
