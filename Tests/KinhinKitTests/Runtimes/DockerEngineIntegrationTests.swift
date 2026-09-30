import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

// MARK: - Config

final class DockerEngineIntegrationTests: XCTestCase {

    func waitUntil(timeout: TimeInterval, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }

    func testDockerConfigParsingAndValidation() throws {
        let cfg = try ConfigLoader.parse(
            """
            accounts:
              - name: github
                forge: github
                scope: "acme"
            labels: ["kinhin"]
            docker:
              image: "ghcr.io/acme/kinhin-ci-linux"
              cpus: 2
              memory_gb: 4
              max_slots: 6
            """)
        let docker = try XCTUnwrap(cfg.docker)
        XCTAssertEqual(docker.image, "ghcr.io/acme/kinhin-ci-linux")
        XCTAssertEqual(docker.cpus, 2)
        XCTAssertEqual(docker.memoryGB, 4)
        XCTAssertEqual(docker.maxSlots, 6)

        XCTAssertThrowsError(
            try ConfigLoader.parse(
                """
                accounts:
                  - name: github
                    forge: github
                    scope: "acme"
                labels: ["kinhin"]
                docker:
                  image: ""
                """)
        ) { error in
            XCTAssertTrue("\(error)".contains("docker.image must not be empty"), "\(error)")
        }
        XCTAssertThrowsError(
            try ConfigLoader.parse(
                """
                accounts:
                  - name: github
                    forge: github
                    scope: "acme"
                labels: ["kinhin"]
                docker:
                  cpus: 0
                """)
        ) { error in
            XCTAssertTrue("\(error)".contains("docker.image must not be empty"), "\(error)")
        }
        XCTAssertThrowsError(
            try ConfigLoader.parse(
                """
                accounts:
                  - name: github
                    forge: github
                    scope: "acme"
                labels: ["kinhin"]
                docker:
                  image: "img"
                  max_slots: 0
                """)
        ) { error in
            XCTAssertTrue("\(error)".contains("docker.max_slots must be >= 1"), "\(error)")
        }
    }

    // MARK: - Engine integration

    func testEngineWithDockerConfigRunsDockerLifecycle() async throws {
        let shell = DockerFakingShell()
        var config = makeTestConfig()
        config.docker = .init(image: "ghcr.io/acme/kinhin-ci-linux", cpus: 2, memoryGB: 4)
        let github = FakeGitHub()
        github.queueDepth = 1
        let ssh = FakeSSH()
        let engine = FleetEngine(
            config: config, github: github, tart: FakeTart(),
            store: makeTestStore(), ssh: ssh, host: testHost,
            containerShell: shell
        )

        // Spawn: a record appears stamped with the docker runtime.
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            let status = await engine.status()
            let phase = status.records.first?.phase
            return phase == .registering || phase == .ready
        }
        let status = await engine.status()
        let record = try XCTUnwrap(status.records.first)
        XCTAssertEqual(record.runtime, RuntimeID.docker.rawValue)
        XCTAssertEqual(
            status.runtime, RuntimeID.docker.rawValue, "docker is the primary runtime when only docker: is configured")
        XCTAssertNil(record.ip, "docker records carry no IP — there is no SSH transport")

        // The lifecycle used docker run/exec (provision) and exec (registration).
        let argvs = shell.argvSnapshot()
        XCTAssertTrue(argvs.contains { $0.contains("run") && $0.contains("--name") })
        XCTAssertTrue(argvs.contains { $0.contains("exec") && $0.contains("/bin/bash") })
        // And never SSH'd (the docker path has no SSH transport).
        XCTAssertTrue(ssh.scripts.isEmpty, "SSH transport must be unused")
    }

    func testEngineWithoutDockerConfigKeepsTartLifecycle() async throws {
        let github = FakeGitHub()
        github.queueDepth = 1
        let tart = FakeTart()
        let ssh = FakeSSH()
        let engine = FleetEngine(
            config: makeTestConfig(), github: github, tart: tart,
            store: makeTestStore(), ssh: ssh, host: testHost
        )
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            let status = await engine.status()
            return status.records.first?.phase == .registering || status.records.first?.phase == .ready
        }
        let status = await engine.status()
        XCTAssertEqual(status.runtime, RuntimeID.tart.rawValue)
        XCTAssertTrue(!ssh.scripts.isEmpty, "tart lifecycle registers over SSH")
    }
}
