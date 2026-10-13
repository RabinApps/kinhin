import Foundation

/// Building a video on a runner kinhin serves, instead of on this Mac: a workflow in the repository runs the same published
/// image, and `kinhin video build --on-fleet` drives it with the user's own `gh` (their sign-in; kinhin handles no extra token).
public enum VideoFleet {
    public static let workflowFile = "kinhin-video.yml"
    public static let workflowPath = ".github/workflows/\(workflowFile)"
    public static let artifactName = "kinhin-video"

    /// Whether `labels` is a comma-separated list of runner labels (`self-hosted,linux`).
    static func parseLabels(_ labels: String) -> [String]? {
        let parts = labels.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard !parts.isEmpty else { return nil }
        let valid = parts.allSatisfy { label in
            guard let first = label.unicodeScalars.first, CharacterSet.alphanumerics.contains(first) else {
                return false
            }
            return label.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || "_.-".unicodeScalars.contains($0)
            }
        }
        return valid ? parts : nil
    }

    /// The workflow `kinhin video init --workflow` writes. Inputs reach the shell through environment variables (never
    /// inlined into the script), the actions are pinned, and the job can only read the repository.
    public static func workflowTemplate(runsOn labels: [String], image: String) -> String {
        """
        # Builds a video from .kinhin/videos/ on a runner, with kinhin's published video image (no copy of the suite needed).
        # Run it with: kinhin video build <name> --on-fleet   (or Actions > kinhin video > Run workflow).
        # The runner needs Docker and a network that can pull \(image).
        name: kinhin video

        on:
          workflow_dispatch:
            inputs:
              project:
                description: "Video in .kinhin/videos/ (for example launch)"
                required: true
                type: string
              theme:
                description: "Theme (empty: the video's own)"
                required: false
                type: string
              format:
                description: "16:9, 9:16, 4:5 or 1:1 (empty: the video's own)"
                required: false
                type: string
              captions:
                description: "on, off or all (empty: the video's own)"
                required: false
                type: string
              caption_style:
                description: "outline, box, shadow, bold or minimal (empty: the video's own)"
                required: false
                type: string
              music:
                description: "A catalog track, a file in the repository, or off (empty: the video's own)"
                required: false
                type: string
              fast:
                description: "A preview: quicker encode, no WebM"
                required: false
                type: boolean
                default: false

        permissions:
          contents: read

        jobs:
          build:
            runs-on: [\(labels.joined(separator: ", "))]
            timeout-minutes: 60
            steps:
              - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
                with:
                  persist-credentials: false

              - name: Build the video
                env:
                  IMAGE: \(image)
                  PROJECT: ${{ inputs.project }}
                  THEME: ${{ inputs.theme }}
                  FORMAT: ${{ inputs.format }}
                  CAPTIONS: ${{ inputs.captions }}
                  CAPTION_STYLE: ${{ inputs.caption_style }}
                  MUSIC: ${{ inputs.music }}
                  FAST: ${{ inputs.fast }}
                run: |
                  set -euo pipefail
                  mkdir -p .kinhin/videos/out .kinhin/videos/.cache
                  args=(--project "$PROJECT")
                  [ -z "$THEME" ] || args+=(--theme "$THEME")
                  [ -z "$FORMAT" ] || args+=(--format "$FORMAT")
                  [ -z "$CAPTIONS" ] || args+=(--captions "$CAPTIONS")
                  [ -z "$CAPTION_STYLE" ] || args+=(--caption-style "$CAPTION_STYLE")
                  [ -z "$MUSIC" ] || args+=(--music "$MUSIC")
                  [ "$FAST" != "true" ] || args+=(--fast)
                  docker run --rm \\
                    -v "$PWD":/project:ro \\
                    -v "$PWD/.kinhin/videos/out":/work/out \\
                    -v "$PWD/.kinhin/videos/.cache":/work/raw \\
                    "$IMAGE" /work/scripts/container-build.sh "${args[@]}"

              - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
                with:
                  name: \(artifactName)
                  path: .kinhin/videos/out
                  if-no-files-found: error

        """
    }

    /// Writes `.github/workflows/kinhin-video.yml`. Never overwrites.
    @discardableResult
    public static func writeWorkflow(in repo: URL, runsOn: String, image: String) throws -> URL {
        guard let labels = parseLabels(runsOn) else {
            throw VideoError.invalidName("--runs-on \(runsOn)")
        }
        let target = repo.appendingPathComponent(workflowPath)
        if FileManager.default.fileExists(atPath: target.path) { throw VideoError.alreadyExists(target.path) }
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(workflowTemplate(runsOn: labels, image: image).utf8).write(to: target, options: .withoutOverwriting)
        return target
    }

    // MARK: driving it with gh

    /// `gh workflow run`: the inputs mirror `VideoBuildOptions`.
    public static func dispatchArguments(gh: String, options: VideoBuildOptions, ref: String) -> [String] {
        var argv = [gh, "workflow", "run", workflowFile, "--ref", ref, "-f", "project=\(options.project)"]
        func add(_ key: String, _ value: String?) {
            if let value, !value.isEmpty { argv += ["-f", "\(key)=\(value)"] }
        }
        add("theme", options.theme)
        add("format", options.format)
        add("captions", options.captions)
        add("caption_style", options.captionStyle)
        add("music", options.music)
        if options.fast { argv += ["-f", "fast=true"] }
        return argv
    }

    public static func listArguments(gh: String, ref: String) -> [String] {
        [
            gh, "run", "list", "--workflow", workflowFile, "--branch", ref, "--event", "workflow_dispatch",
            "--limit", "5", "--json", "databaseId,createdAt",
        ]
    }

    /// The newest run created at or after `notBefore` (a little slack for clock skew), from `gh run list --json`.
    public static func runID(fromListing json: String, notBefore: Date) -> Int? {
        struct Row: Decodable {
            var databaseId: Int
            var createdAt: String
        }
        guard let rows = try? JSONDecoder().decode([Row].self, from: Data(json.utf8)) else { return nil }
        let formatter = ISO8601DateFormatter()
        return
            rows
            .compactMap { row in formatter.date(from: row.createdAt).map { (row.databaseId, $0) } }
            .filter { $0.1 >= notBefore.addingTimeInterval(-10) }
            .max { $0.1 < $1.1 }?.0
    }
}

