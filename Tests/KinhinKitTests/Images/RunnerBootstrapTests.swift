import XCTest

@testable import KinhinKit

final class RunnerBootstrapTests: XCTestCase {
    // MARK: - bootstrap scripts
    func testRegistrationScriptContainsEssentials() {
        let script = RunnerBootstrap.registrationScript(
            configureURL: "https://github.com/acme/widgets",
            token: "SECRET",
            labels: ["macos", "kinhin"],
            ephemeral: true,
            name: "kinhin-1"
        )
        XCTAssertTrue(script.contains("--url https://github.com/acme/widgets"))
        XCTAssertTrue(script.contains("SECRET"))
        XCTAssertTrue(script.contains("--labels 'macos,kinhin'"))
        XCTAssertTrue(script.contains("--name 'kinhin-1'"))
        XCTAssertTrue(script.contains("--ephemeral"))
        XCTAssertTrue(script.contains("./run.sh"))
    }

    func testNonEphemeralScriptOmitsFlag() {
        let script = RunnerBootstrap.registrationScript(
            configureURL: "https://github.com/a/b", token: "t", labels: ["x"], ephemeral: false, name: "n"
        )
        XCTAssertFalse(script.contains("--ephemeral"))
    }

    // MARK: - many-to-one (runners_per_vm)
    func testMultiRunnerScriptRegistersNRunnersWithIndexedNames() {
        let script = RunnerBootstrap.registrationScript(
            configureURL: "https://github.com/acme/widgets",
            token: "SECRET",
            labels: ["macos"],
            ephemeral: true,
            name: "kinhin-9",
            runnerCount: 3
        )
        for index in 1...3 {
            XCTAssertTrue(script.contains("--name 'kinhin-9-r\(index)'"), "missing runner \(index) name")
            XCTAssertTrue(script.contains("cd ~/actions-runner-\(index)"), "missing runner \(index) dir")
            XCTAssertTrue(script.contains("--work _work-\(index)"), "missing runner \(index) work dir")
            XCTAssertTrue(script.contains("run-\(index).log"), "missing runner \(index) log")
        }
        // Three separate registrations (remove + register per runner), three
        // detached processes.
        XCTAssertEqual(script.components(separatedBy: "config.sh --url").count - 1, 3)
        XCTAssertEqual(script.components(separatedBy: "config.sh remove").count - 1, 3)
        XCTAssertEqual(script.components(separatedBy: "nohup ./run.sh").count - 1, 3)
        XCTAssertTrue(script.contains("3 runners started"))
        // Single-runner dir must NOT appear (it would collide with index 1's).
        XCTAssertTrue(script.contains("cd ~/actions-runner-1"))
        XCTAssertFalse(script.contains("cd ~/actions-runner\n"))
    }

    func testSingleRunnerScriptUnchangedByCountParameter() {
        let legacy = RunnerBootstrap.registrationScript(
            configureURL: "https://github.com/a/b", token: "t", labels: ["x"], ephemeral: true, name: "vm"
        )
        let explicit = RunnerBootstrap.registrationScript(
            configureURL: "https://github.com/a/b", token: "t", labels: ["x"], ephemeral: true, name: "vm",
            runnerCount: 1
        )
        XCTAssertEqual(legacy, explicit)
        XCTAssertFalse(legacy.contains("actions-runner-"))
    }

    func testInstallScriptPrecreatesAgentDirsForDensity() {
        let script = RunnerBootstrap.installScript(runnerVersion: "2.319.1", runnerCount: 2)
        XCTAssertTrue(script.contains("mkdir -p \"$HOME/actions-runner\""), "base agent dir")
        XCTAssertTrue(script.contains("mkdir -p \"$HOME/actions-runner-2\""), "second agent dir")
        XCTAssertEqual(script.components(separatedBy: "curl -sL").count - 1, 2, "one download per dir")
    }
}

/// The Linux install scripts run in a bare base image (ubuntu has no curl or
/// CA certificates), so each must install what it downloads with first.
final class LinuxPrerequisitesTests: XCTestCase {
    private var scripts: [(name: String, script: String)] {
        [
            ("github agent", RunnerBootstrap.linuxGitHubAgentInstallScript(runnerVersion: "2.337.0")),
            ("gitea runner", RunnerBootstrap.linuxGiteaRunnerInstallScript(version: "0.2.0")),
            (
                "toolchains",
                RunnerBootstrap.linuxManagedToolchainsInstallScript(
                    selection: ManagedToolchainSelection(), mountPath: nil)
            ),
        ]
    }

    func testEveryScriptInstallsCurlAndCertificatesBeforeDownloading() {
        for (name, script) in scripts {
            let prerequisites = script.range(of: "apt-get install -y --no-install-recommends $need")
            XCTAssertNotNil(prerequisites, "\(name) must install its prerequisites")
            XCTAssertTrue(script.contains("command -v curl"), "\(name) must check for curl")
            XCTAssertTrue(script.contains("ca-certificates"), "\(name) must ensure CA certificates")
            if let prerequisites, let download = script.range(of: "curl -") {
                XCTAssertLessThan(prerequisites.lowerBound, download.lowerBound, "\(name): install before curl runs")
            }
        }
        XCTAssertTrue(scripts[1].script.contains("xz-utils"), "the gitea runner ships as .xz")
    }

    func testScriptsAreValidBashSyntax() async throws {
        for (name, script) in scripts {
            let result = try await Shell().run(["/bin/bash", "-n", "-c", script], cwd: nil, timeout: 10)
            XCTAssertTrue(result.succeeded, "\(name): \(result.stderr)")
        }
    }

    func testPrerequisitesAreANoOpWhenEverythingIsPresent() async throws {
        // `true`, `sh`, and `ls` exist everywhere; with the certificate check
        // satisfied the script must not touch apt.
        let script = RunnerBootstrap.linuxPrerequisitesScript(tools: [("sh", "dash"), ("ls", "coreutils")])
            .replacingOccurrences(of: "/etc/ssl/certs/ca-certificates.crt", with: "/etc/hosts")
            .replacingOccurrences(of: "apt-get", with: "false-apt-get-should-not-run")
        let result = try await Shell().run(["/bin/bash", "-c", script], cwd: nil, timeout: 10)
        XCTAssertTrue(result.succeeded, result.stderr)
    }
}

final class LinuxMisePathTests: XCTestCase {
    func testMiseShimsArePersistedForLoginShells() async throws {
        var selection = ManagedToolchainSelection()
        selection.miseSpecs = ["node@22"]
        let script = RunnerBootstrap.linuxManagedToolchainsInstallScript(selection: selection, mountPath: nil)
        XCTAssertTrue(script.contains("/etc/profile.d/kinhin-mise.sh"))
        // The line must produce a valid profile snippet: run just that line against a temp file.
        let line = try XCTUnwrap(script.split(separator: "\n").first { $0.contains("> /etc/profile.d/kinhin-mise.sh") })
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinhin-mise-\(UUID().uuidString).sh")
        defer { try? FileManager.default.removeItem(at: target) }
        let redirected = line.replacingOccurrences(of: "/etc/profile.d/kinhin-mise.sh", with: target.path)
        let result = try await Shell().run(["/bin/bash", "-c", redirected], cwd: nil, timeout: 10)
        XCTAssertTrue(result.succeeded, result.stderr)
        let written = try String(contentsOf: target, encoding: .utf8)
        XCTAssertEqual(written, "export PATH=\"$HOME/.local/share/mise/shims:$PATH\"\n")
    }
}
