import XCTest

@testable import KinhinKit

/// `container.docker` and `container.flags` (#75): parsing, defaults, the flags the loader rejects because kinhin
/// sets them itself, and the editors that rewrite the whole `container:` section keeping both.
final class ContainerDockerFlagsConfigTests: XCTestCase {
    private static let head = """
        accounts:
          - name: github
            forge: github
            scope: "acme"
        labels: [self-hosted, arm64]
        container:
          image: kinhin-ci-linux

        """

    private func parse(flags: String) throws -> KinhinConfig {
        try ConfigLoader.parse("\(Self.head)  flags: \(flags)\n")
    }

    private func invalidMessage(flags: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        do {
            _ = try parse(flags: flags)
            XCTFail("expected a ConfigError for flags \(flags)", file: file, line: line)
            return ""
        } catch ConfigError.invalid(let why) {
            return why
        } catch {
            XCTFail("expected ConfigError.invalid, got \(error)", file: file, line: line)
            return ""
        }
    }

    // MARK: - Parsing

    func testBothDefaultToOff() throws {
        let cfg = try ConfigLoader.parse(Self.head)
        XCTAssertEqual(cfg.container?.docker, false)
        XCTAssertEqual(cfg.container?.flags, [])
    }

    func testParsesDockerAndFlags() throws {
        let cfg = try ConfigLoader.parse(
            "\(Self.head)  docker: true\n  flags: [\"--shm-size\", \"2g\", \"--dns\", \"1.1.1.1\"]\n")
        XCTAssertEqual(cfg.container?.docker, true)
        XCTAssertEqual(cfg.container?.flags, ["--shm-size", "2g", "--dns", "1.1.1.1"])
    }

    func testFlagsMayBeABlockList() throws {
        let cfg = try ConfigLoader.parse("\(Self.head)  flags:\n    - \"--shm-size=2g\"\n    - \"--init\"\n")
        XCTAssertEqual(cfg.container?.flags, ["--shm-size=2g", "--init"])
    }

    func testTheKeysAreKnownToTheSchema() throws {
        XCTAssertEqual(try ConfigSchema.unknownKeys(in: "container:\n  docker: true\n  flags: [\"--init\"]\n"), [])
    }

    func testTheStarterTemplateStillParses() throws {
        XCTAssertNil(try ConfigLoader.parse(ConfigLoader.template()).container)
        XCTAssertTrue(ConfigLoader.template().contains("#   docker: true"))
        XCTAssertTrue(ConfigLoader.template().contains("#   flags: [\"--shm-size\", \"2g\"]"))
    }

    // MARK: - Validation

    func testFlagsKinhinSetsItselfAreRejectedInEverySpelling() {
        let cases: [(flags: String, spelling: String)] = [
            ("[\"--name\", \"x\"]", "--name"),
            ("[\"--name=x\"]", "--name"),
            ("[\"--rm\"]", "--rm"),
            ("[\"--remove\"]", "--remove"),
            ("[\"--detach\"]", "--detach"),
            ("[\"-d\"]", "-d"),
            ("[\"--cpus\", \"2\"]", "--cpus"),
            ("[\"--cpus=2\"]", "--cpus"),
            ("[\"-c\", \"2\"]", "-c"),
            ("[\"-c2\"]", "-c"),
            ("[\"--memory\", \"4G\"]", "--memory"),
            ("[\"--memory=4G\"]", "--memory"),
            ("[\"-m\", \"4G\"]", "-m"),
            ("[\"--platform\", \"linux/amd64\"]", "--platform"),
            ("[\"--platform=linux/amd64\"]", "--platform"),
            ("[\"--arch\", \"amd64\"]", "--arch"),
            ("[\"--arch=amd64\"]", "--arch"),
            ("[\"-a\", \"amd64\"]", "-a"),
            ("[\"--os\", \"linux\"]", "--os"),
            ("[\"--os=linux\"]", "--os"),
            ("[\"--help\"]", "--help"),
            ("[\"--init\", \"--\"]", "--"),
        ]
        for (flags, spelling) in cases {
            let why = invalidMessage(flags: flags)
            XCTAssertTrue(why.contains("container.flags must not set \(spelling):"), "\(flags): \(why)")
        }
    }

    func testAManagedShortFlagGroupedWithOthersIsRejected() {
        XCTAssertTrue(invalidMessage(flags: "[\"-td\"]").contains("must not set -d:"))
        XCTAssertTrue(invalidMessage(flags: "[\"-im\", \"4G\"]").contains("must not set -m:"))
    }

    func testAManagedFlagLaterInTheListIsRejected() {
        let why = invalidMessage(flags: "[\"--shm-size\", \"2g\", \"--cpus\", \"8\"]")
        XCTAssertTrue(why.contains("must not set --cpus: kinhin sets it from cpus"), why)
    }

