import Foundation
import KinhinKit

/// `kinhin video init | list | validate | build`: make a narrated video of your own product from `.kinhin/videos/*.yml`, in a
/// container, with no copy of the video suite (it ships in a published image). The logic is in KinhinKit (`Video/`).
enum VideoCommand {
    /// Flags that take a value, so a value is never mistaken for the video's name.
    private static let valueFlags: Set<String> = [
        "--dir", "--theme", "--format", "--captions", "--caption-style", "--music", "--runtime", "--image", "--ref",
        "--runs-on", "--from", "--ci", "--quality", "--fps",
    ]

    /// `--ci SYSTEM`, or the system the repository uses when it is absent or `auto`.
    static func ciSystem(_ args: [String], repo: URL) throws -> CISystem {
        guard let name = flag("--ci", in: args), name != "auto" else { return CISystem.detect(repositoryRoot: repo) }
        guard let ci = CISystem(rawValue: name) else {
            throw CLIError("--ci takes auto, \(CISystem.names)", exit: .usage)
        }
        return ci
    }

    /// The first operand that is neither a flag nor a flag's value.
    static func operand(in args: [String]) -> String? {
        var skipNext = false
        for arg in args {
            if skipNext {
                skipNext = false
            } else if valueFlags.contains(arg) {
                skipNext = true
            } else if !arg.hasPrefix("-") {
                return arg
            }
        }
        return nil
    }

    static func repository(_ args: [String]) -> URL {
        URL(fileURLWithPath: flag("--dir", in: args) ?? FileManager.default.currentDirectoryPath).standardizedFileURL
    }

    /// Turns a library error into the CLI's exit codes.
    private static func translate(_ error: Error) -> Error {
        guard let error = error as? VideoError else { return error }
        switch error {
        case .noRuntime, .runtimeUnavailable, .imageUnavailable, .launchFailed:
            return CLIError(error.localizedDescription, exit: .runtime)
        case .invalidName, .alreadyExists, .noVideosFolder, .unknownProject, .unknownTheme, .unmountablePath:
            return CLIError(error.localizedDescription, exit: .usage)
        }
    }

    static func run(path: [String], _ rest: [String]) async throws {
        do {
            switch path.dropFirst().first {
            case "music": try await VideoMusicCommand.run(subcommand: path.dropFirst(2).first, rest)
            case "theme": try VideoThemeCommand.run(subcommand: path.dropFirst(2).first, rest)
            case "init": try initialize(rest)
            case "list": try list(rest)
            case "validate": try await validate(rest)
            case "record": try await VideoRecordCommand.run(rest)
            default: try await build(rest)
            }
        } catch {
            throw translate(error)
        }
    }

    // MARK: init

    static func initialize(_ rest: [String]) throws {
        let repo = repository(rest)
        let name = operand(in: rest)
        let wantsWorkflow = hasFlag("--workflow", in: rest)
        // `init --workflow` with no name adds only the workflow; otherwise a starter video is written.
        if name != nil || !wantsWorkflow {
            let written = try VideoStarter.write(name: name ?? "launch", in: repo)
            for file in written { print("wrote \(relative(file, to: repo))") }
            print("Next: edit it, then run `kinhin video build \(name ?? "launch")`.")
        }
        if wantsWorkflow {
            let written = try VideoFleet.writePipeline(
                in: repo, ci: try ciSystem(rest, repo: repo), runsOn: flag("--runs-on", in: rest),
                image: VideoImage.reference(override: flag("--image", in: rest)))
            for file in [written.file] + written.extraFiles { print("wrote \(relative(file, to: repo))") }
            written.notes.forEach { print($0) }
        }
    }

    // MARK: list

    struct ListDocument: Codable, Equatable {
        var directory: String
        var videos: [String]
    }

    static func list(_ rest: [String]) throws {
        let repo = repository(rest)
        let videos = VideoProjects.list(in: repo)
        if hasFlag("--json", in: rest) {
            try emitJSON(ListDocument(directory: VideoProjects.directory(in: repo).path, videos: videos))
        } else if videos.isEmpty {
            print("no videos in \(VideoProjects.folder)/. Create one with `kinhin video init`.")
        } else {
            for name in videos { print(name) }
        }
    }

    // MARK: build

