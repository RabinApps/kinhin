import Foundation
import Synchronization

/// The tart VM images Cirrus Labs publishes (the quick-start's "VM images"
/// list) — the pre-configured choices for what `image prepare` starts from
/// and what `image prepare --linux --from` clones. All of them ship the
/// `admin`/`admin` credentials and trust Tart's generated SSH key, so
/// kinhin's agent bake works on them out of the box.
public enum TartBaseImage {
    /// The default macOS bake source (matches `ImagePreparer.defaultSource`).
    public static let defaultReference = ImagePreparer.defaultSource

    /// The digest resolver a ``pin(request:)`` uses. Injectable so tests can
    /// stub the registry answer (the default asks the real registry).
    public static var digestResolver: (any DigestResolving)? {
        get { digestResolverStorage.withLock { $0 } }
        set { digestResolverStorage.withLock { $0 = newValue } }
    }
    private static let digestResolverStorage = Mutex<(any DigestResolving)?>(nil)

    /// Images the install scripts are exercised against, for the pickers:
    /// every macOS series the quick-start lists in its three flavors, plus
    /// the Linux bases (Debian/Ubuntu-based only — kinhin's install scripts
    /// need apt-get; Fedora is listed because the docs do, but a bake on it
    /// needs its own scripts).
    public static let curated: [(title: String, reference: String)] = [
        ("macOS 26 Tahoe (base)", "ghcr.io/cirruslabs/macos-tahoe-base:latest"),
        ("macOS 26 Tahoe (vanilla)", "ghcr.io/cirruslabs/macos-tahoe-vanilla:latest"),
        ("macOS 26 Tahoe (Xcode)", "ghcr.io/cirruslabs/macos-tahoe-xcode:latest"),
        ("macOS 15 Sequoia (base)", "ghcr.io/cirruslabs/macos-sequoia-base:latest"),
        ("macOS 15 Sequoia (vanilla)", "ghcr.io/cirruslabs/macos-sequoia-vanilla:latest"),
        ("macOS 15 Sequoia (Xcode)", "ghcr.io/cirruslabs/macos-sequoia-xcode:latest"),
        ("macOS 14 Sonoma (base)", "ghcr.io/cirruslabs/macos-sonoma-base:latest"),
        ("macOS 14 Sonoma (vanilla)", "ghcr.io/cirruslabs/macos-sonoma-vanilla:latest"),
        ("macOS 14 Sonoma (Xcode)", "ghcr.io/cirruslabs/macos-sonoma-xcode:latest"),
        ("Ubuntu (latest)", "ghcr.io/cirruslabs/ubuntu:latest"),
        ("Debian (latest)", "ghcr.io/cirruslabs/debian:latest"),
        ("Fedora (latest)", "ghcr.io/cirruslabs/fedora:latest"),
    ]

    /// Why `reference` can't be used as a tart source, or nil when it's
    /// acceptable. It ends up in a `tart clone`/`tart pull` argv, so anything
    /// that could be read as an option or that splits into several arguments
    /// is rejected — same rules as `LinuxBaseImage.problem(with:)`. A
    /// `@sha256:` suffix is validated for shape (64 lowercase hex chars).
    public static func problem(with reference: String) -> String? {
        if reference.isEmpty { return "must not be empty" }
        if reference.hasPrefix("-") { return "must not start with '-'" }
        if reference.contains(where: \.isWhitespace) { return "must not contain spaces" }
        return digestProblem(in: reference)
    }

    /// The local name kinhin prepares a reference under: the path's last
    /// component without its tag (`…/macos-sequoia-base:latest` →
    /// `macos-sequoia-base`). This is the config `image:` value a prepare
    /// bakes for that source.
    public static func shortName(for reference: String) -> String {
        let withoutTag = reference.split(separator: ":", maxSplits: 1).first.map(String.init) ?? reference
        return withoutTag.split(separator: "/").last.map(String.init) ?? withoutTag
    }

    /// The curated reference whose prepared name is `name`, or nil when
    /// `name` isn't one of them (a custom target name a user chose).
    public static func reference(forShortName name: String) -> String? {
        curated.first { shortName(for: $0.reference) == name }?.reference
    }

    /// Whether `reference` is a source a bake can clone today: a curated
    /// pre-configured image or the default macOS source, either possibly
    /// pinned to a digest (`ref@sha256:…`). Anything else must exist as a
    /// local VM (doctor and the checklist say so when it doesn't — the
    /// failure mode they flag is a typo'd or renamed registry reference,
    /// which would otherwise only surface as a mid-prepare clone failure).
    public static func isKnownSource(_ reference: String) -> Bool {
        if reference.hasSuffix("@sha256:") { return false }  // empty digest is never valid
        return isKnownSourceUnpinned(pinnedDigestSuffix(reference))
    }

