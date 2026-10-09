import XCTest

@testable import KinhinKit

final class BenchmarkScriptsTests: XCTestCase {
    private func runAsGuestWould(_ script: String) async throws -> ShellResult {
        // The guest receives the script on the stdin of `bash -s`, exactly like this.
        try await Shell().run(["/bin/bash", "-s"], input: Data(script.utf8), cwd: nil, timeout: 30)
    }

    func testAChildReadingStdinSwallowsTheRestOfAnUnwrappedScript() async throws {
        // The failure the wrapper exists for: found when `brew install` ate a toolchain install's last steps.
        let script = "cat > /dev/null\necho after\n"
        let raw = try await runAsGuestWould(script)
        XCTAssertFalse(raw.stdout.contains("after"), "the unwrapped script lost its tail: \(raw.stdout)")
    }

    func testTheWrapperRunsEveryLineAndKeepsTheExitStatus() async throws {
        let script = "cat > /dev/null\necho after\nexit 7\n"
        let wrapped = try await runAsGuestWould(BenchmarkScripts.isolatingStdin(script))
        XCTAssertEqual(wrapped.stdout, "after\n")
        XCTAssertEqual(wrapped.exitCode, 7)
    }

    func testTheWrapperKeepsQuotingAndHeredocsIntact() async throws {
        let script = """
            cat > t.txt <<'EOF'
            it's $HOME "quoted" \\n
            EOF
            cat t.txt
            rm t.txt
            """
        let result = try await runAsGuestWould(BenchmarkScripts.isolatingStdin(script))
        XCTAssertEqual(result.stdout, "it's $HOME \"quoted\" \\n\n")
    }

    func testTheSkipExitCodePassesThrough() async throws {
        let result = try await runAsGuestWould(BenchmarkScripts.isolatingStdin("echo why\nexit 77\n"))
        XCTAssertEqual(result.exitCode, BenchmarkScripts.skipExitCode)
        XCTAssertEqual(result.stdout, "why\n")
    }

    func testTheTemporaryScriptIsRemoved() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wrapped = "export TMPDIR=\(BenchmarkScripts.quote(dir.path))\n" + BenchmarkScripts.isolatingStdin("true")
        _ = try await runAsGuestWould(wrapped)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }
}
