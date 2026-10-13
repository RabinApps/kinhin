import Synchronization
import XCTest

@testable import KinhinKit

/// `kinhin video`: finding a repo's configs, the starter, the image, the exact commands a build runs, and the runner's
/// decisions (which runtime, pull or not) against scripted tools.
final class VideoTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-video-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: repo)
    }

    private func write(_ relative: String, _ text: String = "name: x\n") throws {
        let url = repo.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // MARK: projects

    func testListFindsConfigsInSubfoldersAndSkipsTheRest() throws {
        try write(".kinhin/videos/launch.yml")
        try write(".kinhin/videos/teaser.json")
        try write(".kinhin/videos/more.yaml")
        try write(".kinhin/videos/social/vertical.yml")
        try write(".kinhin/videos/adapters/acme/adapter.yml")
        try write(".kinhin/videos/out/launch.json")
        try write(".kinhin/videos/.cache/x.yml")
        try write(".kinhin/videos/fonts/readme.json")
        try write(".kinhin/videos/themes/brand.yml")
        try write(".kinhin/videos/themes/plain.json")
        try write(".kinhin/videos/notes.txt")
        XCTAssertEqual(VideoProjects.list(in: repo), ["launch", "more", "social/vertical", "teaser"])
    }

    func testListOfARepoWithoutVideosIsEmpty() {
        XCTAssertEqual(VideoProjects.list(in: repo), [])
    }

    func testFileLookupAcceptsEveryExtensionAndRefusesEscapes() throws {
        try write(".kinhin/videos/a.yml")
        try write(".kinhin/videos/b.yaml")
        try write(".kinhin/videos/c.json")
        try write("secret.yml")
        XCTAssertNotNil(VideoProjects.file(named: "a", in: repo))
        XCTAssertNotNil(VideoProjects.file(named: "b", in: repo))
        XCTAssertNotNil(VideoProjects.file(named: "c", in: repo))
        XCTAssertNil(VideoProjects.file(named: "missing", in: repo))
        XCTAssertNil(VideoProjects.file(named: "../../secret", in: repo))
        XCTAssertNil(VideoProjects.file(named: "/etc/passwd", in: repo))
        XCTAssertFalse(VideoProjects.isValidName("a//b"))
        XCTAssertTrue(VideoProjects.isValidName("social/vertical"))
    }

    // MARK: starter

    func testStarterWritesAConfigAndAGitignoreAndNeverOverwrites() throws {
        let written = try VideoStarter.write(name: "launch", in: repo)
        XCTAssertEqual(written.map(\.lastPathComponent), ["launch.yml", ".gitignore"])
        let yaml = try String(contentsOf: repo.appendingPathComponent(".kinhin/videos/launch.yml"), encoding: .utf8)
        XCTAssertTrue(yaml.contains("name: launch"))
        XCTAssertTrue(yaml.contains("type: outro"))
        let ignore = try String(contentsOf: repo.appendingPathComponent(".kinhin/videos/.gitignore"), encoding: .utf8)
        XCTAssertTrue(ignore.contains("out/") && ignore.contains(".cache/"))
        XCTAssertEqual(VideoProjects.list(in: repo), ["launch"])

        XCTAssertThrowsError(try VideoStarter.write(name: "launch", in: repo)) {
            guard case VideoError.alreadyExists = $0 else { return XCTFail("\($0)") }
        }
        // A second video reuses the .gitignore.
        XCTAssertEqual(
            try VideoStarter.write(name: "social/vertical", in: repo).map(\.lastPathComponent), ["vertical.yml"])
    }

    func testStarterRefusesUnsafeNames() {
        for name in ["", "../x", "a b", "a:b", "/abs", "x\ny"] {
            XCTAssertThrowsError(try VideoStarter.write(name: name, in: repo), name) {
                XCTAssertEqual($0 as? VideoError, .invalidName(name))
            }
        }
    }

    // MARK: image

    func testImageReferencePrefersTheFlagThenTheEnvironmentThenTheReleasedImage() {
        XCTAssertEqual(VideoImage.reference(override: "mine:1", environment: [:], version: "1.2.3"), "mine:1")
        XCTAssertEqual(
            VideoImage.reference(environment: [VideoImage.overrideVariable: "env:2"], version: "1.2.3"), "env:2")
        XCTAssertEqual(
            VideoImage.reference(environment: [VideoImage.overrideVariable: ""], version: "1.2.3"),
            "ghcr.io/rabinapps/kinhin-video:1.2.3")
    }

    // MARK: the plan

    private func plan(
        _ options: VideoBuildOptions = VideoBuildOptions(project: "launch"), runtime: VideoRuntime = .docker,
        cpus: Int = 8
    ) -> VideoRunPlan {
        VideoRunPlan.make(
            options: options, runtime: runtime, binary: "/bin/rt", image: "img:1", repo: URL(fileURLWithPath: "/r"),
            cpuCount: cpus)
    }

    func testDockerRunMountsTheRepoReadOnlyAndTheOutputAndCache() {
        let p = plan()
        XCTAssertEqual(
            p.run,
            [
                "/bin/rt", "run", "--rm", "--cpus", "4", "--memory", "6g", "-v", "/r:/project:ro",
                "-v", "/r/.kinhin/videos/out:/work/out", "-v", "/r/.kinhin/videos/.cache:/work/raw", "img:1",
                "/work/scripts/container-build.sh", "--project", "launch",
            ])
        XCTAssertEqual(p.inspect, ["/bin/rt", "image", "inspect", "img:1"])
        XCTAssertEqual(p.pull, ["/bin/rt", "image", "pull", "img:1"])
        XCTAssertEqual(p.outputDirectory.path, "/r/.kinhin/videos/out")
    }

    func testAppleContainerUsesItsOwnSizeFlags() {
        let p = plan(runtime: .appleContainer)
        XCTAssertEqual(Array(p.run[0...6]), ["/bin/rt", "run", "--rm", "-c", "4", "-m", "6G"])
    }

    func testCPUsAreClampedToTheMachine() {
        XCTAssertEqual(plan(cpus: 2).run[4], "2")
        XCTAssertEqual(plan(cpus: 1).run[4], "1")
        XCTAssertEqual(plan(cpus: 0).run[4], "1")
        XCTAssertEqual(plan(cpus: 64).run[4], "4")
    }

    func testOptionsBecomeFlagsOfTheEntryScript() {
        var options = VideoBuildOptions(project: "social/vertical")
        options.theme = "midnight"
        options.format = "9:16"
        options.captions = "off"
        options.captionStyle = "box"
        options.music = "audio/bed.mp3"
        options.fast = true
        let tail = Array(plan(options).run.drop { $0 != "/work/scripts/container-build.sh" })
        XCTAssertEqual(
            tail,
            [
                "/work/scripts/container-build.sh", "--project", "social/vertical", "--theme", "midnight", "--format",
                "9:16",
                "--captions", "off", "--caption-style", "box", "--music", "audio/bed.mp3", "--fast",
            ])
    }

    // MARK: the runner

    private final class ScriptedShell: ShellRunning, Sendable {
        let calls = Mutex<[[String]]>([])
        let respond: @Sendable ([String]) -> Int32
        init(_ respond: @escaping @Sendable ([String]) -> Int32) { self.respond = respond }

        func run(_ argv: [String], cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
            calls.withLock { $0.append(argv) }
            return ShellResult(exitCode: respond(argv), stdout: "", stderr: "")
        }
    }

    private final class ScriptedProcess: VideoProcessRunning, Sendable {
        let calls = Mutex<[[String]]>([])
        let respond: @Sendable ([String]) -> Int32
        init(_ respond: @escaping @Sendable ([String]) -> Int32 = { _ in 0 }) { self.respond = respond }

        func runInteractive(_ argv: [String]) async throws -> Int32 {
            calls.withLock { $0.append(argv) }
            return respond(argv)
        }
    }

    private func runner(
        shell: ScriptedShell, process: ScriptedProcess, installed: Set<VideoRuntime> = [.appleContainer, .docker]
    ) -> VideoRunner {
        VideoRunner(
            shell: shell, process: process, environment: [:], cpuCount: 8,
            binaries: { installed.contains($0) ? "/bin/\($0.rawValue)" : nil })
    }

    func testRuntimeDetectionPrefersAppleContainerThenDocker() async throws {
        let both = runner(shell: ScriptedShell { _ in 0 }, process: ScriptedProcess())
        let first = try await both.detectRuntime(preferred: nil)
        XCTAssertEqual(first.runtime, .appleContainer)

        // Apple's service is down: Docker is next.
        let appleDown = runner(shell: ScriptedShell { $0.contains("system") ? 1 : 0 }, process: ScriptedProcess())
        let second = try await appleDown.detectRuntime(preferred: nil)
        XCTAssertEqual(second.runtime, .docker)
    }

    func testNoRuntimeAndAForcedUnusableRuntimeAreExplained() async {
        let none = runner(shell: ScriptedShell { _ in 1 }, process: ScriptedProcess(), installed: [])
        do {
            _ = try await none.detectRuntime(preferred: nil)
            XCTFail("expected an error")
        } catch { XCTAssertEqual(error as? VideoError, .noRuntime) }

        do {
            _ = try await none.detectRuntime(preferred: .docker)
            XCTFail("expected an error")
        } catch {
            guard case VideoError.runtimeUnavailable(let why) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("docker is not installed"), why)
        }
    }

    func testPlanNamesTheProblemsBeforeAnythingRuns() async throws {
        let r = runner(shell: ScriptedShell { _ in 0 }, process: ScriptedProcess())
        do {
            _ = try await r.plan(options: .init(project: "launch"), repo: repo, runtime: nil, image: nil)
            XCTFail("expected an error")
        } catch { guard case VideoError.noVideosFolder = error else { return XCTFail("\(error)") } }

        try write(".kinhin/videos/launch.yml")
        do {
            _ = try await r.plan(options: .init(project: "nope"), repo: repo, runtime: nil, image: nil)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? VideoError, .unknownProject(name: "nope", available: ["launch"]))
        }
        let ok = try await r.plan(options: .init(project: "launch"), repo: repo, runtime: .docker, image: "img:9")
        XCTAssertEqual(ok.image, "img:9")
        XCTAssertEqual(ok.runtime, .docker)
    }

    func testABuildSkipsThePullWhenTheImageIsPresentAndCreatesTheOutputFolders() async throws {
        try write(".kinhin/videos/launch.yml")
        let shell = ScriptedShell { _ in 0 }
        let process = ScriptedProcess()
        let r = runner(shell: shell, process: process)
        let p = try await r.plan(options: .init(project: "launch"), repo: repo, runtime: .docker, image: "img:1")
        let code = try await r.build(plan: p)
        XCTAssertEqual(code, 0)
        XCTAssertEqual(process.calls.withLock { $0 }, [p.run], "only the run: no pull")
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.outputDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.cacheDirectory.path))
    }

    func testABuildPullsAMissingImageFirstAndReturnsThePipelinesExitCode() async throws {
        try write(".kinhin/videos/launch.yml")
        let shell = ScriptedShell { $0.contains("inspect") ? 1 : 0 }
        let process = ScriptedProcess { $0.contains("run") ? 3 : 0 }
        let r = runner(shell: shell, process: process)
        let p = try await r.plan(options: .init(project: "launch"), repo: repo, runtime: .docker, image: "img:1")
        let code = try await r.build(plan: p)
        XCTAssertEqual(code, 3)
        XCTAssertEqual(process.calls.withLock { $0 }, [p.pull, p.run])
    }

    func testAFailedPullStopsTheBuildWithAHelpfulMessage() async throws {
        try write(".kinhin/videos/launch.yml")
        let shell = ScriptedShell { $0.contains("inspect") ? 1 : 0 }
        let process = ScriptedProcess { $0.contains("pull") ? 1 : 0 }
        let r = runner(shell: shell, process: process)
        let p = try await r.plan(options: .init(project: "launch"), repo: repo, runtime: .docker, image: "img:1")
        do {
            _ = try await r.build(plan: p)
            XCTFail("expected an error")
        } catch {
            guard case VideoError.imageUnavailable(let image, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(image, "img:1")
            XCTAssertTrue(error.localizedDescription.contains("--image"))
        }
        XCTAssertEqual(process.calls.withLock { $0 }, [p.pull], "the run never started")
    }

    // MARK: fleet

    func testTheWorkflowTemplateIsPinnedLeastPrivilegeAndKeepsInputsOutOfTheScript() {
        let yaml = VideoFleet.workflowTemplate(runsOn: ["self-hosted", "linux"], image: "ghcr.io/x/y:1")
        XCTAssertTrue(yaml.contains("runs-on: [self-hosted, linux]"))
        XCTAssertTrue(yaml.contains("permissions:\n  contents: read"))
        XCTAssertTrue(yaml.contains("IMAGE: ghcr.io/x/y:1"))
        XCTAssertFalse(yaml.contains("secrets."))
        for line in yaml.split(separator: "\n") where line.contains("uses:") {
            XCTAssertNotNil(line.range(of: "@[0-9a-f]{40}", options: .regularExpression), String(line))
        }
        // Inputs reach the script only as environment variables.
        for line in yaml.split(separator: "\n") where line.contains("${{ inputs.") {
            XCTAssertTrue(line.contains(": ${{ inputs."), "only an env assignment may read an input: \(line)")
        }
    }

    func testTheWorkflowIsWrittenOnceWithValidLabels() throws {
        let file = try VideoFleet.writeWorkflow(in: repo, runsOn: "self-hosted, linux", image: "i:1")
        XCTAssertEqual(file.path, repo.appendingPathComponent(".github/workflows/kinhin-video.yml").path)
        XCTAssertThrowsError(try VideoFleet.writeWorkflow(in: repo, runsOn: "self-hosted", image: "i:1"))
        XCTAssertThrowsError(try VideoFleet.writeWorkflow(in: repo, runsOn: "a]\n  evil: [b", image: "i:1"))
        XCTAssertNil(VideoFleet.parseLabels(""))
        XCTAssertNil(VideoFleet.parseLabels("ok,,x"))
        XCTAssertEqual(VideoFleet.parseLabels("self-hosted,linux"), ["self-hosted", "linux"])
    }

    func testDispatchArgumentsCarryTheOptionsAsInputs() {
        var options = VideoBuildOptions(project: "launch")
        XCTAssertEqual(
            VideoFleet.dispatchArguments(gh: "/gh", options: options, ref: "main"),
            ["/gh", "workflow", "run", "kinhin-video.yml", "--ref", "main", "-f", "project=launch"])
        options.theme = "midnight"
        options.captions = "off"
        options.fast = true
        XCTAssertEqual(
            VideoFleet.dispatchArguments(gh: "/gh", options: options, ref: "dev").suffix(6),
            ["-f", "theme=midnight", "-f", "captions=off", "-f", "fast=true"])
    }

    func testTheRunIsTheNewestOneStartedAfterTheDispatch() {
        let json = """
            [{"databaseId": 1, "createdAt": "2026-10-12T10:00:00Z"},
             {"databaseId": 3, "createdAt": "2026-10-12T10:05:30Z"},
             {"databaseId": 2, "createdAt": "2026-10-12T10:05:10Z"}]
            """
        let after = ISO8601DateFormatter().date(from: "2026-10-12T10:05:00Z")!
        XCTAssertEqual(VideoFleet.runID(fromListing: json, notBefore: after), 3)
        let later = ISO8601DateFormatter().date(from: "2026-10-12T11:00:00Z")!
        XCTAssertNil(VideoFleet.runID(fromListing: json, notBefore: later))
        XCTAssertNil(VideoFleet.runID(fromListing: "not json", notBefore: after))
    }

    private func fleetRunner(
        shell: ScriptedShell, process: ScriptedProcess, gh: String? = "/gh"
    ) -> VideoFleetRunner {
        VideoFleetRunner(
            shell: shell, process: process, ghPath: { gh }, now: { Date() }, pause: { _ in })
    }

    func testFleetBuildNeedsGhAndAPushedWorkflow() async throws {
        let options = VideoBuildOptions(project: "launch")
        do {
            _ = try await fleetRunner(shell: ScriptedShell { _ in 0 }, process: ScriptedProcess(), gh: nil)
                .build(options: options, repo: repo, ref: "main")
            XCTFail("expected an error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("gh auth login"), error.localizedDescription) }

        // `gh workflow view` fails: the workflow is not on the branch.
        let missing = ScriptedShell { $0.contains("view") ? 1 : 0 }
        do {
            _ = try await fleetRunner(shell: missing, process: ScriptedProcess()).build(
                options: options, repo: repo, ref: "main")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("kinhin video init --workflow"), error.localizedDescription)
        }
    }

    func testFleetBuildDispatchesWatchesAndDownloads() async throws {
        let listing = """
            [{"databaseId": 77, "createdAt": "\(ISO8601DateFormatter().string(from: Date().addingTimeInterval(60)))"}]
            """
        let shell = ScriptedShell { _ in 0 }
        let listed = ListingShell(listing)
        _ = shell
        let process = ScriptedProcess()
        let runner = VideoFleetRunner(
            shell: listed, process: process, ghPath: { "/gh" }, now: { Date() }, pause: { _ in })
        let out = try await runner.build(options: VideoBuildOptions(project: "launch"), repo: repo, ref: "main")
        XCTAssertEqual(out.path, repo.appendingPathComponent(".kinhin/videos/out").path)
        let calls = process.calls.withLock { $0 }
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[0][1...2], ["workflow", "run"])
        XCTAssertEqual(calls[1], ["/gh", "run", "watch", "77", "--exit-status"])
        XCTAssertEqual(Array(calls[2].prefix(5)), ["/gh", "run", "download", "77", "-n"])
    }

    func testAFailedFleetBuildPointsAtTheLog() async throws {
        let listing = """
            [{"databaseId": 5, "createdAt": "\(ISO8601DateFormatter().string(from: Date().addingTimeInterval(60)))"}]
            """
        let process = ScriptedProcess { $0.contains("watch") ? 1 : 0 }
        let runner = VideoFleetRunner(
            shell: ListingShell(listing), process: process, ghPath: { "/gh" }, now: { Date() }, pause: { _ in })
        do {
            _ = try await runner.build(options: VideoBuildOptions(project: "launch"), repo: repo, ref: "main")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("gh run view 5 --log-failed"), error.localizedDescription)
        }
        XCTAssertEqual(process.calls.withLock { $0 }.count, 2, "no download after a failed run")
    }

    /// A shell that answers `gh run list` with a fixed listing and everything else with success.
    private final class ListingShell: ShellRunning, Sendable {
        let listing: String
        init(_ listing: String) { self.listing = listing }
        func run(_ argv: [String], cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
            ShellResult(exitCode: 0, stdout: argv.contains("list") ? listing : "", stderr: "")
        }
    }

    // MARK: themes

    func testTheBuiltInThemeTableMatchesTheThemeFilesTheImageShips() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("video/themes")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertEqual(
            Set(files.map { $0.deletingPathExtension().lastPathComponent }), Set(VideoThemes.builtIn.map(\.name)))
        for file in files {
            let theme = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            let built = try XCTUnwrap(VideoThemes.builtIn(named: theme["name"] as? String ?? ""))
            let colors = try XCTUnwrap(theme["colors"] as? [String: Any])
            let font = try XCTUnwrap(theme["font"] as? [String: Any])
            XCTAssertEqual(theme["description"] as? String, built.summary, built.name)
            XCTAssertEqual(font["family"] as? String, built.font, built.name)
            XCTAssertEqual(colors["ink"] as? String, built.ink, built.name)
            XCTAssertEqual(colors["paper"] as? String, built.paper, built.name)
            XCTAssertEqual(colors["accent"] as? String, built.accent, built.name)
        }
    }

    func testThemeNewWritesAStarterThatExtendsTheChosenTheme() throws {
        let file = try VideoThemes.write(name: "brand", from: "midnight", in: repo)
        XCTAssertEqual(file.path, repo.appendingPathComponent(".kinhin/videos/themes/brand.yml").path)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("\nextends: midnight\n"))
        XCTAssertTrue(text.contains("#   accent: \"#7aa2ff\""), "the base theme's own value is shown")
        XCTAssertTrue(text.contains("theme: brand"))
        // Everything but `extends` is a comment, so the file is valid as it stands.
        let active = text.split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }
        XCTAssertEqual(active, ["extends: midnight"])
        XCTAssertEqual(VideoThemes.own(in: repo), ["brand"])
        XCTAssertEqual(VideoProjects.list(in: repo), [], "a theme file is not a video")
    }

    func testThemeNewRefusesBadNamesUnknownBasesAndNeverOverwrites() throws {
        for name in ["", "a b", "../x", "-x", "x/y", "né"] {
            XCTAssertThrowsError(try VideoThemes.write(name: name, in: repo), name) {
                XCTAssertEqual($0 as? VideoError, .invalidName(name))
            }
        }
        XCTAssertThrowsError(try VideoThemes.write(name: "x", from: "neon", in: repo)) {
            guard case VideoError.unknownTheme(let name, let available) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(name, "neon")
            XCTAssertTrue(available.contains("paper"))
        }
        try VideoThemes.write(name: "brand", in: repo)
        XCTAssertThrowsError(try VideoThemes.write(name: "brand", in: repo))
        try write(".kinhin/videos/themes/other.json", "{}")
        XCTAssertThrowsError(
            try VideoThemes.write(name: "other", in: repo), "another extension is a theme of that name too")
        XCTAssertEqual(VideoThemes.own(in: repo), ["brand", "other"])
    }

    // MARK: capturing output

    func testCapturingRunnerDeliversEveryLineFromBothStreamsAndTheExitCode() async throws {
        let lines = Mutex<[String]>([])
        let runner = CapturingProcessRunner { line in lines.withLock { $0.append(line) } }
        let code = try await runner.runInteractive(
            [
                "/bin/sh", "-c",
                "echo one; echo two 1>&2; printf 'progress 1\\rprogress 2\\r'; printf 'no newline at the end'; exit 3",
            ])
        XCTAssertEqual(code, 3)
        let got = lines.withLock { $0 }
        XCTAssertTrue(got.contains("one") && got.contains("two"), "\(got)")
        XCTAssertTrue(
            got.contains("progress 1") && got.contains("progress 2"),
            "a rewritten progress line counts each time: \(got)")
        XCTAssertEqual(got.last, "no newline at the end", "the last partial line is not lost")
    }

    func testCapturingRunnerStopsTheChildWhenCancelled() async throws {
        let runner = CapturingProcessRunner { _ in }
        let started = Date()
        let task = Task { try await runner.runInteractive(["/bin/sleep", "30"]) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let code = try await task.value
        XCTAssertNotEqual(code, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testCapturingRunnerReportsAMissingProgram() async {
        let runner = CapturingProcessRunner { _ in }
        do {
            _ = try await runner.runInteractive(["/nonexistent/program"])
            XCTFail("expected an error")
        } catch {
            guard case VideoError.launchFailed = error else { return XCTFail("\(error)") }
        }
    }
}
