import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class LinuxMisePathTests: XCTestCase {
    func testMiseShimsArePersistedForLoginShells() async throws {
        var selection = ManagedToolchainSelection()
        selection.miseSpecs = ["node@22"]
        let script = RunnerBootstrap.linuxManagedToolchainsInstallScript(selection: selection, mountPath: nil)
        XCTAssertTrue(script.contains("/etc/profile.d/kinhin-mise.sh"))
        // The line must produce a valid profile snippet: run just that line against a temp file.
        let line = try XCTUnwrap(
            script.split(separator: "\n").first { $0.contains("tee /etc/profile.d/kinhin-mise.sh") })
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