    func testOtherFlagsAndTheirValuesAreAccepted() throws {
        let flags = [
            "--shm-size", "2g", "--dns", "1.1.1.1", "--cap-add", "NET_ADMIN", "-e", "FOO=bar", "-it", "--init",
            "--dns-search", "example.com", "--ulimit", "nofile=65536", "--label", "cpus=8",
        ]
        let cfg = try parse(flags: "[" + flags.map { "\"\($0)\"" }.joined(separator: ", ") + "]")
        XCTAssertEqual(cfg.container?.flags, flags, "values are never checked, only options")
    }

    func testOnlyExactOptionNamesAreManaged() {
        XCTAssertNil(ConfigLoader.managedContainerRunFlag(in: "--names"))
        XCTAssertNil(ConfigLoader.managedContainerRunFlag(in: "--rmi"))
        XCTAssertNil(ConfigLoader.managedContainerRunFlag(in: "--cpuset=0"))
        XCTAssertNil(ConfigLoader.managedContainerRunFlag(in: "2g"))
        XCTAssertNil(ConfigLoader.managedContainerRunFlag(in: "-1"))
        XCTAssertEqual(ConfigLoader.managedContainerRunFlag(in: "--memory=8G")?.spelling, "--memory")
        XCTAssertEqual(ConfigLoader.managedContainerRunFlag(in: "-c=2")?.spelling, "-c")
    }

    func testEmptyElementsAreRejected() {
        XCTAssertTrue(invalidMessage(flags: "[\"--dns\", \"\"]").contains("container.flags[1] must not be empty"))
        XCTAssertTrue(invalidMessage(flags: "[\"\"]").contains("container.flags[0] must not be empty"))
    }

    func testTheFirstElementMustBeAnOption() {
        let why = invalidMessage(flags: "[\"2g\", \"--shm-size\"]")
        XCTAssertTrue(why.contains("container.flags must start with an option"), why)
        XCTAssertTrue(why.contains("\"2g\""), why)
    }

    func testControlCharactersAreRejected() {
        let why = invalidMessage(flags: "[\"--env\", \"A=1\\nB=2\"]")
        XCTAssertTrue(why.contains("container.flags[1] must not contain control characters"), why)
    }

    func testAnEmptyListIsNone() throws {
        XCTAssertEqual(try parse(flags: "[]").container?.flags, [])
    }

    // MARK: - Editors keep them

    private func file(_ yaml: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("container-flags-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.yaml")
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testTheSnapshotCarriesDockerAndFlags() throws {
        let url = try file("\(Self.head)  docker: true\n  flags: [\"--shm-size\", \"2g\"]\n")
        let container = try XCTUnwrap(ConfigStore.snapshot(at: url)?.container)
        XCTAssertEqual(container.docker, true)
        XCTAssertEqual(container.flags, ["--shm-size", "2g"])
    }

    func testContainerSectionRewritesKeepDockerAndFlags() throws {
        let flags = ["--shm-size", "2g", "--env", "QUOTE=\"a b\"", "--dns", "1.1.1.1"]
        let url = try file(
            "\(Self.head)  docker: true\n  flags: [\"--shm-size\", \"2g\", \"--env\", \"QUOTE=\\\"a b\\\"\", "
                + "\"--dns\", \"1.1.1.1\"]\n")
        XCTAssertEqual(try ConfigLoader.load(from: url).container?.flags, flags)
        _ = try GeneralConfigEditor.setBaseImage("ubuntu:24.04", for: .appleContainer, at: url)
        let cfg = try ConfigLoader.load(from: url)
        XCTAssertEqual(cfg.container?.baseImage, "ubuntu:24.04")
        XCTAssertEqual(cfg.container?.docker, true, "a container section rewrite keeps docker")
        XCTAssertEqual(cfg.container?.flags, flags, "a container section rewrite keeps flags, quotes included")
    }

    func testEditingTheContainerSectionKeepsDockerAndFlags() throws {
        let yaml = "\(Self.head)  docker: true\n  flags: [\"--init\"]\n"
        var edited = try XCTUnwrap(GeneralConfigEditor.snapshot(from: yaml).container)
        edited.cpus = 6
        let rewritten = try GeneralConfigEditor.replace(field: .container(edited), in: yaml)
        let cfg = try ConfigLoader.parse(rewritten)
        XCTAssertEqual(cfg.container?.cpus, 6)
        XCTAssertEqual(cfg.container?.docker, true, rewritten)
        XCTAssertEqual(cfg.container?.flags, ["--init"], rewritten)
    }

    func testTheSectionWriterOmitsTheKeysWhenOff() {
        let text = GeneralConfigEditor.sectionText(.init(image: "kinhin-ci-linux", cpus: 4, memoryGB: 8))
        XCTAssertFalse(text.contains("docker"), text)
        XCTAssertFalse(text.contains("flags"), text)
    }
}
