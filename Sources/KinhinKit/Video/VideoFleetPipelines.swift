import Foundation

/// What `kinhin video init --workflow` wrote: the pipeline, any file that makes the system run it, and what the user still has
/// to do by hand.
public struct VideoPipelineWrite: Equatable, Sendable {
    public let file: URL
    public let extraFiles: [URL]
    public let notes: [String]
}

/// The video pipeline for every CI system kinhin writes for. Each one runs the same published image with `docker run` and
/// keeps `.kinhin/videos/out` as the `kinhin-video` artifact. Inputs reach the shell only as environment variables.
extension VideoFleet {
    public static func pipelinePath(for ci: CISystem) -> String {
        switch ci {
        case .github: return workflowPath
        case .gitea: return ".gitea/workflows/\(workflowFile)"
        case .forgejo: return ".forgejo/workflows/\(workflowFile)"
        case .gitlab: return ".gitlab/\(workflowFile)"
        // Bitbucket runs only bitbucket-pipelines.yml; this file is the custom pipeline to put in it (see the notes).
        case .bitbucket: return ".kinhin/videos/bitbucket-pipelines.\(workflowFile)"
        case .azure: return ".azure-pipelines/\(workflowFile)"
        case .buildkite: return ".buildkite/\(workflowFile)"
        }
    }

    /// The runner labels used when `--runs-on` is not given: a self-hosted Linux runner with Docker, in each system's terms.
    public static func defaultRunsOn(for ci: CISystem) -> String {
        switch ci {
        case .github: return "self-hosted,linux"
        case .gitea, .forgejo, .gitlab, .azure: return "linux"
        case .bitbucket: return "self.hosted,linux.shell"
        case .buildkite: return "queue=kinhin"
        }
    }

    /// The build, as POSIX shell over the VIDEO_* variables (so it runs under any runner's shell).
    static let buildShell = """
        set -eu
        mkdir -p .kinhin/videos/out .kinhin/videos/.cache
        set -- --project "$VIDEO_PROJECT"
        [ -z "${VIDEO_THEME:-}" ] || set -- "$@" --theme "$VIDEO_THEME"
        [ -z "${VIDEO_FORMAT:-}" ] || set -- "$@" --format "$VIDEO_FORMAT"
        [ -z "${VIDEO_CAPTIONS:-}" ] || set -- "$@" --captions "$VIDEO_CAPTIONS"
        [ -z "${VIDEO_CAPTION_STYLE:-}" ] || set -- "$@" --caption-style "$VIDEO_CAPTION_STYLE"
        [ -z "${VIDEO_MUSIC:-}" ] || set -- "$@" --music "$VIDEO_MUSIC"
        [ "${VIDEO_FAST:-false}" != "true" ] || set -- "$@" --fast
        docker run --rm \\
          -v "$PWD":/project:ro \\
          -v "$PWD/.kinhin/videos/out":/work/out \\
          -v "$PWD/.kinhin/videos/.cache":/work/raw \\
          "$VIDEO_IMAGE" /work/scripts/container-build.sh "$@"
        """

    /// `buildShell` as a YAML block scalar's lines, indented by `spaces`.
    static func indentedShell(_ spaces: Int, escapingDollars: Bool = false) -> String {
        let shell = escapingDollars ? buildShell.replacingOccurrences(of: "$", with: "$$") : buildShell
        let pad = String(repeating: " ", count: spaces)
        return shell.split(separator: "\n", omittingEmptySubsequences: false).map { pad + $0 }.joined(separator: "\n")
    }

    static let header = """
        # Builds a video from .kinhin/videos/ on a kinhin runner, with kinhin's published video image (no copy of the suite
        # needed). The runner needs Docker and a network that can pull the image. The video is kept as the kinhin-video
        # artifact.
        """