    static func options(from rest: [String], repo: URL) throws -> VideoBuildOptions {
        var name = operand(in: rest)
        if name == nil {
            let all = VideoProjects.list(in: repo)
            guard all.count == 1 else {
                throw CLIError(
                    all.isEmpty
                        ? "no videos in \(VideoProjects.folder)/. Create one with `kinhin video init`."
                        : "which video? One of: \(all.joined(separator: ", ")). Run `kinhin video build <name>`.",
                    exit: .usage)
            }
            name = all[0]
        }
        var options = VideoBuildOptions(project: name ?? "")
        options.theme = flag("--theme", in: rest)
        options.format = flag("--format", in: rest)
        options.captions = flag("--captions", in: rest)
        if let captions = options.captions, !["on", "off", "all"].contains(captions) {
            throw CLIError("--captions takes on, off or all", exit: .usage)
        }
        options.captionStyle = flag("--caption-style", in: rest)
        options.music = flag("--music", in: rest)
        options.fast = hasFlag("--fast", in: rest)
        options.quality = flag("--quality", in: rest)
        if let quality = options.quality, !VideoBuildOptions.qualities.contains(quality) {
            throw CLIError("--quality takes draft, standard or high", exit: .usage)
        }
        options.fps = flag("--fps", in: rest)
        if let fps = options.fps, !VideoBuildOptions.frameRates.contains(fps) {
            throw CLIError("--fps takes 24, 30 or 60", exit: .usage)
        }
        return options
    }

    /// `--runtime container|docker`, or nil when it is absent (the first usable runtime is used).
    static func runtimeFlag(_ rest: [String]) throws -> VideoRuntime? {
        guard let named = flag("--runtime", in: rest) else { return nil }
        guard let parsed = VideoRuntime(rawValue: named) else {
            throw CLIError("--runtime takes container or docker", exit: .usage)
        }
        return parsed
    }

    // MARK: validate

    /// Checks a video (or every video with `--all`) without rendering it: the build's own checks, in the same image.
    static func validate(_ rest: [String]) async throws {
        let repo = repository(rest)
        let project: String? = hasFlag("--all", in: rest) ? nil : try options(from: rest, repo: repo).project
        let code = try await VideoRunner().validate(
            repo: repo, project: project, runtime: try runtimeFlag(rest), image: flag("--image", in: rest))
        switch code {
        case 0:
            print(project.map { "Ready to build: `kinhin video build \($0)`." } ?? "Every video is ready to build.")
        case 1:
            throw CLIError("a video has problems (listed above). Nothing was rendered.", exit: .config)
        case 127:
            // The image has no entry point for the check: the runtime could not start it (it was built before the check).
            throw CLIError(
                "this video image predates 'kinhin video validate': use a newer --image, or update kinhin",
                exit: .runtime)
        default:
            throw CLIError("the check could not run (exit \(code)); the output above says why", exit: .general)
        }
    }

    static func build(_ rest: [String]) async throws {
        let repo = repository(rest)
        let options = try options(from: rest, repo: repo)
        let runtime = try runtimeFlag(rest)
        if hasFlag("--on-fleet", in: rest) {
            guard VideoProjects.file(named: options.project, in: repo) != nil else {
                throw VideoError.unknownProject(name: options.project, available: VideoProjects.list(in: repo))
            }
            // A kinhin-video GitHub workflow in the checkout settles it, whatever else the repository runs.
            let hasGitHubWorkflow = FileManager.default.fileExists(
                atPath: repo.appendingPathComponent(VideoFleet.workflowPath).path)
            let ci = flag("--ci", in: rest) == nil && hasGitHubWorkflow ? .github : try ciSystem(rest, repo: repo)
            guard ci == .github else { throw VideoError.runtimeUnavailable(VideoFleet.manualRunHint(for: ci)) }
            let output = try await VideoFleetRunner().build(options: options, repo: repo, ref: flag("--ref", in: rest))
            print("Done. The video is in \(relative(latestVideoFolder(in: output), to: repo))/")
            return
        }
        let runner = VideoRunner()
        let plan = try await runner.plan(
            options: options, repo: repo, runtime: runtime, image: flag("--image", in: rest))
        printError("==> \(options.project): \(plan.runtime.rawValue), image \(plan.image)")
        let code = try await runner.build(plan: plan)
        guard code == 0 else {
            throw CLIError("the video build failed (exit \(code)); the log above says why", exit: .general)
        }
        print("Done. The video is in \(relative(latestVideoFolder(in: plan.outputDirectory), to: repo))/")
    }

    /// Each video has its own folder under `out/` (`out/<name>/`); the one just built is the most recently changed.
    /// Falls back to `out` itself when there is none.
    static func latestVideoFolder(in output: URL) -> URL {
        let entries =
            // No readable out/ folder falls back to out/ itself (documented above).
            (try? FileManager.default.contentsOfDirectory(
                at: output, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
        // Only a cosmetic path in the closing message depends on these reads.
        let folders = entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        func changed(_ url: URL) -> Date {
            // An unreadable date sorts first; it only picks which folder the message names.
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return folders.max { changed($0) < changed($1) } ?? output
    }

    static func relative(_ url: URL, to repo: URL) -> String {
        let base = repo.path.hasSuffix("/") ? repo.path : repo.path + "/"
        return url.path.hasPrefix(base) ? String(url.path.dropFirst(base.count)) : url.path
    }
}