/// `kinhin video build --on-fleet`: dispatch the workflow, follow the run, download the video.
public struct VideoFleetRunner: Sendable {
    let shell: ShellRunning
    let process: VideoProcessRunning
    let ghPath: @Sendable () -> String?
    let now: @Sendable () -> Date
    let pause: @Sendable (TimeInterval) async -> Void

    public init(
        shell: ShellRunning = Shell(), process: VideoProcessRunning = InheritedProcessRunner(),
        ghPath: @escaping @Sendable () -> String? = { Paths.findExecutable(named: "gh") },
        now: @escaping @Sendable () -> Date = { Date() },
        pause: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    ) {
        self.shell = shell
        self.process = process
        self.ghPath = ghPath
        self.now = now
        self.pause = pause
    }

    /// The branch the repository is on.
    func currentBranch(in repo: URL) async throws -> String {
        let result = try await shell.run(["/usr/bin/git", "rev-parse", "--abbrev-ref", "HEAD"], cwd: repo, timeout: 15)
        let branch = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, !branch.isEmpty, branch != "HEAD" else {
            throw VideoError.runtimeUnavailable("could not tell which branch to build on; pass --ref BRANCH")
        }
        return branch
    }

    /// Builds on the fleet and downloads the result into `<repo>/.kinhin/videos/out`; returns that folder.
    public func build(options: VideoBuildOptions, repo: URL, ref: String?) async throws -> URL {
        guard let gh = ghPath() else {
            throw VideoError.runtimeUnavailable(
                "--on-fleet uses the GitHub CLI: install it (brew install gh) and run `gh auth login`")
        }
        let branch: String
        if let ref, !ref.isEmpty { branch = ref } else { branch = try await currentBranch(in: repo) }
        let viewed = try await shell.run(
            [gh, "workflow", "view", VideoFleet.workflowFile, "--ref", branch], cwd: repo, timeout: 30)
        guard viewed.succeeded else {
            throw VideoError.runtimeUnavailable(
                "\(VideoFleet.workflowPath) is not on \(branch) yet. Create it with `kinhin video init --workflow`, "
                    + "then commit and push it")
        }
        let started = now()
        let dispatched = try await process.runInteractive(
            VideoFleet.dispatchArguments(gh: gh, options: options, ref: branch))
        guard dispatched == 0 else {
            throw VideoError.runtimeUnavailable("gh could not start the workflow (exit \(dispatched))")
        }
        var runID: Int?
        for _ in 0..<20 where runID == nil {
            await pause(3)
            let listing = try await shell.run(VideoFleet.listArguments(gh: gh, ref: branch), cwd: repo, timeout: 30)
            runID = VideoFleet.runID(fromListing: listing.stdout, notBefore: started)
        }
        guard let runID else {
            throw VideoError.runtimeUnavailable("the run did not appear; check the Actions tab of the repository")
        }
        let watched = try await process.runInteractive([gh, "run", "watch", String(runID), "--exit-status"])
        guard watched == 0 else {
            throw VideoError.runtimeUnavailable(
                "the build failed on the fleet; see `gh run view \(runID) --log-failed`")
        }
        let output = VideoProjects.directory(in: repo).appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let downloaded = try await process.runInteractive(
            [gh, "run", "download", String(runID), "-n", VideoFleet.artifactName, "-D", output.path])
        guard downloaded == 0 else {
            throw VideoError.runtimeUnavailable(
                "the build finished but the video could not be downloaded (gh run download \(runID))")
        }
        return output
    }
}
