import Foundation
import KinhinKit

/// `kinhin video init | list | build`: make a narrated video of your own product from `.kinhin/videos/*.yml`, in a
/// container, with no copy of the video suite (it ships in a published image). The logic is in KinhinKit (`Video/`).
enum VideoCommand {
    /// Flags that take a value, so a value is never mistaken for the video's name.
    private static let valueFlags: Set<String> = [
        "--dir", "--theme", "--format", "--captions", "--caption-style", "--music", "--runtime", "--image", "--ref",
        "--runs-on",
    ]

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
        case .invalidName, .alreadyExists, .noVideosFolder, .unknownProject:
            return CLIError(error.localizedDescription, exit: .usage)
        }
    }

    static func run(path: [String], _ rest: [String]) async throws {
        do {
            switch path.dropFirst().first {
            case "music": try await VideoMusicCommand.run(subcommand: path.dropFirst(2).first, rest)
            case "init": try initialize(rest)
            case "list": try list(rest)
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
            let file = try VideoFleet.writeWorkflow(
                in: repo, runsOn: flag("--runs-on", in: rest) ?? "self-hosted,linux",
                image: VideoImage.reference(override: flag("--image", in: rest)))
            print("wrote \(relative(file, to: repo))")
            print("Commit and push it, then run `kinhin video build <name> --on-fleet`.")
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
        return options
    }

    static func build(_ rest: [String]) async throws {
        let repo = repository(rest)
        let options = try options(from: rest, repo: repo)
        var runtime: VideoRuntime?
        if let named = flag("--runtime", in: rest) {
            guard let parsed = VideoRuntime(rawValue: named) else {
                throw CLIError("--runtime takes container or docker", exit: .usage)
            }
            runtime = parsed
        }
        if hasFlag("--on-fleet", in: rest) {
            guard VideoProjects.file(named: options.project, in: repo) != nil else {
                throw VideoError.unknownProject(name: options.project, available: VideoProjects.list(in: repo))
            }
            let output = try await VideoFleetRunner().build(options: options, repo: repo, ref: flag("--ref", in: rest))
            print("Done. The video is in \(relative(output, to: repo))/")
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
        print("Done. The video is in \(relative(plan.outputDirectory, to: repo))/")
    }

    static func relative(_ url: URL, to repo: URL) -> String {
        let base = repo.path.hasSuffix("/") ? repo.path : repo.path + "/"
        return url.path.hasPrefix(base) ? String(url.path.dropFirst(base.count)) : url.path
    }
}
