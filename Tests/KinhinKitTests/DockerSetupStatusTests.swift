import XCTest

@testable import KinhinKit

/// Covers the Docker rows of the setup checklist: config-gated appearance
/// (rows only when `docker:` is set), the daemon health states with their fix
/// actions, the image-present check, and the doctor's docker section.
final class DockerSetupStatusTests: XCTestCase {
    private func host() -> HostResources {
        HostResources(logicalCores: 10, memoryGB: 64, freeDiskGB: 120, arm64: true)
    }

    private func config(
        docker: kinhinConfig.DockerForgeConfig? = kinhinConfig.DockerForgeConfig(image: "ghcr.io/acme/kinhin-ci-linux")
    ) -> kinhinConfig {
        var cfg = kinhinConfig.default
        cfg.repo = "acme/widgets"
        cfg.docker = docker
        return cfg
    }

    private func computer(
        dockerHealth: RuntimeHealth?,
        dockerImages: [String]? = nil,
        docker: kinhinConfig.DockerForgeConfig? = kinhinConfig.DockerForgeConfig(image: "ghcr.io/acme/kinhin-ci-linux")
    ) -> SetupStatusComputer {
        SetupStatusComputer(
            host: host(),
            clt: .ok(version: "27.0"),
            tartHealth: .healthy,
            tartList: [
                TartVM(
                    name: "tahoe-base", source: "ghcr.io/cirruslabs/macos-tahoe-base:latest", status: "suspended",
                    cpu: nil, memoryMB: nil)
            ],
            config: .loaded(config(docker: docker)),
            tokenStored: true,
            dockerHealth: dockerHealth,
            dockerImages: dockerImages
        )
    }

    // MARK: - Checklist rows

    func testNoDockerRowsWhenConfigLacksDockerSection() async {
        let status = await computer(dockerHealth: .ready, docker: nil).compute()
        XCTAssertNil(status.checks.first { $0.id == "docker-cli" })
        XCTAssertNil(status.checks.first { $0.id == "docker-image" })
        XCTAssertEqual(status.ready, true, "the checklist stays green with no docker config")
    }

    func testRowOrderAppendsDockerRowsAfterImage() async {
        let status = await computer(dockerHealth: .ready, dockerImages: ["ghcr.io/acme/kinhin-ci-linux:latest"])
            .compute()
        XCTAssertEqual(
            status.checks.map(\.id),
            ["arch", "clt", "tart", "config", "token", "image", "docker-cli", "docker-image", "toolchain-cache"])
        XCTAssertEqual(status.ready, true)
    }

    func testMissingCLIEmitsInstallAction() async {
        let status = await computer(dockerHealth: .missing(tool: "docker", fix: "install Docker Desktop")).compute()
        let row = status.checks.first { $0.id == "docker-cli" }
        XCTAssertEqual(row?.ok, false)
        XCTAssertEqual(row?.action, "install_container_cli", "docker reuses the container-install repair handler")
        XCTAssertFalse(status.ready)
        let imageRow = status.checks.first { $0.id == "docker-image" }
        XCTAssertEqual(imageRow?.action, "prepare_docker_image")
        XCTAssertTrue(imageRow?.detail.contains("after the Docker daemon is reachable") ?? false)
    }

    func testBrokenDaemonShowsReasonWithNoAction() async {
        let status = await computer(dockerHealth: .broken("the Docker daemon is not reachable — start Docker Desktop"))
            .compute()
        let row = status.checks.first { $0.id == "docker-cli" }
        XCTAssertEqual(row?.ok, false)
        XCTAssertTrue(row?.detail.contains("daemon is not reachable") ?? false)
        let imageRow = status.checks.first { $0.id == "docker-image" }
        XCTAssertEqual(imageRow?.action, "prepare_docker_image")
        XCTAssertFalse(status.ready)
    }

