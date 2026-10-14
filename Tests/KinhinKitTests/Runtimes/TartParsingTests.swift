import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class TartParsingTests: XCTestCase {
    func testTartListJSONParsing() throws {
        let json = """
            [{"State":"stopped","Disk":50,"Source":"local","Size":40,"Name":"tahoe-base","Running":false},
             {"State":"running","Disk":50,"Source":"OCI","Size":33,"Name":"ghcr.io/x/y:latest","Running":true}]
            """
        let vms = try TartController.parseListJSON(json)
        XCTAssertEqual(vms.map(\.name), ["tahoe-base", "ghcr.io/x/y:latest"])
        XCTAssertEqual(vms[0].status, "stopped")
        XCTAssertThrowsError(try TartController.parseListJSON("tahoe-base\nother"))
    }

    /// Unreadable JSON plus a names-only `--quiet` listing (newer tart) is an
    /// error, never an empty VM list that makes every image look absent.
    func testListThrowsWhenNeitherListingCanBeRead() async throws {
        let shell = FakeShell()
        shell.scriptedResponses = [
            ScriptedResponse(
                whenContainsAll: ["list", "--format"], ShellResult(exitCode: 0, stdout: "not json", stderr: "")),
            ScriptedResponse(
                whenContainsAll: ["list", "--quiet"], ShellResult(exitCode: 0, stdout: "tahoe-base\n", stderr: "")),
        ]
        let tart = try TartController(configuredPath: "/bin/sh", shell: shell, softnet: false)
        do {
            _ = try await tart.list()
            XCTFail("an unreadable listing must throw")
        } catch let error as TartError {
            XCTAssertTrue(error.localizedDescription.contains("could not read the output"), "\(error)")
        }
    }

    func testTartListParsing() {
        let output = """
            tahoe-base\tghcr.io/cirruslabs/macos-tahoe-base:latest\trunning\t4\t8\t64
            kinhin-1717-abc\ttahoe-base\tsuspended\t2\t4\t64
            """
        let vms = TartController.parseList(output)
        XCTAssertEqual(vms.count, 2)
        XCTAssertEqual(vms[0].name, "tahoe-base")
        XCTAssertEqual(vms[0].status, "running")
        XCTAssertEqual(vms[0].cpu, 4)
        XCTAssertEqual(vms[1].memoryMB, 4096)
    }

    func testIPv4Validation() {
        XCTAssertTrue(TartController.isValidIPv4("192.168.64.3"))
        XCTAssertFalse(TartController.isValidIPv4("999.1.1.1"))
        XCTAssertFalse(TartController.isValidIPv4("abc"))
        XCTAssertFalse(TartController.isValidIPv4("1.2.3"))
    }
}