    /// The pipeline file for `ci` (GitHub, Gitea and Forgejo share the Actions workflow).
    public static func pipelineTemplate(ci: CISystem, runsOn labels: [String], image: String) -> String {
        switch ci {
        case .github: return workflowTemplate(runsOn: labels, image: image)
        case .gitea, .forgejo: return workflowTemplate(runsOn: labels, image: image, forgeHosted: true)
        case .gitlab: return gitlabTemplate(tags: labels, image: image)
        case .bitbucket: return bitbucketTemplate(runsOn: labels, image: image)
        case .azure: return azureTemplate(demands: labels, image: image)
        case .buildkite: return buildkiteTemplate(agentTags: labels, image: image)
        }
    }

    static func gitlabTemplate(tags: [String], image: String) -> String {
        """
        \(header)
        # Included from .gitlab-ci.yml. It runs only in a pipeline started by hand (Build > Pipelines > Run pipeline) with
        # VIDEO_PROJECT set on that form.
        variables:
          VIDEO_PROJECT:
            value: ""
            description: "kinhin video: the video in .kinhin/videos/ to build (empty: no video job)"
          VIDEO_THEME: { value: "", description: "kinhin video: theme (empty: the video's own)" }
          VIDEO_FORMAT: { value: "", description: "kinhin video: 16:9, 9:16, 4:5 or 1:1 (empty: the video's own)" }
          VIDEO_CAPTIONS: { value: "", description: "kinhin video: on, off or all (empty: the video's own)" }
          VIDEO_CAPTION_STYLE: { value: "", description: "kinhin video: caption style (empty: the video's own)" }
          VIDEO_MUSIC: { value: "", description: "kinhin video: a catalog track, a file in the repository, or off" }
          VIDEO_FAST: { value: "false", options: ["false", "true"], description: "kinhin video: a quicker preview" }

        kinhin-video:
          # A runner with Docker. Change the tags with `kinhin video init --workflow --ci gitlab --runs-on TAGS`.
          tags: [\(tags.joined(separator: ", "))]
          rules:
            - if: $CI_PIPELINE_SOURCE == "web" && $VIDEO_PROJECT != ""
          timeout: 60m
          variables:
            VIDEO_IMAGE: "\(image)"
          script:
            - |
        \(indentedShell(6))
          artifacts:
            name: \(artifactName)
            paths: [.kinhin/videos/out]

        """
    }

    static func bitbucketTemplate(runsOn labels: [String], image: String) -> String {
        """
        \(header)
        # Bitbucket runs only bitbucket-pipelines.yml: copy the kinhin-video entry below under its pipelines: custom: section.
        # Then run it by hand (Pipelines > Run pipeline > custom: kinhin-video) and set VIDEO_PROJECT on that form.
        pipelines:
          custom:
            kinhin-video:
              - variables:
                  - name: VIDEO_PROJECT
                  - name: VIDEO_THEME
                  - name: VIDEO_FORMAT
                  - name: VIDEO_CAPTIONS
                  - name: VIDEO_CAPTION_STYLE
                  - name: VIDEO_MUSIC
                  - name: VIDEO_FAST
                    default: "false"
                    allowed-values: ["false", "true"]
              - step:
                  name: kinhin video
                  # A runner with Docker. Change the labels with `--runs-on`.
                  runs-on: [\(labels.joined(separator: ", "))]
                  max-time: 60
                  script:
                    - export VIDEO_IMAGE="\(image)"
                    - |
        \(indentedShell(14))
                  artifacts:
                    - .kinhin/videos/out/**

        """
    }

