import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The release-feed resolver: a feed that answers with an unusable payload
/// (undecodable JSON, malformed tag) must be distinguishable from "no data" —
/// the `latest*` lookups throw `ImageError.malformedVersionFeed` while
/// `resolve()` keeps degrading every failure to the pinned versions.
final class RunnerVersionResolverTests: XCTestCase {
    private func resolverWithStub(_ handler: @escaping StubHandler) -> RunnerVersionResolver {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        StubProtocol.handler = handler
        return RunnerVersionResolver(session: URLSession(configuration: config))
    }

    override func tearDown() {
        StubProtocol.handler = nil
    }

    /// A feed answering garbage (valid HTTP, undecodable body) must throw
    /// instead of silently reading as "no data".
    func testMalformedPayloadThrowsFromLatestLookups() async {
        let resolver = resolverWithStub { _ in (200, Data("<html>not json</html>".utf8), [:]) }

        await XCTAssertThrowsErrorAsync(try await resolver.latestGitHub()) { error in
            guard case ImageError.malformedVersionFeed(let feed, _) = error else {
                return XCTFail("expected ImageError.malformedVersionFeed, got \(error)")
            }
            XCTAssertEqual(feed, "GitHub")
        }
        await XCTAssertThrowsErrorAsync(try await resolver.latestGitea()) { error in
            guard case ImageError.malformedVersionFeed(let feed, _) = error else {
                return XCTFail("expected ImageError.malformedVersionFeed, got \(error)")
            }
            XCTAssertEqual(feed, "Gitea")
        }
        await XCTAssertThrowsErrorAsync(try await resolver.latestGitLab()) { error in
            guard case ImageError.malformedVersionFeed(let feed, _) = error else {
                return XCTFail("expected ImageError.malformedVersionFeed, got \(error)")
            }
            XCTAssertEqual(feed, "GitLab")
        }
    }

    /// A well-formed tag that is not a stable version (no `v` prefix, no dot,
    /// or a GitLab pre-release dash) is a malformed answer too, not nil.
    func testMalformedTagsThrowFromLatestLookups() async {
        let tags = ["api.github.com": "v2", "gitea.com": "latest", "gitlab.com": "v19.5.0-rc1"]
        let resolver = resolverWithStub { request in
            let host = request.url?.host ?? ""
            return (200, Data("{\"tag_name\":\"\(tags[host] ?? "v0.0.0")\"}".utf8), [:])
        }

        await XCTAssertThrowsErrorAsync(try await resolver.latestGitHub(), "tag 'v2' lacks a dot") { error in
            guard case ImageError.malformedVersionFeed = error else {
                return XCTFail("expected ImageError.malformedVersionFeed, got \(error)")
            }
        }
        await XCTAssertThrowsErrorAsync(try await resolver.latestGitea(), "tag 'latest' lacks the v prefix") { error in
            guard case ImageError.malformedVersionFeed = error else {
                return XCTFail("expected ImageError.malformedVersionFeed, got \(error)")
            }
        }
        await XCTAssertThrowsErrorAsync(try await resolver.latestGitLab(), "pre-release tag 'v19.5.0-rc1'") { error in
            guard case ImageError.malformedVersionFeed = error else {
                return XCTFail("expected ImageError.malformedVersionFeed, got \(error)")
            }
        }
    }

    /// Buildkite's feed shares GitHub's API host; its betas are not stable.
    func testBuildkiteFeedReadsTheAgentRepoAndSkipsBetas() async throws {
        let stable = resolverWithStub { request in
            XCTAssertEqual(request.url?.path, "/repos/buildkite/agent/releases/latest")
            return (200, Data(#"{"tag_name":"v4.0.9"}"#.utf8), [:])
        }
        let version = try await stable.latestBuildkite()
        XCTAssertEqual(version, "4.0.9")

        let beta = resolverWithStub { _ in (200, Data(#"{"tag_name":"v4.1.0-beta.1"}"#.utf8), [:]) }
        await XCTAssertThrowsErrorAsync(try await beta.latestBuildkite(), "beta tag") { error in
            guard case ImageError.malformedVersionFeed(let feed, _) = error else {
                return XCTFail("expected ImageError.malformedVersionFeed, got \(error)")
            }
            XCTAssertEqual(feed, "Buildkite")
        }
    }

    func testAzureFeedReadsTheAgentRepo() async throws {
        let resolver = resolverWithStub { request in
            XCTAssertEqual(request.url?.path, "/repos/microsoft/azure-pipelines-agent/releases/latest")
            return (200, Data(#"{"tag_name":"v5.279.0"}"#.utf8), [:])
        }
        let version = try await resolver.latestAzure()
        XCTAssertEqual(version, "5.279.0")
    }

    /// The user-facing path is unchanged by the throwing lookups: any failure
    /// (network or malformed payload) still degrades to pinned versions.
    func testResolveDegradesMalformedPayloadsToPinnedVersions() async {
        let resolver = resolverWithStub { _ in (200, Data("garbage".utf8), [:]) }

        let versions = await resolver.resolve()
        XCTAssertEqual(versions, RunnerVersionResolver.fallback)
    }

    /// The tag parser accepts the shapes each vendor publishes.
    func testStableTagParserAcceptsWellFormedTags() throws {
        XCTAssertEqual(
            try RunnerVersionResolver.stableTag(
                from: Data(#"{"tag_name":"v2.337.0"}"#.utf8), feed: "GitHub", fallback: "fb"), "2.337.0")
        XCTAssertEqual(
            try RunnerVersionResolver.stableTag(
                from: Data(#"{"tag_name":"v19.4.1"}"#.utf8), feed: "GitLab", fallback: "fb", excludesDashes: true),
            "19.4.1")
    }

    /// The tag is spliced into bake scripts and URLs: anything that is not a
    /// plain dotted version is refused, however plausible it looks.
    func testStableTagParserRejectsShellMetacharacters() {
        for tag in ["v1.$(id)", "v1.2;rm -rf ~", "v1.2 3", "v1.2`x`", "v1.2\n3", "v1.", "v.1", "1.2.3", "v1.2/../x"] {
            let payload = Data(#"{"tag_name":"\#(tag.replacingOccurrences(of: "\n", with: "\\n"))"}"#.utf8)
            XCTAssertThrowsError(
                try RunnerVersionResolver.stableTag(from: payload, feed: "GitHub", fallback: "fb"), tag)
        }
    }
}

extension XCTestCase {
    /// Small async shim so `XCTAssertThrowsError` can be awaited inline.
    fileprivate func XCTAssertThrowsErrorAsync<T>(
        _ expression: @autoclosure () async throws -> T,
        _ message: String = "expected the expression to throw",
        _ errorHandler: @escaping (Error) -> Void
    ) async {
        do {
            _ = try await expression()
            XCTFail("expected the expression to throw: \(message)")
        } catch {
            errorHandler(error)
        }
    }
}
