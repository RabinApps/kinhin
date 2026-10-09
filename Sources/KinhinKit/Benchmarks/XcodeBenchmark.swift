import Foundation

/// The Xcode suite: `xcodebuild` clean and incremental builds of a generated
/// multi-file Swift package, or of a real checkout copied into the guest.
enum XcodeBenchmark {
    static func run(_ ctx: BenchmarkContext, on instance: BenchmarkInstance) async throws -> BenchmarkSuiteResult {
        guard instance.platform == .macOS else {
            return BenchmarkSuiteResult(
                name: "xcode", runtime: instance.runtimeID.rawValue, platform: instance.platformLabel,
                status: .skipped, skipReason: "Xcode needs a macOS guest")
        }
        let probe = try await ctx.run(instance, BenchmarkScripts.xcodeProbe, timeout: 120)
        guard probe.succeeded else {
            return BenchmarkSuiteResult(
                name: "xcode", runtime: instance.runtimeID.rawValue, platform: instance.platformLabel,
                status: .skipped, skipReason: "xcodebuild is not in the guest — bake Xcode into the image")
        }
        let version = probe.stdout.split(whereSeparator: \.isNewline).first.map(String.init)
        return try await ctx.suite(
            "xcode", runtime: instance.runtimeID, platform: instance.platformLabel,
            notes: [version].compactMap { $0 }
        ) { steps in
            if let project = ctx.options.projectPath {
                try await buildProject(ctx, instance, path: project, steps: &steps)
            } else {
                try await buildGenerated(ctx, instance, steps: &steps)
            }
        }
    }

    private static func buildGenerated(
        _ ctx: BenchmarkContext, _ instance: BenchmarkInstance, steps: inout [BenchmarkStep]
    ) async throws {
        steps.append(
            try await ctx.step(
                instance, "clean-build", setup: BenchmarkScripts.xcodePackageSetup(files: ctx.profile.xcodeFiles),
                script: BenchmarkScripts.xcodePackageBuild(incremental: false), timeout: 3600))
        steps.append(
            try await ctx.step(
                instance, "incremental-build", script: BenchmarkScripts.xcodePackageBuild(incremental: true),
                timeout: 3600))
        await WorkflowBenchmark.cleanup(ctx, instance, "rm -rf xcodepkg dd")
    }

    private static func buildProject(
        _ ctx: BenchmarkContext, _ instance: BenchmarkInstance, path: String, steps: inout [BenchmarkStep]
    ) async throws {
        let directory = try BenchmarkOptions.validatedProjectDirectory(path)
        let archive = try await archiveProject(ctx, directory)
        let base64 = archive.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        let copied = try await ctx.step(
            instance, "project-copy", script: BenchmarkScripts.projectUpload(base64Archive: base64),
            bytes: archive.count, timeout: 1800)
        steps.append(copied)
        let clean = try await ctx.step(
            instance, "clean-build", script: BenchmarkScripts.projectBuild(incremental: false), timeout: 7200)
        steps.append(clean)
        if clean.skipped == true { return }
        steps.append(
            try await ctx.step(
                instance, "incremental-build", script: BenchmarkScripts.projectBuild(incremental: true),
                timeout: 7200))
        await WorkflowBenchmark.cleanup(ctx, instance, "rm -rf project dd")
    }

    /// `tar -C <dir> -cf - .` of the checkout (relative members only, no VCS or build output), capped in size.
    private static func archiveProject(_ ctx: BenchmarkContext, _ directory: URL) async throws -> Data {
        try ctx.scratch.create()
        let archive = ctx.scratch.root.appendingPathComponent("project.tar")
        let result = try await ctx.env.shell.run(
            [
                "/usr/bin/tar", "--exclude", ".git", "--exclude", ".build", "--exclude", "DerivedData",
                "--exclude", "node_modules", "-C", directory.path, "-cf", archive.path, ".",
            ], cwd: nil, timeout: 600)
        guard result.succeeded else {
            throw BenchmarkError.stepFailed(step: "project-copy", detail: result.failureExcerpt)
        }
        let size = (try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int) ?? 0
        guard size <= BenchmarkLimits.maxProjectArchiveMB * 1_048_576 else {
            throw BenchmarkError.invalidOption(
                "--project is \(size / 1_048_576) MB after excluding .git, .build and node_modules; the cap is \(BenchmarkLimits.maxProjectArchiveMB) MB"
            )
        }
        return try Data(contentsOf: archive)
    }
}
