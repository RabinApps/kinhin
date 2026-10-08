import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class ContainerStatsTests: XCTestCase {
    func testParsesDockerStats() {
        let text = """
            {"Name":"kinhin-1-a","CPUPerc":"12.50%","MemUsage":"512MiB / 2GiB"}
            warning: not json
            {"Name":"db","CPUPerc":"0.00%","MemUsage":"1.5GiB / 8GiB"}
            """
        let stats = ContainerManager.parseDockerStats(text)
        XCTAssertEqual(stats["kinhin-1-a"], ResourceUsage(cpuPercent: 12.5, memoryUsedMB: 512, memoryLimitMB: 2048))
        XCTAssertEqual(stats["db"]?.memoryUsedMB, 1536)
        XCTAssertEqual(stats.count, 2)
    }

    func testParsesAppleStatsMemoryOnly() {
        let text = #"[{"id":"kinhin-2","memoryUsageBytes":1073741824,"memoryLimitBytes":4294967296}]"#
        let stats = ContainerManager.parseAppleStats(text)
        XCTAssertEqual(stats["kinhin-2"], ResourceUsage(cpuPercent: nil, memoryUsedMB: 1024, memoryLimitMB: 4096))
    }

    func testParsesAppleCPUCounters() {
        let text = """
            [{"id":"kinhin-2","cpuUsageUsec":2500000,"memoryUsageBytes":1073741824},
             {"id":"no-counter","memoryUsageBytes":42}]
            """
        let counters = ContainerManager.parseAppleCPUSeconds(text)
        XCTAssertEqual(counters["kinhin-2"], 2.5, "microseconds → seconds")
        XCTAssertNil(counters["no-counter"], "a row without the field is skipped")
    }

    func testAppleStatsWithCountersPairsUsageAndCounter() async throws {
        let shell = FakeShell()
        shell.defaultResult = ShellResult(
            exitCode: 0,
            stdout:
                #"[{"id":"kinhin-2","memoryUsageBytes":1073741824,"memoryLimitBytes":4294967296,"cpuUsageUsec":5000000}]"#,
            stderr: "")
        let stats = try await ContainerManager(tool: .appleContainer, shell: shell, binary: "/usr/bin/container")
            .statsWithCounters()
        XCTAssertEqual(
            stats["kinhin-2"]?.usage, ResourceUsage(cpuPercent: nil, memoryUsedMB: 1024, memoryLimitMB: 4096))
        XCTAssertEqual(stats["kinhin-2"]?.cpuSeconds, 5)
    }

    func testMalformedStatsReadAsEmpty() {
        XCTAssertTrue(ContainerManager.parseDockerStats("garbage").isEmpty)
        XCTAssertTrue(ContainerManager.parseAppleStats("").isEmpty)
    }

    func testMegabytesParsing() {
        XCTAssertEqual(ContainerManager.megabytes(fromSize: "2GiB"), 2048)
        XCTAssertEqual(ContainerManager.megabytes(fromSize: "256KiB"), 0)
        XCTAssertNil(ContainerManager.megabytes(fromSize: "lots"))
    }

    func testStatsRunsDockerStats() async throws {
        let shell = FakeShell()
        shell.defaultResult = ShellResult(
            exitCode: 0, stdout: #"{"Name":"a","CPUPerc":"1%","MemUsage":"1MiB / 2MiB"}"#, stderr: "")
        let stats = try await ContainerManager(tool: .docker, shell: shell, binary: "/usr/bin/docker").stats()
        XCTAssertEqual(stats["a"]?.cpuPercent, 1)
        XCTAssertTrue(shell.calls.first?.contains("stats") ?? false)
    }
}
