import CryptoKit
import E2ESupport
import Foundation
import Testing

/// `kinhin video`, end to end through the real binary: scaffolding a video, searching a music library, adding a track to a
/// video's config, and listing what each video uses. The library is a local stand-in (`MusicLibraryStub`), so nothing here
/// touches the network. One test per tier builds a real video in a container; it needs an image (`KINHIN_E2E_VIDEO_IMAGE`).
@Suite("Video and music", .serialized, .tags(.cli), .enabled(if: E2E.enabled))
struct VideoTests {
    /// A throwaway kinhin install plus a throwaway repository, with the library stand-in running.
    private struct World {
        let sandbox: Sandbox
        let repo: URL
        let stub: MusicLibraryStub
        let audio: Data

        func kinhin(_ arguments: [String], timeout: TimeInterval = 120) async throws -> ProcessResult {
            var env = sandbox.environment
            env["KINHIN_OPENVERSE_URL"] = stub.endpoint
            return try await Shell.run(E2E.kinhinBinary, arguments, environment: env, cwd: repo.path, timeout: timeout)
        }

        func path(_ relative: String) -> URL { repo.appendingPathComponent(relative) }
        func read(_ relative: String) throws -> String { try String(contentsOf: path(relative), encoding: .utf8) }
        func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: path(relative).path) }
        func write(_ relative: String, _ text: String) throws {
            try FileManager.default.createDirectory(
                at: path(relative).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: path(relative))
        }

        func dispose() {
            stub.stop()
            sandbox.dispose()
            try? FileManager.default.removeItem(at: repo)
        }
    }

    private func world(mode: MusicLibraryStub.Mode = .normal, audio: Data? = nil) async throws -> World {
        let sandbox = try Sandbox()
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("ke2e-repo-\(E2E.randomID())")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let filler = [UInt8]((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let bytes: Data = audio ?? Data(filler)
        return World(
            sandbox: sandbox, repo: repo, stub: try await MusicLibraryStub(mode: mode, audio: bytes), audio: bytes)
    }

    private func withWorld(
        mode: MusicLibraryStub.Mode = .normal, _ body: (World) async throws -> Void
    ) async throws {
        let world = try await world(mode: mode)
        defer { world.dispose() }
        try await body(world)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func json(_ result: ProcessResult) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
    }

    // MARK: videos

    @Test("init writes a starter video and a .gitignore, list shows it, and init never overwrites")
    func initAndList() async throws {
        try await withWorld { world in
            let created = try await world.kinhin(["video", "init", "launch"])
            #expect(created.ok, "\(created.output)")
            #expect(world.exists(".kinhin/videos/launch.yml"))
            #expect(try world.read(".kinhin/videos/.gitignore").contains("out/"))

            let listed = try await world.kinhin(["video", "list", "--json"])
            let document = try #require(try json(listed) as? [String: Any])
            #expect(document["videos"] as? [String] == ["launch"])

            let again = try await world.kinhin(["video", "init", "launch"])
            #expect(again.status == 2, "exit \(again.status): \(again.output)")
            #expect(again.output.contains("will not overwrite"))
            let unsafe = try await world.kinhin(["video", "init", "../escape"])
            #expect(unsafe.status == 2, "exit \(unsafe.status): \(unsafe.output)")
            #expect(!world.exists("../escape.yml"))
        }
    }

    @Test("build names the problem before starting anything: no folder, no such video, bad flags")
    func buildPreflight() async throws {
        try await withWorld { world in
            let none = try await world.kinhin(["video", "build", "launch"])
            #expect(none.status == 2, "exit \(none.status): \(none.output)")
            #expect(none.output.contains(".kinhin/videos"))

            _ = try await world.kinhin(["video", "init", "launch"])
            let missing = try await world.kinhin(["video", "build", "nope"])
            #expect(missing.status == 2 && missing.output.contains("launch"), "\(missing.output)")
            let badCaptions = try await world.kinhin(["video", "build", "launch", "--captions", "maybe"])
            #expect(badCaptions.status == 2, "\(badCaptions.output)")
            let badRuntime = try await world.kinhin(["video", "build", "launch", "--runtime", "podman"])
            #expect(badRuntime.status == 2, "\(badRuntime.output)")
        }
    }

    // MARK: music

    @Test("search lists numbered results with license and length, built-in tracks first, and honors the license flag")
    func search() async throws {
        try await withWorld { world in
            let result = try await world.kinhin(["video", "music", "search", "test"])
            #expect(result.ok, "\(result.output)")
            #expect(result.stdout.contains("Lofi Test Loop"))
            #expect(result.stdout.contains("Calm Piano Test"))
            #expect(!result.stdout.contains("Credit Required Test"), "CC BY is not offered by default")
            #expect(!result.stdout.contains("Non Commercial Test"), "non-commercial is never offered")

            let withCredit = try await world.kinhin(["video", "music", "search", "test", "--license", "cc-by"])
            #expect(withCredit.stdout.contains("Credit Required Test"))
            #expect(!withCredit.stdout.contains("Non Commercial Test"))

            let builtIn = try await world.kinhin(["video", "music", "search", "calm", "piano", "--json"])
            let rows = try #require(try json(builtIn) as? [[String: Any]])
            #expect(rows.first?["id"] as? String == "first-light-particles", "the built-in track comes first")
            #expect(rows.first?["origin"] as? String == "builtIn")

            let tooShort = try await world.kinhin(["video", "music", "search", "test", "--min-seconds", "100"])
            #expect(tooShort.stdout.contains("nothing found"), "\(tooShort.output)")
            let usage = try await world.kinhin(["video", "music", "search"])
            #expect(usage.status == 2, "\(usage.output)")
        }
    }

    @Test("add downloads the track, records its source, and sets music in the video, keeping the file's comments")
    func addToTheOnlyVideo() async throws {
        try await withWorld { world in
            try world.write(
                ".kinhin/videos/launch.yml",
                "# my launch video\nname: Launch   # keep me\ntheme: paper\nscenes:\n  - id: a\n    type: title\n")
            _ = try await world.kinhin(["video", "music", "search", "lofi"])
            let added = try await world.kinhin(["video", "music", "add", "1", "--volume", "0.3"])
            #expect(added.ok, "\(added.output)")

            let file = ".kinhin/videos/music/lofi-test-loop.mp3"
            #expect(world.exists(file))
            #expect(try Data(contentsOf: world.path(file)) == world.audio)

            let yaml = try world.read(".kinhin/videos/launch.yml")
            #expect(
                yaml
                    == "# my launch video\nname: Launch   # keep me\ntheme: paper\nmusic:\n  track: \"\(file)\"\n  volume: 0.3\nscenes:\n  - id: a\n    type: title\n",
                "\(yaml)")

            let sidecar = try #require(
                try JSONSerialization.jsonObject(
                    with: Data(contentsOf: world.path(".kinhin/videos/music/lofi-test-loop.json")))
                    as? [String: Any])
            #expect(sidecar["sha256"] as? String == Self.sha256(world.audio))
            #expect(sidecar["license"] as? String == "cc0")
            #expect(sidecar["openverseID"] as? String == MusicLibraryStub.items[0].id)
            #expect(sidecar["credit"] == nil)

            // Saved music and its provenance are not videos.
            let listed = try await world.kinhin(["video", "list", "--json"])
            #expect((try json(listed) as? [String: Any])?["videos"] as? [String] == ["launch"])

            let used = try await world.kinhin(["video", "music", "list", "--json"])
            let listing = try #require(try json(used) as? [String: Any])
            let videos = try #require(listing["videos"] as? [[String: Any]])
            #expect(videos.first?["track"] as? String == file)
            #expect(videos.first?["volume"] as? Double == 0.3)
            let saved = try #require(listing["saved"] as? [[String: Any]])
            #expect(saved.first?["usedBy"] as? [String] == ["launch"])
        }
    }

    @Test("with several videos add needs --video, edits only that one, and downloads nothing until it is named")
    func addNeedsAVideo() async throws {
        try await withWorld { world in
            try world.write(".kinhin/videos/a.yml", "name: a\n")
            try world.write(".kinhin/videos/b.yml", "name: b\n")
            _ = try await world.kinhin(["video", "music", "search", "lofi"])

            let ambiguous = try await world.kinhin(["video", "music", "add", "1"])
            #expect(ambiguous.status == 2 && ambiguous.output.contains("a, b"), "\(ambiguous.output)")
            #expect(!world.exists(".kinhin/videos/music"), "nothing was downloaded")

            let unknown = try await world.kinhin(["video", "music", "add", "1", "--video", "zzz"])
            #expect(unknown.status == 2, "\(unknown.output)")

            let chosen = try await world.kinhin(["video", "music", "add", "1", "--video", "b"])
            #expect(chosen.ok, "\(chosen.output)")
            #expect(try world.read(".kinhin/videos/a.yml") == "name: a\n", "the other video is untouched")
            #expect(try world.read(".kinhin/videos/b.yml").contains("music:"))

            let unused = try await world.kinhin(["video", "music", "list"])
            #expect(unused.stdout.contains("a: none") && unused.stdout.contains("used by b"), "\(unused.stdout)")
        }
    }

    @Test(
        "a track that is not reusable is refused with exit 2 and nothing is saved; CC BY needs the flag and brings its credit"
    )
    func licenseGate() async throws {
        try await withWorld { world in
            try world.write(".kinhin/videos/launch.yml", "name: x\nscenes: []\n")

            let nc = try await world.kinhin([
                "video", "music", "add", MusicLibraryStub.items[3].id, "--license", "cc-by",
            ])
            #expect(nc.status == 2, "exit \(nc.status): \(nc.output)")
            #expect(nc.output.contains("does not put in a video"))
            #expect(!world.exists(".kinhin/videos/music"))

            let by = try await world.kinhin(["video", "music", "add", MusicLibraryStub.items[2].id])
            #expect(by.status == 2, "CC BY needs --license cc-by: \(by.output)")
            #expect(!world.exists(".kinhin/videos/music"))

            let allowed = try await world.kinhin(
                ["video", "music", "add", MusicLibraryStub.items[2].id, "--license", "cc-by"])
            #expect(allowed.ok, "\(allowed.output)")
            #expect(allowed.stdout.contains("Credit required"), "\(allowed.stdout)")
            let yaml = try world.read(".kinhin/videos/launch.yml")
            #expect(yaml.contains("credit: \""), "\(yaml)")
            #expect(try world.read(".kinhin/videos/music/credit-required-test.json").contains("\"credit\""))
        }
    }

    @Test("a built-in track is named in the config and nothing is downloaded")
    func builtInTrack() async throws {
        try await withWorld { world in
            try world.write(".kinhin/videos/launch.yml", "name: x\nmusic: false\nscenes: []\n")
            let result = try await world.kinhin(["video", "music", "add", "first-light-particles"])
            #expect(result.ok, "\(result.output)")
            #expect(
                try world.read(".kinhin/videos/launch.yml")
                    == "name: x\nmusic:\n  track: \"first-light-particles\"\nscenes: []\n")
            #expect(!world.exists(".kinhin/videos/music"))
        }
    }

    @Test("a JSON config is not rewritten: the block to paste is printed, and --no-config only downloads")
    func jsonAndNoConfig() async throws {
        try await withWorld { world in
            try world.write(".kinhin/videos/launch.json", #"{"name": "x", "scenes": []}"#)
            _ = try await world.kinhin(["video", "music", "search", "lofi"])
            let result = try await world.kinhin(["video", "music", "add", "1"])
            #expect(result.ok, "\(result.output)")
            #expect(result.stdout.contains("is JSON, so it was not edited"))
            #expect(result.stdout.contains("track: \".kinhin/videos/music/lofi-test-loop.mp3\""))
            #expect(try world.read(".kinhin/videos/launch.json") == #"{"name": "x", "scenes": []}"#)

            _ = try await world.kinhin(["video", "music", "search", "test"])
            let bare = try await world.kinhin(["video", "music", "add", "2", "--no-config"])
            #expect(bare.ok, "\(bare.output)")
            #expect(world.exists(".kinhin/videos/music/calm-piano-test.mp3"))
        }
    }

    @Test("a rate-limited or unreachable library is a runtime error (exit 4), and built-in tracks still show offline")
    func libraryDown() async throws {
        try await withWorld(mode: .rateLimited) { world in
            let limited = try await world.kinhin(["video", "music", "search", "lofi"])
            #expect(limited.status == 4, "exit \(limited.status): \(limited.output)")
            #expect(
                limited.output.contains("rate limiting") && limited.output.contains("7 seconds"), "\(limited.output)")

            let fallback = try await world.kinhin(["video", "music", "search", "calm", "piano"])
            #expect(fallback.ok, "\(fallback.output)")
            #expect(fallback.stdout.contains("First Light Particles"))
            #expect(fallback.stderr.contains("rate limiting"), "the user is told why only built-in tracks are shown")
        }

        let down = try await world()
        let endpoint = down.stub.endpoint
        down.stub.stop()
        defer {
            down.sandbox.dispose()
            try? FileManager.default.removeItem(at: down.repo)
        }
        var env = down.sandbox.environment
        env["KINHIN_OPENVERSE_URL"] = endpoint
        let result = try await Shell.run(
            E2E.kinhinBinary, ["video", "music", "search", "lofi"], environment: env, timeout: 60)
        #expect(result.status == 4, "exit \(result.status): \(result.output)")
        #expect(result.output.contains("could not reach the music library"), "\(result.output)")
    }

    @Test("a number needs a search first, and a stale number says how many results there were")
    func numbersNeedASearch() async throws {
        try await withWorld { world in
            try world.write(".kinhin/videos/launch.yml", "name: x\n")
            let early = try await world.kinhin(["video", "music", "add", "1"])
            #expect(early.status == 2 && early.output.contains("search"), "\(early.output)")
            _ = try await world.kinhin(["video", "music", "search", "piano"])
            let stale = try await world.kinhin(["video", "music", "add", "9"])
            #expect(stale.status == 2 && stale.output.contains("had"), "\(stale.output)")
        }
    }

    // MARK: a real video

    /// Needs a built video image (`KINHIN_E2E_VIDEO_IMAGE`, for example `kinhin-video:local`) and a container runtime, and
    /// ffmpeg on this machine to make the test track. It builds a real video from a track added with `music add` and checks the
    /// music is in the mix.
    @Test(
        "a video built from a track added with music add has that music mixed in",
        .enabled(
            if: E2E.flag("KINHIN_E2E_VIDEO_IMAGE") != nil && (E2E.dockerAvailable || E2E.appleContainerAvailable)
                && Shell.available("ffmpeg", ["-version"]))
    )
    func buildWithMusic() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ke2e-tone-\(E2E.randomID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tone = directory.appendingPathComponent("tone.mp3")
        let made = try await Shell.run(
            "ffmpeg",
            [
                "-nostdin", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "sine=f=440:d=40", "-b:a", "128k",
                tone.path,
            ],
            timeout: 60)
        try #require(made.ok, "\(made.output)")

        let world = try await world(audio: Data(contentsOf: tone))
        defer { world.dispose() }
        let image = try #require(E2E.flag("KINHIN_E2E_VIDEO_IMAGE"))
        let runtime = E2E.flag("KINHIN_E2E_VIDEO_RUNTIME") ?? (E2E.appleContainerAvailable ? "container" : "docker")

        _ = try await world.kinhin(["video", "init", "launch"])
        _ = try await world.kinhin(["video", "music", "search", "lofi"])
        let added = try await world.kinhin(["video", "music", "add", "1", "--volume", "0.4"])
        #expect(added.ok, "\(added.output)")

        let built = try await world.kinhin(
            ["video", "build", "launch", "--image", image, "--runtime", runtime, "--fast"], timeout: 20 * 60)
        #expect(built.ok, "\(built.output.suffix(1500))")
        #expect(world.exists(".kinhin/videos/out/launch.mp4"))

        let music = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: world.path(".kinhin/videos/out/music.json")))
                as? [String: Any])
        #expect(music["enabled"] as? Bool == true)
        #expect((music["file"] as? String)?.hasSuffix(".kinhin/videos/music/lofi-test-loop.mp3") == true, "\(music)")
        #expect(music["volume"] as? Double == 0.4)

        // The finished mix (voice plus music) is levelled to -16 LUFS.
        let probe = try await Shell.run(
            "ffmpeg",
            [
                "-nostdin", "-hide_banner", "-i", world.path(".kinhin/videos/out/launch.mp4").path, "-af",
                "ebur128=peak=true", "-f", "null", "-",
            ], timeout: 120)
        let loudness = probe.stderr.components(separatedBy: "I:").last?
            .split(separator: " ").first.flatMap { Double($0) }
        let level = try #require(loudness, "no loudness in \(probe.stderr.suffix(300))")
        #expect(abs(level - (-16)) <= 3, "the finished mix should be near -16 LUFS, got \(level)")
    }
}