    func testReadyDaemonGreenWithImagePresent() async {
        let status = await computer(dockerHealth: .ready, dockerImages: ["ghcr.io/acme/kinhin-ci-linux:latest"])
            .compute()
        let row = status.checks.first { $0.id == "docker-cli" }
        XCTAssertEqual(row?.ok, true)
        XCTAssertNil(row?.action)
        let imageRow = status.checks.first { $0.id == "docker-image" }
        XCTAssertEqual(imageRow?.ok, true, "tagged local references match the config name")
        XCTAssertNil(imageRow?.action)
    }

    func testImageMissingEmitsPrepareAction() async {
        let status = await computer(dockerHealth: .ready, dockerImages: ["ubuntu:24.04"]).compute()
        let imageRow = status.checks.first { $0.id == "docker-image" }
        XCTAssertEqual(imageRow?.ok, false)
        XCTAssertEqual(imageRow?.action, "prepare_docker_image")
        XCTAssertTrue(imageRow?.detail.contains("ghcr.io/acme/kinhin-ci-linux") ?? false)
        XCTAssertEqual(SetupAction.title(for: "prepare_docker_image"), "Prepare Docker Image")
    }

    // MARK: - Doctor section

    func testDoctorDockerSectionPresentWhenConfigured() async throws {
        let report = try await DoctorReportBuilder(
            host: host(),
            clt: .ok(version: "27.0"),
            tartHealth: .healthy,
            tartList: [],
            config: .loaded(config(docker: .init(image: "ghcr.io/acme/kinhin-ci-linux"))),
            authLoad: { _ in "token" },
            dockerHealth: .broken("daemon down"),
            dockerImages: []
        ).build()
        let docker = try XCTUnwrap(report.docker)
        XCTAssertEqual(docker.state, "broken")
        XCTAssertEqual(docker.ok, false)
        XCTAssertEqual(docker.fix, "daemon down")
        XCTAssertEqual(docker.image, "ghcr.io/acme/kinhin-ci-linux")
        XCTAssertEqual(docker.imageFound, false)
        XCTAssertNil(report.container, "no container: section → no container section")
    }

    func testDoctorDockerSectionReadyWithMissingImageGetsPrepareCommand() async throws {
        let report = try await DoctorReportBuilder(
            host: host(),
            clt: .ok(version: "27.0"),
            tartHealth: .healthy,
            tartList: [],
            config: .loaded(config(docker: .init(image: "ghcr.io/acme/kinhin-ci-linux"))),
            authLoad: { _ in "token" },
            dockerHealth: .ready,
            dockerImages: ["ubuntu:24.04"]
        ).build()
        let docker = try XCTUnwrap(report.docker)
        XCTAssertEqual(docker.state, "ready")
        XCTAssertEqual(docker.imageFound, false)
        XCTAssertEqual(docker.fix, "kinhin image prepare --docker --target ghcr.io/acme/kinhin-ci-linux")
    }

    func testDoctorDockerSectionAbsentWithoutConfig() async throws {
        let report = try await DoctorReportBuilder(
            host: host(),
            clt: .ok(version: "27.0"),
            tartHealth: .healthy,
            tartList: [],
            config: .loaded(config(docker: nil)),
            authLoad: { _ in "token" },
            dockerHealth: .ready,
            dockerImages: ["whatever"]
        ).build()
        XCTAssertNil(report.docker)
    }

    func testDoctorJSONRoundTripsDockerSection() throws {
        let section = DoctorReport.DockerSection(
            state: "ready", ok: true, fix: nil,
            image: "ghcr.io/acme/kinhin-ci-linux", imageFound: true
        )
        let data = try JSONEncoder().encode(["docker": section])
        let decoded = try JSONDecoder().decode(forKey: "docker", of: DoctorReport.DockerSection.self, from: data)
        XCTAssertEqual(decoded, section)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"imageFound\""), "field names stay additive-stable")
    }
}

extension JSONDecoder {
    fileprivate func `decode`<T: Decodable>(forKey key: String, of type: T.Type, from data: Data) throws -> T {
        let container = try JSONDecoder().decode([String: Flexible<T>].self, from: data)
        return try XCTUnwrap(container[key]?.value)
    }
}

private struct Flexible<T: Decodable>: Decodable {
    let value: T
    init(from decoder: Decoder) throws {
        value = try T(from: decoder)
    }
}