    /// The unpinned base of `reference` (the part before `@sha256:`), or
    /// `reference` itself when it carries no digest.
    public static func pinnedDigestSuffix(_ reference: String) -> String {
        guard let range = reference.range(of: "@sha256:") else { return reference }
        return String(reference[..<range.lowerBound])
    }

    /// The digest of a digest-pinned reference (`ref@sha256:…` → the
    /// `sha256:…` part), or nil when the reference is not pinned.
    public static func digestSuffix(_ reference: String) -> String? {
        guard let range = reference.range(of: "@sha256:") else { return nil }
        return String(reference[reference.index(after: range.lowerBound)...])
    }

    /// Whether `reference` pins a digest — the reproducible form.
    public static func isDigestPinned(_ reference: String) -> Bool {
        digestSuffix(reference) != nil
    }

    /// Whether the reference's mutable tag makes every bake potentially
    /// different from the last: a `:latest` tag (including the curated
    /// references, which all ship `:latest`) or no tag at all. Digest-pinned
    /// references are never mutable.
    public static func isMutableTag(_ reference: String) -> Bool {
        if isDigestPinned(reference) { return false }
        let base = pinnedDigestSuffix(reference)
        return !base.contains(":") || base.hasSuffix(":latest")
    }

    /// The one-line drift warning for a mutable reference, or nil when it is
    /// digest-pinned (or nil/empty — absent `base_image:` is the default and
    /// is never nagged about). The fleet-start log, the doctor surfaces, and
    /// the checklist row all render this, so the wording lives in one place.
    public static func mutableTagWarning(for reference: String?) -> String? {
        guard let reference, isMutableTag(reference) else { return nil }
        return
            "tag is mutable (\(pinnedDigestSuffix(reference))) — bakes may drift; pin a digest with `kinhin image digest \(pinnedDigestSuffix(reference))`"
    }

    /// Validates the digest half of a pinned reference. Valid is `sha256:`
    /// followed by exactly 64 lowercase hex characters. Returns the problem
    /// ("must …") or nil when acceptable — used by `problem(with:)` so a
    /// malformed digest is rejected at parse time, before any bake runs.
    public static func digestProblem(in reference: String) -> String? {
        guard let digest = digestSuffix(reference) else { return nil }
        let hex = digest.dropFirst("sha256:".count)
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit), hex == hex.lowercased() else {
            return "must end with a sha256 digest of 64 lowercase hex characters (sha256:<hex>)"
        }
        return nil
    }

    // MARK: - Digest pinning

    /// One resolve-and-pin request: the unpinned reference to resolve, and
    /// whether the registry should be asked at all.
    public struct PinRequest: Sendable, Equatable {
        /// The reference as typed (an unpinned registry reference).
        public let reference: String
        /// Run the resolver (true), or store the reference as-is — the
        /// cancel path, which must not touch the network.
        public let resolve: Bool

        public init(reference: String, resolve: Bool) {
            self.reference = reference
            self.resolve = resolve
        }
    }

    /// The outcome of a pin request: the reference to store and what the
    /// user should be told about it.
    public struct PinResult: Sendable, Equatable {
        /// The reference to store in `base_image:` — digest-pinned when the
        /// resolver answered.
        public let reference: String
        /// True when the stored reference carries a resolved digest.
        public let pinned: Bool
        /// One-line status for the UI (what was pinned, or why not).
        public let message: String
    }

    /// Resolves `request.reference` against its registry and returns the
    /// digest-pinned form. Purely a registry round trip: nothing is written
    /// and no config is read, so callers keep full control of persistence —
    /// and the same helper serves the picker, a future CLI flag, or tests.
    /// Throws when the registry cannot be asked or answers unusably
    /// (`ImageError.malformedVersionFeed`), or `CancellationError` if the
    /// surrounding task is cancelled.
    public static func pin(_ request: PinRequest, resolver: (any DigestResolving)? = nil) async throws -> PinResult {
        guard request.resolve else {
            return PinResult(
                reference: request.reference, pinned: false,
                message: "Left unpinned — bakes use whatever the registry serves for \(request.reference)")
        }
        let resolved = try await (resolver ?? digestResolver ?? RegistryDigestResolver()).resolveDigest(
            request.reference)
        let pinned = "\(request.reference)@\(resolved)"
        return PinResult(reference: pinned, pinned: true, message: "Pinned to \(resolved)")
    }

    private static func isKnownSourceUnpinned(_ unpinned: String) -> Bool {
        unpinned == defaultReference || curated.contains { $0.reference == unpinned }
    }

    /// What `image prepare` should use given the config's prepared image
    /// name: a curated name keeps its published source (or its digest-pinned
    /// form, verbatim — the pin must survive the round trip); anything else
    /// (a hand-picked target, or a VM created via `--linux`) starts from the
    /// default macOS source and keeps the name as the target.
    public static func resolveSource(preparedName: String) -> String {
        if isDigestPinned(preparedName) { return preparedName }
        return reference(forShortName: preparedName) ?? defaultReference
    }
}
