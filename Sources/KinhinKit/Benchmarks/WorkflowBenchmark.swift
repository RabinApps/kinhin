import Foundation

/// The Casual and Large suites: representative workloads timed inside one
/// shared bench instance. Timing is host-side around each exec, so every
/// step includes one exec round trip; the Casual suite measures that
/// overhead on its own so readers can discount it.
enum WorkflowBenchmark {
    // MARK: - Casual

    static func casual(_ ctx: BenchmarkContext, on instance: BenchmarkInstance) async throws -> BenchmarkSuiteResult {
        try await ctx.suite("casual", runtime: instance.runtimeID, platform: instance.platformLabel) { steps in
            steps.append(try await execOverhead(ctx, instance))

            let tree = BenchmarkScripts.createTree(megabytes: ctx.profile.treeMB)
            steps.append(try await ctx.step(instance, "file-create", script: tree.script, bytes: tree.bytes))
            steps.append(try await ctx.step(instance, "tar-gzip", script: BenchmarkScripts.tarGzip, bytes: tree.bytes))
            steps.append(try await ctx.step(instance, "untar", script: BenchmarkScripts.untar, bytes: tree.bytes))
            steps.append(try await ctx.step(instance, "checksum", script: BenchmarkScripts.hashTree, bytes: tree.bytes))
            steps.append(
                try await ctx.step(
                    instance, "git-commit", setup: BenchmarkScripts.gitSetup(files: ctx.profile.gitFiles),
                    script: BenchmarkScripts.gitCommit,
                    timeout: 600))

            let swift = try await ctx.run(instance, BenchmarkScripts.hasSwift)
            if swift.succeeded {
                steps.append(
                    try await ctx.step(
                        instance, "swift-build",
                        setup: BenchmarkScripts.swiftPackageSetup(files: ctx.profile.swiftFiles),
                        script: BenchmarkScripts.swiftBuild, timeout: 1800))
            } else {
                steps.append(
                    BenchmarkStep(
                        name: "swift-build", durationMs: 0, note: "no Swift toolchain in the image", skipped: true))
            }
            await cleanup(ctx, instance, "rm -rf tree base.bin tree.tgz untar repo swiftpkg")
        }
    }

    /// The median round trip of an empty command: what every other step pays once.
    private static func execOverhead(_ ctx: BenchmarkContext, _ instance: BenchmarkInstance) async throws
        -> BenchmarkStep
    {
        ctx.sink.set(step: "exec-overhead")
        var samples: [Double] = []
        for _ in 0..<ctx.profile.overheadLoops {
            try Task.checkCancellation()
            let timed = try await BenchmarkContext.measure { try await instance.exec("true", timeout: 120) }
            guard timed.value.succeeded else {
                throw BenchmarkError.stepFailed(step: "exec-overhead", detail: BenchmarkContext.detail(of: timed.value))
            }
            samples.append(timed.ms)
        }
        return .summarizing("exec-overhead", milliseconds: samples, note: "one empty command per sample")
    }

    // MARK: - Large

    static func large(_ ctx: BenchmarkContext, on instance: BenchmarkInstance) async throws -> BenchmarkSuiteResult {
        let blob = ctx.profile.blobMB
        let blobBytes = blob * 1_048_576
        return try await ctx.suite("large", runtime: instance.runtimeID, platform: instance.platformLabel) { steps in
            steps.append(
                try await ctx.step(
                    instance, "disk-write", script: BenchmarkScripts.diskWrite(megabytes: blob), bytes: blobBytes,
                    timeout: 1800))
            steps.append(
                try await ctx.step(
                    instance, "disk-read", script: BenchmarkScripts.diskRead, bytes: blobBytes, timeout: 1800))
            steps.append(
                try await ctx.step(
                    instance, "disk-checksum", script: BenchmarkScripts.hashBlob, bytes: blobBytes, timeout: 1800))
            await cleanup(ctx, instance, "rm -f blob.bin")

            steps.append(
                try await ctx.step(
                    instance, "cpu-gzip", setup: BenchmarkScripts.cpuSetup(megabytes: ctx.profile.cpuMB),
                    script: BenchmarkScripts.cpuGzip(megabytes: ctx.profile.cpuMB), timeout: 900))
            await cleanup(ctx, instance, "rm -f rand.bin")

            if let url = ctx.options.networkURL {
                steps.append(
                    try await ctx.step(
                        instance, "git-clone", script: BenchmarkScripts.gitClone(url: url), timeout: 900))
                await cleanup(ctx, instance, "rm -rf clone")
            }
        }
    }

    /// Frees guest disk between suites. A failure only costs space, so it is logged.
    static func cleanup(_ ctx: BenchmarkContext, _ instance: BenchmarkInstance, _ command: String) async {
        await bestEffortAsync(instance.name, "removing benchmark files") {
            _ = try await ctx.run(instance, command, timeout: 300)
        }
    }
}
