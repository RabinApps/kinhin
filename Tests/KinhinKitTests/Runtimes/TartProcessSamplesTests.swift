import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The guest's usage comes from the Virtualization host process, not the
/// `tart run` client: on recent macOS the client is a near-empty stub whose
/// RSS and CPU barely move, so sampling it shows frozen numbers.
final class TartProcessSamplesTests: XCTestCase {
    /// `ps -axo pid=,rss=,time=,command=` — a stub client and its host.
    private let clientRow =
        "     81013   39632   0:01.32 /opt/homebrew/bin/tart run --no-graphics --net-softnet kinhin-1-a"
    private let hostRow =
        "     81017 9868240  13:13.32 /System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"

    func testParsesTheTartClientAndSkipsOtherProcesses() {
        let text = """
            \(clientRow)
                 81016   51200   0:10.00 /opt/homebrew/bin/tart run --no-graphics other-vm
                   7    1024   0:00.10 /usr/bin/ssh kinhin-1-a
            \(hostRow)
            """
        let lines = TartController.parseProcessLines(text)
        XCTAssertEqual(lines.count, 4, "every well-formed line parses, the host included")
        let clients = TartController.tartClients(lines, names: ["kinhin-1-a"])
        XCTAssertEqual(Array(clients.keys), ["kinhin-1-a"], "only a wanted tart run client counts")
        let samples = TartController.preferredSamples(clients: clients, hosts: [:])
        XCTAssertEqual(samples, ["kinhin-1-a": ProcessSample(rssMB: 38, cpuSeconds: 1.32)])
    }

    func testTheHostIsFoundThroughTheDiskItHolds() {
        let lines = TartController.parseProcessLines(clientRow + "\n" + hostRow)
        let clients = TartController.tartClients(lines, names: ["kinhin-1-a"])
        let disk = TartController.diskImage(for: "kinhin-1-a", tartHome: "/tmp/tart-home")
        XCTAssertEqual(disk, "/tmp/tart-home/vms/kinhin-1-a/disk.img")
        // lsof -Fpn: both the client and the host hold the disk.
        let holders = TartController.diskHolders(
            from: "p81017\nn\(disk)\np81013\nn\(disk)\n",
            disks: ["kinhin-1-a": disk])
        XCTAssertEqual(holders["kinhin-1-a"], [81017, 81013])
        let host = TartController.virtualMachineHost(holders["kinhin-1-a"] ?? [], lines: lines)
        XCTAssertEqual(host?.pid, 81017, "the Virtualization XPC process hosts the guest")
        let samples = TartController.preferredSamples(clients: clients, hosts: ["kinhin-1-a": host!])
        XCTAssertEqual(samples["kinhin-1-a"]?.rssMB, 9636, "9,868,240 KiB of guest + host overhead")
        XCTAssertEqual(samples["kinhin-1-a"]?.cpuSeconds, 793.32)
    }

    func testFallsBackToTheClientWhenNoHolderIsAHost() {
        // Older systems host the guest in the client itself: the only pid
        // holding the disk is the tart run line, which is then the answer.
        let lines = TartController.parseProcessLines(clientRow)
        let clients = TartController.tartClients(lines, names: ["kinhin-1-a"])
        let disk = TartController.diskImage(for: "kinhin-1-a", tartHome: "/tmp/tart-home")
        let holders = TartController.diskHolders(from: "p81013\nn\(disk)\n", disks: ["kinhin-1-a": disk])
        XCTAssertNil(TartController.virtualMachineHost(holders["kinhin-1-a"] ?? [], lines: lines))
        let samples = TartController.preferredSamples(clients: clients, hosts: [:])
        XCTAssertEqual(samples["kinhin-1-a"], ProcessSample(rssMB: 38, cpuSeconds: 1.32))
    }

    func testDiskImageFollowsTartHome() {
        XCTAssertEqual(TartController.diskImage(for: "vm", tartHome: "/custom"), "/custom/vms/vm/disk.img")
        XCTAssertTrue(
            TartController.diskImage(for: "vm", tartHome: nil).hasSuffix("/.tart/vms/vm/disk.img"),
            "no TART_HOME: tart's default home")
    }

    func testProcessSamplesPrefersTheHostEndToEnd() async throws {
        let shell = FakeShell()
        let disk = TartController.diskImage(for: "kinhin-1-a")
        shell.scriptedResponses = [
            ScriptedResponse(
                whenContains: "pid=,rss=,time=,command=",
                ShellResult(exitCode: 0, stdout: clientRow + "\n" + hostRow + "\n", stderr: "")),
            // lsof exits nonzero as soon as one of several paths is unheld;
            // its stdout still carries the mapping and must be parsed.
            ScriptedResponse(
                whenContains: "lsof",
                ShellResult(exitCode: 1, stdout: "p81017\nn\(disk)\np81013\nn\(disk)\n", stderr: "lsof: stat")),
        ]
        let tart = try TartController(configuredPath: "/bin/sh", shell: shell)
        let samples = try await tart.processSamples(of: ["kinhin-1-a"])
        XCTAssertEqual(samples["kinhin-1-a"], ProcessSample(rssMB: 9636, cpuSeconds: 793.32))
    }

    func testProcessSamplesFallsBackWhenLsofFindsNothing() async throws {
        let shell = FakeShell()
        shell.scriptedResponses = [
            ScriptedResponse(
                whenContains: "pid=,rss=,time=,command=",
                ShellResult(exitCode: 0, stdout: clientRow + "\n", stderr: "")),
            ScriptedResponse(whenContains: "lsof", ShellResult(exitCode: 1, stdout: "", stderr: "")),
        ]
        let tart = try TartController(configuredPath: "/bin/sh", shell: shell)
        let samples = try await tart.processSamples(of: ["kinhin-1-a"])
        XCTAssertEqual(samples["kinhin-1-a"], ProcessSample(rssMB: 38, cpuSeconds: 1.32))
    }

    func testParsesCPUTimeFormats() {
        XCTAssertEqual(TartController.parseCPUTime("0:01.50"), 1.5)
        XCTAssertEqual(TartController.parseCPUTime("1:00:00"), 3600)
        XCTAssertEqual(TartController.parseCPUTime("1-00:00:00"), 86400)
        XCTAssertNil(TartController.parseCPUTime("n/a"))
    }
}
