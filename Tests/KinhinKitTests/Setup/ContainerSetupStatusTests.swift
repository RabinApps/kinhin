import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Covers the Apple-container rows of the setup checklist: config-gated
/// appearance (rows only when `container:` is set), the three CLI health
/// states with their fix actions, and the image-present check.
final class ContainerSetupStatusTests: XCTestCase {
    private func host() -> HostResources {
        HostResources(logicalCores: 10, memoryGB: 64, freeDiskGB: 120, arm64: true)
    }

    private func config(
        container: KinhinConfig.ContainerConfig? = KinhinConfig.ContainerConfig(image: "kinhin-ci-linux")
    ) -> KinhinConfig {
        var cfg = KinhinConfig.default
        cfg.repo = "acme/widgets"
        cfg.container = container
        return cfg
    }

    private func computer(
        containerHealth: RuntimeHealth?,
        containerImages: [String]? = nil,
        container: KinhinConfig.ContainerConfig? = KinhinConfig.ContainerConfig(image: "kinhin-ci-linux"),
        host: HostResources? = nil,
        macOS: Int = 26
    ) -> SetupStatusComputer {
        SetupStatusComputer(
            host: host ?? self.host(),
            clt: .ok(version: "27.0"),
            tartHealth: .healthy,
            tartList: [
                TartVM(
                    name: "tahoe-base", source: "ghcr.io/cirruslabs/macos-tahoe-base:latest", status: "suspended",
                    cpu: nil, memoryMB: nil)
            ],
            config: .loaded(config(container: container)),
            tokenStored: true,
            containerHealth: containerHealth,
            containerImages: containerImages,
            osVersion: OperatingSystemVersion(majorVersion: macOS, minorVersion: 0, patchVersion: 0)
        )
    }

    func testNoContainerRowsWhenConfigLacksContainerSection() async {
        let status = await computer(containerHealth: .ready, container: nil).compute()
        XCTAssertNil(status.checks.first { $0.id == "container-cli" })
        XCTAssertNil(status.checks.first { $0.id == "container-image" })
        XCTAssertEqual(status.ready, true, "the checklist stays green with no container config")
    }

    func testRowOrderAppendsContainerRowsAfterImage() async {
        let status = await computer(containerHealth: .ready, containerImages: ["kinhin-ci-linux"]).compute()
        XCTAssertEqual(
            status.checks.map(\.id),
            ["arch", "clt", "tart", "config", "token", "image", "container-cli", "container-image", "toolchain-cache"])
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

    func testMissingCLIOnAnUnsupportedMacExplainsInsteadOfOfferingAnInstall() async {
        let intel = HostResources(logicalCores: 8, memoryGB: 16, freeDiskGB: 120, arm64: false)
        let missing = RuntimeHealth.missing(tool: "apple container", fix: "brew")
        for status in [
            await computer(containerHealth: missing, host: intel).compute(),
            await computer(containerHealth: missing, macOS: 15).compute(),
        ] {
            let row = status.checks.first { $0.id == "container-cli" }
            XCTAssertEqual(row?.ok, false)
            XCTAssertNil(row?.action, "no install button for something that can't run here")
            XCTAssertTrue(row?.detail.contains("Apple container needs") ?? false, row?.detail ?? "")
        }
    }

    func testServiceDownEmitsStartAction() async {
        let status = await computer(containerHealth: .broken("the container system service is not running")).compute()
        let row = status.checks.first { $0.id == "container-cli" }
        XCTAssertEqual(row?.action, "start_container_system")
        XCTAssertEqual(SetupAction.title(for: "start_container_system"), "Start container system")
    }

    func testReadyCLIGreenWithImagePresent() async {
        let status = await computer(containerHealth: .ready, containerImages: ["kinhin-ci-linux"]).compute()
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
        XCTAssertTrue(imageRow?.detail.contains("kinhin-ci-linux") ?? false)
        XCTAssertEqual(SetupAction.title(for: "prepare_container_image"), "Prepare Container Image")
    }

    func testImageListMatchingHandlesTaggedReferences() async {
        // A locally tagged reference like "kinhin-ci-linux:latest" matches
        // the bare config name — pinned so the row doesn't nag over tags.
        let status = await computer(containerHealth: .ready, containerImages: ["kinhin-ci-linux:latest"]).compute()
        let imageRow = status.checks.first { $0.id == "container-image" }
        XCTAssertEqual(imageRow?.ok, true)
    }

    func testLocalImageNamesParsesQuietOutput() async {
        let shell = FakeShell()
        shell.defaultResult = ShellResult(exitCode: 0, stdout: "kinhin-ci-linux:latest\nubuntu:24.04\n", stderr: "")
        let runtime = AppleContainerRuntime(shell: shell, binPath: "/usr/local/bin/container")
        let names = await runtime.localImageNames()
        XCTAssertEqual(names, ["kinhin-ci-linux:latest", "ubuntu:24.04"])
        XCTAssertEqual(shell.calls.first?.last, "--quiet")
        XCTAssertTrue(shell.calls.first?.contains("image") ?? false)
    }
}

final class ContainerKernelTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-kernels-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: detection

