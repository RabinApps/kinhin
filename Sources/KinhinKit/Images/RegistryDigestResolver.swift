import Foundation

/// Answers with the digest a registry currently serves for an image
/// reference (the `sha256:…` part). Injectable seam for the pin flow —
/// `RegistryDigestResolver` is the production implementation.
public protocol DigestResolving: Sendable {
    func resolveDigest(_ reference: String) async throws -> String
}

/// Resolves an OCI image reference to the digest the registry currently
/// serves for it, so a `base_image:` can be pinned to the reproducible
/// `ref@sha256:…` form (`kinhin image digest ghcr.io/cirruslabs/ubuntu:latest`).
///
/// Speaks the Docker Registry HTTP API v2 with the anonymous-pull flow
/// (token → HEAD manifest) — enough for the public Cirrus Labs images and
/// any other public registry; private registries need credentials kinhin
/// deliberately never handles (the tart CLI already supports `@sha256:`
/// references natively).
public struct RegistryDigestResolver: DigestResolving, Sendable {
    /// The registry API root for the reference's host. ghcr.io serves both
    /// the API and the token endpoint on the same host.
    let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 15
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Reference parsing

    struct Reference {
        let host: String
        let repository: String
        let tag: String
    }

    /// Splits `ghcr.io/cirruslabs/ubuntu:latest` into host, repository, and
    /// tag (default `latest`, like docker). The pinned form (`…@sha256:…`)
    /// has nothing to resolve and is rejected here — resolvers are for
    /// discovering digests, not re-reading them.
    static func parse(_ reference: String) throws -> Reference {
        guard !reference.contains("@") else {
            throw ImageError.malformedVersionFeed(
                feed: reference, reason: "already digest-pinned — there is nothing to resolve")
        }
        let parts = reference.split(separator: ":", maxSplits: 1).map(String.init)
        let hostAndRepo: String
        let tag: String
        if parts.count == 2 {
            hostAndRepo = parts[0]
            tag = parts[1]
        } else {
            hostAndRepo = reference
            tag = "latest"
        }
        // One slash at minimum: host/repository (the short docker-style
        // names that would need an implicit docker.io are not accepted).
        guard let hostEnd = hostAndRepo.firstIndex(of: "/") else {
            throw ImageError.malformedVersionFeed(feed: reference, reason: "expected <registry>/<repo>:<tag>")
        }
        return Reference(
            host: String(hostAndRepo[..<hostEnd]),
            repository: String(hostAndRepo[hostAndRepo.index(after: hostEnd)...]),
            tag: tag)
    }

    // MARK: - Resolution

    /// The `sha256:…` digest the registry currently serves for `reference`.
    /// Throws `ImageError.malformedVersionFeed` for an unreachable registry
    /// or an unusable answer (feed: the reference, reason: what failed) —
    /// the same error family the runner-version feeds use.
    public func resolveDigest(_ reference: String) async throws -> String {
        let ref = try Self.parse(reference)
        let token = try await anonymousToken(host: ref.host, repository: ref.repository)
        return try await manifestDigest(host: ref.host, repository: ref.repository, tag: ref.tag, token: token)
    }

    /// `POST /v2/auth` on ghcr.io mints a short-lived anonymous pull token
    /// scoped to the repository. (docker.io would use auth.docker.io/token.)
    private func anonymousToken(host: String, repository: String) async throws -> String {
        guard
            let url = URL(string: "https://\(host)/token?service=ghcr.io&scope=repository:\(repository):pull")
        else {
            throw ImageError.malformedVersionFeed(feed: host, reason: "token URL did not parse")
        }
        struct Payload: Decodable { let token: String }
        // Every registry-side failure is surfaced as the resolver's error
        // family, with the *user's reference* as the feed — callers match on
        // ImageError and the messages name what they asked about.
        let data: Data
        let status: Int
        do {
            (data, status) = try await get(url: url, accept: nil)
        } catch {
            throw ImageError.malformedVersionFeed(
                feed: "\(host)/\(repository)",
                reason: "token endpoint unreachable: \(error.localizedDescription)")
        }
        guard (200...299).contains(status) else {
            throw ImageError.malformedVersionFeed(
                feed: "\(host)/\(repository)", reason: "token endpoint answered HTTP \(status)")
        }
        // An undecodable token reply throws below with the same "no token" reason.
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data), !payload.token.isEmpty else {
            throw ImageError.malformedVersionFeed(
                feed: "\(host)/\(repository)", reason: "token endpoint returned no token")
        }
        return payload.token
    }

    /// `HEAD /v2/<repo>/manifests/<tag>` with the token; the `Docker-Content-Digest`
    /// response header carries the digest. HEAD keeps the (potentially
    /// multi-hundred-MB) manifest body and its layers out of the transfer.
    private func manifestDigest(host: String, repository: String, tag: String, token: String) async throws -> String {
        guard let url = URL(string: "https://\(host)/v2/\(repository)/manifests/\(tag)") else {
            throw ImageError.malformedVersionFeed(feed: "\(host)/\(repository)", reason: "manifest URL did not parse")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.oci.image.index.v1+json", forHTTPHeaderField: "Accept")
        request.setValue("Kinhin/1.0", forHTTPHeaderField: "User-Agent")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ImageError.malformedVersionFeed(
                feed: "\(host)/\(repository):\(tag)", reason: "registry answer was not HTTP")
        }
        guard (200...299).contains(http.statusCode) else {
            throw ImageError.malformedVersionFeed(
                feed: "\(host)/\(repository):\(tag)", reason: "registry answered HTTP \(http.statusCode)")
        }
        if let digest = http.value(forHTTPHeaderField: "Docker-Content-Digest"), digest.hasPrefix("sha256:") {
            return digest
        }
        throw ImageError.malformedVersionFeed(
            feed: "\(host)/\(repository):\(tag)", reason: "registry did not report a Docker-Content-Digest header")
    }

    /// Transport-only fetch: returns the body and status. Only transport
    /// failures throw — callers decide what a status means for their stage.
    private func get(url: URL, accept: String?) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        request.setValue("Kinhin/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http.statusCode)
    }
}