    static func azureTemplate(demands labels: [String], image: String) -> String {
        // kinhin exports agent labels as capabilities with `-` turned into `_`.
        let demands = labels.map { $0.replacingOccurrences(of: "-", with: "_") }
        return """
            \(header)
            # Create a pipeline from this file (Pipelines > New pipeline > Existing Azure Pipelines YAML file). It has no
            # trigger, so it runs only when started by hand.
            trigger: none
            pr: none

            parameters:
              - name: project
                displayName: Video in .kinhin/videos/ (for example launch)
                type: string
              - { name: theme, displayName: "Theme (empty: the video's own)", type: string, default: "" }
              - { name: format, displayName: "16:9, 9:16, 4:5 or 1:1 (empty: the video's own)", type: string, default: "" }
              - { name: captions, displayName: "on, off or all (empty: the video's own)", type: string, default: "" }
              - { name: captionStyle, displayName: "Caption style (empty: the video's own)", type: string, default: "" }
              - { name: music, displayName: "A catalog track, a file in the repository, or off", type: string, default: "" }
              - { name: fast, displayName: "A preview: quicker encode, no WebM", type: boolean, default: false }
              # The agent pool your kinhin Azure DevOps account serves (its scope in kinhin's config).
              - { name: pool, displayName: kinhin agent pool, type: string, default: kinhin }

            jobs:
              - job: video
                displayName: kinhin video
                timeoutInMinutes: 60
                pool:
                  name: ${{ parameters.pool }}
                  # An agent with Docker. Change the demands with `--runs-on`.
                  demands: [\(demands.joined(separator: ", "))]
                steps:
                  - checkout: self
                  - script: |
            \(indentedShell(10))
                    displayName: Build the video
                    env:
                      VIDEO_IMAGE: "\(image)"
                      VIDEO_PROJECT: ${{ parameters.project }}
                      VIDEO_THEME: ${{ parameters.theme }}
                      VIDEO_FORMAT: ${{ parameters.format }}
                      VIDEO_CAPTIONS: ${{ parameters.captions }}
                      VIDEO_CAPTION_STYLE: ${{ parameters.captionStyle }}
                      VIDEO_MUSIC: ${{ parameters.music }}
                      VIDEO_FAST: ${{ lower(parameters.fast) }}
                  - publish: .kinhin/videos/out
                    artifact: \(artifactName)

            """
    }

    static func buildkiteTemplate(agentTags labels: [String], image: String) -> String {
        let agents = labels.map { label -> String in
            let pair = label.split(separator: "=", maxSplits: 1).map(String.init)
            return pair.count == 2 ? "\(pair[0]): \"\(pair[1])\"" : "\(label): \"true\""
        }
        return """
            \(header)
            # Make a pipeline whose steps are `buildkite-agent pipeline upload \(pipelinePath(for: .buildkite))`, with no
            # trigger on push, and start a build by hand. `$$` keeps a variable for the agent's shell (Buildkite would
            # otherwise fill it in at upload time).
            steps:
              - input: "kinhin video"
                key: video-input
                fields:
                  - { text: "Video in .kinhin/videos/ (for example launch)", key: project, required: true }
                  - { text: "Theme (empty: the video's own)", key: theme, required: false }
                  - { text: "16:9, 9:16, 4:5 or 1:1 (empty: the video's own)", key: format, required: false }
                  - { text: "on, off or all (empty: the video's own)", key: captions, required: false }
                  - { text: "Caption style (empty: the video's own)", key: caption_style, required: false }
                  - { text: "A catalog track, a file in the repository, or off", key: music, required: false }
                  - select: "A preview: quicker encode, no WebM"
                    key: fast
                    default: "false"
                    options: [{ label: "no", value: "false" }, { label: "yes", value: "true" }]
              - label: "kinhin video"
                depends_on: video-input
                timeout_in_minutes: 60
                # An agent with Docker. Change the tags with `--runs-on`.
                agents: { \(agents.joined(separator: ", ")) }
                env:
                  VIDEO_IMAGE: "\(image)"
                command: |
                  export VIDEO_PROJECT="$$(buildkite-agent meta-data get project)"
                  export VIDEO_THEME="$$(buildkite-agent meta-data get theme --default '')"
                  export VIDEO_FORMAT="$$(buildkite-agent meta-data get format --default '')"
                  export VIDEO_CAPTIONS="$$(buildkite-agent meta-data get captions --default '')"
                  export VIDEO_CAPTION_STYLE="$$(buildkite-agent meta-data get caption_style --default '')"
                  export VIDEO_MUSIC="$$(buildkite-agent meta-data get music --default '')"
                  export VIDEO_FAST="$$(buildkite-agent meta-data get fast --default false)"
            \(indentedShell(6, escapingDollars: true))
                artifact_paths: ".kinhin/videos/out/**/*"

            """
    }