    func testKernelIsMissingFromAnEmptyOrAbsentDirectory() throws {
        XCTAssertFalse(AppleContainerRuntime.hasInstalledKernel(in: dir))
        XCTAssertFalse(AppleContainerRuntime.hasInstalledKernel(in: dir.appendingPathComponent("nope")))
        try Data().write(to: dir.appendingPathComponent(".DS_Store"))
        XCTAssertFalse(AppleContainerRuntime.hasInstalledKernel(in: dir), "hidden files are not kernels")
    }

    func testKernelIsPresentWhenTheDirectoryHoldsOne() throws {
        try Data().write(to: dir.appendingPathComponent("default.kernel-arm64"))
        XCTAssertTrue(AppleContainerRuntime.hasInstalledKernel(in: dir))
    }

    // MARK: install

    func testInstallRunsTheRecommendedKernelCommand() async throws {
        let shell = FakeShell()
        try await AppleContainerRuntime.installKernel(shell: shell, binary: "/bin/container")
        XCTAssertEqual(shell.calls, [["/bin/container", "system", "kernel", "set", "--recommended"]])
    }

    func testInstallFailureCarriesTheCLIsLastLine() async {
        let shell = FakeShell()
        shell.defaultResult = ShellResult(exitCode: 1, stdout: "", stderr: "progress...\nError: download failed")
        do {
            try await AppleContainerRuntime.installKernel(shell: shell, binary: "/bin/container")
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("download failed"), error.localizedDescription)
            XCTAssertFalse(error.localizedDescription.contains("progress"))
        }
    }

    // MARK: checklist

    private func status(kernel: Bool?) async -> SetupStatus {
        var cfg = KinhinConfig.default
        cfg.repo = "acme/widgets"
        cfg.container = KinhinConfig.ContainerConfig(image: "kinhin-ci-linux")
        return await SetupStatusComputer(
            host: HostResources(logicalCores: 10, memoryGB: 64, freeDiskGB: 120, arm64: true),
            clt: .ok(version: "27.0"), tartHealth: .healthy, tartList: [], config: .loaded(cfg), tokenStored: true,
            containerHealth: .ready, containerImages: ["kinhin-ci-linux"], containerKernelInstalled: kernel
        ).compute()
    }

    func testMissingKernelAddsARowWithAnInstallAction() async {
        let row = await status(kernel: false).checks.first { $0.id == "container-kernel" }
        XCTAssertEqual(row?.ok, false)
        XCTAssertEqual(row?.action, "install_container_kernel")
        XCTAssertEqual(SetupAction.title(for: "install_container_kernel"), "Install Linux kernel")
    }

    func testInstalledKernelAddsNoRow() async {
        let checks = await status(kernel: true).checks
        XCTAssertNil(checks.first { $0.id == "container-kernel" })
    }

    func testInjectedHealthAssumesAKernelSoFixturesStayHermetic() async {
        let checks = await status(kernel: nil).checks
        XCTAssertNil(checks.first { $0.id == "container-kernel" })
    }
}
