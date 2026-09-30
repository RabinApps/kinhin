import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The registry digest resolver: reference parsing, and the anonymous-token
/// → HEAD-manifest flow against a URLProtocol-stubbed registry. The digest
/// answer is what `base_image:` pinning and `kinhin image digest` stand on.
final class RegistryDigestResolverTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    private func makeResolver() -> RegistryDigestResolver {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return RegistryDigestResolver(session: URLSession(configuration: config))
    }

    private static let digest = "sha256:\(String(repeating: "9f", count: 32))"

    /// The whole anonymous flow: the token endpoint is hit first, then the
    /// manifest HEAD, and the digest comes from the response header.
    func testResolveDigestMintsATokenThenHeadsTheManifest() async throws {
        let manifestPaths = Mutex<[String]>([])
        let authHeaders = Mutex<[String]>([])
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/token" {
                return (200, Data(#"{"token":"anon-123"}"#.utf8), [:])
            }
            if path == "/v2/cirruslabs/ubuntu/manifests/latest" {
                authHeaders.withLock { $0.append(request.value(forHTTPHeaderField: "Authorization") ?? "") }
                manifestPaths.withLock { $0.append(request.httpMethod ?? "?") }
                var headers: [String: String] = [:]
                headers["Docker-Content-Digest"] = Self.digest
                return (200, Data(), headers)
            }
            return (404, Data(), [:])
        }

        let digest = try await makeResolver().resolveDigest("ghcr.io/cirruslabs/ubuntu:latest")
        XCTAssertEqual(digest, Self.digest)
        XCTAssertEqual(manifestPaths.withLock { $0 }, ["HEAD"], "the manifest is probed with HEAD, not GET")
        XCTAssertEqual(
            authHeaders.withLock { $0 }, ["Bearer anon-123"], "the anonymous token authorizes the manifest HEAD")
    }

    func testRegistryErrorsSurfaceWithTheReferenceAndReason() async {
        StubProtocol.handler = { _ in (404, Data(), [:]) }
        do {
            _ = try await makeResolver().resolveDigest("ghcr.io/cirruslabs/missing:latest")
            XCTFail("expected the 404 registry to throw")
        } catch let error as ImageError {
            guard case .malformedVersionFeed(let feed, let reason) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(feed, "ghcr.io/cirruslabs/missing", "the failing reference, not the bare host")
            XCTAssertTrue(reason.contains("404"), reason)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testAMissingDigestHeaderIsAnErrorNotAGuess() async throws {
        // Token minting succeeds; the manifest HEAD answers without the header.
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/token" { return (200, Data(#"{"token":"anon"}"#.utf8), [:]) }
            if path.hasPrefix("/v2/") { return (200, Data(), [:]) }
            return (404, Data(), [:])
        }
        do {
            _ = try await makeResolver().resolveDigest("ghcr.io/cirruslabs/ubuntu:latest")
            XCTFail("a registry that withholds the digest header must not resolve")
        } catch let error as ImageError {
            guard case .malformedVersionFeed(_, let reason) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertTrue(reason.contains("Docker-Content-Digest"), reason)
        }
    }

    // MARK: - Reference parsing

    func testReferenceParsing() throws {
        let tagged = try RegistryDigestResolver.parse("ghcr.io/cirruslabs/ubuntu:24.04")
        XCTAssertEqual(tagged.host, "ghcr.io")
        XCTAssertEqual(tagged.repository, "cirruslabs/ubuntu")
        XCTAssertEqual(tagged.tag, "24.04")

        let untagged = try RegistryDigestResolver.parse("ghcr.io/cirruslabs/ubuntu")
        XCTAssertEqual(untagged.tag, "latest", "an untagged reference resolves latest, like docker")
    }

    func testParsingRejectsUnusableReferences() {
        // Digest-pinned references have nothing to resolve; short forms have
        // no registry host.
        for bad in ["ghcr.io/cirruslabs/ubuntu:latest@sha256:\(String(repeating: "0", count: 64))", "ubuntu"] {
            XCTAssertThrowsError(try RegistryDigestResolver.parse(bad)) { error in
                guard case ImageError.malformedVersionFeed(_, let reason) = error else {
                    return XCTFail("wrong error: \(error)")
                }
                XCTAssertFalse(reason.isEmpty)
            }
        }
    }
}
