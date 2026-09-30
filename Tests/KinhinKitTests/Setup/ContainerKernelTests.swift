import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class ContainerKernelTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-kernels-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - detection

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

    // MARK: - install

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

    // MARK: - checklist

    private func status(kernel: Bool?) async -> SetupStatus {
        var cfg = KinhinConfig.default
        cfg.accounts = [AccountConfig(name: "github", forge: .github, scope: "acme/widgets")]
        cfg.container = KinhinConfig.ContainerConfig(image: "kinhin-ci-linux")
        return await SetupStatusComputer(
            host: HostResources(logicalCores: 10, memoryGB: 64, freeDiskGB: 120, arm64: true),
            clt: .ok(version: "27.0"), tartHealth: .healthy, tartList: [], config: .loaded(cfg),
            accountTokensStored: ["github": true],
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
