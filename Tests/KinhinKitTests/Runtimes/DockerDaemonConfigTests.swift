import XCTest

@testable import KinhinKit

/// Merging the Docker Hub cache's mirror into a runner image's `/etc/docker/daemon.json`: every other key kept, an
/// existing (stale) mirror replaced rather than kept beside it, and a file that is not a JSON object left alone.
final class DockerDaemonConfigTests: XCTestCase {
    private let mirror = "http://192.168.64.3:5000"

    private func merged(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        guard case .merged(let json) = DockerDaemonConfig.merging(mirror: mirror, into: text) else {
            XCTFail("expected a merge of:\n\(text)", file: file, line: line)
            return [:]
        }
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try XCTUnwrap(object as? [String: Any], file: file, line: line)
    }

    /// The GitHub ubuntu image's file (kinhin-github-ubuntu:24.04): mtu for the container network and a mirror at an
    /// address from an earlier setup.
    private static let githubImageFile = """
        {
          "mtu": 1280,
          "registry-mirrors": ["http://192.168.64.1:5055"]
        }
        """

    func testTheStaleMirrorIsReplacedAndTheMTUKept() throws {
        let settings = try merged(Self.githubImageFile)
        XCTAssertEqual(settings["registry-mirrors"] as? [String], [mirror], "replaced, not duplicated")
        XCTAssertEqual(settings["mtu"] as? Int, 1280)
        XCTAssertEqual(settings.count, 2)
    }

    func testAnImageWithoutAFileGetsOnlyTheMirror() throws {
        for text in ["", "  \n", "{}"] {
            let settings = try merged(text)
            XCTAssertEqual(settings["registry-mirrors"] as? [String], [mirror], "'\(text)'")
            XCTAssertEqual(settings.count, 1, "'\(text)'")
        }
    }

    func testEveryOtherKeyIsKeptAsItIs() throws {
        let text = """
            {"log-driver": "json-file", "log-opts": {"max-size": "10m"}, "debug": true, "insecure-registries": [],
             "default-address-pools": [{"base": "172.80.0.0/16", "size": 24}]}
            """
        let settings = try merged(text)
        XCTAssertEqual(settings["log-driver"] as? String, "json-file")
        XCTAssertEqual(settings["log-opts"] as? [String: String], ["max-size": "10m"])
        XCTAssertEqual(settings["debug"] as? Bool, true)
        XCTAssertEqual(settings["insecure-registries"] as? [String], [])
        XCTAssertEqual((settings["default-address-pools"] as? [[String: Any]])?.first?["size"] as? Int, 24)
        XCTAssertEqual(settings["registry-mirrors"] as? [String], [mirror])
    }

    func testTheOutputIsPrettySortedAndKeepsSlashes() throws {
        guard case .merged(let json) = DockerDaemonConfig.merging(mirror: mirror, into: Self.githubImageFile) else {
            return XCTFail("expected a merge")
        }
        XCTAssertTrue(json.contains("\"http://192.168.64.3:5000\""), "slashes are not escaped: \(json)")
        XCTAssertLessThan(
            try XCTUnwrap(json.range(of: "\"mtu\"")).lowerBound,
            try XCTUnwrap(json.range(of: "\"registry-mirrors\"")).lowerBound, "keys sorted")
        XCTAssertTrue(json.contains("\n"), "one key per line, readable in the runner")
        XCTAssertFalse(
            json.components(separatedBy: "\n").contains("KINHIN_DAEMON_JSON"),
            "no line can end the heredoc that writes it")
    }

    func testInvalidJSONIsLeftAlone() {
        guard case .invalid(let why) = DockerDaemonConfig.merging(mirror: mirror, into: "{\"mtu\": 1280,") else {
            return XCTFail("expected invalid")
        }
        XCTAssertTrue(why.contains("not valid JSON"), why)
    }

    func testATopLevelThatIsNotAnObjectIsLeftAlone() {
        for text in ["[1, 2]", "\"text\"", "42"] {
            guard case .invalid(let why) = DockerDaemonConfig.merging(mirror: mirror, into: text) else {
                XCTFail("expected invalid for \(text)")
                continue
            }
            XCTAssertFalse(why.isEmpty, text)
        }
    }
}
