import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Where Apple's `container` came from and how it is signed: the facts `kinhin doctor` uses to warn that an ad-hoc
/// build with its data on an external volume loses its privacy grants on every upgrade (#106).
final class AppleContainerInstallTests: XCTestCase {
    // What `codesign -dv --verbose=2` prints (on stderr) for each kind of build.
    private let adhoc = """
        Executable=/opt/homebrew/Cellar/container/1.6.1/libexec/container
        Identifier=container
        Format=Mach-O thin (arm64)
        CodeDirectory v=20400 size=12345 flags=0x20002(adhoc,linker-signed) hashes=380+0 location=embedded
        Signature=adhoc
        Info.plist=not bound
        TeamIdentifier=not set
        """
    private let developerID = """
        Executable=/usr/local/bin/container
        Identifier=com.apple.container.cli
        Format=Mach-O thin (arm64)
        Authority=Developer ID Application: Apple Inc. (ABCDE12345)
        Authority=Developer ID Certification Authority
        Authority=Apple Root CA
        TeamIdentifier=ABCDE12345
        """

    // MARK: - Classification

    func testTheSourceComesFromTheResolvedPath() {
        func source(_ path: String) -> AppleContainerInstall.Source {
            AppleContainerInstall.classifySource(ofResolvedPath: path)
        }
        XCTAssertEqual(source("/opt/homebrew/Cellar/container/1.6.1/libexec/container"), .homebrew)
        XCTAssertEqual(source("/usr/local/Cellar/container/1.6.1/bin/container"), .homebrew)
        XCTAssertEqual(source("/usr/local/bin/container"), .installer)
        XCTAssertEqual(source("/Users/me/src/container/bin/container"), .other)
    }

    func testCodesignOutputGivesTheSignature() {
        XCTAssertEqual(AppleContainerInstall.classifySignature(fromCodesign: adhoc, succeeded: true).0, .adhoc)
        let signed = AppleContainerInstall.classifySignature(fromCodesign: developerID, succeeded: true)
        XCTAssertEqual(signed.0, .developerID)
        XCTAssertEqual(signed.1, "ABCDE12345")
        XCTAssertEqual(
            AppleContainerInstall.classifySignature(
                fromCodesign: "/x/container: code object is not signed at all", succeeded: false
            ).0, .unsigned)
        XCTAssertEqual(AppleContainerInstall.classifySignature(fromCodesign: "boom", succeeded: false).0, .unknown)
    }

    // MARK: - Warnings

    private func install(_ signature: AppleContainerInstall.Signature, external: Bool) -> AppleContainerInstall {
        AppleContainerInstall(
            binaryPath: "/opt/homebrew/Cellar/container/1.6.1/libexec/container",
            source: signature == .developerID ? .installer : .homebrew, signature: signature,
            teamID: signature == .developerID ? "ABCDE12345" : nil,
            appRoot: external ? "/Volumes/Fast/container" : "/Users/me/Library/Application Support/com.apple.container",
            appRootExternal: external)
    }

    func testAnAdhocBuildWithExternalDataIsWarnedAbout() throws {
        let warning = try XCTUnwrap(install(.adhoc, external: true).warning)
        XCTAssertTrue(warning.contains("`brew upgrade container` drops those grants"), warning)
        XCTAssertTrue(warning.contains(AppleContainerInstall.installerURL), warning)
        XCTAssertTrue(warning.contains("launchd, not kinhin"), warning)
        XCTAssertNil(install(.adhoc, external: true).note)
        XCTAssertTrue(install(.adhoc, external: true).summaryLine.hasSuffix(" ⚠"))
    }

    func testAnAdhocBuildOnTheInternalDiskGetsOnlyANote() {
        XCTAssertNil(install(.adhoc, external: false).warning)
        XCTAssertNotNil(install(.adhoc, external: false).note)
        XCTAssertEqual(
            install(.adhoc, external: false).summaryLine, "Homebrew, ad-hoc signed, data on internal disk ✓")
    }

    func testTheSignedInstallerIsNeverWarnedAbout() {
        let signed = install(.developerID, external: true)
        XCTAssertNil(signed.warning)
        XCTAssertNil(signed.note)
        XCTAssertEqual(
            signed.summaryLine,
            "signed installer, Developer ID (ABCDE12345), data on external volume /Volumes/Fast/container ✓")
    }

    // MARK: - Probe

    func testTheProbeAsksCodesignAboutTheResolvedBinary() async throws {
        let shell = FakeShell()
        shell.defaultResult = ShellResult(exitCode: 0, stdout: "", stderr: adhoc)
        let probed = try await XCTUnwrap(
            AppleContainerInstall.probe(
                shell: shell, binary: "/opt/homebrew/Cellar/container/1.6.1/libexec/container",
                appRoot: URL(fileURLWithPath: "/Volumes/Fast/container"), isExternal: { _ in true }))
        XCTAssertEqual(probed.source, .homebrew)
        XCTAssertEqual(probed.signature, .adhoc)
        XCTAssertTrue(probed.appRootExternal)
        XCTAssertEqual(shell.calls.first?.prefix(3), ["/usr/bin/codesign", "-dv", "--verbose=2"])
        XCTAssertNotNil(probed.warning)
    }

    func testTheProbeIsNilWithoutTheCLIAndUnknownWhenCodesignCannotRun() async throws {
        let none = await AppleContainerInstall.probe(shell: FakeShell(), binary: nil)
        XCTAssertNil(none)
        let shell = FakeShell()
        shell.throwOnRun = true
        let probed = try await XCTUnwrap(
            AppleContainerInstall.probe(
                shell: shell, binary: "/usr/local/bin/container", appRoot: URL(fileURLWithPath: "/tmp"),
                isExternal: { _ in false }))
        XCTAssertEqual(probed.signature, .unknown)
        XCTAssertNil(probed.warning)
    }

    func testAPathUnderVolumesIsExternal() {
        XCTAssertTrue(AppleContainerInstall.isExternalVolume(URL(fileURLWithPath: "/Volumes/Fast/container")))
    }
}
