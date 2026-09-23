import XCTest
@testable import OrchardKit

/// Covers the Apple-container rows of the setup checklist: config-gated
/// appearance (rows only when `container:` is set), the three CLI health
/// states with their fix actions, and the image-present check.
final class ContainerSetupStatusTests: XCTestCase {
    private func host() -> HostResources {
        HostResources(logicalCores: 10, memoryGB: 64, freeDiskGB: 120, arm64: true)
    }

    private func config(container: OrchardConfig.ContainerConfig? = OrchardConfig.ContainerConfig(image: "orchard-ci-linux")) -> OrchardConfig {
        var cfg = OrchardConfig.default
        cfg.repo = "acme/widgets"
        cfg.container = container
        return cfg
    }

    private func computer(
        containerHealth: RuntimeHealth?,
        containerImages: [String]? = nil,
        container: OrchardConfig.ContainerConfig? = OrchardConfig.ContainerConfig(image: "orchard-ci-linux")
    ) -> SetupStatusComputer {
        SetupStatusComputer(
            host: host(),
            clt: .ok(version: "27.0"),
            tartHealth: .healthy,
            tartList: [TartVM(name: "tahoe-base", source: "ghcr.io/cirruslabs/macos-tahoe-base:latest", status: "suspended", cpu: nil, memoryMB: nil)],
            config: .loaded(config(container: container)),
            tokenStored: true,
            containerHealth: containerHealth,
            containerImages: containerImages
        )
    }

    func testNoContainerRowsWhenConfigLacksContainerSection() async {
        let status = await computer(containerHealth: .ready, container: nil).compute()
        XCTAssertNil(status.checks.first { $0.id == "container-cli" })
        XCTAssertNil(status.checks.first { $0.id == "container-image" })
        XCTAssertEqual(status.ready, true, "the checklist stays green with no container config")
    }

    func testRowOrderAppendsContainerRowsAfterImage() async {
        let status = await computer(containerHealth: .ready, containerImages: ["orchard-ci-linux"]).compute()
        XCTAssertEqual(status.checks.map(\.id),
                       ["arch", "clt", "tart", "config", "token", "image", "container-cli", "container-image"])
        XCTAssertEqual(status.ready, true)
    }

    func testMissingCLIEmitsInstallAction() async {
        let status = await computer(containerHealth: .missing(tool: "apple container", fix: "brew")).compute()
        let row = status.checks.first { $0.id == "container-cli" }
        XCTAssertEqual(row?.ok, false)
        XCTAssertEqual(row?.action, "install_container_cli")
        XCTAssertFalse(status.ready)
        // The image row appears too, gated on the health state.
        let imageRow = status.checks.first { $0.id == "container-image" }
        XCTAssertEqual(imageRow?.action, "prepare_container_image")
        XCTAssertTrue(imageRow?.detail.contains("after the container system is running") ?? false)
    }

    func testServiceDownEmitsStartAction() async {
        let status = await computer(containerHealth: .broken("the container system service is not running")).compute()
        let row = status.checks.first { $0.id == "container-cli" }
        XCTAssertEqual(row?.action, "start_container_system")
        XCTAssertEqual(SetupAction.title(for: "start_container_system"), "Start container system")
    }

    func testReadyCLIGreenWithImagePresent() async {
        let status = await computer(containerHealth: .ready, containerImages: ["orchard-ci-linux"]).compute()
        let row = status.checks.first { $0.id == "container-cli" }
        XCTAssertEqual(row?.ok, true)
        XCTAssertNil(row?.action)
        let imageRow = status.checks.first { $0.id == "container-image" }
        XCTAssertEqual(imageRow?.ok, true, "image list matching the config name should be ok")
        XCTAssertNil(imageRow?.action)
    }

    func testImageMissingEmitsPrepareAction() async {
        let status = await computer(containerHealth: .ready, containerImages: ["ubuntu:24.04"]).compute()
        let imageRow = status.checks.first { $0.id == "container-image" }
        XCTAssertEqual(imageRow?.ok, false)
        XCTAssertEqual(imageRow?.action, "prepare_container_image")
        XCTAssertTrue(imageRow?.detail.contains("orchard-ci-linux") ?? false)
        XCTAssertEqual(SetupAction.title(for: "prepare_container_image"), "Prepare Container Image")
    }

    func testImageListMatchingHandlesTaggedReferences() async {
        // A locally tagged reference like "orchard-ci-linux:latest" matches
        // the bare config name — pinned so the row doesn't nag over tags.
        let status = await computer(containerHealth: .ready, containerImages: ["orchard-ci-linux:latest"]).compute()
        let imageRow = status.checks.first { $0.id == "container-image" }
        XCTAssertEqual(imageRow?.ok, true)
    }

    func testLocalImageNamesParsesQuietOutput() async {
        let shell = RecordingShell()
        shell.result = ShellResult(exitCode: 0, stdout: "orchard-ci-linux:latest\nubuntu:24.04\n", stderr: "")
        let runtime = AppleContainerRuntime(shell: shell, binPath: "/usr/local/bin/container")
        let names = await runtime.localImageNames()
        XCTAssertEqual(names, ["orchard-ci-linux:latest", "ubuntu:24.04"])
        XCTAssertEqual(shell.argvs.first?.last, "--quiet")
        XCTAssertTrue(shell.argvs.first?.contains("image") ?? false)
    }
}
