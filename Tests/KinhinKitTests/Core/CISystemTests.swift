import Foundation
import XCTest

@testable import KinhinKit

final class CISystemTests: XCTestCase {
    func testRemoteHostsNameTheirSystem() {
        let cases: [(String, CISystem?)] = [
            ("https://github.com/acme/app.git", .github),
            ("git@github.com:acme/app.git", .github),
            ("https://acme.ghe.com/acme/app.git", .github),
            ("git@gitlab.com:acme/app.git", .gitlab),
            ("https://gitlab.acme.internal/mobile/app", .gitlab),
            ("ssh://git@gitea.acme.dev:2222/acme/app.git", .gitea),
            ("https://codeberg.org/acme/app.git", .forgejo),
            ("git@bitbucket.org:acme/app.git", .bitbucket),
            ("https://acme@dev.azure.com/acme/app/_git/app", .azure),
            ("git@ssh.dev.azure.com:v3/acme/app/app", .azure),
            ("https://git.acme.dev/acme/app.git", nil),
        ]
        for (url, expected) in cases {
            XCTAssertEqual(CISystem.fromRemote(url), expected, url)
        }
    }

    func testOriginURLIsReadFromTheOriginSectionOnly() {
        let config = """
            [core]
            \trepositoryformatversion = 0
            [remote "upstream"]
            \turl = https://github.com/upstream/app.git
            [remote "origin"]
            \turl = git@gitlab.com:acme/app.git
            \tfetch = +refs/heads/*:refs/remotes/origin/*
            """
        XCTAssertEqual(CISystem.originURL(gitConfig: config), "git@gitlab.com:acme/app.git")
        XCTAssertNil(CISystem.originURL(gitConfig: "[core]\n\tbare = false\n"))
    }

    func testDetectionPrefersHostIndependentFilesThenTheRemoteThenFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ci-detect-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func make(_ path: String, _ text: String = "") throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(CISystem.detect(repositoryRoot: root), .github, "nothing says: GitHub")
        try make(".gitea/workflows/ci.yml")
        XCTAssertEqual(CISystem.detect(repositoryRoot: root), .gitea)
        try make(".git/config", "[remote \"origin\"]\n\turl = https://gitlab.com/acme/app.git\n")
        XCTAssertEqual(CISystem.detect(repositoryRoot: root), .gitlab, "the remote's host wins over workflow files")
        try make(".buildkite/pipeline.yml")
        XCTAssertEqual(CISystem.detect(repositoryRoot: root), .buildkite, "Buildkite runs on any host")
    }
}