    /// Why `--on-fleet` stops for `ci`: it drives GitHub Actions through `gh`, so other systems are started by hand.
    public static func manualRunHint(for ci: CISystem) -> String {
        let start: String
        switch ci {
        case .github: return "--on-fleet runs the workflow with gh"
        case .gitea, .forgejo: start = "the repository's Actions tab (kinhin video > Run workflow)"
        case .gitlab: start = "Build > Pipelines > Run pipeline, with VIDEO_PROJECT set"
        case .bitbucket: start = "Pipelines > Run pipeline > custom: kinhin-video, with VIDEO_PROJECT set"
        case .azure: start = "the pipeline made from \(pipelinePath(for: .azure)) (Run pipeline)"
        case .buildkite: start = "a new build of the pipeline that uploads \(pipelinePath(for: .buildkite))"
        }
        return "--on-fleet drives GitHub Actions through gh; this repository uses \(ci.rawValue). "
            + "Create the pipeline with `kinhin video init --workflow --ci \(ci.rawValue)`, start it from \(start), then download its "
            + "\(artifactName) artifact into .kinhin/videos/out (or pass --ci github for a GitHub mirror)"
    }

    /// Writes the pipeline for `ci` (never overwriting), and for GitLab a `.gitlab-ci.yml` that includes it when the
    /// repository has none.
    @discardableResult
    public static func writePipeline(in repo: URL, ci: CISystem, runsOn: String?, image: String) throws
        -> VideoPipelineWrite
    {
        let requested = runsOn ?? defaultRunsOn(for: ci)
        guard let labels = parseLabels(requested) else {
            throw VideoError.invalidName("--runs-on \(requested)")
        }
        let path = pipelinePath(for: ci)
        let target = repo.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: target.path) { throw VideoError.alreadyExists(target.path) }
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(pipelineTemplate(ci: ci, runsOn: labels, image: image).utf8).write(
            to: target, options: .withoutOverwriting)

        var extra: [URL] = []
        var notes: [String] = []
        switch ci {
        case .github:
            notes.append("Commit and push it, then run `kinhin video build <name> --on-fleet`.")
        case .gitea, .forgejo:
            notes.append(
                "Commit and push it, then run it from the repository's Actions tab (kinhin video > Run workflow).")
        case .gitlab:
            let main = repo.appendingPathComponent(".gitlab-ci.yml")
            if !FileManager.default.fileExists(atPath: main.path) {
                let include =
                    "# Written by kinhin video init: the manual kinhin video job.\ninclude:\n  - local: \(path)\n"
                try Data(include.utf8).write(to: main, options: .withoutOverwriting)
                extra.append(main)
            } else if (try? String(contentsOf: main, encoding: .utf8))?.contains(path) != true {
                notes.append("Add this to .gitlab-ci.yml so the job runs: include: [{ local: \(path) }]")
            }
            notes.append(
                "Commit and push, then run a pipeline by hand (Build > Pipelines > Run pipeline) with VIDEO_PROJECT set."
            )
        case .bitbucket:
            notes.append(
                "Copy its kinhin-video entry under pipelines: custom: in bitbucket-pipelines.yml, then run it by hand.")
        case .azure:
            notes.append(
                "Commit and push it, then create a pipeline from it (Pipelines > New pipeline > Existing YAML file).")
        case .buildkite:
            notes.append(
                "Commit and push it, then make a pipeline whose steps are: buildkite-agent pipeline upload \(path)")
        }
        return VideoPipelineWrite(file: target, extraFiles: extra, notes: notes)
    }
}
